import Foundation

/// Any JSON value, for MCP messages and tool arguments, whose shapes vary.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v):
            // Whole numbers go out as integers, which JSON-RPC ids and schemas expect.
            if v.rounded() == v, abs(v) < 1e15 { try c.encode(Int(v)) } else { try c.encode(v) }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? { if case .string(let v) = self { return v } else { return nil } }
    var number: Double? { if case .number(let v) = self { return v } else { return nil } }
    var int: Int? { number.map { Int($0) } }
    var bool: Bool? { if case .bool(let v) = self { return v } else { return nil } }
    var array: [JSONValue]? { if case .array(let v) = self { return v } else { return nil } }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}

/// One tool call from `Proof --mcp` to the running app.
struct AgentRequest: Codable {
    let id: Int
    let tool: String
    let arguments: JSONValue
    /// The agent app, as it named itself to the MCP server ("claude-code").
    let client: String?
}

/// The app's answer: a message for the agent, and images to show it.
struct AgentResponse: Codable {
    struct Image: Codable {
        let data: String
        let mimeType: String
    }

    let id: Int
    let ok: Bool
    let text: String
    var images: [Image] = []
}

/// How far along a tool call is, sent by the app before its answer.
struct AgentProgress: Codable {
    var event = "progress"
    let id: Int
    let progress: Double
    let total: Double?
    let message: String?
}

/// The bridge asks the app to stop a tool call, because the agent cancelled it.
struct AgentCancel: Codable {
    let cancel: Int
}

/// Writes whole lines to a file descriptor from any thread, one at a time, and stops once closed.
final class LineWriter {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    @discardableResult
    func send<T: Encodable>(_ value: T) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && AgentLink.send(value, to: fd)
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

/// The private channel between `Proof --mcp` and the running app: a Unix socket in a folder only
/// this user can open, carrying one JSON message per line.
enum AgentLink {
    static let folder: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("io.github.nickpagz.proof", isDirectory: true)
    }()

    static var socketPath: String { folder.appendingPathComponent("agent.sock").path }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        return address
    }

    /// Connects to the app's socket; nil when the app isn't listening.
    static func connect() -> Int32? {
        guard var address = address(socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        ignoreBrokenPipe(fd)
        return fd
    }

    /// Writing to a socket the other side closed fails instead of killing the process.
    static func ignoreBrokenPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Writes one message and a newline. False when the other side has gone.
    static func send<T: Encodable>(_ value: T, to fd: Int32) -> Bool {
        guard var data = try? JSONEncoder().encode(value) else { return false }
        data.append(0x0A)
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}

/// Reads newline-separated messages from a file descriptor, blocking.
final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    /// The next line without its newline, or nil at the end of the stream.
    func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return buffer
            }
            buffer.append(chunk, count: count)
        }
    }
}

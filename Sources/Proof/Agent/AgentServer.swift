import Foundation
import Observation

/// One thing an agent did, for Settings → Agents.
struct AgentActivity: Identifiable {
    let id = UUID()
    let date: Date
    let client: String
    let summary: String
}

/// Listens on `AgentLink.socketPath` while agents are allowed, and runs each request through
/// `AgentTools`. Only this user's processes can connect: the socket's folder and the socket are
/// theirs alone, and each connection's user is checked too.
@MainActor @Observable
final class AgentServer {
    private(set) var isListening = false
    private(set) var lastError: String?
    /// Newest first, this session only.
    private(set) var activity: [AgentActivity] = []

    @ObservationIgnored let tools: AgentTools
    @ObservationIgnored private var listenFD: Int32 = -1
    @ObservationIgnored private var acceptSource: DispatchSourceRead?
    @ObservationIgnored private let queue = DispatchQueue(label: "io.github.nickpagz.proof.agents")

    init(tools: AgentTools) {
        self.tools = tools
        tools.record = { [weak self] client, summary in self?.note(client: client, summary) }
    }

    func setEnabled(_ enabled: Bool) {
        enabled ? start() : stop()
    }

    private func start() {
        guard !isListening else { return }
        let path = AgentLink.socketPath
        do {
            try FileManager.default.createDirectory(at: AgentLink.folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            chmod(AgentLink.folder.path, 0o700)
        } catch {
            fail("Couldn't create \(AgentLink.folder.path): \(error.localizedDescription)")
            return
        }
        guard var address = AgentLink.address(path) else { fail("The socket path is too long: \(path)"); return }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fail("Couldn't open a socket (\(String(cString: strerror(errno))))"); return }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            fail("Couldn't listen at \(path) (\(String(cString: strerror(errno))))")
            close(fd)
            return
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            Task { @MainActor in self?.serve(client) }
        }
        source.setCancelHandler {
            close(fd)
            unlink(path)
        }
        source.resume()
        acceptSource = source
        isListening = true
        lastError = nil
        Log.note("agents: listening at \(path)")
    }

    private func stop() {
        guard isListening else { return }
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        isListening = false
        tools.stopEverything()
        Log.note("agents: stopped listening")
    }

    /// Reads one connection on a thread of its own. Each request runs as its own task on the main
    /// actor, reporting progress as it goes; a cancel message stops it, and so does the connection
    /// closing (the agent app quit).
    private func serve(_ fd: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        AgentLink.ignoreBrokenPipe(fd)
        let tools = self.tools
        Thread.detachNewThread {
            let reader = LineReader(fd: fd)
            let writer = LineWriter(fd: fd)
            let lock = NSLock()
            var running: [Int: Task<Void, Never>] = [:]
            while let line = reader.next() {
                guard let message = try? JSONDecoder().decode(JSONValue.self, from: line) else {
                    writer.send(AgentResponse(id: 0, ok: false, text: "Proof couldn't read that request."))
                    continue
                }
                if let id = message["cancel"]?.int {
                    lock.lock()
                    running[id]?.cancel()
                    lock.unlock()
                    continue
                }
                guard let request = try? JSONDecoder().decode(AgentRequest.self, from: line) else {
                    writer.send(AgentResponse(id: message["id"]?.int ?? 0, ok: false, text: "Proof couldn't read that request."))
                    continue
                }
                lock.lock()
                running[request.id] = Task { @MainActor in
                    let response = await tools.run(request) { progress, total, note in
                        writer.send(AgentProgress(id: request.id, progress: progress, total: total, message: note))
                    }
                    writer.send(response)
                    lock.withLock { running[request.id] = nil }
                }
                lock.unlock()
            }
            lock.lock()
            running.values.forEach { $0.cancel() }
            lock.unlock()
            writer.close()
            close(fd)
        }
    }

    private func note(client: String, _ summary: String) {
        activity.insert(AgentActivity(date: Date(), client: client, summary: summary), at: 0)
        if activity.count > 30 { activity.removeLast(activity.count - 30) }
        Log.note("agents: \(client) \(summary)")
    }

    private func fail(_ message: String) {
        lastError = message
        Log.note("agents: \(message)")
    }
}

import AppKit
import Foundation

/// `Proof --mcp`: a Model Context Protocol server on stdin and stdout that agent apps (Claude
/// Code, Cursor and others) start. It speaks MCP and hands each tool call to the running Proof,
/// which holds the Screen Recording permission and does the work.
final class MCPServer {
    static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Runs a tool in the app. Swapped out in tests.
    private let callTool: (_ name: String, _ arguments: JSONValue, _ client: String?) -> AgentResponse
    private var client: String?

    init(callTool: @escaping (String, JSONValue, String?) -> AgentResponse) {
        self.callTool = callTool
    }

    /// Reads requests from stdin until it closes. Nothing but protocol messages goes to stdout.
    static func run() -> Never {
        let link = AppConnection()
        let server = MCPServer { name, arguments, client in link.call(name, arguments: arguments, client: client) }
        let reader = LineReader(fd: STDIN_FILENO)
        while let line = reader.next() {
            guard !line.isEmpty else { continue }
            let reply: JSONValue?
            if let message = try? JSONDecoder().decode(JSONValue.self, from: line) {
                reply = server.handle(message)
            } else {
                reply = Self.error(id: .null, code: -32700, message: "Parse error")
            }
            if let reply, var data = try? JSONEncoder().encode(reply) {
                data.append(0x0A)
                FileHandle.standardOutput.write(data)
            }
        }
        exit(0)
    }

    /// The reply to one message, or nil for a notification.
    func handle(_ message: JSONValue) -> JSONValue? {
        guard let method = message["method"]?.string else { return nil }
        let id = message["id"]
        let params = message["params"] ?? [:]
        // Notifications have no id and get no reply.
        guard let id else { return nil }
        switch method {
        case "initialize":
            client = params["clientInfo"]?["name"]?.string
            let asked = params["protocolVersion"]?.string ?? ""
            let version = Self.protocolVersions.contains(asked) ? asked : Self.protocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "proof", "version": .string(AppInfo.version)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(AgentToolList.definitions)])
        case "tools/call":
            guard let name = params["name"]?.string else {
                return Self.error(id: id, code: -32602, message: "tools/call needs a tool name")
            }
            guard AgentToolList.names.contains(name) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool \(name)")
            }
            let response = callTool(name, params["arguments"] ?? [:], client)
            var content: [JSONValue] = [["type": "text", "text": .string(response.text)]]
            for image in response.images {
                content.append(["type": "image", "data": .string(image.data), "mimeType": .string(image.mimeType)])
            }
            return Self.result(id: id, ["content": .array(content), "isError": .bool(!response.ok)])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static let instructions = """
    Proof is a screenshot and screen recording app on this Mac. Use it to see windows (including \
    native apps a browser tool can't reach), annotate screenshots for pull requests and bug \
    reports, record short MP4s or GIFs of a flow, and share files as links. Coordinates are \
    global points with the origin at the top left of the main display; list_windows gives every \
    window's frame. Captures are saved to the agent folder set in Proof's settings unless save_to \
    is given.
    """

    static func result(id: JSONValue, _ result: [String: JSONValue]) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": .object(result)]
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}

/// The bridge's side of the socket: connects to the running app, starting it if needed, and
/// reconnects if the app restarts.
private final class AppConnection {
    private var fd: Int32?
    private var reader: LineReader?
    private var nextID = 1

    func call(_ tool: String, arguments: JSONValue, client: String?) -> AgentResponse {
        guard Preferences.load().allowAgents else {
            return AgentResponse(id: 0, ok: false, text: "Proof doesn't allow agents yet. Ask the person to turn on Proof → Settings → Agents → Allow agents to use Proof, then try again.")
        }
        let request = AgentRequest(id: nextID, tool: tool, arguments: arguments, client: client)
        nextID += 1
        // Once on the open connection, and once more on a fresh one in case the app restarted.
        for attempt in 0..<2 {
            guard let fd = self.fd ?? connect(launching: attempt == 1 || self.fd == nil) else { break }
            if AgentLink.send(request, to: fd), let line = reader?.next(),
               let response = try? JSONDecoder().decode(AgentResponse.self, from: line) {
                return response
            }
            disconnect()
        }
        return AgentResponse(id: request.id, ok: false, text: "Couldn't reach Proof. Make sure it's running, with Settings → Agents → Allow agents to use Proof turned on.")
    }

    private func connect(launching: Bool) -> Int32? {
        if let fd = AgentLink.connect() { return adopt(fd) }
        guard launching else { return nil }
        // Not running (or still starting): open the app this binary belongs to, then wait for it.
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").isEmpty
        if !running, AppInfo.isRunningFromBundle {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        }
        for _ in 0..<50 {
            Thread.sleep(forTimeInterval: 0.2)
            if let fd = AgentLink.connect() { return adopt(fd) }
        }
        return nil
    }

    private func adopt(_ fd: Int32) -> Int32 {
        self.fd = fd
        reader = LineReader(fd: fd)
        return fd
    }

    private func disconnect() {
        if let fd { close(fd) }
        fd = nil
        reader = nil
    }
}

/// The tools, as MCP lists them. The app implements them in `AgentTools`.
enum AgentToolList {
    static var names: Set<String> { Set(definitions.compactMap { $0["name"]?.string }) }

    private static let saveTo: JSONValue = ["type": "string", "description": "Where to save the file (a full path). Default: Proof's agent folder."]
    private static let windowArgs: [String: JSONValue] = [
        "window": ["type": "string", "description": "Part of an app name or window title, not case-sensitive. The frontmost match is used."],
        "window_id": ["type": "integer", "description": "A window id from list_windows."],
    ]
    private static let areaArgs: [String: JSONValue] = [
        "x": ["type": "number"], "y": ["type": "number"],
        "width": ["type": "number"], "height": ["type": "number"],
    ]

    private static func tool(_ name: String, _ description: String, _ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return ["name": .string(name), "description": .string(description), "inputSchema": .object(schema)]
    }

    static let definitions: [JSONValue] = [
        tool("list_windows",
             "Lists the windows on screen, front to back, with their id, app, title and frame (global points, origin at the top left of the main display), and the displays with their index and bounds.",
             [:]),
        tool("capture_window",
             "Screenshots one window, even if other windows cover it. Returns the saved file's path and the image. Give window or window_id.",
             windowArgs.merging([
                "shadow": ["type": "boolean", "description": "Include the window's shadow. Default false."],
                "save_to": saveTo,
             ]) { a, _ in a }),
        tool("capture_screen",
             "Screenshots a whole display. Returns the saved file's path and the image.",
             ["display": ["type": "integer", "description": "Display index from list_windows. Default 0, the main display."], "save_to": saveTo]),
        tool("capture_area",
             "Screenshots a rectangle of the screen, in global points. Returns the saved file's path and the image.",
             areaArgs.merging(["save_to": saveTo]) { a, _ in a }, required: ["x", "y", "width", "height"]),
        tool("capture_scrolling",
             """
             Captures a whole long page by scrolling it: Proof brings the window to the front, puts the pointer in the \
             middle of it, scrolls to the top (unless from_top is false), then down to the end, and joins everything into \
             one tall image, keeping a fixed header or \
             footer once. Give window or window_id (its frame is used), or an area (x, y, width, height in global points) \
             covering just the part that scrolls. Takes a few seconds per screenful; a bar on screen lets the person stop \
             it. Needs Accessibility for Proof. Returns the saved file and the image, in parts if it's long.
             """,
             windowArgs.merging(areaArgs) { a, _ in a }.merging([
                "from_top": ["type": "boolean", "description": "Scroll to the top before starting. Default true."],
                "save_to": saveTo,
             ]) { a, _ in a }),
        tool("annotate",
             """
             Draws annotations on an image file and saves a new file; returns its path and the image. Coordinates are in the \
             image's points (the size capture tools report), origin top left. Each annotation has a type and: \
             rectangle, filled_rectangle, ellipse, blur, pixelate, spotlight take rect [x, y, width, height]; \
             arrow and line take from [x, y] and to [x, y] (the arrow head is at to), and an optional label: text Proof \
             places just past the from end, away from the head, so a callout is one annotation. text takes at [x, y] (its \
             top left) and text; \
             counter takes at [x, y] and an optional number (otherwise 1, 2, 3 in order). Optional: color (red, orange, \
             yellow, green, blue, purple, black, white or #RRGGBB), line_width, font_size, text_style (filled, outlined, plain).
             """,
             [
                "path": ["type": "string", "description": "The image to annotate."],
                "annotations": ["type": "array", "items": ["type": "object"]],
                "background": ["type": "boolean", "description": "Put the image on Proof's padded gradient background. Default false."],
                "save_to": saveTo,
             ], required: ["path", "annotations"]),
        tool("start_recording",
             "Starts recording a window, an area (x, y, width, height in global points) or a display, without sound. A red border shows on screen. Do the flow, then call stop_recording. Recording stops by itself after 2 minutes.",
             windowArgs.merging(areaArgs) { a, _ in a }.merging([
                "display": ["type": "integer", "description": "Display index from list_windows, to record a whole display."],
             ]) { a, _ in a }),
        tool("stop_recording",
             "Stops the recording and saves it. Returns the file's path, size and length, and frames from across the recording in one image, each labelled with its time, to check what was recorded.",
             [
                "frames": ["type": "integer", "description": "How many frames to show, 0 to 12. Default 6."],
                "format": ["type": "string", "enum": ["mp4", "gif"], "description": "Default mp4. GIFs suit PR descriptions; keep them short."],
                "gif_width": ["type": "integer", "description": "Widest the GIF gets, in pixels. Default: Proof's GIF size setting."],
                "save_to": saveTo,
             ]),
        tool("share",
             "Uploads a file with the sharing service set in Proof (CloudUp or WordPress.com) and returns the link. The upload appears in Proof's Recent shares, where it can be deleted.",
             [
                "path": ["type": "string"],
                "visibility": ["type": "string", "enum": ["private", "public"], "description": "Which of Proof's two share destinations to use. Default private."],
             ], required: ["path"]),
    ]
}

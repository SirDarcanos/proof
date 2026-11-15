import XCTest
@testable import Proof

final class AgentTests: XCTestCase {
    private func decode(_ json: String) -> JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    // MARK: MCP

    func testInitializeNamesTheClientAndAgreesOnAVersion() {
        var seenClient: String?
        let server = MCPServer(callTool: { _, _, client, _, _ in
            seenClient = client
            return AgentResponse(id: 1, ok: true, text: "ok")
        })
        let reply = server.handle(decode(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.0"}}}"#))
        XCTAssertEqual(reply?["id"], 1)
        XCTAssertEqual(reply?["result"]?["protocolVersion"]?.string, "2025-03-26")
        XCTAssertNotNil(reply?["result"]?["capabilities"]?["tools"])
        XCTAssertEqual(reply?["result"]?["serverInfo"]?["name"]?.string, "proof")

        // An unknown version gets the newest one Proof speaks.
        let other = server.handle(decode(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#))
        XCTAssertEqual(other?["result"]?["protocolVersion"]?.string, MCPServer.protocolVersions[0])

        _ = server.handle(decode(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_windows","arguments":{}}}"#))
        XCTAssertEqual(seenClient, nil, "the second initialize had no clientInfo")
    }

    func testNotificationsGetNoReply() {
        let server = MCPServer(callTool: { _, _, _, _, _ in XCTFail("no tool call"); return AgentResponse(id: 0, ok: false, text: "") })
        XCTAssertNil(server.handle(decode(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)))
    }

    func testToolsListHasEveryToolWithASchema() {
        let server = MCPServer(callTool: { _, _, _, _, _ in AgentResponse(id: 0, ok: true, text: "") })
        let tools = server.handle(decode(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#))?["result"]?["tools"]?.array ?? []
        let names = tools.compactMap { $0["name"]?.string }
        XCTAssertEqual(Set(names), ["list_windows", "capture_window", "capture_screen", "capture_area", "capture_scrolling", "ask_for_area", "open_in_editor", "annotate",
                                    "start_recording", "stop_recording", "share"])
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"]?.string, "object", tool["name"]?.string ?? "")
            XCTAssertFalse(tool["description"]?.string?.isEmpty ?? true)
        }
    }

    func testToolCallPassesArgumentsAndReturnsTextAndImages() {
        var seen: (String, JSONValue, String?)?
        let server = MCPServer(callTool: { name, arguments, client, _, _ in
            seen = (name, arguments, client)
            return AgentResponse(id: 9, ok: true, text: "Saved: /tmp/a.png", images: [.init(data: "AAAA", mimeType: "image/png")])
        })
        _ = server.handle(decode(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"clientInfo":{"name":"cursor"}}}"#))
        let reply = server.handle(decode(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"capture_window","arguments":{"window":"Safari"}}}"#))
        XCTAssertEqual(seen?.0, "capture_window")
        XCTAssertEqual(seen?.1["window"]?.string, "Safari")
        XCTAssertEqual(seen?.2, "cursor")
        let content = reply?["result"]?["content"]?.array ?? []
        XCTAssertEqual(content.first?["type"]?.string, "text")
        XCTAssertEqual(content.first?["text"]?.string, "Saved: /tmp/a.png")
        XCTAssertEqual(content.last?["type"]?.string, "image")
        XCTAssertEqual(content.last?["mimeType"]?.string, "image/png")
        XCTAssertEqual(reply?["result"]?["isError"]?.bool, false)
    }

    func testFailuresAreToolErrorsAndUnknownsAreProtocolErrors() {
        let server = MCPServer(callTool: { _, _, _, _, _ in AgentResponse(id: 0, ok: false, text: "No window matches") })
        let failed = server.handle(decode(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture_window","arguments":{}}}"#))
        XCTAssertEqual(failed?["result"]?["isError"]?.bool, true)
        let unknownTool = server.handle(decode(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"format_disk"}}"#))
        XCTAssertEqual(unknownTool?["error"]?["code"]?.int, -32602)
        let unknownMethod = server.handle(decode(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#))
        XCTAssertEqual(unknownMethod?["error"]?["code"]?.int, -32601)
    }

    func testProgressGoesOutOnlyWhenTheAgentAskedForIt() {
        let server = MCPServer(callTool: { _, _, _, _, progress in
            progress(1200, nil, "1200 points captured so far")
            progress(2400, nil, "2400 points captured so far")
            return AgentResponse(id: 1, ok: true, text: "Saved")
        })
        var notes: [JSONValue] = []
        let reply = server.handle(decode(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"capture_scrolling","arguments":{"window":"Safari"},"_meta":{"progressToken":"tok-1"}}}"#),
                                  notify: { notes.append($0) })
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.first?["method"]?.string, "notifications/progress")
        XCTAssertEqual(notes.first?["params"]?["progressToken"]?.string, "tok-1")
        XCTAssertEqual(notes.map { $0["params"]?["progress"]?.number }, [1200, 2400])
        XCTAssertEqual(notes.last?["params"]?["message"]?.string, "2400 points captured so far")
        XCTAssertEqual(reply?["result"]?["isError"]?.bool, false)

        // Without a token, the same call sends no notifications.
        notes = []
        _ = server.handle(decode(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"capture_scrolling","arguments":{}}}"#),
                          notify: { notes.append($0) })
        XCTAssertTrue(notes.isEmpty)
    }

    func testCancelStopsTheCallInTheAppAndItGetsNoReply() {
        var cancelledKeys: [String] = []
        var server: MCPServer!
        server = MCPServer(callTool: { _, _, _, key, _ in
            // The agent cancels while the tool runs; the app then answers anyway.
            XCTAssertNil(server.handle(self.decode(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"call-9","reason":"user"}}"#)))
            XCTAssertEqual(key, #""call-9""#)
            return AgentResponse(id: 1, ok: false, text: "Cancelled before it finished.")
        }, cancelTool: { cancelledKeys.append($0) })
        let reply = server.handle(decode(#"{"jsonrpc":"2.0","id":"call-9","method":"tools/call","params":{"name":"ask_for_area","arguments":{}}}"#))
        XCTAssertNil(reply, "a cancelled call gets no reply")
        XCTAssertEqual(cancelledKeys, [#""call-9""#])

        // The next call with another id answers as usual.
        let next = server.handle(decode(#"{"jsonrpc":"2.0","id":10,"method":"ping"}"#))
        XCTAssertNotNil(next)
    }

    func testRequestIDsComeBackUnchanged() throws {
        let server = MCPServer(callTool: { _, _, _, _, _ in AgentResponse(id: 0, ok: true, text: "") })
        let reply = server.handle(decode(#"{"jsonrpc":"2.0","id":"abc-1","method":"ping"}"#))
        let data = try JSONEncoder().encode(reply)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""id":"abc-1""#))
    }

    // MARK: Annotations

    func testAnnotationsBecomeEditorAnnotations() throws {
        let list = decode("""
        [
          {"type": "arrow", "from": [10, 20], "to": [110, 70], "color": "blue", "line_width": 6},
          {"type": "rectangle", "rect": [5, 5, 100, 50]},
          {"type": "text", "at": [40, 200], "text": "Broken here", "text_style": "outlined", "font_size": 28},
          {"type": "counter", "at": [300, 40]},
          {"type": "counter", "at": [320, 40]},
          {"type": "blur", "rect": [0, 0, 20, 20], "color": "#00ff80"}
        ]
        """)
        let annotations = try AgentAnnotations.parse(list)
        XCTAssertEqual(annotations.map(\.tool), [.arrow, .rectangle, .text, .counter, .counter, .blur])
        XCTAssertEqual(annotations[0].start, CGPoint(x: 10, y: 20))
        XCTAssertEqual(annotations[0].end, CGPoint(x: 110, y: 70))
        XCTAssertEqual(annotations[0].style.color, .blue)
        XCTAssertEqual(annotations[0].style.lineWidth, 6)
        XCTAssertEqual(annotations[1].rect, CGRect(x: 5, y: 5, width: 100, height: 50))
        XCTAssertEqual(annotations[2].text, "Broken here")
        XCTAssertEqual(annotations[2].style.textStyle, .outlined)
        XCTAssertEqual(annotations[2].style.fontSize, 28)
        XCTAssertEqual(annotations[3].number, 1)
        XCTAssertEqual(annotations[4].number, 2)
        XCTAssertEqual(annotations[5].style.color, RGBA(r: 0, g: 1, b: 128.0 / 255))
    }

    func testBadAnnotationsSayWhatIsWrong() {
        func message(_ json: String) -> String {
            do {
                _ = try AgentAnnotations.parse(decode(json))
                return "no error"
            } catch {
                return error.localizedDescription
            }
        }
        XCTAssertTrue(message("[]").contains("at least one"))
        XCTAssertTrue(message(#"[{"type": "arrow", "from": [1, 2]}]"#).contains("to: [x, y]"))
        XCTAssertTrue(message(#"[{"type": "rectangle", "rect": [1, 2, 3]}]"#).contains("rect: [x, y, width, height]"))
        XCTAssertTrue(message(#"[{"type": "star", "at": [1, 2]}]"#).contains("unknown type star"))
        XCTAssertTrue(message(#"[{"type": "text", "at": [1, 2], "text": "a", "color": "teal"}]"#).contains("unknown color teal"))
    }

    func testArrowLabelSitsPastTheTailAwayFromTheHead() throws {
        let drawn = try AgentAnnotations.parseItems(decode(#"[{"type": "arrow", "from": [450, 343], "to": [330, 150], "label": "Agents switch"}]"#),
                                                    imageSize: CGSize(width: 600, height: 572))
        XCTAssertEqual(drawn.map(\.name), ["arrow", "arrow label"])
        XCTAssertEqual(drawn.map(\.item), [0, 0])
        let label = drawn[1].annotation
        XCTAssertEqual(label.tool, .text)
        XCTAssertEqual(label.text, "Agents switch")
        XCTAssertEqual(label.style.color, drawn[0].annotation.style.color)
        let box = CGRect(origin: label.start, size: AnnotationRenderer.textSize(for: label))
        let tail = CGPoint(x: 450, y: 343)
        // Below and to the right of the tail, as the arrow runs up and to the left, close but not touching.
        XCTAssertFalse(box.contains(tail))
        XCTAssertGreaterThan(box.midY, tail.y)
        XCTAssertGreaterThan(box.midX, tail.x)
        let gap = max(box.minX - tail.x, box.minY - tail.y)
        XCTAssertGreaterThanOrEqual(gap, 5)
        XCTAssertLessThanOrEqual(gap, 8)
    }

    func testArrowLabelStaysInsideTheImage() {
        // An arrow from near the bottom right corner pointing up-left would push its label off the image.
        let size = CGSize(width: 120, height: 30)
        let origin = AgentAnnotations.labelOrigin(size: size, tail: CGPoint(x: 590, y: 560), head: CGPoint(x: 400, y: 300),
                                                  imageSize: CGSize(width: 600, height: 572))
        XCTAssertEqual(origin.x, 480)
        XCTAssertEqual(origin.y, 542)
        // Straight down: centred under the tail.
        let below = AgentAnnotations.labelOrigin(size: size, tail: CGPoint(x: 300, y: 300), head: CGPoint(x: 300, y: 100), imageSize: nil)
        XCTAssertEqual(below.x, 240)
        XCTAssertEqual(below.y, 306)
    }

    func testPlacementsReportWhereThingsLanded() throws {
        let drawn = try AgentAnnotations.parseItems(decode(#"[{"type": "rectangle", "rect": [10, 20, 100, 50]}, {"type": "counter", "at": [200, 200]}, {"type": "blur", "rect": [580, 560, 100, 100]}]"#))
        var document = AnnotationDocument(imageSize: CGSize(width: 600, height: 572), scale: 2)
        document.annotations = drawn.map(\.annotation)
        let plain = AgentTools.placements(drawn, layout: AnnotationRenderer.layout(document))
        XCTAssertTrue(plain.contains("1. rectangle: [10, 20, 100, 50]"), plain)
        XCTAssertTrue(plain.contains("2. counter: [186, 186, 28, 28]"), plain)
        // Clipped to the image.
        XCTAssertTrue(plain.contains("3. blur: [580, 560, 20, 12]"), plain)
        // With a background, positions move by the padding, since the agent sees the padded image.
        document.background.enabled = true
        let padded = AgentTools.placements(drawn, layout: AnnotationRenderer.layout(document))
        XCTAssertTrue(padded.contains("1. rectangle: [58, 68, 100, 50]"), padded)
    }

    func testLongImagesComeInReadableParts() throws {
        // A page 500 points wide and 6000 tall, at 1 pixel per point.
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 6000, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 6000))
        let image = try XCTUnwrap(context.makeImage())
        let (parts, note) = AgentTools.previews(image, pointSize: CGSize(width: 500, height: 6000))
        XCTAssertEqual(parts.count, 4)
        XCTAssertTrue(note.contains("start at y = 0, 1568, 3136, 4704 points"), note)
        XCTAssertTrue(note.contains("100%"), note)
        // Far longer (1000 × 60000 points, stored at a tenth of a pixel per point to keep the test
        // light): never more than 8 parts, scaled down to fit.
        let narrow = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 100, height: 6000)))
        let (many, longNote) = AgentTools.previews(narrow, pointSize: CGSize(width: 1000, height: 60000))
        XCTAssertEqual(many.count, AgentTools.maxPreviewParts)
        XCTAssertTrue(longNote.contains("start at y = 0, 7500,"), longNote)
        // An ordinary screenshot stays one picture.
        let (one, oneNote) = AgentTools.previews(image, pointSize: CGSize(width: 1200, height: 800))
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue(oneNote.contains("1 pixel per point"), oneNote)
    }

    func testRecordingFramesAreSpreadAcrossTheVideo() {
        XCTAssertEqual(AgentTools.frameTimes(duration: 12, count: 6), [1, 3, 5, 7, 9, 11])
        XCTAssertEqual(AgentTools.frameTimes(duration: 4, count: 1), [2])
        XCTAssertEqual(AgentTools.frameTimes(duration: 4, count: 0), [])
        XCTAssertEqual(AgentTools.frameTimes(duration: 0, count: 6), [])
    }

    func testContactSheetLaysFramesInTwoColumns() throws {
        func frame(_ gray: CGFloat) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1728, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1728, height: 1024))
            return try XCTUnwrap(context.makeImage())
        }
        let frames = try (0..<5).map { (image: try frame(CGFloat($0) / 5), time: Double($0)) }
        let sheet = try XCTUnwrap(AgentTools.contactSheet(frames))
        // Two columns of 772 px tiles with 8 px gaps make 1568; three rows of 457 px tiles.
        XCTAssertEqual(sheet.width, 1568)
        XCTAssertEqual(sheet.height, 457 * 3 + 8 * 4)
        let single = try XCTUnwrap(AgentTools.contactSheet([(image: try frame(1), time: 0)]))
        XCTAssertEqual(single.width, 1568)
        XCTAssertNil(AgentTools.contactSheet([]))
    }

    func testClientNamesReadNaturally() {
        XCTAssertEqual(AgentTools.displayName("claude-code"), "Claude Code")
        XCTAssertEqual(AgentTools.displayName("cursor"), "Cursor")
        XCTAssertEqual(AgentTools.displayName(nil), "An agent")
    }
}

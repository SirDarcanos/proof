import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI

/// Runs a scrolling capture: the border and bar around the chosen area, Start, the live preview
/// while the person scrolls (or Proof scrolls for them), and Done, which hands the joined image on
/// like any other capture.
@MainActor @Observable
final class ScrollingCaptureController {
    enum Phase: Equatable {
        case idle
        /// The bar is up, waiting for Start.
        case ready
        case capturing
        case finishing
    }

    private(set) var phase: Phase = .idle
    /// A warning on the bar, such as scrolling too fast.
    private(set) var message: String?
    /// Pixels in the image so far.
    private(set) var pixelSize: CGSize = .zero
    /// Proof is scrolling the area itself.
    private(set) var isAutoScrolling = false
    /// Shown over the area while auto-scroll waits for the pointer to come back.
    private(set) var pauseMessage: String?

    var isActive: Bool { phase != .idle }

    @ObservationIgnored var onFinished: ((Capture) -> Void)?

    @ObservationIgnored private var area: CGRect = .zero
    @ObservationIgnored private var appName: String?
    @ObservationIgnored private var date = Date()
    @ObservationIgnored private var grabber: ScrollGrabber?
    @ObservationIgnored private var border: AreaBorderPanel?
    @ObservationIgnored private var bar: ScrollBarPanel?
    @ObservationIgnored private var preview: ScrollPreviewPanel?
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    /// For auto-scroll: steps that moved the content, lost it or went back, pixels moved in all,
    /// when the stitcher last reported any of those, and whether its last word was that it lost
    /// track.
    @ObservationIgnored private var moves = 0
    @ObservationIgnored private var losses = 0
    @ObservationIgnored private var movedPixels = 0
    @ObservationIgnored private var backwardSteps = 0
    @ObservationIgnored private var lastActivity = Date.distantPast
    @ObservationIgnored private var isLost = false
    /// The stitcher's last word was that the content moved back: a page bouncing at its end, or
    /// one that jumped back to its top.
    @ObservationIgnored private var wentBack = false
    /// An agent's capture ended with auto-scroll giving up, so the image may be incomplete.
    @ObservationIgnored private var agentGaveUp = false
    @ObservationIgnored private var pausePanel: ScrollPausePanel?
    /// An agent waiting for the capture it asked for, instead of `onFinished`.
    @ObservationIgnored private var agentWaiter: CheckedContinuation<Result<Capture, Error>, Never>?
    /// Told how long the image is so far, in points, while an agent waits.
    @ObservationIgnored private var agentProgress: ((Int) -> Void)?

    /// Puts the border, bar and preview up around `area` (global points); nothing is captured until Start.
    func begin(_ area: CGRect, appName: String?) {
        guard phase == .idle else { return }
        self.area = area.integral
        self.appName = appName
        date = Date()
        message = nil
        pixelSize = .zero
        let border = AreaBorderPanel(around: self.area, activeColor: .controlAccentColor)
        border.orderFrontRegardless()
        self.border = border
        let preview = ScrollPreviewPanel(beside: self.area)
        preview.orderFrontRegardless()
        self.preview = preview
        let bar = ScrollBarPanel(controller: self, below: self.area)
        bar.orderFrontRegardless()
        bar.makeKey()
        self.bar = bar
        phase = .ready
    }

    /// The shortcut: Start when the bar is waiting, Done while capturing.
    func primaryAction() {
        switch phase {
        case .ready: Task { await start() }
        case .capturing: Task { await finish() }
        default: break
        }
    }

    func start() async {
        guard phase == .ready else { return }
        phase = .capturing
        border?.isActive = true
        let grabber = ScrollGrabber()
        grabber.onUpdate = { [weak self] update in self?.apply(update) }
        self.grabber = grabber
        do {
            // The border, bar and preview are on screen, so the filter leaves them out.
            try await grabber.start(area: area)
        } catch {
            fail(error)
        }
    }

    func finish() async {
        guard phase == .capturing, let grabber else { return }
        phase = .finishing
        let image = await grabber.stop()
        let waiter = agentWaiter
        agentWaiter = nil
        close()
        guard let image else {
            if let waiter {
                waiter.resume(returning: .failure(AgentError("No picture of the area came through.")))
            } else {
                Notifier.shared.notify(title: "Scrolling capture failed", body: "No picture of the area came through.")
            }
            return
        }
        // The stream captures at the display's pixel density; points follow from the area's width or height.
        let scale = max(1, CGFloat(grabber.frameWidth) / max(area.width, 1))
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        Log.note("scrolling capture \(image.width)x\(image.height) px")
        let capture = Capture(image: image, pointSize: pointSize, kind: .scrolling, appName: appName, date: date)
        if let waiter { waiter.resume(returning: .success(capture)) } else { onFinished?(capture) }
    }

    /// A whole auto-scrolled capture of `area` for an agent: the pointer goes to the middle of the
    /// area (scroll events go to whatever is under it), Proof scrolls to the end, and the joined
    /// image comes back. The bar stays up, so the person can still press Done or Cancel; moving
    /// the pointer out of the area pauses it, as usual.
    /// `complete` is false when auto-scroll lost track of the page and gave up, so the image may
    /// stop short or have a seam.
    func captureForAgent(_ area: CGRect, appName: String?, fromTop: Bool = true, timeLimit: Duration = .seconds(300),
                         progress: ((Int) -> Void)? = nil) async throws -> (capture: Capture, complete: Bool) {
        guard phase == .idle else { throw AgentError("A scrolling capture is already running. Try again once it's done.") }
        guard Permissions.accessibilityGranted(prompt: true) else {
            throw AgentError("Scrolling needs Proof turned on in System Settings → Privacy & Security → Accessibility. Ask the person to turn it on, then try again.")
        }
        begin(area, appName: appName)
        agentProgress = progress
        agentGaveUp = false
        let middle = CGPoint(x: self.area.midX, y: self.area.midY)
        let home = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(middle)
        if fromTop {
            // Back to the top first, in big steps, then let it settle before the first frame.
            for _ in 0..<12 {
                CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 5000, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(30))
            }
            try? await Task.sleep(for: .milliseconds(800))
        }
        let limit = Task { [weak self] in
            try? await Task.sleep(for: timeLimit)
            guard !Task.isCancelled, let self else { return }
            // Keep what there is; if capturing never started, cancelling still answers the agent.
            if self.phase == .capturing { await self.finish() } else { await self.cancel() }
        }
        let result = await withCheckedContinuation { continuation in
            agentWaiter = continuation
            Task { await startAutoScroll() }
        }
        limit.cancel()
        // Put the pointer back, unless the person has taken it since.
        if let home, let now = CGEvent(source: nil)?.location, hypot(now.x - middle.x, now.y - middle.y) <= 4 {
            CGWarpMouseCursorPosition(home)
        }
        return (try result.get(), !agentGaveUp)
    }

    func cancel() async {
        let grabber = self.grabber
        close()
        _ = await grabber?.stop()
    }

    /// Start, then Proof scrolls down a quarter of the area at a time, waiting each time for the
    /// page to settle, until nothing moves (the end of the page). The pointer can move around
    /// inside the area; outside it, scrolling pauses until the pointer comes back.
    func startAutoScroll() async {
        guard phase == .ready else { return }
        // Posting scroll events to another app needs Accessibility.
        guard Permissions.accessibilityGranted(prompt: true) else {
            message = "Auto-scroll needs Proof turned on in System Settings → Privacy & Security → Accessibility. Then press Auto-scroll again."
            return
        }
        // On screen (empty) before the stream starts, so the capture leaves it out.
        let pause = ScrollPausePanel(controller: self, over: area)
        pause.orderFrontRegardless()
        pausePanel = pause
        await start()
        guard phase == .capturing else { return }
        isAutoScrolling = true
        autoTask = Task { await autoScroll() }
    }

    private func autoScroll() async {
        let pixelsPerPoint = max(1, CGFloat(grabber?.frameWidth ?? 0) / max(area.width, 1))
        // Points of content to move each step: a quarter of the area, less after losing track.
        // Apps don't all scroll exactly as far as asked, so `ratio` (moved ÷ asked) is measured
        // and the ask corrected by it.
        let fullStep = max(40, area.height / 4)
        var stepSize = fullStep
        var ratio: CGFloat = 1
        var started = false
        Log.note("auto-scroll start: area \(Int(area.width))x\(Int(area.height)) pt, step \(Int(fullStep)) pt")
        // Let the first frame arrive.
        try? await Task.sleep(for: .milliseconds(200))
        while !Task.isCancelled, phase == .capturing {
            // Scroll events go to whatever is under the pointer, so wait while it's elsewhere.
            if !pointerInArea {
                pauseMessage = started ? "Move the pointer back here to continue" : "Move the pointer here to start scrolling"
                Log.note("auto-scroll paused: pointer outside the area")
                while !Task.isCancelled, phase == .capturing, !pointerInArea {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                pauseMessage = nil
                guard !Task.isCancelled, phase == .capturing else { return }
                Log.note("auto-scroll resumed")
                // Let anything the pointer brought up on its way in settle first.
                try? await Task.sleep(for: .milliseconds(300))
                continue
            }
            started = true
            let ask = stepSize / ratio
            let movesBefore = moves, lossesBefore = losses, backBefore = backwardSteps, pixelsBefore = movedPixels
            let posted = await scroll(by: ask)
            // Wait for the content to move and then hold still, or for nothing to happen at all.
            let postedAt = Date()
            var reacted = false
            while !Task.isCancelled, phase == .capturing {
                try? await Task.sleep(for: .milliseconds(50))
                reacted = moves > movesBefore || losses > lossesBefore || backwardSteps > backBefore
                if reacted, Date().timeIntervalSince(lastActivity) > 0.3 || Date().timeIntervalSince(postedAt) > 2 { break }
                if !reacted, Date().timeIntervalSince(postedAt) > 1.5 { break }
            }
            guard !Task.isCancelled, phase == .capturing else { return }
            // Cut short by the pointer leaving: pause, then carry on from wherever the page is.
            if posted == 0 { continue }
            if !reacted {
                guard posted >= ask * 0.9 else { continue }
                // Nothing moved: the end of the page.
                Log.note("auto-scroll done: nothing moved")
                await finish()
                return
            }
            let moved = CGFloat(movedPixels - pixelsBefore) / pixelsPerPoint
            if wentBack {
                // The page settled back instead of going on: its end (a bounce), or it jumped.
                Log.note("auto-scroll done: the page moved back")
                await finish()
                return
            }
            if isLost {
                // Moved too far to follow. Undo the part the stitcher didn't follow, which puts
                // the page back where it last saw it, and take smaller steps.
                let back = max(posted * ratio - moved, 0) / ratio
                Log.note("auto-scroll lost after asking \(Int(posted)) pt (followed \(Int(moved)) pt); backing up \(Int(back)) pt")
                _ = await scroll(by: -back)
                try? await Task.sleep(for: .milliseconds(500))
                // That was Proof moving the page back, not the page ending.
                wentBack = false
                stepSize /= 2
                if stepSize < 10 {
                    Log.note("auto-scroll gave up: still lost")
                    stopAutoScroll()
                    return
                }
                continue
            }
            if moved > 4, losses == lossesBefore, posted >= ask * 0.9 {
                ratio = min(max(moved / posted, 0.1), 10)
                stepSize = min(stepSize * 1.5, fullStep)
            }
            Log.note("auto-scroll asked \(Int(posted)) pt, moved \(Int(moved)) pt")
        }
    }

    /// Whether the pointer is over the area, where scroll events reach the page being captured.
    /// The bar can sit inside a large area, and scrolling over it reaches nothing.
    private var pointerInArea: Bool {
        guard let location = CGEvent(source: nil)?.location else { return false }
        if let bar, bar.frame.contains(NSEvent.mouseLocation) { return false }
        return area.insetBy(dx: 2, dy: 2).contains(location)
    }

    /// Hands scrolling back to the person, with what to do next on the bar.
    private func stopAutoScroll() {
        // An agent can't scroll by hand: keep what there is, and say it may be incomplete.
        if agentWaiter != nil {
            agentGaveUp = true
            Task { await finish() }
            return
        }
        isAutoScrolling = false
        pauseMessage = nil
        message = isLost
            ? "Auto-scroll stopped. Scroll back up a little until the preview moves again, then scroll by hand or press Done."
            : "Auto-scroll stopped. Scroll by hand, or press Done."
    }

    /// Scrolls the content under the pointer down by `points` (up when negative), in a few small
    /// wheel events so apps that animate scrolling keep up. Stops early if the pointer leaves the
    /// area; returns the points actually sent.
    private func scroll(by points: CGFloat) async -> CGFloat {
        let parts = 6
        let total = Int(points.rounded())
        var sent = 0
        for part in 0..<parts {
            // Spread the remainder so the parts add up to exactly `points`.
            let amount = total * (part + 1) / parts - total * part / parts
            guard !Task.isCancelled, phase == .capturing, pointerInArea,
                  let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                      wheel1: Int32(-amount), wheel2: 0, wheel3: 0) else { break }
            event.post(tap: .cghidEventTap)
            sent += amount
            try? await Task.sleep(for: .milliseconds(16))
        }
        return CGFloat(sent)
    }

    private func apply(_ update: ScrollGrabber.Update) {
        guard phase == .capturing else { return }
        pixelSize = update.pixelSize
        switch update.step {
        case .started, .unchanged: break
        default: Log.note("scrolling step \(update.step), moved \(update.distance) px, image \(Int(update.pixelSize.width))x\(Int(update.pixelSize.height))")
        }
        switch update.step {
        case .lost:
            wentBack = false
            losses += 1
            isLost = true
            lastActivity = Date()
            if !isAutoScrolling { message = "Lost track of the page. Scroll back a little, then go more slowly." }
        case .backwards:
            backwardSteps += 1
            lastActivity = Date()
            wentBack = true
            if !isAutoScrolling { message = "Scroll down or to the right only." }
        case .extended:
            wentBack = false
            moves += 1
            movedPixels += update.distance
            if let agentProgress, let axis = update.axis {
                let pixelsPerPoint = max(1, CGFloat(grabber?.frameWidth ?? 0) / max(area.width, 1))
                agentProgress(Int((axis == .vertical ? update.pixelSize.height : update.pixelSize.width) / pixelsPerPoint))
            }
            lastActivity = Date()
            isLost = false
            if !isAutoScrolling { message = nil }
        case .full:
            message = nil
            Task { await finish() }
        case .started, .unchanged: break
        }
        if let axis = update.axis { preview?.show(axis: axis, around: area) }
        preview?.apply(update.preview)
    }

    private func fail(_ error: Error) {
        Log.note("scrolling capture failed: \(error.localizedDescription)")
        let grabber = self.grabber
        agentWaiter?.resume(returning: .failure(error))
        agentWaiter = nil
        close()
        Task { _ = await grabber?.stop() }
        if case CaptureError.permissionDenied = error { Permissions.requestScreenRecording() }
        Notifier.shared.notify(title: "Scrolling capture failed", body: error.localizedDescription)
    }

    private func close() {
        // Cancelled (or failed) while an agent waited.
        agentWaiter?.resume(returning: .failure(AgentError("The scrolling capture was cancelled.")))
        agentWaiter = nil
        agentProgress = nil
        autoTask?.cancel()
        autoTask = nil
        isAutoScrolling = false
        pauseMessage = nil
        moves = 0
        losses = 0
        movedPixels = 0
        backwardSteps = 0
        isLost = false
        wentBack = false
        [bar, border, preview, pausePanel].forEach { $0?.orderOut(nil) }
        bar = nil
        border = nil
        preview = nil
        pausePanel = nil
        grabber = nil
        message = nil
        phase = .idle
    }
}

// MARK: - Grabber

/// Streams the area and feeds each new frame to the stitcher on its own queue, so a slow match
/// never holds up the screen. Frames that arrive while one is being matched are dropped.
private final class ScrollGrabber: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum PreviewChange {
        case none
        /// Replace every strip (the first frame, or the first strip was shortened).
        case reset([CGImage])
        case append([CGImage])
    }

    struct Update {
        let step: ScrollStitcher.Step
        /// Pixels the content moved, when it did.
        let distance: Int
        let axis: ScrollStitcher.Axis?
        let pixelSize: CGSize
        let preview: PreviewChange
    }

    @MainActor var onUpdate: ((Update) -> Void)?
    /// Pixels across one frame, to work out the image's size in points.
    private(set) var frameWidth = 0

    private let queue = DispatchQueue(label: "io.github.nickpagz.proof.scrolling")
    private var stream: SCStream?
    /// Touched only on `queue`.
    private var stitcher: ScrollStitcher?
    private var stopped = false
    private var previewScale: CGFloat = 1

    /// Long sides of the preview strips, in pixels.
    static let previewWidth: CGFloat = 320
    static let previewHeight: CGFloat = 240

    @MainActor
    func start(area: CGRect) async throws {
        let content = try await ScreenGrabber.shareableContent()
        guard let displayID = ScreenGeometry.displayID(containing: area),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.noDisplay }
        let bounds = CGDisplayBounds(displayID)
        let local = area.intersection(bounds).offsetBy(dx: -bounds.minX, dy: -bounds.minY).integral
        guard local.width >= 8, local.height >= 8 else { throw CaptureError.emptyArea }
        let filter = SCContentFilter(display: display, excludingWindows: ScreenGrabber.excludedWindows(
            in: content, hideDesktopIcons: false, chrome: ScreenGrabber.chromeWindowIDs()))
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = Int((local.width * scale).rounded())
        config.height = Int((local.height * scale).rounded())
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.captureResolution = .best
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3
        frameWidth = config.width
        // An overlay scroll bar is about 12 points wide.
        let edge = Int((12 * scale).rounded())
        queue.sync { stitcher = ScrollStitcher(ignoredEdge: edge) }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Ends the stream and returns everything joined so far.
    @MainActor
    func stop() async -> CGImage? {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { continuation in
            queue.async {
                self.stopped = true
                continuation.resume(returning: self.stitcher?.makeImage())
                self.stitcher = nil
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, let stitcher, isComplete(sampleBuffer),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer), let frame = ScrollFrame(pixelBuffer: pixels) else { return }
        let before = stitcher.strips.count
        let step = stitcher.add(frame)
        let axis = stitcher.axis
        var preview = PreviewChange.none
        switch step {
        case .started:
            previewScale = min(1, Self.previewWidth / CGFloat(frame.width))
            preview = .reset(stitcher.strips.compactMap(shrink))
        case .extended, .full:
            if stitcher.trimmedFirstStrip {
                previewScale = axis == .horizontal ? min(1, Self.previewHeight / CGFloat(frame.height)) : min(1, Self.previewWidth / CGFloat(frame.width))
                preview = .reset(stitcher.strips.compactMap(shrink))
            } else if stitcher.strips.count > before {
                preview = .append(stitcher.strips[before...].compactMap(shrink))
            }
        default:
            break
        }
        let length = CGFloat(stitcher.length > 0 ? stitcher.length : frame.height)
        let size = axis == .horizontal ? CGSize(width: length, height: CGFloat(frame.height)) : CGSize(width: CGFloat(frame.width), height: length)
        let distance: Int
        if case .extended = step { distance = stitcher.lastDistance } else if case .full = step { distance = stitcher.lastDistance } else { distance = 0 }
        let update = Update(step: step, distance: distance, axis: axis, pixelSize: size, preview: preview)
        Task { @MainActor in self.onUpdate?(update) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.note("scrolling capture stream stopped: \(error.localizedDescription)")
    }

    private func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// A small copy of a strip for the preview.
    private func shrink(_ image: CGImage) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * previewScale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * previewScale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: ScrollFrame.colorSpace, bitmapInfo: ScrollFrame.bitmapInfo) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Bar

/// Floats under the area. Proof's windows are left out of the capture, so it can sit anywhere,
/// and it can be dragged out of the way.
private final class ScrollBarPanel: NSPanel, CaptureChrome {
    init(controller: ScrollingCaptureController, below frame: CGRect) {
        let size = NSSize(width: 640, height: 96)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: ScrollBar(controller: controller))
        setFrameOrigin(ScreenGeometry.barOrigin(for: size, below: frame))
    }

    override var canBecomeKey: Bool { true }
}

private struct ScrollBar: View {
    let controller: ScrollingCaptureController

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                switch controller.phase {
                case .ready:
                    Text("Start, then scroll slowly down or right")
                    Button {
                        Task { await controller.start() }
                    } label: {
                        Label("Start", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button {
                        Task { await controller.startAutoScroll() }
                    } label: {
                        Label("Auto-scroll", systemImage: "arrow.down.circle")
                    }
                    .help("Proof scrolls down to the end of the page. It pauses while the pointer is outside the area.")
                    Button("Cancel") { Task { await controller.cancel() } }
                        .keyboardShortcut(.cancelAction)
                case .capturing:
                    if controller.pauseMessage != nil {
                        Image(systemName: "pause.circle.fill")
                    } else if controller.isAutoScrolling {
                        ProgressView().controlSize(.small)
                    }
                    Text(sizeLabel)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .frame(minWidth: 110, alignment: .leading)
                    Button {
                        Task { await controller.finish() }
                    } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button("Cancel") { Task { await controller.cancel() } }
                        .keyboardShortcut(.cancelAction)
                case .finishing:
                    ProgressView().controlSize(.small)
                    Text("Joining…")
                case .idle:
                    EmptyView()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            if let message = controller.message {
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 480)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    private var sizeLabel: String {
        let size = controller.pixelSize
        return size == .zero ? "Scroll…" : "\(Int(size.width)) × \(Int(size.height))"
    }
}

// MARK: - Pause

/// Over the area while auto-scroll runs: empty and click-through, except while the pointer is
/// outside the area, when it asks for the pointer back. Left out of the capture.
private final class ScrollPausePanel: NSPanel, CaptureChrome {
    init(controller: ScrollingCaptureController, over area: CGRect) {
        let frame = ScreenGeometry.cocoaRect(fromGlobal: area)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = NSHostingView(rootView: ScrollPauseView(controller: controller))
        setFrame(frame, display: false)
    }
}

private struct ScrollPauseView: View {
    let controller: ScrollingCaptureController

    var body: some View {
        ZStack {
            if let message = controller.pauseMessage {
                VStack(spacing: 10) {
                    Image(systemName: "cursorarrow.rays")
                        .font(.system(size: 34, weight: .medium))
                    Text(message)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
                .environment(\.colorScheme, .dark)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

/// The image so far, beside the area: the newest part shows, older parts run off the far edge.
private final class ScrollPreviewPanel: NSPanel, CaptureChrome {
    private let view = ScrollPreviewView()
    private var axis: ScrollStitcher.Axis = .vertical

    /// Points across the preview.
    static let thickness: CGFloat = 160

    init(beside area: CGRect) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = view
        place(around: area)
    }

    func show(axis: ScrollStitcher.Axis, around area: CGRect) {
        guard axis != self.axis else { return }
        self.axis = axis
        view.axis = axis
        place(around: area)
    }

    func apply(_ change: ScrollGrabber.PreviewChange) {
        switch change {
        case .none: return
        case .reset(let strips): view.strips = strips
        case .append(let strips): view.strips += strips
        }
        view.needsDisplay = true
    }

    /// Vertical: beside the area, right if there's room, else left, else just inside its right
    /// edge. Horizontal: above it, else just inside its top edge.
    private func place(around global: CGRect) {
        let area = ScreenGeometry.cocoaRect(fromGlobal: global)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: area.midX, y: area.midY)) } ?? ScreenGeometry.screenUnderMouse
        let visible = screen.visibleFrame
        let gap: CGFloat = 12
        var frame: NSRect
        if axis == .vertical {
            let height = min(area.height, visible.height - 16)
            let y = min(max(area.minY, visible.minY + 8), visible.maxY - height - 8)
            var x = area.maxX + gap
            if x + Self.thickness > visible.maxX { x = area.minX - gap - Self.thickness }
            if x < visible.minX { x = area.maxX - Self.thickness - gap }
            frame = NSRect(x: x, y: y, width: Self.thickness, height: height)
        } else {
            let height: CGFloat = 120
            let width = min(area.width, visible.width - 16)
            let x = min(max(area.minX, visible.minX + 8), visible.maxX - width - 8)
            var y = area.maxY + gap
            if y + height > visible.maxY { y = area.maxY - height - gap }
            frame = NSRect(x: x, y: y, width: width, height: height)
        }
        setFrame(frame, display: true)
    }
}

private final class ScrollPreviewView: NSView {
    var strips: [CGImage] = []
    var axis: ScrollStitcher.Axis = .vertical

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor.black.withAlphaComponent(0.75).setFill()
        box.fill()
        guard let context = NSGraphicsContext.current?.cgContext, !strips.isEmpty else { return }
        context.saveGState()
        box.addClip()
        let inner = bounds.insetBy(dx: 6, dy: 6)
        // Every strip has the same width (vertical) or height (horizontal); scale that to fit.
        let across = axis == .vertical ? CGFloat(strips[0].width) : CGFloat(strips[0].height)
        let scale = (axis == .vertical ? inner.width : inner.height) / max(across, 1)
        let total = strips.reduce(CGFloat(0)) { $0 + CGFloat(axis == .vertical ? $1.height : $1.width) * scale }
        // The newest content sits at the bottom (or right) once the image is longer than the view.
        if axis == .vertical {
            var top = total > inner.height ? inner.minY + total : inner.maxY
            for strip in strips {
                let height = CGFloat(strip.height) * scale
                top -= height
                let rect = NSRect(x: inner.minX, y: top, width: inner.width, height: height)
                if rect.intersects(inner) { context.draw(strip, in: rect) }
            }
        } else {
            var left = total > inner.width ? inner.maxX - total : inner.minX
            for strip in strips {
                let width = CGFloat(strip.width) * scale
                let rect = NSRect(x: left, y: inner.minY, width: width, height: inner.height)
                if rect.intersects(inner) { context.draw(strip, in: rect) }
                left += width
            }
        }
        context.restoreGState()
    }
}

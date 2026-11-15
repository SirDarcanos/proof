import AppKit

/// A small note under the menu bar for a couple of seconds whenever an agent uses Proof, so
/// nothing happens on screen unseen. Left out of captures.
@MainActor
enum AgentNotice {
    private static var panel: NoticePanel?
    private static var hideTask: Task<Void, Never>?

    static func show(_ message: String) {
        let panel = self.panel ?? NoticePanel()
        self.panel = panel
        panel.label.stringValue = message
        let size = NSSize(width: min(panel.label.intrinsicContentSize.width + 52, 460), height: 34)
        let screen = NSScreen.screens.first ?? ScreenGeometry.screenUnderMouse
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - size.width - 12, y: visible.maxY - size.height - 8, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: nil)
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

private final class NoticePanel: NSPanel, CaptureChrome {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.masksToBounds = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, label])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        contentView = box
        appearance = NSAppearance(named: .vibrantDark)
    }
}

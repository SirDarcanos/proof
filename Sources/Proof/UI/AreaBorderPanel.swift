import AppKit

/// A line just outside an area being recorded or scrolled (inside the screen edge for a whole
/// display): dashed white while waiting, solid `activeColor` once it's running. Clicks pass through.
final class AreaBorderPanel: NSPanel, CaptureChrome {
    var isActive = false { didSet { contentView?.needsDisplay = true } }
    let activeColor: NSColor

    /// `frame` in global points.
    init(around frame: CGRect, fullscreen: Bool = false, activeColor: NSColor) {
        self.activeColor = activeColor
        let inset: CGFloat = fullscreen ? 0 : -3
        let rect = ScreenGeometry.cocoaRect(fromGlobal: frame).insetBy(dx: inset, dy: inset)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(rect, display: false)
        contentView = BorderView(panel: self)
    }
}

private final class BorderView: NSView {
    private unowned let panel: AreaBorderPanel

    init(panel: AreaBorderPanel) {
        self.panel = panel
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        if panel.isActive {
            panel.activeColor.setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.9).setStroke()
            path.setLineDash([8, 6], count: 2, phase: 0)
        }
        path.stroke()
    }
}

extension ScreenGeometry {
    /// Where a bar of `size` goes for an area (global points): under it if there's room, else
    /// above it, else inside along its bottom edge. Cocoa coordinates.
    static func barOrigin(for size: NSSize, below frame: CGRect) -> NSPoint {
        let area = cocoaRect(fromGlobal: frame)
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: area.midX, y: area.midY)) } ?? screenUnderMouse
        let visible = screen.visibleFrame
        var y = area.minY - 8 - size.height
        if y < visible.minY {
            y = area.maxY + 8
            if y + size.height > visible.maxY { y = max(area.minY, visible.minY) + 16 }
        }
        let x = min(max(area.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: y)
    }
}

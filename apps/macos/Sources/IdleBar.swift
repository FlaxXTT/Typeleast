import AppKit

// IdleBar.swift - the resting voice bar (Reference "Show voice bar on desktop").
//
// A small, faint capsule at the bottom centre of the screen. Hovering widens it and
// shows the shortcut; clicking it starts a dictation. Like the recording pill it is a
// non-activating panel: it never takes focus from the app being typed into, so a
// click on it still pastes into the field that had the cursor.

private final class IdleBarView: NSView {
    var onClick: (() -> Void)?
    var hint = L10n.text("按 fn 开始听写")
    private(set) var hovering = false {
        didSet { needsDisplay = true }
    }
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private func setHover(_ value: Bool) {
        hovering = value
        (window as? IdleBarPanel)?.resize(expanded: value)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(calibratedWhite: 0.07, alpha: hovering ? 0.92 : 0.55).setFill()
        path.fill()
        NSColor(calibratedWhite: 1, alpha: hovering ? 0.14 : 0.18).setStroke()
        path.lineWidth = 1
        path.stroke()
        guard hovering else {
            // three faint dots, the resting mark
            for i in -1...1 {
                let r: CGFloat = 1.6
                let x = bounds.midX + CGFloat(i) * 6
                NSColor.white.withAlphaComponent(0.7).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - r, y: bounds.midY - r, width: r * 2, height: r * 2)).fill()
            }
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let text = hint as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

final class IdleBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static let restingSize = NSSize(width: 46, height: 12)
    static let expandedSize = NSSize(width: 150, height: 28)

    func resize(expanded: Bool) {
        let size = expanded ? IdleBarPanel.expandedSize : IdleBarPanel.restingSize
        let centreX = frame.midX
        let bottom = frame.minY
        setFrame(NSRect(x: (centreX - size.width / 2).rounded(), y: bottom, width: size.width, height: size.height),
                 display: true, animate: false)
    }
}

final class IdleBar {
    var onClick: (() -> Void)?
    private var panel: IdleBarPanel?
    private var view: IdleBarView?
    private var screenObserver: NSObjectProtocol?

    var hint: String = L10n.text("按 fn 开始听写") {
        didSet { view?.hint = hint; view?.needsDisplay = true }
    }

    func show() {
        if panel == nil { build() }
        position()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func build() {
        let rect = NSRect(origin: .zero, size: IdleBarPanel.restingSize)
        let p = IdleBarPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let v = IdleBarView(frame: rect)
        v.hint = hint
        v.onClick = { [weak self] in self?.onClick?() }
        p.contentView = v
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.level = .statusBar
        // No .fullScreenAuxiliary: the resting bar must not sit on top of full-screen
        // video, slides or games. (The recording pill does show there: dictating into
        // a full-screen app is deliberate.)
        p.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovable = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.animationBehavior = .none
        panel = p
        view = v
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.position()
        }
    }

    /// Bottom centre of the main screen, just above the Dock.
    private func position() {
        guard let p = panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = p.frame.size
        p.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + 8).rounded()))
    }
}

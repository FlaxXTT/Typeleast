import AppKit
import SwiftUI

// IdleBar.swift - the resting voice bar ("Show voice bar on desktop").
//
// A small charcoal capsule at the bottom centre of the screen. Hovering widens it and
// shows the shortcut; clicking it starts a dictation. Like the recording pill it is a
// non-activating panel: it never takes focus from the app being typed into, so a
// click on it still pastes into the field that had the cursor.

final class IdleBarView: NSView {
    var onClick: (() -> Void)?
    var hint = L10n.text("按 fn 听写")
    private(set) var hovering = false
    private var expansion: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var animationTimer: Timer?
    private var delayedExit: DispatchWorkItem?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBackingScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateBackingScale()
    }

    private func updateBackingScale() {
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    deinit {
        animationTimer?.invalidate()
        delayedExit?.cancel()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        delayedExit?.cancel()
        delayedExit = nil
        setHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        delayedExit?.cancel()
        // Updating the panel size also updates tracking areas. Ignore an exit
        // caused by that geometry change while the mouse is still on the bar.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.delayedExit = nil
            guard self.window?.frame.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation) != true else { return }
            self.setHover(false)
        }
        delayedExit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    func reset() {
        animationTimer?.invalidate()
        animationTimer = nil
        delayedExit?.cancel()
        delayedExit = nil
        hovering = false
        updateExpansion(0)
    }

    private func updateExpansion(_ value: CGFloat) {
        expansion = min(1, max(0, value))
        (window as? IdleBarPanel)?.setExpansion(expansion)
        needsDisplay = true
    }

    private func setHover(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        animationTimer?.invalidate()
        animationTimer = nil
        let target: CGFloat = value ? 1 : 0
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            updateExpansion(target)
            return
        }
        let initial = expansion
        let began = ProcessInfo.processInfo.systemUptime
        let duration = 0.28 * max(0.45, Double(abs(target - initial)))
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.updateExpansion(target)
                timer.invalidate()
                self.animationTimer = nil
                return
            }
            let t = min(1, (ProcessInfo.processInfo.systemUptime - began) / duration)
            let eased = 1 - pow(1 - t, 3)
            self.updateExpansion(initial + (target - initial) * CGFloat(eased))
            if t >= 1 {
                timer.invalidate()
                self.animationTimer = nil
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = max(1, window?.backingScaleFactor ?? layer?.contentsScale ?? 2)
        let pixel = 1 / scale
        let rect = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        context.clear(bounds)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let path = RoundedRectangle(cornerRadius: rect.height / 2, style: .continuous).path(in: rect).cgPath
        context.saveGState()
        context.addPath(path)
        context.clip()
        NSGradient(starting: VoiceBarPalette.surfaceBottom, ending: VoiceBarPalette.surfaceTop)?
            .draw(in: bounds, angle: 90)
        context.restoreGState()
        VoiceBarPalette.edge.setStroke()
        context.setLineWidth(pixel)
        context.addPath(path)
        context.strokePath()

        // The resting dots become a small waveform as the capsule unfolds.
        // Stagger the heights without leaving an animation running while idle.
        let symbolX = bounds.midX + (28 - bounds.midX) * expansion
        let heights: [CGFloat] = [6, 11, 16, 11, 6]
        for i in 0..<5 {
            let delay = CGFloat(i) * 0.06
            let progress = min(1, max(0, (expansion - delay) / (1 - delay)))
            let height = 3.2 + (heights[i] - 3.2) * progress
            let x = symbolX + CGFloat(i - 2) * 5
            VoiceBarPalette.ink.withAlphaComponent(0.6 + expansion * 0.35).setFill()
            let bar = NSRect(x: x - 1.6, y: bounds.midY - height / 2, width: 3.2, height: height)
            NSBezierPath(roundedRect: bar, xRadius: 1.6, yRadius: 1.6).fill()
        }
        let labelOpacity = min(1, max(0, (expansion - 0.35) / 0.65))
        guard labelOpacity > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: VoiceBarPalette.ink.withAlphaComponent(0.9 * labelOpacity),
            .paragraphStyle: paragraph,
        ]
        let text = hint as NSString
        let size = text.size(withAttributes: attributes)
        let labelX = 48 + (1 - labelOpacity) * 5
        text.draw(in: NSRect(x: labelX, y: bounds.midY - size.height / 2,
                             width: max(0, bounds.width - labelX - 10), height: size.height),
                  withAttributes: attributes)
    }
}

final class IdleBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static let restingSize = NSSize(width: 56, height: 16)
    static let expandedSize = NSSize(width: 176, height: 34)

    func resize(expanded: Bool) { setExpansion(expanded ? 1 : 0) }

    func setExpansion(_ progress: CGFloat) {
        let compact = Self.restingSize, expanded = Self.expandedSize
        let size = NSSize(width: compact.width + (expanded.width - compact.width) * progress,
                          height: compact.height + (expanded.height - compact.height) * progress)
        let centreX = frame.midX
        let bottom = frame.minY
        setFrame(NSRect(x: centreX - size.width / 2, y: bottom, width: size.width, height: size.height),
                 display: true, animate: false)
    }
}

final class IdleBar {
    var onClick: (() -> Void)?
    private var panel: IdleBarPanel?
    private var view: IdleBarView?
    private var screenObserver: NSObjectProtocol?

    var hint: String = L10n.text("按 fn 听写") {
        didSet { view?.hint = hint; view?.needsDisplay = true }
    }

    func show() {
        if panel == nil { build() }
        position()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        view?.reset()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    private func build() {
        let rect = NSRect(origin: .zero, size: IdleBarPanel.restingSize)
        let p = IdleBarPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let v = IdleBarView(frame: rect)
        v.wantsLayer = true
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
        p.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + 24).rounded()))
    }
}

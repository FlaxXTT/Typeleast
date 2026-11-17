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
    var countdown: String? {
        didSet {
            if let panel = window as? IdleBarPanel, panel.countdownVisible != (countdown != nil) {
                panel.countdownVisible = countdown != nil
                panel.setExpansion(expansion, animated: true)
            }
            needsDisplay = true
        }
    }
    private(set) var hovering = false
    private var expansion: CGFloat = 0
    private var opacityProgress: CGFloat = 0
    private var tracking: NSTrackingArea?
    private var animationTimer: Timer?
    private var delayedExit: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = VoiceBarPalette.appearance
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        appearance = VoiceBarPalette.appearance
    }

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
        opacityProgress = 0
        updateExpansion(0)
    }

    private func updateExpansion(_ value: CGFloat) {
        expansion = min(1, max(0, value))
        if window?.hasShadow != (expansion > 0) { window?.hasShadow = expansion > 0 }
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
            opacityProgress = target
            updateExpansion(target)
            return
        }
        let initial = expansion
        let initialOpacity = opacityProgress
        let began = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.updateExpansion(target)
                self.opacityProgress = target
                timer.invalidate()
                self.animationTimer = nil
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            let shape = VoiceBarGeometry.shapeProgress(elapsed / VoiceBarGeometry.shapeDuration)
            let opacity = min(1, elapsed / VoiceBarGeometry.opacityDuration)
            let easedOpacity = VoiceBarGeometry.opacityProgress(opacity)
            self.opacityProgress = initialOpacity + (target - initialOpacity) * CGFloat(easedOpacity)
            self.updateExpansion(initial + (target - initial) * CGFloat(shape))
            if opacity >= 1 {
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
        let radius = min(VoiceBarGeometry.radius, min(rect.width, rect.height) / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.setAlpha(0.5 + opacityProgress * 0.5)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer(); context.restoreGState() }
        NSColor(calibratedWhite: (128.0 / 255) * (1 - expansion), alpha: 1).setFill()
        VoiceBarPalette.edge.setStroke()
        context.setLineWidth(1)
        context.addPath(path)
        context.drawPath(using: .fillStroke)

        guard expansion > 0 else { return }
        let heights: [CGFloat] = [4, 7, 11, 15, 18, 18, 15, 11, 7, 4]
        for i in heights.indices {
            let height = 2 + (heights[i] - 2) * expansion
            let centre = min(bounds.midX, VoiceBarGeometry.hover.width / 2)
            let x = centre - VoiceBarGeometry.waveform.width / 2 + CGFloat(i) * 4
            VoiceBarPalette.ink.withAlphaComponent(opacityProgress).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: bounds.midY - height / 2, width: 2, height: height),
                         xRadius: 1, yRadius: 1).fill()
        }
        if let countdown, bounds.width >= 100 {
            (countdown as NSString).draw(in: NSRect(x: bounds.maxX - 38, y: bounds.midY - 7, width: 32, height: 14),
                                        withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                                         .foregroundColor: VoiceBarPalette.ink.withAlphaComponent(opacityProgress)])
        }
    }
}

final class IdleBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static let restingSize = VoiceBarGeometry.idle
    static let expandedSize = VoiceBarGeometry.hover
    var countdownVisible = false

    func resize(expanded: Bool) { setExpansion(expanded ? 1 : 0) }

    func setExpansion(_ progress: CGFloat, animated: Bool = false) {
        let compact = Self.restingSize, expanded = Self.expandedSize
        let width = expanded.width + (countdownVisible ? 40 : 0)
        let size = NSSize(width: compact.width + (width - compact.width) * progress,
                          height: compact.height + (expanded.height - compact.height) * progress)
        guard frame.size != size else { return }
        let centreX = frame.midX
        let bottom = frame.minY
        let target = NSRect(x: centreX - size.width / 2, y: bottom, width: size.width, height: size.height)
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = VoiceBarGeometry.shapeDuration
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.05, 0.6, 0.4, 0.95)
                animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true, animate: false)
        }
    }
}

final class IdleBar {
    var onClick: (() -> Void)?
    var countdown: String? { didSet { view?.countdown = countdown } }
    private var panel: IdleBarPanel?
    private var view: IdleBarView?
    private var screenObserver: NSObjectProtocol?

    var hint: String = L10n.text("按 fn 听写") {
        didSet { view?.hint = hint; view?.toolTip = hint; view?.needsDisplay = true }
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
        v.countdown = countdown
        p.countdownVisible = countdown != nil
        v.toolTip = hint
        v.onClick = { [weak self] in self?.onClick?() }
        p.appearance = VoiceBarPalette.appearance
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

import AppKit

// RecordingBar.swift - the on-screen recording indicator (the "pill").
//
// A small floating capsule near the bottom-centre of the screen the mouse is on.
// It exists only while dictation is live (recording / thinking / a short result
// flash) and is completely gone when idle.
//
// Focus rules (hard requirement - the pill must never steal focus):
//   * NSPanel with .nonactivatingPanel: showing or clicking it never activates the
//     app, so the frontmost app keeps its keyboard focus.
//   * .borderless + becomesKeyOnlyIfNeeded + canBecomeMain == false: ordinary clicks
//     and the mere appearance of the pill never make it key.
//   * the only code path that may call makeKey() is an explicit press on the pill's
//     cancel affordance, and that affordance re-checks isKeyWindow before firing.
//   * it is shown with orderFrontRegardless() so no activation dance happens.
//   * clicks anywhere else on the pill are swallowed and do nothing.
//
// The "pure helpers" section is deliberately free of AppKit so the state machine,
// the level history and the formatting can be unit-tested headlessly.

// MARK: - pure helpers (no AppKit; exercised by Tests/main.swift)

enum RecordingBarFormat {
    /// Elapsed seconds as "m:ss"; negative / NaN / infinite input becomes "0:00".
    static func elapsed(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(min(seconds, 59999).rounded(.down))
        return String(total / 60) + ":" + String(format: "%02d", total % 60)
    }

    /// One-line preview of a transcript: every run of whitespace collapses to a single
    /// space, and anything past the character limit is cut and marked with an ellipsis.
    static func summary(_ text: String, limit: Int = 40) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }

    /// Maps any reading into a usable 0...1 level (NaN / infinite / negative -> 0).
    static func clampLevel(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// Height of a silent bar: silence reads as a row of dots, not an empty box.
    static let silenceFloor: Float = 0.08
    /// Expansion applied to the loudness: >1 pushes quiet speech down and keeps loud
    /// speech tall, so the two are easy to tell apart at a glance.
    static let expansion: Float = 1.4

    /// Bar height 0...1 for a loudness level from Recorder.loudness(rms:) (already on
    /// a decibel scale: 0 = room noise, 1 = a raised voice).
    static func barHeight(for level: Float) -> Float {
        let value = clampLevel(level)
        let shaped = Float(pow(Double(value), Double(expansion)))
        return min(1, max(silenceFloor, shaped))
    }
}

/// Rolling window of audio levels drawn as the scrolling waveform.
struct LevelHistory {
    static let defaultCapacity = 40

    let capacity: Int
    private(set) var samples: [Float] = []

    init(capacity: Int = LevelHistory.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { samples.count }
    var isEmpty: Bool { samples.isEmpty }
    var latest: Float { samples.last ?? 0 }

    /// Appends a level (clamped to 0...1), dropping the oldest sample past the capacity.
    mutating func append(_ level: Float) {
        samples.append(RecordingBarFormat.clampLevel(level))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Bar heights 0...1, oldest first, ready to draw.
    func heights() -> [Float] {
        samples.map { RecordingBarFormat.barHeight(for: $0) }
    }
}

/// Pure show/hide state machine behind the pill.
struct RecordingBarModel {
    enum Phase: Equatable {
        case hidden
        case recording
        case thinking
        case result
    }

    private(set) var phase: Phase = .hidden
    private(set) var destination = ""
    private(set) var detail = ""
    private(set) var resultText = ""
    private(set) var warning = false
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    private(set) var history: LevelHistory

    init(historyCapacity: Int = LevelHistory.defaultCapacity) {
        history = LevelHistory(capacity: historyCapacity)
    }

    var isVisible: Bool { phase != .hidden }

    mutating func showRecording(destination: String) {
        self.destination = destination
        detail = ""
        resultText = ""
        warning = false
        elapsed = 0
        level = 0
        history.reset()
        phase = .recording
    }

    /// Level ticks only mean something while listening; late ticks are ignored so a
    /// stale timer can never repaint the pill after it moved on.
    mutating func update(level: Float, elapsed: Double) {
        guard phase == .recording else { return }
        let value = RecordingBarFormat.clampLevel(level)
        self.level = value
        if elapsed.isFinite, elapsed >= 0 { self.elapsed = elapsed }
        history.append(value)
    }

    mutating func showThinking(detail: String) {
        self.detail = detail
        phase = .thinking
    }

    mutating func showResult(_ text: String, warning: Bool) {
        resultText = RecordingBarFormat.summary(text)
        self.warning = warning
        phase = .result
    }

    mutating func hide() {
        phase = .hidden
        destination = ""
        detail = ""
        resultText = ""
        warning = false
        elapsed = 0
        level = 0
        history.reset()
    }
}

// MARK: - AppKit

/// Borderless overlay panel that may hold key status only while the user is pressing
/// the cancel affordance. It never activates the app.
final class PillPanel: NSPanel {
    private var keyAllowedForCancelPress = false

    override var canBecomeKey: Bool { keyAllowedForCancelPress }
    override var canBecomeMain: Bool { false }

    func allowKeyForCancelPress() { keyAllowedForCancelPress = true }
    func endCancelPress() { keyAllowedForCancelPress = false }
}

/// The pill's small cancel affordance. It takes the first click without activating
/// the app, and it only fires once the panel actually holds key status.
final class CancelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let panel = window as? PillPanel {
            panel.allowKeyForCancelPress()
            if !panel.isKeyWindow { panel.makeKey() }
            super.mouseDown(with: event)
            panel.endCancelPress()
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// Draws the capsule in its three looks (Typeless-style: a small dark capsule, a live
/// waveform, × to cancel and a stop button to finish). Only the two buttons are subviews.
final class PillView: NSView {
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var reduceMotion = false
    /// The recording cap; the countdown appears in the last `countdownSeconds`.
    var limitSeconds: Double = 120
    static let countdownSeconds: Double = 15
    /// How many of the most recent levels the waveform shows (about 1.5 s at 20 Hz).
    static let visibleBars = 30

    var model = RecordingBarModel() {
        didSet {
            if model.phase != oldValue.phase { phaseChanged() }
            needsDisplay = true
        }
    }

    private let cancelButton = CancelButton()
    private let stopButton = CancelButton()
    private var bars: [Float] = []
    private var spinnerPhase: CGFloat = 0
    private var pulse: CGFloat = 0

    static let height: CGFloat = 32
    /// Diameter of the cancel (left) and stop (right) buttons.
    static let buttonSize: CGFloat = 20
    /// Font of the result line.
    static let resultFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// Capsule width for the current look; the host sizes the panel to it.
    static func width(for model: RecordingBarModel, limit: Double) -> CGFloat {
        switch model.phase {
        case .hidden: return 100
        case .recording: return limit - model.elapsed <= countdownSeconds ? 206 : 168
        case .thinking: return 72
        case .result:
            let text = (model.resultText.isEmpty ? L10n.text("（无内容）") : model.resultText) as NSString
            let width = text.size(withAttributes: [.font: resultFont]).width
            return min(320, max(100, ceil(width) + 50))
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        bars = Array(repeating: 0, count: LevelHistory.defaultCapacity)
        configure(cancelButton, glyph: "✕", tip: L10n.text("取消听写（Esc）"), action: #selector(cancelPressed))
        configure(stopButton, glyph: "", tip: L10n.text("结束并整理"), action: #selector(stopPressed))
        addSubview(cancelButton)
        addSubview(stopButton)
    }

    private func configure(_ button: CancelButton, glyph: String, tip: String, action: Selector) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.attributedTitle = NSAttributedString(string: glyph, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.78),
        ])
        button.target = self
        button.action = action
        button.toolTip = tip
        button.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("RecordingBar is created in code only")
    }

    override var acceptsFirstResponder: Bool { false }

    /// Body clicks are deliberately ignored: they must not move, focus or close anything.
    override func mouseDown(with event: NSEvent) {}

    private var cancelRect: NSRect {
        let size = PillView.buttonSize
        return NSRect(x: 6, y: (bounds.height - size) / 2, width: size, height: size)
    }
    private var stopRect: NSRect {
        let size = PillView.buttonSize
        return NSRect(x: bounds.width - size - 6, y: (bounds.height - size) / 2, width: size, height: size)
    }

    override func layout() {
        super.layout()
        cancelButton.frame = cancelRect
        stopButton.frame = stopRect
    }

    @objc private func cancelPressed() {
        guard let panel = window as? PillPanel, panel.isKeyWindow else { return }
        onCancel?()
    }

    @objc private func stopPressed() {
        guard let panel = window as? PillPanel, panel.isKeyWindow else { return }
        onStop?()
    }

    private func phaseChanged() {
        spinnerPhase = 0
        pulse = 0
        if model.phase == .recording {
            bars = Array(repeating: 0, count: model.history.capacity)
        }
        cancelButton.isHidden = model.phase != .recording
        stopButton.isHidden = model.phase != .recording
        needsLayout = true
    }

    /// One 20 Hz animation step: scroll the waveform, advance the thinking dots,
    /// follow the live level. Bars take their sample heights as-is: easing each slot
    /// towards its neighbour's value would smear the peaks the user needs to see.
    func advance() {
        if !reduceMotion {
            spinnerPhase += 0.18
            if spinnerPhase > 2 * .pi { spinnerPhase -= 2 * .pi }
        }
        let slots = max(1, model.history.capacity)
        let targets = model.history.heights()
        let padding = max(0, slots - targets.count)
        bars = [Float](repeating: 0, count: padding) + Array(targets.suffix(slots))
        pulse += (CGFloat(model.level) - pulse) * 0.5
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSColor(calibratedWhite: 0.09, alpha: 0.92).setFill()
        capsule.fill()
        NSColor(calibratedWhite: 1.0, alpha: 0.12).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        switch model.phase {
        case .hidden:
            return
        case .recording:
            drawRecording()
        case .thinking:
            drawThinking()
        case .result:
            drawResult()
        }
    }

    // MARK: state looks

    private func drawRecording() {
        // cancel: a soft circle behind the × glyph
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: cancelRect).fill()

        // stop: a white disc with a dark rounded square, the "finish" affordance
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(ovalIn: stopRect).fill()
        let square = NSRect(x: stopRect.midX - 3.5, y: stopRect.midY - 3.5, width: 7, height: 7)
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: square, xRadius: 1.5, yRadius: 1.5).fill()

        // the microphone is live: a small red dot that brightens with the voice
        let live = reduceMotion ? 0.5 : min(1, pulse * 1.4)
        let dotRadius: CGFloat = 2.6
        let dotCentre = NSPoint(x: cancelRect.maxX + 9, y: bounds.midY)
        NSColor.systemRed.withAlphaComponent(0.6 + 0.4 * live).setFill()
        NSBezierPath(ovalIn: NSRect(x: dotCentre.x - dotRadius, y: dotCentre.y - dotRadius,
                                    width: dotRadius * 2, height: dotRadius * 2)).fill()

        let remaining = limitSeconds - model.elapsed
        var waveRight = stopRect.minX - 8
        if remaining <= PillView.countdownSeconds {
            let label = RecordingBarFormat.elapsed(max(0, remaining))
            drawText(label, x: stopRect.minX - 44, centerY: bounds.midY, width: 36,
                     font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                     color: NSColor.systemOrange)
            waveRight = stopRect.minX - 46
        }
        let waveLeft = dotCentre.x + dotRadius + 7
        let waveHeight = bounds.height - 8
        drawWaveform(NSRect(x: waveLeft, y: bounds.midY - waveHeight / 2,
                            width: waveRight - waveLeft, height: waveHeight))
    }

    private func drawThinking() {
        // three dots breathing in sequence
        let spacing: CGFloat = 10
        let centreX = bounds.midX
        for index in 0..<3 {
            let phase = spinnerPhase - CGFloat(index) * 0.9
            let wave = reduceMotion ? 0.6 : (0.35 + 0.65 * (0.5 + 0.5 * sin(phase)))
            let radius: CGFloat = 2.6 + (reduceMotion ? 0 : CGFloat(wave) * 0.7)
            let x = centreX + CGFloat(index - 1) * spacing
            NSColor.white.withAlphaComponent(CGFloat(wave)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - radius, y: bounds.midY - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func drawResult() {
        let rowY = bounds.midY
        let tint = model.warning ? NSColor.systemOrange : NSColor.systemGreen
        let centre = NSPoint(x: 18, y: rowY)
        tint.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - 8, y: centre.y - 8, width: 16, height: 16)).fill()
        tint.setStroke()
        tint.setFill()
        if model.warning {
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: centre.x, y: centre.y + 3.6))
            stem.line(to: NSPoint(x: centre.x, y: centre.y - 0.8))
            stem.lineWidth = 1.8
            stem.lineCapStyle = .round
            stem.stroke()
            NSBezierPath(ovalIn: NSRect(x: centre.x - 1, y: centre.y - 4, width: 2, height: 2)).fill()
        } else {
            let check = NSBezierPath()
            check.move(to: NSPoint(x: centre.x - 3.8, y: centre.y + 0.2))
            check.line(to: NSPoint(x: centre.x - 1.0, y: centre.y - 2.6))
            check.line(to: NSPoint(x: centre.x + 4.2, y: centre.y + 3.2))
            check.lineWidth = 1.8
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        }
        let text = model.resultText.isEmpty ? L10n.text("（无内容）") : model.resultText
        drawText(text, x: 34, centerY: rowY, width: bounds.width - 46,
                 font: PillView.resultFont,
                 color: NSColor.white)
    }

    // MARK: drawing primitives

    /// Thin vertical lines, mirrored around the centre line, newest on the right.
    /// Older samples fade out; silent samples are short and dim, so silence reads as
    /// a dotted line and speech as tall bright strokes.
    private func drawWaveform(_ rect: NSRect) {
        guard !bars.isEmpty, rect.width > 4 else { return }
        let shown = Array(bars.suffix(PillView.visibleBars))
        let slot = rect.width / CGFloat(shown.count)
        let lineWidth = min(1.6, max(1.0, slot * 0.45))
        let silent = CGFloat(RecordingBarFormat.silenceFloor)
        for (index, value) in shown.enumerated() {
            let x = rect.minX + slot * CGFloat(index) + (slot - lineWidth) / 2
            let magnitude = CGFloat(value)
            let height = max(lineWidth, magnitude * rect.height)
            let line = NSRect(x: x, y: rect.midY - height / 2, width: lineWidth, height: height)
            let age = CGFloat(index + 1) / CGFloat(shown.count)        // 0 oldest ... 1 newest
            let voiced = magnitude > silent + 0.02
            let alpha = (voiced ? 0.45 + 0.55 * age : 0.22 + 0.18 * age)
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: line, xRadius: lineWidth / 2, yRadius: lineWidth / 2).fill()
        }
    }

    private func drawText(_ string: String, x: CGFloat, centerY: CGFloat, width: CGFloat,
                          font: NSFont, color: NSColor) {
        guard !string.isEmpty, width > 0 else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let text = string as NSString
        let height = text.size(withAttributes: attributes).height
        let rect = NSRect(x: x, y: centerY - height / 2, width: width, height: height)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }
}

/// The public indicator. All entry points are safe to call from any thread; they hop to
/// the main queue when needed. While hidden the 20 Hz timer is invalidated, so the
/// indicator costs exactly zero CPU when idle.
final class RecordingBar {
    /// Set by the host to react to the pill's cancel affordance. It only ever fires for
    /// a direct press on that affordance, never for a click on the pill body.
    var onCancel: (() -> Void)?
    /// Set by the host to finish the recording from the pill's stop button.
    var onStop: (() -> Void)?
    /// Recording cap, for the last-seconds countdown.
    var limitSeconds: Double = 120 {
        didSet { pillBox?.limitSeconds = limitSeconds }
    }

    /// Largest panel the capsule can need; the panel is resized to the capsule per look.
    static let size = NSSize(width: 360, height: PillView.height)
    private static let tickInterval: TimeInterval = 1.0 / 20.0
    private static let resultHold: TimeInterval = 1.0
    private static let fadeDuration: TimeInterval = 1.0

    /// Both views are created on first use.
    ///
    /// Constructing them in init() allocated the panel, its layer backing and the
    /// window-server resources at launch — measured at roughly 40 MB resident
    /// while the pill is not even visible, and most launches never record. They
    /// stay nil until something actually needs to display them.
    private var panelBox: PillPanel?
    private var pillBox: PillView?
    private var model = RecordingBarModel()
    private var timer: Timer?
    private var resultShownAt: Date?
    private var fadeToken = 0

    /// Nothing is allocated here on purpose: the panel is the expensive part and
    /// is only needed once dictation actually starts (or on an explicit warm-up).
    init() {}

    /// The panel, built on first access. Construction now lives in createPanel().
    private var panel: PillPanel {
        if let existing = panelBox { return existing }
        let created = createPanel()
        panelBox = created
        return created
    }

    /// The pill view, built on first access.
    private var pill: PillView {
        if let existing = pillBox { return existing }
        let view = PillView(frame: NSRect(origin: .zero, size: RecordingBar.size))
        view.onCancel = { [weak self] in self?.onCancel?() }
        view.onStop = { [weak self] in self?.onStop?() }
        view.limitSeconds = limitSeconds
        pillBox = view
        return view
    }

    /// Build the pill panel. Reached from `panel`, i.e. on first display or on an
    /// explicit warm-up — never from the hot paths below.
    private func createPanel() -> PillPanel {
        let rect = NSRect(origin: .zero, size: RecordingBar.size)
        let created = PillPanel(contentRect: rect,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        created.contentView = pill
        created.isFloatingPanel = true
        created.becomesKeyOnlyIfNeeded = true
        created.level = .statusBar
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.isMovable = false
        created.isMovableByWindowBackground = false
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        created.animationBehavior = .none
        created.titleVisibility = .hidden
        created.isRestorable = false
        created.ignoresMouseEvents = false
        created.alphaValue = 1
        created.orderOut(nil)
        return created
    }

    /// Build the panel ahead of the first recording, without showing it.
    ///
    /// The host calls this once shortly after launch: the panel costs ~40 MB and
    /// need not exist while idle, but building it *during* the first recording
    /// would drop the first frame of the waveform.
    func warmUp() {
        _ = panel
    }

    deinit {
        timer?.invalidate()
    }

    /// True while the pill is on screen (recording, thinking or the result flash).
    /// Reads the box directly: answering must never build the panel.
    var isVisible: Bool { panelBox?.isVisible ?? false }

    /// The phase the pill is in; exposed for wiring and diagnostics.
    var phase: RecordingBarModel.Phase { model.phase }

    /// Read-only snapshot of the panel facts that guarantee the pill can never steal
    /// focus. Building it has no side effects, so ./test.sh can assert the focus
    /// contract against the real panel without ever putting it on screen.
    struct FocusPolicy: Equatable {
        var nonactivating: Bool
        var becomesKeyOnlyIfNeeded: Bool
        var floatingPanel: Bool
        var level: Int
        var joinsAllSpaces: Bool
        var fullScreenAuxiliary: Bool
        var canBecomeKey: Bool
        var canBecomeMain: Bool
        var onScreen: Bool
    }

    var focusPolicy: FocusPolicy {
        // Reads `panel`, so asking for the policy builds the panel on purpose:
        // ./test.sh asserts this contract against the real panel, which is the
        // only way to prove the pill cannot steal focus without showing it.
        FocusPolicy(nonactivating: panel.styleMask.contains(.nonactivatingPanel),
                    becomesKeyOnlyIfNeeded: panel.becomesKeyOnlyIfNeeded,
                    floatingPanel: panel.isFloatingPanel,
                    level: panel.level.rawValue,
                    joinsAllSpaces: panel.collectionBehavior.contains(.canJoinAllSpaces),
                    fullScreenAuxiliary: panel.collectionBehavior.contains(.fullScreenAuxiliary),
                    canBecomeKey: panel.canBecomeKey,
                    canBecomeMain: panel.canBecomeMain,
                    onScreen: panel.isVisible)
    }

    // MARK: API

    /// Starts the listening look. The destination is the bundle id the text will land in.
    func showRecording(destination: String) {
        onMain {
            self.cancelPendingFade()
            self.model.showRecording(destination: destination)
            self.pill.reduceMotion = RecordingBar.prefersReducedMotion
            self.pushModel()
            self.present()
            self.startTimer()
        }
    }

    /// Called about 20x per second while recording: live level 0...1 and elapsed seconds.
    func update(level: Float, elapsed: Double) {
        onMain {
            guard self.model.phase == .recording else { return }
            self.model.update(level: level, elapsed: elapsed)
            self.pushModel()
        }
    }

    /// Transcription / cleanup in flight.
    func showThinking(detail: String) {
        onMain {
            self.cancelPendingFade()
            self.model.showThinking(detail: detail)
            self.pill.reduceMotion = RecordingBar.prefersReducedMotion
            self.pushModel()
            self.present()
            self.startTimer()
        }
    }

    /// Brief confirmation, then a ~1 s fade out. A warning shows an amber mark instead.
    func showResult(_ text: String, warning: Bool) {
        onMain {
            self.cancelPendingFade()
            self.model.showResult(text, warning: warning)
            self.pill.reduceMotion = RecordingBar.prefersReducedMotion
            self.pushModel()
            self.present()
            self.startTimer()
            self.resultShownAt = Date()
        }
    }

    /// Hides immediately (no fade) and stops the animation timer.
    func hide() {
        onMain {
            self.cancelPendingFade()
            self.dismiss()
        }
    }

    // MARK: internals

    private static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func pushModel() {
        pill.model = model
        // Resize only a panel that exists and is showing: sizing must not build one.
        if let existing = panelBox, existing.isVisible { resizeToCapsule(existing) }
    }

    private func capsuleSize() -> NSSize {
        NSSize(width: PillView.width(for: model, limit: limitSeconds), height: PillView.height)
    }

    /// Keep the capsule centred on the same bottom-centre point as its width changes.
    private func resizeToCapsule(_ target: PillPanel) {
        let size = capsuleSize()
        guard target.frame.size != size else { return }
        let centreX = target.frame.midX
        target.setFrame(NSRect(x: (centreX - size.width / 2).rounded(), y: target.frame.minY,
                               width: size.width, height: size.height), display: true)
    }

    private func present() {
        positionOnMouseScreen()
        if panel.alphaValue != 1 {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            panel.animator().alphaValue = 1
            NSAnimationContext.endGrouping()
        }
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }

    /// Bottom-centre of whichever screen currently holds the mouse.
    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let target = screen else { return }
        let visible = target.visibleFrame
        let size = capsuleSize()
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + 24).rounded(),
                              width: size.width, height: size.height), display: false)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let ticker = Timer(timeInterval: RecordingBar.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard model.isVisible, panelBox?.isVisible == true else {
            stopTimer()
            return
        }
        if model.phase == .result, let shown = resultShownAt,
           Date().timeIntervalSince(shown) >= RecordingBar.resultHold {
            fadeOut()
            return
        }
        pill.advance()
    }

    private func cancelPendingFade() {
        resultShownAt = nil
        fadeToken += 1
    }

    private func fadeOut() {
        resultShownAt = nil
        stopTimer()
        guard model.phase == .result, panelBox?.isVisible == true else {
            dismiss()
            return
        }
        if RecordingBar.prefersReducedMotion {
            dismiss()
            return
        }
        fadeToken += 1
        let token = fadeToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = RecordingBar.fadeDuration
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A newer state may have re-presented the pill while this fade was running.
            guard let self = self, self.fadeToken == token, self.model.phase == .result else { return }
            self.dismiss()
        })
    }

    private func dismiss() {
        stopTimer()
        cancelPendingFade()
        // Only touch an existing panel: hiding must not build one.
        if let existing = panelBox {
            existing.orderOut(nil)
            existing.alphaValue = 1
            existing.endCancelPress()
        }
        model.hide()
        pushModel()
    }
}

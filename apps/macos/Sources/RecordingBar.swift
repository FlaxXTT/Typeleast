import AppKit
import SwiftUI
import QuartzCore

// RecordingBar.swift - the on-screen recording indicator (the "pill").
//
// A small floating capsule near the bottom-centre of the screen the mouse is on.
// It exists only while dictation is live (recording / thinking / a short result
// flash) and is completely gone when idle.
//
// Focus rules (hard requirement - the pill must never steal focus):
//   * NSPanel with .nonactivatingPanel: showing or clicking it never activates the
//     app, so the frontmost app keeps its keyboard focus.
//   * .borderless + canBecomeKey == false + canBecomeMain == false: nothing, not even
//     a press on × or ✓, makes it key. A key pill would receive the Cmd+V meant for
//     the field the user is dictating into.
//   * the two buttons take the first click and fire on mouse-up inside, as any button.
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
    static let silenceFloor: Float = 0.055
    /// Expansion applied to the loudness: >1 pushes quiet speech down and keeps loud
    /// speech tall, so the two are easy to tell apart at a glance.
    static let expansion: Float = 1.7

    /// Bar height 0...1 for a loudness level from Recorder.loudness(rms:) (already on
    /// a decibel scale: 0 = room noise, 1 = a raised voice).
    static func barHeight(for level: Float) -> Float {
        let value = clampLevel(level)
        // Keep the quiet baseline low and let a raised voice fill the waveform.
        let normalized = min(1, max(0, (value - 0.08) / 0.76))
        let shaped = Float(pow(Double(normalized), Double(expansion)))
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
    /// The mode used by this recording, or the translation target.
    private(set) var badge = ""
    private(set) var resultText = ""
    private(set) var warning = false
    private(set) var isStartingMicrophone = false
    private(set) var mode: RecordingBarMode = .handsFree
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    private(set) var voice = VoiceLevel()
    private(set) var history: LevelHistory

    init(historyCapacity: Int = LevelHistory.defaultCapacity) {
        history = LevelHistory(capacity: historyCapacity)
    }

    var isVisible: Bool { phase != .hidden }

    mutating func showRecording(destination: String, badge: String = "", mode: RecordingBarMode = .handsFree) {
        self.mode = mode
        self.destination = destination
        self.badge = badge
        detail = ""
        resultText = ""
        warning = false
        isStartingMicrophone = false
        elapsed = 0
        level = 0
        voice = VoiceLevel()
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
        voice = VoiceLevel(volume: value, signal: value, response: VoiceResponse.height(value), hasAudio: true)
    }

    mutating func update(voice: VoiceLevel, elapsed: Double) {
        guard phase == .recording else { return }
        update(level: voice.volume, elapsed: elapsed)
        self.voice = voice
    }

    mutating func showThinking(detail: String, startingMicrophone: Bool = false) {
        self.detail = detail
        isStartingMicrophone = startingMicrophone
        phase = .thinking
    }

    mutating func showResult(_ text: String, warning: Bool) {
        isStartingMicrophone = false
        resultText = RecordingBarFormat.summary(text)
        self.warning = warning
        phase = .result
    }

    mutating func hide() {
        phase = .hidden
        destination = ""
        detail = ""
        badge = ""
        resultText = ""
        warning = false
        isStartingMicrophone = false
        elapsed = 0
        level = 0
        voice = VoiceLevel()
        history.reset()
    }
}

// MARK: - AppKit

/// Borderless overlay panel that never becomes key and never activates the app, so the
/// field the user is dictating into keeps the keyboard, and the paste, throughout.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The pill's × and ✓ buttons. They take the first click without activating the app or
/// taking key status.
final class CancelButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// The desktop voice controls keep the same dark surface in either app appearance.
enum VoiceBarPalette {
    static let ink = NSColor.white
    static let surfaceTop = NSColor.black
    static let surfaceBottom = NSColor.black
    static let edge = NSColor.white.withAlphaComponent(0.32)
    static let card = NSColor(srgbRed: 29.0 / 255, green: 26.0 / 255, blue: 26.0 / 255, alpha: 1)
    static let finishSurface = NSColor.white
    static let finishInk = NSColor.black
    static let warning = NSColor(srgbRed: 240.0 / 255, green: 160.0 / 255, blue: 75.0 / 255, alpha: 1)
    static let appearance = NSAppearance(named: .darkAqua)!
}

/// Draws the capsule in its three looks (a dark capsule, a live
/// waveform, × to cancel and a stop button to finish). Only the two buttons are subviews.
final class PillView: NSView {
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var reduceMotion = false
    /// The recording cap; the countdown appears in the last `countdownSeconds`.
    var limitSeconds: Double = 120
    static let countdownSeconds: Double = 15
    static let visibleBars = VoiceWaveform.count

    var model = RecordingBarModel() {
        didSet {
            if model.phase != oldValue.phase || model.mode != oldValue.mode || model.isStartingMicrophone != oldValue.isStartingMicrophone {
                phaseChanged(from: oldValue)
            } else if model.phase == .recording, reduceMotion {
                _ = waveform.advance(level: model.voice, delta: 0.05, reduceMotion: true)
            }
            // The animation timer paints recording frames. Audio samples must
            // not schedule another independent series of redraws between them.
            if model.phase != .recording || reduceMotion { needsDisplay = true }
        }
    }

    private let cancelButton = CancelButton()
    private let stopButton = CancelButton()
    private var waveform = VoiceWaveform()
    private struct RecordingHandoff {
        let model: RecordingBarModel
        let waveform: VoiceWaveform
        let width: CGFloat
    }
    private var recordingHandoff: RecordingHandoff?
    private static let handoffHold: TimeInterval = 0.08
    private static let handoffFade: TimeInterval = 0.15
    private var spinnerPhase: CGFloat = 0
    private var phaseElapsed: Double = 0
    private var lastAdvancedAt = ProcessInfo.processInfo.systemUptime
    private static let ink = VoiceBarPalette.ink
    private var cancelHover = false
    private var stopHover = false
    private var cancelHoverAmount: CGFloat = 0
    private var stopHoverAmount: CGFloat = 0

    static let height: CGFloat = 34
    /// Scale the existing geometry together, including the waveform and hit areas.
    static let displayScale: CGFloat = 1
    /// Diameter of the cancel (left) and finish (right) buttons.
    static let buttonSize: CGFloat = 26

    var holdsRecordingWidth: Bool {
        recordingHandoff != nil && !reduceMotion && phaseElapsed < Self.handoffHold
    }

    /// Only presentation waits for the frozen frame. The model is already transcribing.
    var presentationWidth: CGFloat {
        if holdsRecordingWidth, let recordingHandoff { return recordingHandoff.width }
        return Self.width(for: model, limit: limitSeconds)
    }
    var presentationHeight: CGFloat { model.isStartingMicrophone ? VoiceBarGeometry.starting.height : Self.height }
    static func badgeWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 10, weight: .bold)
        return max(34, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12)
    }
    /// Font of the result line.
    static let resultFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// Capsule width for the current look; the host sizes the panel to it.
    static func width(for model: RecordingBarModel, limit: Double) -> CGFloat {
        switch model.phase {
        case .hidden: return 100
        case .recording:
            return model.mode.width + (limit - model.elapsed <= countdownSeconds ? 40 : 0)
        case .thinking:
            if model.isStartingMicrophone { return VoiceBarGeometry.starting.width }
            return 94 + min(220, ceil((model.detail as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width))
        case .result:
            if model.warning { return 70 }
            let text = (model.resultText.isEmpty ? L10n.text("（无内容）") : model.resultText) as NSString
            let width = text.size(withAttributes: [.font: resultFont]).width
            return min(320, max(100, ceil(width) + 50))
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appearance = VoiceBarPalette.appearance
        setBoundsSize(NSSize(width: frameRect.width / Self.displayScale, height: frameRect.height / Self.displayScale))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        configure(cancelButton, glyph: "", tip: L10n.text("取消听写（Esc）"), action: #selector(cancelPressed))
        configure(stopButton, glyph: "", tip: L10n.text("结束并整理"), action: #selector(stopPressed))
        cancelButton.onHover = { [weak self] hovering in
            self?.cancelHover = hovering
            self?.needsDisplay = true
        }
        stopButton.onHover = { [weak self] hovering in
            self?.stopHover = hovering
            self?.needsDisplay = true
        }
        addSubview(cancelButton)
        addSubview(stopButton)
    }

    private func configure(_ button: CancelButton, glyph: String, tip: String, action: Selector) {
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.attributedTitle = NSAttributedString(string: glyph, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: PillView.ink.withAlphaComponent(0.78),
        ])
        button.target = self
        button.action = action
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("RecordingBar is created in code only")
    }

    override var acceptsFirstResponder: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsSize(NSSize(width: newSize.width / Self.displayScale, height: newSize.height / Self.displayScale))
        needsLayout = true
    }

    private var drawingScale: CGFloat {
        max(0.5, (window?.backingScaleFactor ?? layer?.contentsScale ?? 2) * Self.displayScale)
    }

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

    /// Body clicks are deliberately ignored: they must not move, focus or close anything.
    override func mouseDown(with event: NSEvent) {}

    private var cancelRect: NSRect {
        let size = PillView.buttonSize
        return NSRect(x: 4, y: (bounds.height - size) / 2, width: size, height: size)
    }
    private var stopRect: NSRect {
        let size = PillView.buttonSize
        return NSRect(x: bounds.width - size - 4, y: (bounds.height - size) / 2, width: size, height: size)
    }

    override func layout() {
        super.layout()
        cancelButton.frame = cancelRect
        stopButton.frame = stopRect
    }

    @objc private func cancelPressed() { onCancel?() }

    @objc private func stopPressed() { onStop?() }

    private func phaseChanged(from previous: RecordingBarModel) {
        if previous.phase == .recording, model.phase == .thinking,
           !model.isStartingMicrophone, !reduceMotion {
            recordingHandoff = RecordingHandoff(model: previous, waveform: waveform, width: bounds.width)
        } else {
            recordingHandoff = nil
        }
        spinnerPhase = 0
        phaseElapsed = 0
        lastAdvancedAt = ProcessInfo.processInfo.systemUptime
        cancelHover = false
        stopHover = false
        cancelHoverAmount = 0
        stopHoverAmount = 0
        if model.phase == .recording {
            waveform.reset()
        }
        cancelButton.isHidden = model.isStartingMicrophone || (model.phase != .recording && model.phase != .thinking)
            || (model.phase == .recording && model.mode != .handsFree)
        stopButton.isHidden = model.phase != .recording || model.mode != .handsFree
        needsLayout = true
    }

    /// Time-based attack and release keep the wave smooth between audio updates.
    func advance(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let delta = max(0, min(0.1, now - lastAdvancedAt))
        lastAdvancedAt = now
        phaseElapsed += delta
        if reduceMotion || phaseElapsed >= Self.handoffHold + Self.handoffFade {
            recordingHandoff = nil
        }
        let cancelTarget: CGFloat = cancelHover ? 1 : 0
        let stopTarget: CGFloat = stopHover ? 1 : 0
        if reduceMotion {
            cancelHoverAmount = cancelTarget
            stopHoverAmount = stopTarget
        } else {
            let blend = CGFloat(1 - pow(0.85, delta * 60))
            cancelHoverAmount += (cancelTarget - cancelHoverAmount) * blend
            stopHoverAmount += (stopTarget - stopHoverAmount) * blend
        }
        if !reduceMotion {
            spinnerPhase = (spinnerPhase + CGFloat(delta * 3.6)).truncatingRemainder(dividingBy: 2 * .pi)
        }
        let waveChanged = model.phase == .recording
            ? waveform.advance(level: model.voice, delta: delta, reduceMotion: reduceMotion) : false
        let hoverChanged = abs(cancelTarget - cancelHoverAmount) > 0.001 || abs(stopTarget - stopHoverAmount) > 0.001
        if waveChanged || hoverChanged || model.phase == .thinking { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(VoiceBarGeometry.radius, min(bounds.width, bounds.height) / 2)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        let capsule = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius,
                             cornerHeight: radius, transform: nil)
        NSColor.black.withAlphaComponent(model.isStartingMicrophone ? 0.5 : 1).setFill()
        VoiceBarPalette.edge.setStroke()
        context.setLineWidth(1)
        context.addPath(capsule)
        context.drawPath(using: .fillStroke)
        context.saveGState()
        context.addPath(capsule)
        context.clip()
        defer { context.restoreGState() }

        switch model.phase {
        case .hidden:
            return
        case .recording:
            drawRecording(model, waveform: waveform, width: bounds.width)
        case .thinking:
            if model.isStartingMicrophone {
                drawStarting()
            } else if let recordingHandoff {
                drawHandoff(recordingHandoff, context: context)
            } else {
                drawThinking()
            }
        case .result:
            drawResult()
        }
    }

    // MARK: state looks

    private func fillBadge(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .circular)
        context.addPath(shape.path(in: rect).cgPath)
        context.fillPath()
    }

    private func drawHandoff(_ handoff: RecordingHandoff, context: CGContext) {
        let progress = min(1, max(0, (phaseElapsed - Self.handoffHold) / Self.handoffFade))
        let blend = CGFloat(progress * progress * (3 - 2 * progress))
        // Keep the cancel control stable while the two content layers crossfade.
        drawCancel()
        context.saveGState()
        context.setAlpha(1 - blend)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawRecording(handoff.model, waveform: handoff.waveform, width: handoff.width,
                      showsCancel: false, collapse: blend)
        context.endTransparencyLayer()
        context.restoreGState()
        if blend > 0 {
            context.saveGState()
            context.setAlpha(blend)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            drawThinking(showsCancel: false)
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    private func drawRecording(_ recording: RecordingBarModel, waveform: VoiceWaveform, width: CGFloat,
                               showsCancel: Bool = true, collapse: CGFloat = 0) {
        let content = NSRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        let handsFree = recording.mode == .handsFree
        let stop = NSRect(x: content.maxX - Self.buttonSize - 4, y: content.midY - Self.buttonSize / 2,
                          width: Self.buttonSize, height: Self.buttonSize)
        if handsFree {
            if showsCancel { drawCancel() }
            VoiceBarPalette.finishSurface.setFill()
            let expansion = reduceMotion ? 0 : stopHoverAmount * 1.8
            NSBezierPath(ovalIn: stop.insetBy(dx: -expansion, dy: -expansion)).fill()
            let c = NSPoint(x: stop.midX, y: stop.midY)
            let check = NSBezierPath()
            check.move(to: NSPoint(x: c.x - 5.5, y: c.y + 0.2))
            check.line(to: NSPoint(x: c.x - 1.8, y: c.y - 3.8))
            check.line(to: NSPoint(x: c.x + 5.8, y: c.y + 4.4))
            check.lineWidth = 2.2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            VoiceBarPalette.finishInk.setStroke()
            check.stroke()
        }
        let remaining = limitSeconds - recording.elapsed
        let countingDown = remaining <= Self.countdownSeconds
        let waveX = content.minX + (handsFree ? 38 : (recording.mode.width - VoiceBarGeometry.waveform.width) / 2)
        drawWaveform(NSRect(x: waveX, y: content.midY - VoiceBarGeometry.waveform.height / 2,
                            width: VoiceBarGeometry.waveform.width, height: VoiceBarGeometry.waveform.height),
                     waveform: waveform, collapse: collapse)
        if countingDown {
            let x = handsFree ? stop.minX - 40 : content.maxX - 36
            drawText(RecordingBarFormat.elapsed(max(0, remaining)), x: x, centerY: content.midY, width: 32,
                     font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), color: VoiceBarPalette.warning)
        }
    }

    private func drawThinking(showsCancel: Bool = true) {
        // three dots breathing in sequence
        let spacing: CGFloat = 10
        if showsCancel { drawCancel() }
        let centreX: CGFloat = 56
        for index in 0..<3 {
            let phase = spinnerPhase - CGFloat(index) * 0.9
            let wave = reduceMotion ? 0.6 : (0.35 + 0.65 * (0.5 + 0.5 * sin(phase)))
            let radius: CGFloat = 2.4
            let x = centreX + CGFloat(index - 1) * spacing
            let y = bounds.midY + (reduceMotion ? 0 : sin(phase) * 2)
            PillView.ink.withAlphaComponent(CGFloat(wave)).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
        if !model.detail.isEmpty {
            let x: CGFloat = 82
            drawProcessingText(model.detail, x: x, width: max(0, bounds.width - x - 10))
        }
    }

    private func drawStarting() {
        guard !reduceMotion, let context = NSGraphicsContext.current?.cgContext else { return }
        let colours = [NSColor.white.withAlphaComponent(0).cgColor,
                       NSColor.white.withAlphaComponent(0.35).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colours, locations: [0, 0.5, 1]) else { return }
        let x = CGFloat((phaseElapsed * 100).truncatingRemainder(dividingBy: Double(bounds.width + 40))) - 20
        context.drawLinearGradient(gradient, start: CGPoint(x: x - 16, y: bounds.midY),
                                   end: CGPoint(x: x + 16, y: bounds.midY), options: [])
    }

    private func drawResult() {
        let rowY = bounds.midY
        let tint = model.warning ? VoiceBarPalette.warning : VoiceBarPalette.ink
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
        let text = model.warning ? L10n.text("错误") : (model.resultText.isEmpty ? L10n.text("（无内容）") : model.resultText)
        drawText(text, x: model.warning ? 31 : 34, centerY: rowY, width: bounds.width - (model.warning ? 37 : 46),
                 font: model.warning ? .systemFont(ofSize: 10, weight: .medium) : PillView.resultFont,
                 color: PillView.ink)
    }

    // MARK: drawing primitives

    /// A quiet grey disc with a dark ×.
    private func drawCancel() {
        NSColor(calibratedWhite: 0.28 + cancelHoverAmount * 0.06, alpha: 1).setFill()
        let expansion = reduceMotion ? 0 : cancelHoverAmount * 1.8
        NSBezierPath(ovalIn: cancelRect.insetBy(dx: -expansion, dy: -expansion)).fill()
        let c = NSPoint(x: cancelRect.midX, y: cancelRect.midY), r: CGFloat = 4.6
        let angle: CGFloat = 0
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: c.x + x * cos(angle) - y * sin(angle), y: c.y + x * sin(angle) + y * cos(angle))
        }
        let cross = NSBezierPath()
        cross.move(to: point(-r, -r)); cross.line(to: point(r, r))
        cross.move(to: point(-r, r)); cross.line(to: point(r, -r))
        cross.lineWidth = 1.6
        cross.lineCapStyle = .round
        PillView.ink.setStroke()
        cross.stroke()
    }

    /// Stationary white bars change height around the centre line.
    private func drawWaveform(_ rect: NSRect, waveform: VoiceWaveform, collapse: CGFloat = 0) {
        guard rect.width > 4, let context = NSGraphicsContext.current?.cgContext else { return }
        let width: CGFloat = 2
        let gap: CGFloat = 2
        let total = CGFloat(Self.visibleBars) * width + CGFloat(Self.visibleBars - 1) * gap
        let origin = rect.midX - total / 2
        context.saveGState()
        context.clip(to: rect)
        for index in 0..<Self.visibleBars {
            let height = 2 + (CGFloat(waveform.heights[index]) - 2) * (1 - collapse)
            let line = NSRect(x: origin + CGFloat(index) * (width + gap), y: rect.midY - height / 2,
                              width: width, height: height)
            PillView.ink.withAlphaComponent(waveform.opacities[index]).setFill()
            NSBezierPath(roundedRect: line, xRadius: 1, yRadius: 1).fill()
        }
        context.restoreGState()
    }

    /// Fixed travel speed keeps long and short processing labels equally calm.
    private func drawProcessingText(_ text: String, x: CGFloat, width: CGFloat) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        guard !reduceMotion, let context = NSGraphicsContext.current?.cgContext else {
            drawText(text, x: x, centerY: bounds.midY, width: width, font: font, color: PillView.ink)
            return
        }
        let textWidth = min(width, ceil((text as NSString).size(withAttributes: [.font: font]).width))
        let travel = textWidth + 70
        let position = x + travel - CGFloat((phaseElapsed * 55).truncatingRemainder(dividingBy: Double(travel))) - 35
        context.saveGState()
        context.clip(to: NSRect(x: x, y: 0, width: width, height: bounds.height))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawText(text, x: x, centerY: bounds.midY, width: width, font: font,
                 color: NSColor(calibratedWhite: 0.59, alpha: 1))
        context.setBlendMode(.sourceAtop)
        let colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.cgColor,
                      NSColor.white.withAlphaComponent(0).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: position - 35, y: bounds.midY),
                                   end: CGPoint(x: position + 35, y: bounds.midY), options: [])
        context.endTransparencyLayer()
        context.restoreGState()
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
/// the main queue when needed. While hidden the drawing timer is invalidated, so the
/// indicator costs exactly zero CPU when idle.
final class RecordingBar {
    var onDismiss: (() -> Void)?
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
    static let size = VoiceBarGeometry.overlay
    private static let tickInterval: TimeInterval = 1.0 / 60.0
    private static let resultHold: TimeInterval = 1.0
    private static let fadeDuration: TimeInterval = VoiceBarGeometry.opacityDuration

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
    private var timerPhase: RecordingBarModel.Phase?
    private var fadeToken = 0
    private var isDismissing = false
    private var screenCheckedAt: Double = 0
    private var mouseScreenNumber: NSNumber?
    private var microphoneHintPanel: PillPanel?
    private var microphoneHintDismissal: DispatchWorkItem?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

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
        let view = PillView(frame: NSRect(x: (Self.size.width - 116) / 2, y: VoiceBarGeometry.bottomInset, width: 116, height: PillView.height))
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
        created.appearance = VoiceBarPalette.appearance
        created.contentView = RecordingOverlayHost(pill: pill)
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
        created.hasShadow = false // two specified shadows are drawn inside the transparent carrier
        created.animationBehavior = .none
        created.titleVisibility = .hidden
        created.isRestorable = false
        created.ignoresMouseEvents = true
        created.acceptsMouseMovedEvents = true
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
        stopPointerTracking()
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
    func showRecording(destination: String, badge: String = "", mode: RecordingBarMode = .handsFree) {
        onMain {
            self.cancelPendingFade()
            self.model.showRecording(destination: destination, badge: badge, mode: mode)
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

    /// The capture callback performs FFT work; the UI receives only its snapshot.
    func update(voice: VoiceLevel, elapsed: Double) {
        onMain {
            guard self.model.phase == .recording else { return }
            self.model.update(voice: voice, elapsed: elapsed)
            self.pushModel()
        }
    }

    /// A short reminder after cold/idle capture. It never takes keyboard or mouse focus.
    func showMicrophoneHint(_ name: String) {
        onMain { [self] in
            self.hideMicrophoneHint()
            let view = MicrophoneHintView(name: name)
            let hint = PillPanel(contentRect: NSRect(origin: .zero, size: view.fittingSize),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            hint.appearance = VoiceBarPalette.appearance
            hint.contentView = view
            hint.isFloatingPanel = true
            hint.becomesKeyOnlyIfNeeded = true
            hint.level = .statusBar
            hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            hint.hidesOnDeactivate = false
            hint.isReleasedWhenClosed = false
            hint.isOpaque = false
            hint.backgroundColor = .clear
            hint.hasShadow = true
            hint.ignoresMouseEvents = true
            hint.animationBehavior = .none
            self.microphoneHintPanel = hint
            self.positionMicrophoneHint()
            hint.orderFrontRegardless()
            let dismissal = DispatchWorkItem { [weak self, weak hint] in
                guard let self, self.microphoneHintPanel === hint else { return }
                self.hideMicrophoneHint()
            }
            self.microphoneHintDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: dismissal)
        }
    }

    private func positionMicrophoneHint() {
        guard let hint = microphoneHintPanel, let bar = panelBox, let host = bar.contentView as? RecordingOverlayHost else { return }
        host.layoutSubtreeIfNeeded()
        let anchor = bar.convertToScreen(NSRect(x: host.bounds.midX, y: host.hintTop, width: 0, height: 0))
        hint.setFrameOrigin(NSPoint(x: (anchor.midX - hint.frame.width / 2).rounded(), y: (anchor.maxY + 8).rounded()))
    }

    private func hideMicrophoneHint() {
        microphoneHintDismissal?.cancel()
        microphoneHintDismissal = nil
        microphoneHintPanel?.orderOut(nil)
        microphoneHintPanel = nil
    }

    /// Transcription / cleanup in flight.
    func showThinking(detail: String, startingMicrophone: Bool = false) {
        onMain {
            self.cancelPendingFade()
            self.hideMicrophoneHint()
            self.model.showThinking(detail: detail.isEmpty ? "thinking" : detail, startingMicrophone: startingMicrophone)
            self.pill.reduceMotion = RecordingBar.prefersReducedMotion
            self.pushModel()
            self.present()
            self.startTimer()
        }
    }

    /// Brief confirmation, then a short fade out. A warning shows an amber mark instead.
    func showResult(_ text: String, warning: Bool) {
        onMain {
            self.cancelPendingFade()
            self.hideMicrophoneHint()
            self.model.showResult(text, warning: warning)
            self.pill.reduceMotion = RecordingBar.prefersReducedMotion
            self.pushModel()
            self.present()
            self.stopTimer()
            self.stopPointerTracking()
            self.startTimer()
        }
    }

    /// Stop interaction immediately, then fade the visible capsule over 500ms.
    func hide() {
        onMain {
            self.cancelPendingFade()
            self.stopTimer()
            self.stopPointerTracking()
            self.hideMicrophoneHint()
            guard let panel = self.panelBox, panel.isVisible, !Self.prefersReducedMotion else {
                self.dismiss()
                return
            }
            panel.ignoresMouseEvents = true
            self.isDismissing = true
            let token = self.fadeToken
            NSAnimationContext.runAnimationGroup { context in
                context.duration = VoiceBarGeometry.opacityDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.fadeToken == token else { return }
                self.dismiss()
            }
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
        let previous = pill.model
        let wasCountingDown = limitSeconds - previous.elapsed <= PillView.countdownSeconds
        let isCountingDown = limitSeconds - model.elapsed <= PillView.countdownSeconds
        let widthChanged = previous.phase != model.phase || previous.badge != model.badge
            || previous.detail != model.detail || previous.resultText != model.resultText
            || previous.mode != model.mode || previous.isStartingMicrophone != model.isStartingMicrophone
            || wasCountingDown != isCountingDown
        pill.model = model
        (panelBox?.contentView as? RecordingOverlayHost)?.apply(model)
        // Resize only a panel that exists and is showing: sizing must not build one.
        if widthChanged, let existing = panelBox, existing.isVisible { resizeToCapsule(existing) }
    }

    private func capsuleSize() -> NSSize {
        NSSize(width: (pill.presentationWidth * PillView.displayScale).rounded(),
               height: pill.presentationHeight * PillView.displayScale)
    }

    /// Keep the capsule centred on the same bottom-centre point as its width changes.
    private func resizeToCapsule(_ target: PillPanel) {
        let size = capsuleSize()
        let frame = NSRect(x: ((Self.size.width - size.width) / 2).rounded(), y: VoiceBarGeometry.bottomInset,
                           width: size.width, height: size.height)
        guard pill.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.prefersReducedMotion ? 0 : VoiceBarGeometry.shapeDuration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.05, 0.6, 0.4, 0.95)
            pill.animator().setFrameOrigin(frame.origin)
            pill.animator().setFrameSize(frame.size)
        }
        target.contentView?.needsLayout = true
        positionMicrophoneHint()
        updatePointerPassthrough()
    }

    private func present() {
        let entering = !panel.isVisible
        if entering || model.phase == .recording { positionOnMouseScreen() }
        if entering {
            let size = capsuleSize()
            pill.frame = NSRect(x: (Self.size.width - size.width) / 2, y: VoiceBarGeometry.bottomInset, width: size.width, height: size.height)
            (panel.contentView as? RecordingOverlayHost)?.apply(model)
            panel.contentView?.needsLayout = true
        }
        if panel.alphaValue != 1 {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            panel.animator().alphaValue = 1
            NSAnimationContext.endGrouping()
        }
        panel.invalidateShadow()
        if entering && !Self.prefersReducedMotion { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        startPointerTracking()
        if entering && !Self.prefersReducedMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = VoiceBarGeometry.opacityDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
        }
        updatePointerPassthrough()
    }

    /// Bottom-centre of whichever screen currently holds the mouse.
    private func positionOnMouseScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let target = screen else { return }
        mouseScreenNumber = target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let visible = target.visibleFrame
        let size = Self.size
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.minY + 24 - VoiceBarGeometry.bottomInset).rounded(),
                              width: size.width, height: size.height), display: false)
        positionMicrophoneHint()
    }

    private func updatePointerPassthrough() {
        guard let panelBox, let pillBox else { return }
        let interactive = (model.phase == .recording && model.mode == .handsFree)
            || (model.phase == .thinking && !model.isStartingMicrophone)
        let rect = pillBox.layer?.presentation()?.frame ?? pillBox.frame
        let inside = VoiceBarGeometry.contains(NSEvent.mouseLocation, in: panelBox.convertToScreen(rect))
        let ignore = isDismissing || !interactive || !inside
        if panelBox.ignoresMouseEvents != ignore { panelBox.ignoresMouseEvents = ignore }
    }

    private func startPointerTracking() {
        let interactive = (model.phase == .recording && model.mode == .handsFree)
            || (model.phase == .thinking && !model.isStartingMicrophone)
        guard interactive else { stopPointerTracking(); return }
        if globalMouseMonitor == nil {
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] _ in
                self?.updatePointerPassthrough()
            }
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
                self?.updatePointerPassthrough()
                return event
            }
        }
    }

    private func stopPointerTracking() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
    }

    private func startTimer() {
        guard timer == nil || timerPhase != model.phase else { return }
        stopTimer()
        let interval = model.phase == .result ? Self.resultHold : pill.reduceMotion ? 0.05 : Self.tickInterval
        let ticker = Timer(timeInterval: interval, repeats: model.phase != .result) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        timerPhase = model.phase
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        timerPhase = nil
    }

    private func tick() {
        guard model.isVisible, panelBox?.isVisible == true else {
            stopTimer()
            return
        }
        if model.phase == .result {
            fadeOut()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - screenCheckedAt >= 0.1 {
            screenCheckedAt = now
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
               screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber != mouseScreenNumber {
                positionOnMouseScreen()
            }
        }
        let wasHoldingWidth = pill.holdsRecordingWidth
        pill.advance(at: now)
        updatePointerPassthrough()
        if wasHoldingWidth && !pill.holdsRecordingWidth, let panelBox {
            resizeToCapsule(panelBox)
        }
    }

    private func cancelPendingFade() {
        fadeToken += 1
        isDismissing = false
    }

    private func fadeOut() {
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
        isDismissing = true
        let token = fadeToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = RecordingBar.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A newer state may have re-presented the pill while this fade was running.
            guard let self = self, self.fadeToken == token, self.model.phase == .result else { return }
            self.dismiss()
        })
    }

    private func dismiss() {
        hideMicrophoneHint()
        stopTimer()
        stopPointerTracking()
        cancelPendingFade()
        // Only touch an existing panel: hiding must not build one.
        if let existing = panelBox {
            existing.orderOut(nil)
            existing.alphaValue = 1
        }
        model.hide()
        pushModel()
        onDismiss?()
    }
}


final class MicrophoneHintView: NSView {
    private let name: String
    private static let titleFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let nameFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    init(name: String) {
        self.name = name
        let width = min(300, max(160, ceil((name as NSString).size(withAttributes: [.font: Self.nameFont]).width) + 48))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 46))
        appearance = VoiceBarPalette.appearance
    }
    required init?(coder: NSCoder) { fatalError("Microphone hint is created in code") }
    override var fittingSize: NSSize { frame.size }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: min(99, rect.height / 2), yRadius: min(99, rect.height / 2))
        VoiceBarPalette.card.setFill()
        shape.fill()
        VoiceBarPalette.edge.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(paletteColors: [VoiceBarPalette.ink]))
        let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        if let symbol {
            NSGraphicsContext.saveGraphicsState()
            let iconRect = NSRect(x: 13, y: 14, width: 14, height: 18)
            symbol.draw(in: iconRect)
            NSGraphicsContext.restoreGraphicsState()
        }
        (L10n.text("当前麦克风") as NSString).draw(at: NSPoint(x: 37, y: 27), withAttributes: [
            .font: Self.titleFont, .foregroundColor: VoiceBarPalette.ink.withAlphaComponent(0.6)])
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (name as NSString).draw(in: NSRect(x: 37, y: 8, width: bounds.width - 48, height: 17),
                               withAttributes: [.font: Self.nameFont, .foregroundColor: VoiceBarPalette.ink,
                                                .paragraphStyle: paragraph])
    }
}

import AppKit
import SwiftUI
import QuartzCore

// RecordingBar.swift - the on-screen recording indicator (the "pill").
//
// A small floating capsule near the bottom-centre of the screen the mouse is on.
// It appears for dictation and for a brief text-selection count.
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
    private static let selectionWords: NSRegularExpression = {
        let han = #"[\p{L}&&\p{Han}]"#
        let letter = #"[\p{L}&&[^\p{Han}]]\p{M}*"#
        let word = "(?:\(letter))+(?:['’‐‑-](?:\(letter))+)*"
        return try! NSRegularExpression(pattern: han + "|" + word)
    }()

    /// Each Han character and each alphabetic word contribute one to the total.
    static func selectionCount(_ text: String) -> String {
        let count = selectionWords.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        return L10n.formattedNumber(NSNumber(value: count)) + " words"
    }

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
        case selectionCount
    }

    enum ThinkingActivity: Equatable {
        case cleanup
        case prompt
        case translation
        case transcription
    }

    static let cleanupSubtitles = [
        "Certify", "Polishing", "Refining", "Editing", "Tidying", "Organizing",
        "Structuring", "Revising", "Proofreading", "Reviewing", "Finalizing",
    ]

    private(set) var phase: Phase = .hidden
    private(set) var isProcessingCapture = false
    private(set) var thinkingActivity: ThinkingActivity?
    private var lastCleanupSubtitle: String?
    private(set) var destination = ""
    private(set) var detail = ""
    /// The mode used by this recording, or the translation target.
    private(set) var badge = ""
    private(set) var resultText = ""
    private(set) var warning = false
    private(set) var requiresReview = false
    private(set) var isStartingMicrophone = false
    private(set) var mode: RecordingBarMode = .handsFree
    private(set) var elapsed: Double = 0
    private(set) var level: Float = 0
    private(set) var history: LevelHistory

    init(historyCapacity: Int = LevelHistory.defaultCapacity) {
        history = LevelHistory(capacity: historyCapacity)
    }

    var isVisible: Bool { phase != .hidden }
    var showsRecordingControls: Bool { phase == .recording && mode == .handsFree }
    var isDictationThinking: Bool { thinkingActivity == .transcription || thinkingActivity == .cleanup }
    var thinkingSubtitle: String? {
        switch thinkingActivity {
        case .cleanup: return lastCleanupSubtitle
        case .prompt: return "Prompt"
        case .translation: return "Translation"
        case .transcription, nil: return nil
        }
    }

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
        history.reset()
        phase = .recording
        isProcessingCapture = false
        thinkingActivity = nil
        requiresReview = false
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

    mutating func updateBadge(_ badge: String) {
        guard phase == .recording else { return }
        self.badge = badge
    }

    mutating func showThinking(detail: String, startingMicrophone: Bool = false, activity: ThinkingActivity? = nil) {
        self.detail = detail
        isStartingMicrophone = startingMicrophone
        if startingMicrophone || phase != .thinking || activity != nil { thinkingActivity = activity }
        phase = .thinking
        if startingMicrophone { isProcessingCapture = false }
    }

    mutating func processing(activity: ThinkingActivity = .transcription) {
        showThinking(detail: "", activity: activity)
        isProcessingCapture = true
    }

    mutating func beginCertification() -> Bool {
        guard phase == .thinking, thinkingActivity == .transcription, !isStartingMicrophone else { return false }
        lastCleanupSubtitle = Self.cleanupSubtitles.filter { $0 != lastCleanupSubtitle }.randomElement()
        detail = ""
        thinkingActivity = .cleanup
        return true
    }

    mutating func showResult(_ text: String, warning: Bool, requiresReview: Bool = false) {
        isProcessingCapture = false
        thinkingActivity = nil
        isStartingMicrophone = false
        resultText = RecordingBarFormat.summary(text)
        self.warning = warning
        self.requiresReview = requiresReview
        phase = .result
    }

    mutating func showSelectionCount(_ label: String) {
        hide()
        phase = .selectionCount
        resultText = label
    }

    mutating func hide() {
        phase = .hidden
        isProcessingCapture = false
        thinkingActivity = nil
        destination = ""
        detail = ""
        badge = ""
        resultText = ""
        warning = false
        requiresReview = false
        isStartingMicrophone = false
        elapsed = 0
        level = 0
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
    var handoffPause: TimeInterval = 0.08
    var countdownInsideCapsule = true
    /// The recording cap; the countdown appears in the last `countdownSeconds`.
    var limitSeconds: Double = 120
    static let countdownSeconds: Double = 15

    var model = RecordingBarModel() {
        didSet {
            if model.phase != oldValue.phase || model.mode != oldValue.mode || model.isStartingMicrophone != oldValue.isStartingMicrophone {
                phaseChanged(from: oldValue)
            }
            if model.thinkingActivity != oldValue.thinkingActivity {
                certificationBeganAt = model.thinkingActivity == .cleanup ? phaseElapsed : nil
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
    private static let handoffFade = VoiceBarGeometry.shapeDuration
    private var spinnerPhase: CGFloat = 0
    private var phaseElapsed: Double = 0
    private var certificationBeganAt: TimeInterval?
    private var lastAdvancedAt = ProcessInfo.processInfo.systemUptime
    private static let ink = VoiceBarPalette.ink
    private var cancelHover = false
    private var stopHover = false
    private var cancelHoverAmount: CGFloat = 0
    private var stopHoverAmount: CGFloat = 0

    static let height: CGFloat = 38
    static let thinkingWidth: CGFloat = 150
    /// Scale the existing geometry together, including the waveform and hit areas.
    static let displayScale: CGFloat = 1
    /// Diameter of the cancel (left) and finish (right) buttons.
    static let buttonSize: CGFloat = 24

    var holdsRecordingWidth: Bool {
        recordingHandoff != nil && !reduceMotion && phaseElapsed < handoffPause
    }

    var presentationWidth: CGFloat {
        if holdsRecordingWidth, let recordingHandoff { return recordingHandoff.width }
        if !countdownInsideCapsule, model.phase == .recording { return model.mode.width }
        return Self.width(for: model, limit: limitSeconds)
    }
    var presentationHeight: CGFloat { model.isStartingMicrophone ? VoiceBarGeometry.starting.height : Self.height }
    static func badgeWidth(_ text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = InterfaceTypography.localizedAppKit(10, weight: .bold)
        return max(34, ceil((text as NSString).size(withAttributes: [.font: font]).width) + 12)
    }
    /// Font of the result line.
    static let resultFont = InterfaceTypography.localizedAppKit(14, weight: .medium)
    private static let dictationTitleSize: CGFloat = 21
    private static let stackedDictationTitleScale = 16 / dictationTitleSize
    private static let dictationThinkingFont = NSFont(name: "Futura-Medium", size: dictationTitleSize)
        ?? NSFont.systemFont(ofSize: dictationTitleSize, weight: .semibold)
    private static let thinkingFont = NSFontManager.shared.convert(dictationThinkingFont, toSize: 15)
    private static let thinkingSubtitleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let cleanupSubtitleFont = NSFont(name: "BigCaslon-Medium", size: 13)
        ?? NSFont(name: "Georgia", size: 12)
        ?? NSFont(name: "Times New Roman", size: 12)
        ?? thinkingSubtitleFont
    private static let cleanupSubtitleInset: CGFloat = 6
    private static let processingFont = InterfaceTypography.localizedAppKit(13, weight: .medium)
    private static let thinkingWaveCount = 8
    private static let thinkingWaveSpacing: CGFloat = 6
    private static let thinkingWaveRadius: CGFloat = 1.75
    private static let thinkingWaveGap: CGFloat = 8
    private static let thinkingWaveWidth = CGFloat(thinkingWaveCount - 1) * thinkingWaveSpacing + 2 * thinkingWaveRadius
    private static let dictationThinkingTextWidth: CGFloat = {
        let title = ("Thinking" as NSString).size(withAttributes: [.font: dictationThinkingFont]).width
        let subtitleAttributes: [NSAttributedString.Key: Any] = [.font: cleanupSubtitleFont]
        let subtitle = RecordingBarModel.cleanupSubtitles
            .map { ($0 as NSString).size(withAttributes: subtitleAttributes).width }
            .max() ?? 0
        return ceil(max(title, subtitle + cleanupSubtitleInset)) + 1
    }()

    var certificationMotion: (lift: CGFloat, titleScale: CGFloat, reveal: CGFloat) {
        guard model.thinkingActivity == .cleanup else { return (0, 1, 0) }
        let settled: (CGFloat, CGFloat, CGFloat) = (8, Self.stackedDictationTitleScale, 1)
        guard !reduceMotion, let certificationBeganAt else { return settled }
        let elapsed = phaseElapsed - certificationBeganAt
        guard elapsed < 0.395 else { return settled }

        func ease(_ fraction: TimeInterval) -> CGFloat {
            let t = min(1, max(0, fraction))
            return CGFloat(t * t * (3 - 2 * t))
        }
        let rise = ease(elapsed / 0.27)
        let settle = ease((elapsed - 0.27) / 0.125)
        let titleScale = 1 - (1 - Self.stackedDictationTitleScale) * rise
        return (9.3 * rise - 1.3 * settle, titleScale, ease((elapsed - 0.17) / 0.215))
    }

    private static func thinkingTextWidth(for model: RecordingBarModel) -> CGFloat {
        if model.isDictationThinking { return dictationThinkingTextWidth }
        let titleWidth = ceil(("Thinking" as NSString).size(withAttributes: [.font: thinkingFont]).width) + 1
        guard let subtitle = model.thinkingSubtitle else { return titleWidth }
        let subtitleWidth = ceil((subtitle as NSString).size(withAttributes: [.font: thinkingSubtitleFont]).width) + 1
        return max(titleWidth, subtitleWidth)
    }

    /// Capsule width for the current look; the host sizes the panel to it.
    static func width(for model: RecordingBarModel, limit: Double) -> CGFloat {
        switch model.phase {
        case .hidden: return 100
        case .recording:
            return model.mode.width + (limit - model.elapsed <= countdownSeconds ? 40 : 0)
        case .thinking:
            if model.isStartingMicrophone { return VoiceBarGeometry.starting.width }
            if model.isProcessingCapture || model.detail.isEmpty {
                let textWidth = thinkingTextWidth(for: model)
                return max(thinkingWidth, textWidth + thinkingWaveGap + thinkingWaveWidth + 26)
            }
            return 94 + min(220, ceil((model.detail as NSString).size(withAttributes: [.font: processingFont]).width))
        case .selectionCount:
            return ceil((model.resultText as NSString).size(withAttributes: [.font: resultFont]).width) + 36
        case .result:
            if model.requiresReview { return 106 }
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
            .font: InterfaceTypography.localizedAppKit(10, weight: .bold),
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
        if Self.displayScale != 1 {
            setBoundsSize(NSSize(width: newSize.width / Self.displayScale, height: newSize.height / Self.displayScale))
        }
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
        if model.phase != previous.phase {
            if model.phase == .recording && !reduceMotion {
                let phaseRange = 0..<(2 * Double.pi)
                waveform.reset(edgePhases: SIMD3(.random(in: phaseRange), .random(in: phaseRange), .random(in: phaseRange)))
            } else {
                waveform.reset()
            }
        }
        cancelButton.isHidden = !model.showsRecordingControls
        stopButton.isHidden = !model.showsRecordingControls
        needsLayout = true
    }

    /// Audio samples start pulses. The animation clock renders them independently.
    func receiveLevel(_ level: Float, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard model.phase == .recording else { return }
        waveform.receive(level, at: now, reduceMotion: reduceMotion)
        if reduceMotion { needsDisplay = true }
    }

    func advance(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let delta = max(0, min(0.1, now - lastAdvancedAt))
        lastAdvancedAt = now
        phaseElapsed += delta
        if reduceMotion || phaseElapsed >= handoffPause + Self.handoffFade {
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
        let waveChanged = model.phase == .recording && !reduceMotion && waveform.advance(at: now)
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
        case .selectionCount:
            drawText(model.resultText, x: 18, centerY: bounds.midY, width: bounds.width - 34,
                     font: Self.resultFont, color: Self.ink)
        }
    }

    // MARK: state looks

    private func fillBadge(in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shape = RoundedRectangle(cornerRadius: VoiceBarGeometry.radius, style: .circular)
        context.addPath(shape.path(in: rect).cgPath)
        context.fillPath()
    }

    private func drawHandoff(_ handoff: RecordingHandoff, context: CGContext) {
        let progress = min(1, max(0, (phaseElapsed - handoffPause) / Self.handoffFade))
        let blend = CGFloat(progress * progress * (3 - 2 * progress))
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
            drawThinking()
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
        let countingDown = countdownInsideCapsule && remaining <= Self.countdownSeconds
        let waveX = content.minX + (recording.mode.width - VoiceBarGeometry.waveform.width) / 2
        drawWaveform(NSRect(x: waveX, y: content.midY - VoiceBarGeometry.waveform.height / 2,
                            width: VoiceBarGeometry.waveform.width, height: VoiceBarGeometry.waveform.height),
                     waveform: waveform, collapse: collapse)
        if countingDown {
            let x = handsFree ? stop.minX - 34 : content.maxX - 36
            drawText(RecordingBarFormat.elapsed(max(0, remaining)), x: x, centerY: content.midY, width: 32,
                     font: InterfaceTypography.localizedAppKit(11, weight: .semibold), color: VoiceBarPalette.warning)
        }
    }

    private func drawThinking() {
        if model.isProcessingCapture || model.detail.isEmpty {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let textWidth = Self.thinkingTextWidth(for: model)
            let x = bounds.midX - (textWidth + Self.thinkingWaveGap + Self.thinkingWaveWidth) / 2
            let subtitle = model.thinkingSubtitle
            let motion = certificationMotion
            let titleLift = model.isDictationThinking ? motion.lift : (subtitle == nil ? 0 : 7)
            let titleFont = model.isDictationThinking ? Self.dictationThinkingFont : Self.thinkingFont
            context.saveGState()
            context.translateBy(x: x, y: bounds.midY + titleLift)
            context.scaleBy(x: motion.titleScale, y: motion.titleScale)
            drawText("Thinking", x: 0, centerY: 0, width: textWidth, font: titleFont, color: Self.ink)
            context.restoreGState()

            let cleanup = model.thinkingActivity == .cleanup
            let reveal = cleanup ? motion.reveal : 1
            if let subtitle, reveal > 0 {
                let subtitleY = bounds.midY - 8.5 - (1 - reveal) * 3
                let inset = cleanup ? Self.cleanupSubtitleInset : 0
                drawText(subtitle, x: x + inset, centerY: subtitleY, width: textWidth - inset,
                         font: cleanup ? Self.cleanupSubtitleFont : Self.thinkingSubtitleFont,
                         color: Self.ink.withAlphaComponent(0.78 * reveal))
            }
            drawThinkingDots(count: Self.thinkingWaveCount,
                             start: x + textWidth + Self.thinkingWaveGap + Self.thinkingWaveRadius,
                             spacing: Self.thinkingWaveSpacing, radius: Self.thinkingWaveRadius)
            return
        }
        drawThinkingDots(count: 3, start: 29, spacing: 10, radius: 2.4)
        let x: CGFloat = 65
        drawProcessingText(model.detail, x: x, width: max(0, bounds.width - x - 29))
    }

    private func drawThinkingDots(count: Int, start: CGFloat, spacing: CGFloat, radius: CGFloat) {
        for index in 0..<count {
            let wave = reduceMotion ? 0 : sin(spinnerPhase - CGFloat(index) * 0.75)
            let x = start + CGFloat(index) * spacing
            let y = bounds.midY + wave * 2.6
            PillView.ink.withAlphaComponent(0.68 + wave * 0.30).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }
    }

    private func drawCheck(at centre: NSPoint, color: NSColor) {
        let check = NSBezierPath()
        check.move(to: NSPoint(x: centre.x - 3.8, y: centre.y + 0.2))
        check.line(to: NSPoint(x: centre.x - 1.0, y: centre.y - 2.6))
        check.line(to: NSPoint(x: centre.x + 4.2, y: centre.y + 3.2))
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        color.setStroke()
        check.stroke()
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
            drawCheck(at: centre, color: tint)
        }
        let text: String
        if model.requiresReview { text = L10n.text("待确认") }
        else if model.warning { text = L10n.text("错误") }
        else { text = model.resultText.isEmpty ? L10n.text("（无内容）") : model.resultText }
        drawText(text, x: model.warning ? 31 : 34, centerY: rowY, width: bounds.width - (model.warning ? 37 : 46),
                 font: PillView.resultFont,
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
        let width = VoiceBarGeometry.waveformBarWidth
        let stride = width + VoiceBarGeometry.waveformBarGap
        context.saveGState()
        context.clip(to: rect)
        let restingHeight = CGFloat(VoiceWaveform.restingHeight)
        PillView.ink.setFill()
        for index in waveform.heights.indices {
            let height = restingHeight + (CGFloat(waveform.heights[index]) - restingHeight) * (1 - collapse)
            let line = NSRect(x: rect.minX + CGFloat(index) * stride, y: rect.midY - height / 2,
                              width: width, height: height)
            let aligned = backingAlignedRect(line, options: .alignAllEdgesNearest)
            NSBezierPath(roundedRect: aligned, xRadius: 1, yRadius: 1).fill()
        }
        context.restoreGState()
    }

    /// Fixed travel speed keeps long and short processing labels equally calm.
    private func drawProcessingText(_ text: String, x: CGFloat, width: CGFloat) {
        let font = Self.processingFont
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

    /// The transparent panel stays fixed while the capsule changes size inside it.
    static let size = VoiceBarGeometry.overlay
    private static let tickInterval: TimeInterval = 1.0 / 60.0
    private static let resultHold: TimeInterval = 1.0
    static let selectionCountHold: TimeInterval = 0.75
    static let selectionCountFade: TimeInterval = 0.30
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
    private var currentTake: UUID?
    private var resultAt: TimeInterval?
    private var resizing: (from: NSRect, to: NSRect, start: TimeInterval)?

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
        view.handoffPause = 0
        view.countdownInsideCapsule = false
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

    func resetAfterOnboarding() {
        guard model.phase == .hidden else { return }
        panelBox?.close()
        panelBox = nil
        pillBox = nil
        warmUp()
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
    var capsuleSize: CGSize? { pillBox?.frame.size }

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

    final class Take {
        private weak var bar: RecordingBar?
        private let id: UUID
        private let mode: RecordingBarMode

        fileprivate init(bar: RecordingBar, id: UUID, mode: RecordingBarMode) {
            self.bar = bar
            self.id = id
            self.mode = mode
        }

        private func apply(_ change: @escaping (RecordingBar) -> Void) {
            guard let bar else { return }
            bar.onMain { [id] in
                guard bar.currentTake == id else { return }
                change(bar)
            }
        }

        func recording(destination: String, badge: String) {
            apply {
                guard $0.model.isStartingMicrophone else { return }
                $0.showRecording(destination: destination, badge: badge, mode: self.mode)
            }
        }

        func badge(_ text: String) {
            apply { $0.model.updateBadge(text); $0.pushModel() }
        }

        func level(_ value: Float, elapsed: Double) {
            apply { $0.update(level: value, elapsed: elapsed) }
        }

        func processing(activity: RecordingBarModel.ThinkingActivity = .transcription) {
            apply {
                guard $0.model.phase == .recording else { return }
                $0.model.processing(activity: activity)
                $0.showThinking(detail: "")
            }
        }

        func done() {
            apply { bar in
                guard bar.model.phase == .thinking, bar.model.isProcessingCapture else { return }
                bar.hide()
            }
        }

        func needsReview(_ text: String) { apply { $0.showResult(text, warning: true, requiresReview: true) } }

        func failed(_ text: String) {
            apply { bar in
                guard bar.model.phase == .thinking, bar.model.isProcessingCapture else { return }
                bar.showResult(text, warning: true)
            }
        }

        func cancel() { apply { $0.hide() } }
    }

    func begin(handsFree: Bool) -> Take {
        let id = UUID()
        onMain {
            self.currentTake = id
            self.showThinking(detail: L10n.text("正在打开麦克风…"), startingMicrophone: true)
        }
        return Take(bar: self, id: id, mode: handsFree ? .handsFree : .recording)
    }

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
            self.pill.receiveLevel(self.model.level)
        }
    }

    /// Show the capture device without taking keyboard or mouse focus.
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
    func showThinking(detail: String, startingMicrophone: Bool = false, activity: RecordingBarModel.ThinkingActivity? = nil) {
        onMain {
            self.cancelPendingFade()
            self.hideMicrophoneHint()
            self.model.showThinking(detail: detail, startingMicrophone: startingMicrophone, activity: activity)
            self.pill.reduceMotion = RecordingBar.prefersReducedMotion
            self.pushModel()
            self.present()
            self.startTimer()
        }
    }

    func beginCertification() {
        onMain {
            guard self.model.beginCertification() else { return }
            self.pushModel()
        }
    }

    /// Brief confirmation, then a short fade out. A warning shows an amber mark instead.
    func showResult(_ text: String, warning: Bool, requiresReview: Bool = false) {
        onMain {
            self.cancelPendingFade()
            self.hideMicrophoneHint()
            self.currentTake = nil
            self.resultAt = ProcessInfo.processInfo.systemUptime
            self.model.showResult(text, warning: warning, requiresReview: requiresReview)
            self.pill.reduceMotion = RecordingBar.prefersReducedMotion
            self.pushModel()
            self.present()
            self.stopTimer()
            self.stopPointerTracking()
            self.startTimer()
        }
    }

    /// Immediately show the count, then dismiss without a display timer.
    func flashSelectionCount(for text: String) {
        onMain {
            self.cancelPendingFade()
            self.stopTimer()
            self.hideMicrophoneHint()
            self.currentTake = nil
            self.resultAt = nil
            self.model.showSelectionCount(RecordingBarFormat.selectionCount(text))
            self.pushModel()
            self.present(animated: false)
            let token = self.fadeToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.selectionCountHold) { [weak self] in
                guard let self, self.fadeToken == token else { return }
                self.fadeOut(phase: .selectionCount, duration: Self.selectionCountFade)
            }
        }
    }

    /// Stop interaction immediately, then fade the visible capsule over 500ms.
    func hide() {
        onMain {
            self.currentTake = nil
            self.cancelPendingFade()
            self.stopPointerTracking()
            self.hideMicrophoneHint()
            self.fadeOut(phase: self.model.phase)
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
            || previous.thinkingActivity != model.thinkingActivity
            || previous.mode != model.mode || previous.isStartingMicrophone != model.isStartingMicrophone
            || wasCountingDown != isCountingDown
        pill.model = model
        if previous.phase == .selectionCount || model.phase == .selectionCount {
            let showingCount = model.phase == .selectionCount
            pill.setAccessibilityElement(showingCount)
            pill.setAccessibilityRole(showingCount ? .staticText : nil)
            pill.setAccessibilityValue(showingCount ? model.resultText : nil)
        }
        (panelBox?.contentView as? RecordingOverlayHost)?.apply(model)
        // Resize only a panel that exists and is showing: sizing must not build one.
        if widthChanged, let existing = panelBox, existing.isVisible { resizeToCapsule(existing) }
    }

    private func capsuleFrame() -> NSRect {
        let width = (pill.presentationWidth * PillView.displayScale).rounded()
        return NSRect(x: ((Self.size.width - width) / 2).rounded(), y: VoiceBarGeometry.bottomInset,
                      width: width, height: pill.presentationHeight * PillView.displayScale)
    }

    /// Keep the capsule centred on the same bottom-centre point as its width changes.
    private func resizeToCapsule(_ target: PillPanel) {
        let frame = capsuleFrame()
        guard resizing?.to != frame else { return }
        if !pill.reduceMotion, pill.frame != frame {
            resizing = (pill.frame, frame, ProcessInfo.processInfo.systemUptime)
        } else {
            resizing = nil
            applyCapsuleFrame(frame, to: target)
        }
    }

    private func applyCapsuleFrame(_ frame: NSRect, to target: PillPanel) {
        guard pill.frame != frame else { return }
        pill.frame = frame
        target.contentView?.needsLayout = true
        positionMicrophoneHint()
        updatePointerPassthrough()
    }

    private func present(animated: Bool = true) {
        let entering = !panel.isVisible
        if entering || model.phase == .recording || !animated { positionOnMouseScreen() }
        if entering || !animated {
            resizing = nil
            pill.frame = capsuleFrame()
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
        let fadesIn = entering && animated && !Self.prefersReducedMotion
        if fadesIn { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        startPointerTracking()
        if fadesIn {
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
        let inside = VoiceBarGeometry.contains(NSEvent.mouseLocation, in: panelBox.convertToScreen(pillBox.frame))
        let ignore = isDismissing || !model.showsRecordingControls || !inside
        if panelBox.ignoresMouseEvents != ignore { panelBox.ignoresMouseEvents = ignore }
    }

    private func startPointerTracking() {
        guard model.showsRecordingControls else { stopPointerTracking(); return }
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
        let interval = pill.reduceMotion ? 0.05 : Self.tickInterval
        let ticker = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
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
        let now = ProcessInfo.processInfo.systemUptime
        if let motion = resizing, let panelBox {
            let elapsed = (now - motion.start) / VoiceBarGeometry.shapeDuration
            let amount = VoiceBarGeometry.shapeProgress(elapsed)
            func mix(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * amount }
            applyCapsuleFrame(NSRect(x: mix(motion.from.minX, motion.to.minX), y: motion.to.minY,
                                    width: mix(motion.from.width, motion.to.width),
                                    height: mix(motion.from.height, motion.to.height)), to: panelBox)
            if elapsed >= 1 { resizing = nil }
        }
        if model.phase == .result, let resultAt, now - resultAt >= Self.resultHold {
            fadeOut()
            return
        }
        if now - screenCheckedAt >= 0.1 {
            screenCheckedAt = now
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
               screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber != mouseScreenNumber {
                positionOnMouseScreen()
            }
        }
        pill.advance(at: now)
        updatePointerPassthrough()
    }

    private func cancelPendingFade() {
        fadeToken += 1
        isDismissing = false
    }

    private func fadeOut(phase: RecordingBarModel.Phase = .result, duration: TimeInterval = RecordingBar.fadeDuration) {
        stopTimer()
        guard model.phase == phase, let panel = panelBox, panel.isVisible, !Self.prefersReducedMotion else {
            dismiss()
            return
        }
        panel.ignoresMouseEvents = true
        fadeToken += 1
        isDismissing = true
        let token = fadeToken
        let finish = { [weak self] in
            // A newer state may have re-presented the pill while this fade was running.
            guard let self = self, self.fadeToken == token, self.model.phase == phase else { return }
            self.dismiss()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: finish)
        // AppKit can omit the completion when the window's animation is interrupted.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.04, execute: finish)
    }

    private func dismiss() {
        currentTake = nil
        resultAt = nil
        resizing = nil
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
    private static let titleFont = InterfaceTypography.localizedAppKit(10, weight: .medium)
    private static let nameFont = InterfaceTypography.localizedAppKit(12, weight: .semibold)

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

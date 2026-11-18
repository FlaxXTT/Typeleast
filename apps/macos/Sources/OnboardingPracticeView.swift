import SwiftUI
import AppKit
import QuartzCore

/// 试说一句: the same recording pill as in daily use. Click it or press the dictation key to
/// start; ✓ finishes, ✕ cancels. The result is shown here only.
struct OnboardingPracticeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var practice: OnboardingPracticeController

    var body: some View {
        VStack(spacing: 18) {
            Text(L10n.text("试说一句")).font(InterfaceTypography.localized(24, weight: .bold))
            Text(L10n.text("按 {0} 或点下面的录音条，读这句话。", model.hotkeyLabel))
                .font(InterfaceTypography.localized(14)).foregroundColor(Theme.secondary).multilineTextAlignment(.center)
            Text(practice.sample)
                .font(InterfaceTypography.localized(15, weight: .medium)).multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .circular).fill(Theme.card))
                .fixedSize(horizontal: false, vertical: true)
            PracticePill(practice: practice)
                .environment(\.colorScheme, .dark)
                .padding(.top, 4)
            if !practice.status.isEmpty {
                Text(practice.status).font(InterfaceTypography.localized(14, weight: .medium))
                    .foregroundColor(practice.needsReview ? Theme.warning : (practice.complete ? Theme.success : Theme.secondary))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(PracticeResultRow.rows(raw: practice.raw, output: practice.output, needsReview: practice.needsReview).enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text(row.title)).font(Theme.captionFont).foregroundColor(Theme.secondary)
                    Text(row.text).font(InterfaceTypography.localized(14)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .circular).fill(Theme.card))
            }
        }
        .onAppear { practice.acceptsShortcut = true }
        .onDisappear { practice.acceptsShortcut = false; practice.cancel() }
    }
}

/// Practice and desktop dictation use the same native capsule and animation engine.
private struct PracticePill: View {
    @ObservedObject var practice: OnboardingPracticeController

    var body: some View {
        if practice.phase == .idle {
            Button(action: practice.toggle) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                    Text(practice.complete ? L10n.text("再试一次") : L10n.text("点这里开始"))
                        .font(InterfaceTypography.localized(12, weight: .medium)).padding(.trailing, 12)
                }
                .foregroundColor(.white)
                .padding(3)
                .background(Capsule().fill(LinearGradient(
                    colors: [Color(nsColor: VoiceBarPalette.surfaceTop), Color(nsColor: VoiceBarPalette.surfaceBottom)],
                    startPoint: .top, endPoint: .bottom)))
                .overlay(Capsule().stroke(Color(nsColor: VoiceBarPalette.edge), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        } else {
            PracticeVoiceBar(practice: practice).frame(width: 240, height: PillView.height)
        }
    }
}

private struct PracticeVoiceBar: NSViewRepresentable {
    let practice: OnboardingPracticeController
    func makeNSView(context: Context) -> PracticeVoiceBarHost { PracticeVoiceBarHost(practice: practice) }
    func updateNSView(_ view: PracticeVoiceBarHost, context: Context) { view.applyPhase() }
    static func dismantleNSView(_ view: PracticeVoiceBarHost, coordinator: ()) { view.stopAnimation() }
}

/// Audio ticks redraw the capsule without publishing frames through the onboarding tree.
private final class PracticeVoiceBarHost: NSView {
    private weak var practice: OnboardingPracticeController?
    private let pill = PillView(frame: NSRect(x: 0, y: 0, width: 118, height: PillView.height))
    private var phase: AppPhase?
    private var model = RecordingBarModel()
    private var timer: Timer?
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var sampleTime: Double = 0

    init(practice: OnboardingPracticeController) {
        self.practice = practice
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: PillView.height))
        pill.limitSeconds = 40
        pill.onCancel = { [weak practice] in practice?.cancel() }
        pill.onStop = { [weak practice] in practice?.stop() }
        addSubview(pill)
        applyPhase()
    }
    required init?(coder: NSCoder) { fatalError("Practice voice bar is created in code") }
    deinit { timer?.invalidate() }

    func applyPhase() {
        guard let practice, phase != practice.phase else { return }
        phase = practice.phase
        pill.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        switch practice.phase {
        case .recording: model.showRecording(destination: "tutorial")
        case .starting: model.showThinking(detail: L10n.text("正在打开麦克风…"), startingMicrophone: true)
        case .thinking: model.showThinking(detail: L10n.text("正在整理…"))
        case .idle: model.hide()
        }
        pill.model = model
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = pill.presentationWidth
        let height = pill.presentationHeight
        let frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
        guard pill.frame != frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = pill.reduceMotion || window == nil ? 0 : 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.05, 0.6, 0.4, 0.95)
            pill.animator().setFrameOrigin(frame.origin)
            pill.animator().setFrameSize(frame.size)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopAnimation()
        guard window != nil else { return }
        lastFrame = ProcessInfo.processInfo.systemUptime
        let interval = pill.reduceMotion ? 0.05 : 1.0 / 60.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimation() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let practice else { stopAnimation(); return }
        let now = ProcessInfo.processInfo.systemUptime
        sampleTime += min(0.1, max(0, now - lastFrame))
        lastFrame = now
        if practice.phase == .recording, sampleTime >= 0.05 {
            sampleTime.formTruncatingRemainder(dividingBy: 0.05)
            let oldWidth = PillView.width(for: model, limit: 40)
            model.update(voice: practice.voiceLevel, elapsed: practice.elapsed)
            pill.model = model
            if oldWidth != PillView.width(for: model, limit: 40) { needsLayout = true }
        }
        let wasHoldingWidth = pill.holdsRecordingWidth
        pill.advance(at: now)
        if wasHoldingWidth && !pill.holdsRecordingWidth { needsLayout = true }
    }
}

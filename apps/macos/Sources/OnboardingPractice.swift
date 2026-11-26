import Combine
import Foundation

enum OnboardingDemo: CaseIterable {
    case dictation, voiceTranslation, selectionTranslation, skill

    enum Shortcut { case dictation, translation, skill }

    var shortcut: Shortcut {
        switch self {
        case .dictation: return .dictation
        case .voiceTranslation, .selectionTranslation: return .translation
        case .skill: return .skill
        }
    }

    var usesSpeech: Bool { self == .dictation || self == .voiceTranslation }

    var title: String {
        switch self {
        case .dictation: return L10n.text("口述成文字")
        case .voiceTranslation: return L10n.text("说话后翻译")
        case .selectionTranslation: return L10n.text("选中文字翻译")
        case .skill: return L10n.text("调用 Skill")
        }
    }

    var symbol: String {
        switch self {
        case .dictation: return "waveform"
        case .voiceTranslation: return "mic"
        case .selectionTranslation: return "character.bubble"
        case .skill: return "circle.hexagongrid"
        }
    }

    var instruction: String {
        switch self {
        case .dictation: return L10n.text("按一下开始，说完再按一下。整理好的文字会写到光标处。")
        case .voiceTranslation: return L10n.text("没有选中文字时，按一下开始，说完再按一下。译文会写到光标处。")
        case .selectionTranslation: return L10n.text("先选中文字，再按快捷键。译文会显示在单独的面板里。")
        case .skill: return L10n.text("打开 Harness EQ，移到想用的 Skill，再调用到当前输入框。")
        }
    }

    func binding(in settings: Settings) -> HotKeyBinding {
        switch shortcut {
        case .dictation: return settings.hotkeyMain.enabled ? settings.hotkeyMain : settings.hotkeyAlt
        case .translation: return settings.hotkeyTranslate
        case .skill: return settings.hotkeyAssistant
        }
    }

    func shortcutLabel(in settings: Settings) -> String {
        let binding = binding(in: settings)
        guard binding.enabled else { return L10n.text("未设置快捷键") }
        return binding.isFn ? "Fn" : HotKeyCentre.describe(keyCode: binding.keyCode, modifiers: binding.modifiers)
    }

    var sample: String {
        switch self {
        case .dictation: return L10n.text("嗯，报告周三发，不对，改成周四。")
        case .voiceTranslation, .selectionTranslation: return "明天下午三点开会。"
        case .skill: return L10n.text("提炼待办")
        }
    }

    var result: String {
        switch self {
        case .dictation: return L10n.text("报告改为周四发送。")
        case .voiceTranslation, .selectionTranslation: return "The meeting is at 3 p.m. tomorrow."
        case .skill: return L10n.text("请从这段文字中提炼待办，保留原文提到的负责人和截止时间。")
        }
    }
}

/// Runs solely inside the onboarding window. The capsule and its output are simulated.
final class OnboardingPracticeController: ObservableObject {
    @Published private(set) var phase: AppPhase = .idle
    @Published private(set) var mode: OnboardingDemo?
    @Published private(set) var output = ""
    @Published private(set) var selectionHighlighted = false
    @Published private(set) var showingSkill = false

    private var startTime: TimeInterval = 0
    private var pending: DispatchWorkItem?
    private var generation = 0
    private let recordingHold: TimeInterval
    private let processingHold: TimeInterval

    init(recordingHold: TimeInterval = 1.55, processingHold: TimeInterval = 0.55) {
        self.recordingHold = recordingHold
        self.processingHold = processingHold
    }

    var busy: Bool { phase != .idle || showingSkill }
    var complete: Bool { !output.isEmpty }
    var elapsed: TimeInterval { phase == .recording ? ProcessInfo.processInfo.systemUptime - startTime : 0 }
    func enter(_ mode: OnboardingDemo?) {
        cancel()
        self.mode = mode
    }

    func selectExample() {
        guard mode == .selectionTranslation, !busy else { return }
        selectionHighlighted = true
    }

    func handle(_ shortcut: OnboardingDemo.Shortcut, held: Bool = false) {
        guard let mode, mode.shortcut == shortcut else { return }
        if mode.usesSpeech {
            if phase == .recording { stop() }
            else if phase == .idle { beginSpeech(duration: max(5, recordingHold)) }
        } else if mode == .skill, held {
            guard !busy else { return }
            showingSkill = true
            output = ""
        } else if !busy {
            playExample()
        }
    }

    func releaseSkill() {
        guard mode == .skill, showingSkill else { return }
        showingSkill = false
        showResult()
    }

    func playExample() {
        guard let mode, !busy else { return }
        output = ""
        if mode.usesSpeech {
            beginSpeech(duration: recordingHold)
        } else if mode == .skill {
            showingSkill = true
            schedule(after: processingHold) { $0.releaseSkill() }
        } else {
            selectExample()
            showResult()
        }
    }

    func stop() {
        guard phase == .recording else { return }
        showResult()
    }

    func cancel() {
        generation += 1
        pending?.cancel()
        pending = nil
        phase = .idle
        output = ""
        selectionHighlighted = false
        showingSkill = false
    }

    private func beginSpeech(duration: TimeInterval) {
        output = ""
        startTime = ProcessInfo.processInfo.systemUptime
        phase = .recording
        schedule(after: duration) { $0.stop() }
    }

    private func showResult() {
        guard let mode else { return }
        phase = .thinking
        schedule(after: processingHold) { practice in
            practice.output = mode.result
            practice.phase = .idle
        }
    }

    private func schedule(after delay: TimeInterval, _ action: @escaping (OnboardingPracticeController) -> Void) {
        pending?.cancel()
        generation += 1
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.pending = nil
            action(self)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

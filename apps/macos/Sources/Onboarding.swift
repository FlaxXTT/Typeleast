import SwiftUI
import AppKit
import AVFoundation
import Combine

// Onboarding.swift - first-run setup, in this order:
// welcome, the local service and speech model, microphone, accessibility, the Globe
// key, a microphone test, a first try, and where the settings are.

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model: AppModel
    var onFinish: (() -> Void)?
    let practice = OnboardingPracticeController()

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil || window?.isVisible == false {
            practice.reset()
            let host = NSHostingController(rootView: OnboardingView(practice: practice, finish: { [weak self] in self?.finish() })
                .environmentObject(model))
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.setContentSize(NSSize(width: 600, height: 560))
            w.isReleasedWhenClosed = false
            w.center()
            w.delegate = self
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private var finishing = false
    private func finish() {
        finishing = true; window?.close(); onFinish?(); finishing = false
    }
    /// Closing the window is the same as 跳过引导.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if !finishing { onFinish?() }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        practice.acceptsShortcut = false
        practice.cancel()
        model.refreshPermissions()
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, localService, microphone, accessibility, globeKey, micTest, tryIt, translate, promptMode, guide, done
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var practice: OnboardingPracticeController
    let finish: () -> Void
    @State private var step: OnboardingStep = .welcome
    @StateObject private var meter = MicMeter()
    @State private var tryText = ""
    @State private var globeConfirmed = false
    /// The cleanup model form stays open once shown, even after the key is saved.
    @State private var modelFormShown = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 34)
            ScrollView {
                content.frame(maxWidth: 440).padding(.horizontal, 40).padding(.vertical, 20)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer.padding(.horizontal, 40).padding(.bottom, 28)
        }
        .frame(width: 600, height: 560)
        .background(Theme.window)
        .onReceive(poll) { _ in model.refreshPermissions() }
        .onDisappear { meter.stop(); practice.cancel() }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Theme.ink : Theme.border)
                    .frame(width: s == step ? 22 : 8, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            StepView(symbol: nil, title: L10n.text("说话，不用打字"),
                     text: L10n.text("在任何 App 里按 Fn 说话，再按一下结束。文字写到光标处。")) {
                VStack(spacing: 14) {
                    AppMarkView(size: 72)
                    Text(L10n.text("遇到简称或专名，可补充全称、含义或逐字拼写。听写会结合整段理解，删除只用于确认名称的解释。")).font(.callout).foregroundColor(.secondary)
                }
            }
        case .localService:
            StepView(symbol: "cpu", title: L10n.text("本地识别"),
                     text: "") {
                VStack(alignment: .leading, spacing: 12) {
                    OnboardingCheck(done: model.serviceState.isRunning, title: L10n.text("本地服务"),
                                    detail: model.serviceState.isRunning ? L10n.text("运行中") : model.serviceSummary) {
                        if model.serviceState.needsNode {
                            Button(L10n.text("下载 Node.js")) { NSWorkspace.shared.open(URL(string: "https://nodejs.org/zh-cn/download")!) }
                                .buttonStyle(SecondaryButtonStyle())
                            Button(L10n.text("已安装，请重试")) { model.actions?.restartService() }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    SpeechModelOptions()
                    // Filled in right here: it is the same setting the Settings page shows.
                    if modelFormShown {
                        ModelSection()
                    } else {
                        OnboardingCheck(done: model.llmConfigured, title: L10n.text("整理模型"), detail: model.modelSummary) {
                            EmptyView()
                        }
                    }
                }
                .frame(width: 440)
                .onAppear { if !model.llmConfigured { modelFormShown = true } }
            }
        case .microphone:
            StepView(symbol: "mic.fill", title: L10n.text("允许麦克风"),
                     text: L10n.text("音频不出本机。")) {
                permissionState(granted: model.micStatus == .authorized,
                                denied: model.micStatus == .denied || model.micStatus == .restricted,
                                ask: { model.actions?.requestMicrophone() },
                                open: { model.actions?.openMicrophoneSettings() })
            }
        case .accessibility:
            StepView(symbol: "accessibility", title: L10n.text("允许辅助功能"),
                     text: L10n.text("请在系统设置里打开 TypeLeast。")) {
                permissionState(granted: model.accessibilityTrusted, denied: false,
                                ask: { model.actions?.requestAccessibility() }, open: nil)
            }
        case .globeKey:
            StepView(symbol: "globe", title: L10n.text("把 🌐 设为「无操作」"),
                     text: L10n.text("在「系统设置 › 键盘」把「按下 🌐 键时」设为「无操作」。否则 Fn 会打开表情或切换输入法。")) {
                VStack(spacing: 12) {
                    Button(L10n.text("打开键盘设置")) { model.actions?.openKeyboardSettings() }.buttonStyle(SecondaryButtonStyle())
                    Toggle(L10n.text("已改好"), isOn: $globeConfirmed).toggleStyle(.checkbox)
                }
            }
        case .micTest:
            StepView(symbol: "waveform", title: L10n.text("试试麦克风"),
                     text: L10n.text("点「开始测试」并说话，条变蓝表示听到了。{0} 秒后关闭。", Int(MicMeter.maxSeconds))) {
                VStack(spacing: 14) {
                    LevelBars(level: meter.level, count: 18).scaleEffect(1.3)
                    Text(meter.heardVoice ? L10n.text("听到了 ✓") : (meter.running ? L10n.text("等待说话…") : L10n.text("麦克风未打开")))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(meter.heardVoice ? Theme.success : Theme.secondary)
                    Button(meter.running ? L10n.text("停止测试") : L10n.text("开始测试")) {
                        if meter.running { meter.stop() } else { meter.start(deviceUID: model.settings.inputDeviceUID) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .onDisappear { meter.stop() }
            }
        case .tryIt:
            OnboardingPracticeView(practice: practice)
        case .translate:
            TranslatePracticeView(practice: practice)
        case .promptMode:
            // fn only dictates; 提示词模式 has its own key (⌥Space unless the user changed it).
            StepView(symbol: "text.bubble", title: L10n.text("提示词模式"),
                     text: model.assistantLabel.isEmpty
                        ? L10n.text("在「设置 › 快捷键」给提示词模式设一个键：说出需求，它先问清范围，再生成完整提示词。")
                        : L10n.text("按 {0} 进入：说出需求，它先问清范围，再生成完整提示词。", model.assistantLabel)) {
                VStack(spacing: 14) {
                    if !model.assistantLabel.isEmpty { Keycap(label: model.assistantLabel, large: true) }
                    Text(L10n.text("先选中一段文字再按这个键，就以选中内容为底稿修改。按翻译键则直接翻译选中内容。"))
                        .font(.system(size: 13)).foregroundColor(Theme.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("拆解一段示例提示词")) { model.actions?.breakdownSample() }
                        .buttonStyle(SecondaryButtonStyle()).disabled(!model.llmConfigured)
                }
            }
        case .guide:
            StepView(symbol: "map", title: L10n.text("设置位置"),
                     text: "") {
                GuideList().frame(width: 400)
            }
        case .done:
            StepView(symbol: "checkmark.circle", title: L10n.text("准备好了"),
                     text: L10n.text("在任何 App 里按 {0} 听写。", model.hotkeyLabel)) {
                Keycap(label: model.hotkeyLabel, large: true)
            }
        }
    }

    @ViewBuilder
    private func permissionState(granted: Bool, denied: Bool, ask: @escaping () -> Void, open: (() -> Void)?) -> some View {
        if granted {
            Label(L10n.text("已允许"), systemImage: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.success)
        } else if denied, let open = open {
            VStack(spacing: 8) {
                Text(L10n.text("之前已拒绝，请在系统设置里打开。")).font(.system(size: 12)).foregroundColor(Theme.secondary)
                Button(L10n.text("打开系统设置"), action: open).buttonStyle(PrimaryButtonStyle())
            }
        } else {
            Button(L10n.text("允许"), action: ask).buttonStyle(PrimaryButtonStyle())
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button(L10n.text("上一步")) { meter.stop(); if let previous = OnboardingStep(rawValue: step.rawValue - 1) { step = previous } }.buttonStyle(.plain).disabled(practice.busy)
            }
            Spacer()
            // Every step can be skipped, and so can the whole guide.
            if step != .done {
                Button(L10n.text("跳过引导")) { practice.cancel(); meter.stop(); finish() }
                    .buttonStyle(SecondaryButtonStyle()).disabled(practice.busy)
                if step != .welcome {
                    Button(L10n.text("跳过这步")) { skip() }.buttonStyle(SecondaryButtonStyle()).disabled(practice.busy)
                }
            }
            Button(step == .done ? L10n.text("开始使用") : (step == .welcome ? L10n.text("开始设置") : L10n.text("继续"))) {
                if step == .done { finish() } else { advance() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }

    /// 继续 waits for what the step is about; 跳过这步 never does.
    private var canContinue: Bool {
        if practice.busy { return false }
        switch step {
        case .globeKey: return globeConfirmed
        case .tryIt: return practice.complete
        default: return true
        }
    }

    private func advance() {
        guard canContinue else { return }
        skip()
    }

    private func skip() {
        meter.stop()
        if let next = OnboardingStep(rawValue: step.rawValue + 1) { step = next }
    }
}

private struct StepView<Accessory: View>: View {
    let symbol: String?
    let title: String
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 18) {
            if let symbol = symbol {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Theme.card))
            }
            Text(title).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
            Text(text)
                .font(.system(size: 14))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            accessory.padding(.top, 6)
        }
    }
}

/// One line of the local-service step: a check mark, what it is, and its button.
private struct OnboardingCheck<Trailing: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundColor(done ? Theme.success : Theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done { trailing() }
        }
    }
}

/// 翻译成其他语言: pick a language, then say the sample in Chinese and get it back translated.
private struct TranslatePracticeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var practice: OnboardingPracticeController

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.text("说中文，写成其他语言")).font(.system(size: 24, weight: .bold))
            Text(L10n.text("平时按 {0} 翻译。现在选一种语言，读下面这句试试。", HotKeyCentre.describe(keyCode: model.settings.hotkeyTranslate.keyCode, modifiers: model.settings.hotkeyTranslate.modifiers)))
                .font(.system(size: 14)).foregroundColor(Theme.secondary).multilineTextAlignment(.center)
            Picker("", selection: model.setting(\.translateTarget)) {
                ForEach(TranslateLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }.labelsHidden().frame(width: 180).disabled(practice.busy)
            Text(practice.translateSample)
                .font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            Button(practice.phase == .recording ? L10n.text("停止并翻译") : L10n.text("开始录音")) { practice.toggle() }
                .buttonStyle(PrimaryButtonStyle()).disabled(practice.phase == .thinking)
            if !practice.status.isEmpty {
                Text(practice.status).font(.system(size: 13)).foregroundColor(Theme.secondary).multilineTextAlignment(.center)
            }
            if !practice.output.isEmpty {
                Text(practice.output).font(.system(size: 14)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            }
        }
        .onAppear { practice.translateTo = model.settings.translateTarget; practice.acceptsShortcut = true; practice.reset() }
        .onChange(of: model.settings.translateTarget) { practice.translateTo = $0 }
        .onDisappear { practice.translateTo = nil; practice.acceptsShortcut = false; practice.cancel() }
    }
}

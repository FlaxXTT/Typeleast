import AppKit
import AVFoundation
import Combine
import SwiftUI

enum OnboardingExit { case home, tryDictation }

struct OnboardingReadiness {
    enum Item: Equatable { case speech, microphone, writing, shortcut }

    enum Speech: Equatable {
        case ready, missingModel, downloading, loading, modelError, serviceUnavailable
        case keyLocked, checkingKey, missingKey, savedKey

        var canTry: Bool { self == .ready || self == .savedKey }

        var label: String {
            switch self {
            case .ready: return L10n.text("就绪")
            case .missingModel: return L10n.text("尚未下载语音模型")
            case .downloading: return L10n.text("正在下载…")
            case .loading: return L10n.text("准备中")
            case .modelError: return L10n.text("语音模型未能加载")
            case .serviceUnavailable: return L10n.text("本地服务未就绪")
            case .keyLocked: return L10n.text("钥匙串已锁定")
            case .checkingKey: return L10n.text("正在检查 API Key…")
            case .missingKey: return L10n.text("待配置 API Key")
            case .savedKey: return L10n.text("已保存 API Key，待试听")
            }
        }

        static func local(serviceRunning: Bool, status: SpeechStatus?, operation: SpeechModelOperation?) -> Self {
            guard serviceRunning else { return .serviceUnavailable }
            if status?.ready == true { return .ready }
            let phase = (operation ?? status?.operation)?.phase ?? status?.phase
            switch phase {
            case "downloading": return .downloading
            case "error": return .modelError
            case "missing-model": return .missingModel
            default: return .loading
            }
        }

        static func cloud(locked: Bool, hasKey: Bool?) -> Self {
            if locked { return .keyLocked }
            guard let hasKey else { return .checkingKey }
            return hasKey ? .savedKey : .missingKey
        }
    }

    let speech: Speech
    let microphone: Bool
    let writing: Bool
    let shortcut: String?

    var next: Item? {
        if !speech.canTry { return .speech }
        if !microphone { return .microphone }
        if !writing { return .writing }
        return shortcut == nil ? .shortcut : nil
    }

    static func shortcutLabel(main: HotKeyBinding, alternate: HotKeyBinding, problems: [String: String]) -> String? {
        [(HotkeySlot.main, main), (.alt, alternate)].first { slot, binding in
            binding.enabled && problems[slot.name] == nil
        }.map { _, binding in
            binding.isFn ? "Fn" : HotKeyCentre.describe(keyCode: binding.keyCode, modifiers: binding.modifiers)
        }
    }
}

private enum OnboardingSetupSection: Hashable { case overview, speech, cleanup, permissions, shortcut }

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model: AppModel
    var onFinish: ((OnboardingExit) -> Void)?
    let practice = OnboardingPracticeController()
    private var finishing = false

    var isKeyWindow: Bool { window?.isKeyWindow == true }

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil || window?.isVisible == false {
            practice.enter(nil)
            let host = NSHostingController(rootView: OnboardingView(practice: practice, finish: { [weak self] exit in self?.finish(exit) })
                .environmentObject(model))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            let size = NSSize(width: 940, height: 610)
            window.setContentSize(size)
            AppWindowStyle.fixSize(window, to: size)
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            AppWindowStyle.round(window)
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// First-run shortcuts stay inside this window, including on the setup page.
    func handleShortcut(_ shortcut: OnboardingDemo.Shortcut, held: Bool = false) -> Bool {
        guard isKeyWindow else { return false }
        practice.handle(shortcut, held: held)
        return true
    }

    func close() { window?.close() }

    private func finish(_ exit: OnboardingExit) {
        finishing = true
        close()
        onFinish?(exit)
        finishing = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Close the onboarding window before presenting Home.
        if !finishing { DispatchQueue.main.async { [weak self] in self?.onFinish?(.home) } }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        if practice.showingSkill { practice.cancel() }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refreshPermissions()
    }

    func windowWillClose(_ notification: Notification) {
        practice.enter(nil)
        model.refreshPermissions()
        window?.contentViewController = nil
        window = nil
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, dictation, voiceTranslation, selectionTranslation, skill, setup

    var demo: OnboardingDemo? {
        switch self {
        case .welcome, .setup: return nil
        case .dictation: return .dictation
        case .voiceTranslation: return .voiceTranslation
        case .selectionTranslation: return .selectionTranslation
        case .skill: return .skill
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var practice: OnboardingPracticeController
    let finish: (OnboardingExit) -> Void
    @State private var step: OnboardingStep = .welcome
    @State private var stepBeforeSetup: OnboardingStep = .skill
    @State private var setupSection: OnboardingSetupSection = .overview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 34)
            ScrollViewReader { scroll in
                HubScrollView(showsChrome: step == .setup) {
                    content.frame(maxWidth: 680).padding(.horizontal, 40).padding(.vertical, 22)
                }
                .id(step)
                .onChange(of: setupSection) { _, section in
                    scroll.scrollTo(section == .overview ? "setup-top" : "setup-controls", anchor: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer.padding(.horizontal, 40).padding(.bottom, 28)
        }
        .frame(width: 940, height: 610)
        .font(Theme.bodyFont)
        .background(Theme.window)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? Theme.ink : Theme.border)
                    .frame(width: item == step ? 22 : 8, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: step)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if let demo = step.demo {
            OnboardingPracticeView(practice: practice, demo: demo)
        } else if step == .setup {
            OnboardingSetupView(section: $setupSection, readiness: readiness)
        } else {
            VStack(spacing: 13) {
                AppMarkView(size: 54)
                Text(L10n.text("TypeLeast 能做什么？")).font(Theme.sectionTitleFont)
                Text(L10n.text("先试按键和示例。配置放在最后。"))
                    .font(Theme.rowFont).foregroundStyle(Theme.secondary)
                VStack(spacing: 0) {
                    ForEach(OnboardingDemo.allCases, id: \.self) { demo in
                        HStack(spacing: 12) {
                            Image(systemName: demo.symbol)
                                .frame(width: 26).foregroundStyle(Theme.secondary)
                                .accessibilityHidden(true)
                            Text(demo.title)
                            Spacer()
                            Keycap(label: demo.shortcutLabel(in: model.settings))
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 45)
                        if demo != .skill { Divider().padding(.leading, 53) }
                    }
                }
                .frame(maxWidth: 555)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button(L10n.text("上一步")) { move(-1) }.buttonStyle(FlatActionButtonStyle())
            }
            Spacer()
            if step == .setup {
                Button(L10n.text("进入首页")) { finish(.home) }.buttonStyle(SecondaryButtonStyle())
            } else {
                Button(L10n.text("跳过引导")) { finish(.home) }.buttonStyle(SecondaryButtonStyle())
                if step == .welcome {
                    Button(L10n.text("直接去配置")) { go(to: .setup) }.buttonStyle(SecondaryButtonStyle())
                }
                if step.demo != nil {
                    Button(L10n.text("跳过这步")) { move(1) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            Button(primaryTitle, action: primaryAction)
                .buttonStyle(PrimaryButtonStyle(feedback: .magnetic))
                .keyboardShortcut(step == .setup ? nil : .defaultAction)
                .disabled(step.demo != nil && practice.busy)
        }
    }

    private var primaryTitle: String {
        if step == .welcome { return L10n.text("开始演示") }
        if step == .setup {
            switch readiness.next {
            case .speech: return L10n.text("准备语音识别")
            case .microphone: return L10n.text("设置麦克风")
            case .writing: return L10n.text("设置辅助功能")
            case .shortcut: return L10n.text("设置快捷键")
            case nil: return L10n.text("在文本编辑里试一句")
            }
        }
        return L10n.text(practice.complete ? "继续" : "播放示例")
    }

    private func primaryAction() {
        if step == .setup {
            switch readiness.next {
            case .speech: setupSection = .speech
            case .microphone, .writing: setupSection = .permissions
            case .shortcut: setupSection = .shortcut
            case nil: finish(.tryDictation)
            }
        }
        else if step.demo != nil && !practice.complete { practice.playExample() }
        else { move(1) }
    }

    private func move(_ offset: Int) {
        if step == .setup, offset < 0 {
            go(to: stepBeforeSetup)
            return
        }
        guard let next = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        go(to: next)
    }

    private func go(to next: OnboardingStep) {
        if next == .setup {
            stepBeforeSetup = step
            setupSection = .overview
        }
        practice.enter(next.demo)
        step = next
    }

    private var readiness: OnboardingReadiness {
        let settings = model.settings
        let speech: OnboardingReadiness.Speech = settings.onlineASRProvider == .local
            ? .local(serviceRunning: model.serviceState.isRunning, status: model.speech, operation: model.speechCatalog?.operation)
            : .cloud(locked: model.credentialsLocked, hasKey: model.onlineASRKeyPresence)
        return OnboardingReadiness(speech: speech, microphone: model.micStatus == .authorized,
            writing: model.accessibilityTrusted, shortcut: OnboardingReadiness.shortcutLabel(
                main: settings.hotkeyMain, alternate: settings.hotkeyAlt, problems: model.hotkeyProblems))
    }
}

private struct OnboardingSetupView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var section: OnboardingSetupSection
    let readiness: OnboardingReadiness
    @State private var activeHotkey: HotkeySlot?
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(L10n.text("准备第一次听写")).font(Theme.sectionTitleFont).id("setup-top")
            checklist
            ChipPicker(options: [
                (.speech, L10n.text("语音识别")),
                (.cleanup, L10n.text("整理与翻译")),
                (.permissions, L10n.text("系统权限")),
                (.shortcut, L10n.text("快捷键"))
            ], selection: $section)
            controls.id("setup-controls")
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(permissionPoll) { _ in
            if section == .permissions { model.refreshPermissions() }
        }
    }

    private var checklist: some View {
        SettingsSection(title: L10n.text("听写准备")) {
            statusRow(L10n.text("语音识别"), detail: model.settings.onlineASRProvider.label,
                      status: readiness.speech.label, ready: readiness.speech.canTry)
            statusRow(L10n.text("麦克风"), status: L10n.text(readiness.microphone ? "已允许" : "待授权"), ready: readiness.microphone)
            statusRow(L10n.text("跨 App 写入"), status: L10n.text(readiness.writing ? "已允许" : "待授权"), ready: readiness.writing)
            statusRow(L10n.text("听写快捷键"), status: readiness.shortcut ?? L10n.text("需要设置"), ready: readiness.shortcut != nil)
            statusRow(L10n.text("整理与翻译"), status: L10n.text(model.llmConfigured ? "已配置" : "可选"),
                      ready: model.llmConfigured)
            if readiness.next == nil, let shortcut = readiness.shortcut {
                Text(L10n.text("在文本编辑中新建空白文稿（⌘N）。按 {0} 说一句，再按一次，看看文字是否写进文稿。", shortcut))
                    .font(Theme.rowFont).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(_ title: String, detail: String? = nil, status: String, ready: Bool) -> some View {
        SettingRow(title: title, detail: detail) {
            Label {
                Text(status).foregroundStyle(ready ? Theme.ink : Theme.secondary)
            } icon: {
                Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(ready ? Theme.success : Theme.secondary)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch section {
        case .overview: EmptyView()
        case .speech:
            unlockCredentials
            OnlineASRSettings(dictationOnly: true)
            if model.settings.onlineASRProvider == .local {
                SettingsSection(title: L10n.text("本地模型")) {
                    if !model.serviceState.isRunning {
                        SettingRow(title: L10n.text("本地服务"), detail: model.serviceSummary) {
                            Button(L10n.text("重试")) { model.actions?.restartService() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                    SpeechModelOptions()
                }
            }
        case .cleanup:
            unlockCredentials
            ModelSection()
        case .permissions:
            permissions
        case .shortcut:
            SettingsSection(title: L10n.text("听写快捷键")) {
                SettingRow(title: L10n.text("主快捷键"), detail: model.hotkeyProblems[HotkeySlot.main.name]) {
                    HotkeyField(slot: .main, activeSlot: $activeHotkey)
                }
                SettingRow(title: L10n.text("备用快捷键"), detail: model.hotkeyProblems[HotkeySlot.alt.name]) {
                    HotkeyField(slot: .alt, activeSlot: $activeHotkey)
                }
            }
        }
    }

    @ViewBuilder private var unlockCredentials: some View {
        if model.credentialsLocked {
            Button(L10n.text(model.credentialsUnlocking ? "正在解锁…" : "用 Touch ID 解锁")) {
                model.actions?.unlockCredentials()
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.credentialsUnlocking)
        }
    }

    private var permissions: some View {
        SettingsSection(title: L10n.text("麦克风和辅助功能")) {
            SettingRow(title: L10n.text("麦克风"), detail: model.settings.onlineASRProvider.recordingPrivacyText) {
                if model.micStatus == .authorized {
                    granted
                } else if model.micStatus == .denied || model.micStatus == .restricted {
                    Button(L10n.text("打开系统设置")) { model.actions?.openMicrophoneSettings() }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button(L10n.text("允许")) { model.actions?.requestMicrophone() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingRow(title: L10n.text("辅助功能"), detail: L10n.text("允许在其他 App 的光标处写入文字。")) {
                if model.accessibilityTrusted {
                    granted
                } else {
                    Button(L10n.text("打开系统设置")) { model.actions?.requestAccessibility() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingRow(title: L10n.text("把 🌐 设为「无操作」"),
                       detail: L10n.text("在「系统设置 › 键盘」把「按下 🌐 键时」设为「无操作」。否则 Fn 会打开表情或切换输入法。")) {
                Button(L10n.text("打开键盘设置")) { model.actions?.openKeyboardSettings() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var granted: some View {
        Label(L10n.text("已允许"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
    }
}

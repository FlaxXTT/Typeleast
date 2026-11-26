import AppKit
import AVFoundation
import Combine
import SwiftUI

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    let model: AppModel
    var onFinish: (() -> Void)?
    let practice = OnboardingPracticeController()
    private var finishing = false

    var isKeyWindow: Bool { window?.isKeyWindow == true }

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil || window?.isVisible == false {
            practice.enter(nil)
            let host = NSHostingController(rootView: OnboardingView(practice: practice, finish: { [weak self] in self?.finish() })
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

    private func finish() {
        finishing = true
        close()
        onFinish?()
        finishing = false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Close the onboarding window before presenting Home.
        if !finishing { DispatchQueue.main.async { [weak self] in self?.onFinish?() } }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        if practice.showingSkill { practice.cancel() }
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
    let finish: () -> Void
    @State private var step: OnboardingStep = .welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 34)
            HubScrollView(showsChrome: step == .setup) {
                content.frame(maxWidth: 680).padding(.horizontal, 40).padding(.vertical, 22)
            }
            .id(step)
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
            OnboardingSetupView()
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
            if step != .setup {
                Button(L10n.text("跳过引导"), action: finish).buttonStyle(SecondaryButtonStyle())
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
        if step == .setup { return L10n.text("进入首页") }
        return L10n.text(practice.complete ? "继续" : "播放示例")
    }

    private func primaryAction() {
        if step == .setup { finish() }
        else if step.demo != nil && !practice.complete { practice.playExample() }
        else { move(1) }
    }

    private func move(_ offset: Int) {
        guard let next = OnboardingStep(rawValue: step.rawValue + offset) else { return }
        practice.enter(next.demo)
        step = next
    }
}

private struct OnboardingSetupView: View {
    private enum Section: Hashable { case speech, cleanup, permissions }

    @EnvironmentObject private var model: AppModel
    @State private var section = Section.speech
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(L10n.text("配置 TypeLeast")).font(Theme.sectionTitleFont)
            Text(L10n.text("选本地模型或云端识别。需要整理和翻译时，再添加整理模型。"))
                .font(Theme.rowFont).foregroundStyle(Theme.secondary)
            ChipPicker(options: [
                (.speech, L10n.text("语音识别")),
                (.cleanup, L10n.text("整理与翻译")),
                (.permissions, L10n.text("系统权限"))
            ], selection: $section)
            switch section {
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
            }
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(permissionPoll) { _ in
            if section == .permissions { model.refreshPermissions() }
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

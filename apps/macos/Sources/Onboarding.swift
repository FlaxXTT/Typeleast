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

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView(finish: { [weak self] in self?.finish() })
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

    private func finish() {
        window?.close()
        onFinish?()
    }

    func windowWillClose(_ notification: Notification) {
        model.refreshPermissions()
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, localService, microphone, accessibility, globeKey, micTest, tryIt, guide, done
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let finish: () -> Void
    @State private var step: OnboardingStep = .welcome
    @StateObject private var meter = MicMeter()
    @State private var tryText = ""
    @State private var globeConfirmed = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 34)
            Spacer(minLength: 10)
            content
                .frame(maxWidth: 440)
                .padding(.horizontal, 40)
            Spacer(minLength: 10)
            footer.padding(.horizontal, 40).padding(.bottom, 28)
        }
        .frame(width: 600, height: 560)
        .background(Theme.window)
        .onReceive(poll) { _ in model.refreshPermissions() }
        .onDisappear { meter.stop() }
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
                AppMarkView(size: 72)
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
                    OnboardingCheck(done: model.speech?.ready == true, title: model.speech?.modelName ?? "SenseVoice Small",
                                    detail: AppDelegate.speechProblem(model.speech).isEmpty ? L10n.text("就绪") : AppDelegate.speechProblem(model.speech)) {
                        if model.modelsMissing || model.speech?.phase == "error" {
                            Button(L10n.text("下载")) { model.actions?.downloadModels() }.buttonStyle(PrimaryButtonStyle())
                        } else if let fraction = model.speech?.downloadFraction {
                            ProgressView(value: fraction).frame(width: 140)
                        }
                    }
                    if model.speech?.networkFailure == true { MirrorHint { model.retryModelDownload() } }
                    OnboardingCheck(done: model.llmConfigured, title: L10n.text("整理模型（可稍后设置）"),
                                    detail: model.llmConfigured ? model.modelSummary : L10n.text("在「设置 → 整理」填 API Key。不填也能听写，但不整理。")) {
                        EmptyView()
                    }
                }
                .frame(width: 440)
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
            StepView(symbol: "keyboard", title: L10n.text("说一句试试"),
                     text: L10n.text("点下面的输入框，按 {0} 说话，再按 {1} 结束。", model.hotkeyLabel, model.hotkeyLabel)) {
                VStack(spacing: 10) {
                    TextEditor(text: $tryText)
                        .font(.system(size: 14))
                        .frame(height: 110)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                    if model.phase == .recording {
                        Text(L10n.text("正在听…")).font(.system(size: 12)).foregroundColor(Theme.accent)
                    } else if model.phase == .thinking {
                        Text(L10n.text("正在整理…")).font(.system(size: 12)).foregroundColor(Theme.secondary)
                    } else if !model.serviceUp {
                        Text(model.serviceProblem.isEmpty ? L10n.text("本地服务未就绪，请回到「本地识别」一步。") : model.serviceProblem)
                            .font(.system(size: 12)).foregroundColor(Theme.warning)
                    }
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
            if step != .welcome && step != .done {
                Button(L10n.text("跳过")) { advance() }.buttonStyle(.plain).foregroundColor(Theme.secondary)
            }
            Spacer()
            Button(step == .done ? L10n.text("开始使用") : (step == .welcome ? L10n.text("开始设置") : L10n.text("继续"))) {
                if step == .done { finish() } else { advance() }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func advance() {
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

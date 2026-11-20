import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

// HubSettings.swift - Settings for dictation, translation, prompts, models and general preferences.

/// ServiceManagement may contact a system service. Never query it from a view body
/// or a Binding getter: SwiftUI can evaluate those repeatedly while laying out rows.
final class LoginItemStatus: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var isLoading = false
    private let readStatus: () -> SMAppService.Status
    private let queue = DispatchQueue(label: "typeleast.settings.login-item", qos: .userInitiated)

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status }) {
        self.readStatus = readStatus
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        queue.async { [self] in
            let next = readStatus()
            DispatchQueue.main.async {
                if self.status != next { self.status = next }
                self.isLoading = false
            }
        }
    }

    func setEnabled(_ enabled: Bool, completion: @escaping (Result<SMAppService.Status, Error>) -> Void) {
        guard !isLoading else { return }
        isLoading = true
        queue.async { [self] in
            let result = Result { () throws -> SMAppService.Status in
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                return readStatus()
            }
            DispatchQueue.main.async {
                if case .success(let next) = result { self.status = next }
                self.isLoading = false
                completion(result)
            }
        }
    }
}

struct SettingsPage: View {
    static let sidebarWidth: CGFloat = 202
    var onClose: () -> Void = {}
    @EnvironmentObject var model: AppModel
    @StateObject private var meter = MicMeter()
    @StateObject private var loginItemStatus: LoginItemStatus
    @State private var devices: [AudioInputDevice] = []
    @State private var loginError = ""
    @State private var activeHotkeySlot: HotkeySlot?
    // Keep category offsets only for the lifetime of this settings presentation.
    @State private var scrollMemory = HubScrollMemory()

    init(loginItemStatus: LoginItemStatus = LoginItemStatus(), onClose: @escaping () -> Void = {}) {
        _loginItemStatus = StateObject(wrappedValue: loginItemStatus)
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                InitialHeading(title: L10n.settingTitle, initialSize: 38, bodySize: 21)
                    .foregroundColor(Theme.ink)
                    .padding(.horizontal, 8).padding(.bottom, 12)
                ForEach(SettingsCategory.allCases) { category in
                    let selected = model.settingsCategory == category
                    Button {
                        if !selected { model.settingsCategory = category }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 16)).frame(width: 16)
                            Text(category.title).font(Theme.rowFont)
                            Spacer()
                        }
                        .foregroundColor(selected ? Theme.accent : Theme.secondary)
                        .padding(.horizontal, 8).frame(height: 36)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: Theme.radius)
                            .fill(selected ? Theme.selection : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(FlatActionButtonStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.top, 44).padding(.bottom, 20)
            .frame(width: Self.sidebarWidth).background(Theme.sidebar)
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.settingsCategory.title).font(Theme.sectionTitleFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36).padding(.top, 44).padding(.bottom, 16)
                HubScrollView(key: model.settingsCategory.rawValue, memory: scrollMemory, showsProgress: false) {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        switch model.settingsCategory {
                        case .dictation: shortcuts; language; audio; cleanup
                        case .translation: translationShortcut; selectionTranslation
                        case .prompts: promptFiles
                        case .models:
                            if model.credentialsLocked {
                                SettingsSection { CredentialUnlockRow() }
                            }
                            OnlineASRSettings()
                            speech
                            ModelSection()
                        case .general: general; privacy; permissions; updates; advanced
                        }
                    }
                    .padding(.horizontal, 36).padding(.bottom, 24)
                }
                .id(model.settingsCategory)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
        .font(Theme.bodyFont).foregroundColor(Theme.ink).tint(Theme.accent).controlSize(.large)
        .background(Theme.tile)
        .background(RoundedWindowMarker(radius: Theme.settingsRadius))
        .overlay(alignment: .topLeading) {
            IconButton(symbol: "xmark", help: L10n.text("关闭"), size: 28, action: onClose)
                .accessibilityLabel(L10n.text("关闭"))
                .padding(.leading, 14)
                .padding(.top, 10)
        }
        .overlay(alignment: .bottomTrailing) { FixedWindowCornerRegion().frame(width: 16, height: 16) }
        .onExitCommand { onClose() }
        .onChange(of: model.settingsCategory) { _ in
            if meter.running { meter.stop() }
            refreshLoginStatus()
        }
        .onAppear {
            DispatchQueue.global(qos: .userInitiated).async {
                let inputs = AudioDevices.inputs()
                DispatchQueue.main.async { devices = inputs }
            }
            model.refreshPermissions()
            refreshLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Reflect changes made in System Settings when the user returns.
            refreshLoginStatus()
        }
        .onDisappear { meter.stop() }
    }

    // MARK: sections

    private var shortcuts: some View {
        SettingsSection(title: L10n.text("快捷键")) {
            SettingRow(title: L10n.text("听写"), detail: L10n.text("按一下录音，再按一下结束并整理")) {
                HStack(spacing: 8) {
                    HotkeyField(slot: .main, activeSlot: $activeHotkeySlot)
                    HotkeyField(slot: .alt, activeSlot: $activeHotkeySlot)
                }
            }
            SettingRow(title: L10n.text("提示词模式"), detail: nil) {
                HotkeyField(slot: .assistant, activeSlot: $activeHotkeySlot)
            }
            SettingRow(title: L10n.text("粘贴上一条"), detail: nil) {
                HotkeyField(slot: .pasteLast, activeSlot: $activeHotkeySlot)
            }
            SettingRow(title: L10n.text("取消听写"), detail: nil) {
                Keycap(label: "esc")
            }
            if model.settings.hotkeyMain.isFn || model.settings.hotkeyAlt.isFn {
                NoteRow(symbol: "globe",
                        text: L10n.text("Fn 需要辅助功能权限，并在「系统设置 › 键盘」把「按下 🌐 键时」设为「无操作」。"),
                        action: L10n.text("打开键盘设置")) { model.actions?.openKeyboardSettings() }
            }
        }
    }

    private var translationShortcut: some View {
        SettingsSection(title: L10n.text("快捷键翻译")) {
            SettingRow(title: L10n.text("翻译快捷键"),
                       detail: L10n.text("有选区时在面板显示译文。无选区时按两次快捷键录音并插入译文。")) {
                HotkeyField(slot: .translate, activeSlot: $activeHotkeySlot)
            }
            SettingRow(title: L10n.text("翻译成"), detail: nil) {
                Picker(L10n.text("翻译成"), selection: model.setting(\.translateTarget)) {
                    ForEach(TranslateLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 180)
            }
        }
    }

    private var selectionTranslation: some View {
        SettingsSection(title: SelectionTranslator.featureName) {
            ToggleRow(title: L10n.text("显示翻译按钮"), detail: nil,
                      isOn: model.setting(\.selectionTranslate))
            SettingRow(title: L10n.text("首选译文语言"), detail: L10n.text("原文已是首选语言时，译为中文或英文。")) {
                Picker(L10n.text("首选译文语言"), selection: model.setting(\.selectionTranslateTarget)) {
                    Text(L10n.text("跟随快捷键设置")).tag("")
                    ForEach(TranslateLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 180)
                    .disabled(!model.settings.selectionTranslate)
            }
        }
    }

    private var cleanup: some View {
        SettingsSection(title: L10n.text("整理选项")) {
            ToggleRow(title: L10n.text("听写后用 AI 整理"), detail: nil,
                      isOn: model.setting(\.dictationCleanupEnabled))
            if model.settings.dictationCleanupEnabled { shortDictationSettings }
            ToggleRow(title: L10n.text("参考光标附近的文字"), detail: nil,
                      isOn: model.setting(\.readFieldContext))
            ToggleRow(title: L10n.text("提示词模式推荐模型"), detail: L10n.text("生成提示词后联网推荐。"),
                      isOn: model.setting(\.recommendModel))
        }
    }

    @ViewBuilder private var shortDictationSettings: some View {
        let settings = model.settings
        SettingRow(title: L10n.text("简要整理模型"),
                   detail: L10n.text("25 以内直出，26–100 简要整理，101 起完整整理。中日韩按字，其他语言按词。")) {
            Picker("", selection: model.setting(\.shortDictationMode)) {
                ForEach(ShortDictationMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden().frame(width: 180)
        }
        if settings.shortDictationMode == .smallModel {
            SettingRow(title: L10n.text("小模型服务商"), detail: L10n.text("使用在「模型」中配置的接口和 Key。")) {
                Picker("", selection: model.setting(\.shortDictationProvider)) {
                    ForEach(LLMPreset.all) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 180)
            }
            SettingRow(title: L10n.text("小模型 ID"), detail: L10n.text("小模型不可用时直接输出。")) {
                TextField(L10n.text("模型 ID"), text: model.setting(\.shortDictationModel))
                    .textFieldStyle(.plain).capsuleInput()
                    .frame(width: 180)
            }
        }
    }

    private var promptFiles: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection {
                PromptFileRow(kind: .briefCleanup, title: L10n.text("简要整理提示词"), detail: L10n.text("26–100 字或词"))
                Divider()
                PromptFileRow(kind: .asrEngineering, title: L10n.text("ASR Engineering 提示词"))
            }
            SettingsSection {
                PromptFileRow(kind: .translation, title: L10n.text("翻译提示词"),
                              detail: L10n.text("{{to}} 代表目标语言。"))
            }
            SettingsSection(title: L10n.text("提示词模式")) {
                PromptFileRow(kind: .promptClarify, title: L10n.text("澄清问题"))
                Divider()
                PromptFileRow(kind: .promptBreakdown, title: L10n.text("拆解选中的提示词"))
                Divider()
                PromptFileRow(kind: .promptDraft, title: L10n.text("生成最终提示词"))
            }
        }
    }

    private var dictationLanguage: Binding<String> {
        Binding(get: {
            let saved = Settings.shared.recognitionLanguage(for: model.speech?.modelId)
            if model.settings.onlineASRProvider != .local { return saved }
            return model.speech?.languages?.contains(saved) == false || model.speech?.canSetLanguage == false ? "auto" : saved
        }, set: {
            if model.settings.onlineASRProvider == .local, model.speech?.modelId == "mlx-fun-asr-nano-bf16" {
                model.setting(\.funRecognitionLanguage).wrappedValue = $0
            } else {
                model.setting(\.language).wrappedValue = $0
            }
        })
    }
    private var language: some View {
        let onDevice = model.settings.onlineASRProvider == .local
        return SettingsSection(title: L10n.text("语言")) {
            SettingRow(title: L10n.text("听写语言"), detail: nil) {
                Picker("", selection: dictationLanguage) {
                    ForEach(VoiceLanguage.allCases, id: \.self) {
                        Text($0.label).tag($0.rawValue)
                            .disabled(onDevice && model.speech?.languages?.contains($0.rawValue) == false)
                    }
                }
                .disabled(onDevice && model.speech?.canSetLanguage != true)
                .labelsHidden()
                .frame(width: 150)
            }
            SettingRow(title: L10n.text("中文字形"),
                       detail: onDevice && model.speech?.modelId == "mlx-fun-asr-nano-bf16"
                        ? L10n.text("此模型不会确认听写语言。选择中文时应用繁体；听写日语请选日语，以免只有汉字的日文被转换。自动模式不转换。") : nil) {
                Picker("", selection: model.setting(\.zhVariant)) {
                    ForEach(ChineseVariant.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 150)
            }
        }
    }

    private var audio: some View {
        SettingsSection(title: L10n.text("音频")) {
            SettingRow(title: L10n.text("麦克风"), detail: meter.running
                       ? (meter.heardVoice ? L10n.text("听到了。{0} 秒后关闭麦克风", Int(MicMeter.maxSeconds)) : L10n.text("正在听…请说话，条变蓝表示听到了"))
                       : "") {
                HStack(spacing: 12) {
                    LevelBars(level: meter.level)
                    Button(meter.running ? L10n.text("停止") : L10n.text("测试麦克风")) {
                        if meter.running { meter.stop() } else { meter.start(deviceUID: Settings.shared.inputDeviceUID) }
                    }
                    Picker("", selection: model.setting(\.inputDeviceUID, then: {
                        // Switching device restarts a test that is already running, never starts one.
                        if meter.running { meter.start(deviceUID: Settings.shared.inputDeviceUID) }
                    })) {
                        Text(L10n.text("自动检测")).tag("")
                        ForEach(devices) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
            }
            ToggleRow(title: L10n.text("提示音"), detail: nil, isOn: model.setting(\.soundEnabled))
            ToggleRow(title: L10n.text("听写时静音"), detail: nil, isOn: model.setting(\.muteWhileDictating))
        }
    }

    private var general: some View {
        SettingsSection {
            SettingRow(title: L10n.text("界面语言"), detail: L10n.text("重启后生效。")) {
                Picker("", selection: model.setting(\.interfaceLanguage)) {
                    Text(L10n.text("跟随系统")).tag("system")
                    Text("简体中文").font(Theme.rowFont).tag("zh-Hans")
                    Text("English").tag("en")
                }.labelsHidden().frame(width: 150)
            }
            SettingRow(title: L10n.text("外观"), detail: nil) {
                HStack(spacing: 2) {
                    ForEach(AppearancePreference.allCases, id: \.self) { preference in
                        FlexibleSegment(label: preference.label, selected: model.settings.appearance == preference) {
                            model.setting(\.appearance, then: { model.actions?.applyGeneralSettings() }).wrappedValue = preference
                        }
                    }
                }.padding(3).background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).fill(Theme.window))
                    .frame(width: 220)
            }
            SettingRow(title: L10n.text("开机启动"), detail: loginDetail) {
                HStack(spacing: 8) {
                    if loginItemStatus.isLoading {
                        SkeletonWave(width: 38, height: 22, radius: 11)
                    } else {
                        Toggle(L10n.text("开机启动"), isOn: Binding(get: { loginItemStatus.status == .enabled }, set: { setLogin($0) }))
                            .toggleStyle(StateSwitchStyle()).labelsHidden()
                    }
                }
            }
            ToggleRow(title: L10n.text("在 Dock 中显示"), detail: nil,
                      isOn: model.setting(\.showInDock, then: { model.actions?.applyGeneralSettings() }))
            ToggleRow(title: L10n.text("显示语音条"), detail: nil,
                      isOn: model.setting(\.showIdleBar, then: { model.actions?.applyGeneralSettings() }))
            SettingRow(title: L10n.text("新手引导"), detail: nil) {
                Button(L10n.text("打开")) { model.actions?.showOnboarding() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var privacy: some View {
        SettingsSection(title: L10n.text("隐私与数据")) {
            ToggleRow(title: L10n.text("保留录音 5 分钟"), detail: nil,
                      isOn: model.setting(\.keepAudio24h))
            NoteRow(symbol: "lock", text: model.settings.onlineASRProvider.recordingPrivacyText
                    + " " + L10n.text("联网整理会发送文字，自动隐藏部分凭据。"),
                    action: nil, perform: nil)
        }
    }

    private var permissions: some View {
        SettingsSection(title: L10n.text("权限")) {
            PermissionRow(title: L10n.text("麦克风"), granted: model.micStatus == .authorized,
                          action: model.micStatus == .notDetermined ? L10n.text("允许") : L10n.text("打开设置")) {
                if model.micStatus == .notDetermined { model.actions?.requestMicrophone() } else { model.actions?.openMicrophoneSettings() }
            }
            PermissionRow(title: L10n.text("辅助功能（粘贴、Fn 键）"), granted: model.accessibilityTrusted, action: L10n.text("允许")) {
                model.actions?.requestAccessibility()
            }
        }
    }

    private var speech: some View {
        SpeechModelOptions()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .circular).fill(Theme.card))
    }

    private var updates: some View {
        SettingsSection(title: L10n.text("版本与更新")) {
            SettingRow(title: L10n.text("当前版本 ") + Updater.currentVersion, detail: nil) {
                Button(L10n.text("检查更新")) { model.actions?.checkForUpdates(interactive: true) }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    /// What most people never need: the local service, and where downloads come from.
    private var advanced: some View {
        SettingsSection(title: L10n.text("高级")) {
            SettingRow(title: model.serviceSummary,
                       detail: model.nodeDescription.isEmpty ? "" : "Node.js " + model.nodeDescription) {
                HStack(spacing: 8) {
                    if model.serviceState.needsNode {
                        Button(L10n.text("下载 Node.js")) { NSWorkspace.shared.open(URL(string: "https://nodejs.org/zh-cn/download")!) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    Button(L10n.text("选择 Node.js…")) { model.actions?.chooseNode() }.buttonStyle(SecondaryButtonStyle())
                    Button(L10n.text("重新启动")) { model.actions?.restartService() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            SettingRow(title: L10n.text("模型下载镜像（可选）"),
                       detail: nil) {
                HStack(spacing: 8) {
                    TextField("https://huggingface.co", text: model.setting(\.modelMirror))
                        .textFieldStyle(.plain).capsuleInput()
                        .frame(width: 220)
                    if model.settings.modelMirror != ModelMirror.suggested {
                        Button(L10n.text("使用 hf-mirror.com")) { model.setting(\.modelMirror).wrappedValue = ModelMirror.suggested }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            SettingRow(title: L10n.text("更新下载源"),
                       detail: nil) {
                Picker("", selection: model.setting(\.updateSource)) {
                    Text(L10n.text("自动（GitHub 慢时用镜像）")).tag("auto")
                    Text(L10n.text("只用 GitHub")).tag("github")
                    Text(L10n.text("镜像优先")).tag("mirror")
                }.labelsHidden().frame(width: 220)
            }
            if let version = model.health?.version {
                InterfaceTypography.text(L10n.text("服务版本 ") + version, size: 11)
                    .foregroundColor(Theme.tertiary)
            }
        }
    }

    private var loginDetail: String {
        if !loginError.isEmpty { return loginError }
        // Switched off under System Settings → Login Items: only the user can allow it again there.
        if loginItemStatus.status == .requiresApproval { return L10n.text("请在「系统设置 → 通用 → 登录项」允许 TypeLeast") }
        return ""
    }

    private func refreshLoginStatus() {
        if model.settingsCategory == .general { loginItemStatus.refresh() }
    }

    private func setLogin(_ on: Bool) {
        loginItemStatus.setEnabled(on) { result in
            switch result {
            case .success(let status):
                model.settings.launchAtLogin = on
                loginError = ""
                if on, status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            case .failure(let error):
                loginError = L10n.text("无法修改：") + error.localizedDescription
            }
        }
    }
}

// MARK: - building blocks

struct CredentialUnlockRow: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(L10n.text("钥匙串已锁定"), systemImage: "lock").font(Theme.rowFont)
                Spacer()
                Button(L10n.text(model.credentialsUnlocking ? "正在解锁…" : "用 Touch ID 解锁")) {
                    model.actions?.unlockCredentials()
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(model.credentialsUnlocking || model.phase != .idle)
            }
            if let message = model.credentialUnlockError {
                Text(message).font(Theme.captionFont).foregroundColor(Theme.warning)
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                InterfaceTypography.text(title, size: 14, weight: .semibold).foregroundColor(Theme.secondary)
            }
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .circular).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .circular).strokeBorder(Theme.border, lineWidth: 1))
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    let detail: String?
    var loading = false
    @ViewBuilder var trailing: Trailing

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.rowFont)
                .fixedSize(horizontal: false, vertical: true)
            if loading {
                SkeletonWave(width: 97, height: 12)
            } else if let detail = detail, !detail.isEmpty {
                Text(detail).font(Theme.captionFont).lineSpacing(4).foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                labels.frame(minWidth: 140, alignment: .leading)
                Spacer(minLength: 12)
                trailing.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                labels
                trailing
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8).frame(minHeight: 48)
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn).toggleStyle(StateSwitchStyle()).labelsHidden()
        }
    }
}

/// A switch whose track shows the state by colour: green when on, grey when off
/// (the system switch follows the accent colour, which can look the same either way).
struct StateSwitchStyle: ToggleStyle {
    static let onColor = Theme.success
    static let offColor = Color(nsColor: .systemGray).opacity(0.45)

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule(style: .circular)
                    .fill(configuration.isOn ? Self.onColor : Self.offColor)
                    .frame(width: 38, height: 22)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    .frame(width: 18, height: 18)
                    .padding(2)
            }
            .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(FlatActionButtonStyle(cornerRadius: Theme.capsuleRadius))
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
        }
    }
}

private struct NoteRow: View {
    let symbol: String
    let text: String
    let action: String?
    let perform: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundColor(Theme.secondary).padding(.top, 1)
            Text(text).font(InterfaceTypography.localized(12)).foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action = action, let perform = perform {
                Button(action, action: perform).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).fill(Theme.window.opacity(0.7)))
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundColor(granted ? Theme.success : Theme.warning)
            Text(title).font(Theme.rowFont)
            Spacer()
            if granted {
                Text(L10n.text("已允许")).font(InterfaceTypography.localized(12)).foregroundColor(Theme.secondary)
            } else {
                Button(action, action: perform).buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

// MARK: - shortcut recorder

enum HotkeySlot {
    case main, alt, pasteLast, translate, assistant

    /// The registration slot name (AppDelegate.registerHotKeys).
    var name: String {
        switch self {
        case .main: return "main"
        case .alt: return "alt"
        case .pasteLast: return "pasteLast"
        case .translate: return "translate"
        case .assistant: return "assistant"
        }
    }

    var keyPath: ReferenceWritableKeyPath<Settings, HotKeyBinding> {
        switch self {
        case .main: return \.hotkeyMain
        case .alt: return \.hotkeyAlt
        case .pasteLast: return \.hotkeyPasteLast
        case .translate: return \.hotkeyTranslate
        case .assistant: return \.hotkeyAssistant
        }
    }
}

/// Shows a binding as keycaps; click, then press a key combination (or Fn) to change it.
struct HotkeyField: View {
    @EnvironmentObject var model: AppModel
    let slot: HotkeySlot
    @Binding var activeSlot: HotkeySlot?
    @State private var monitor: Any?
    @State private var fnTap = FnTapDetector()

    private var recording: Bool { activeSlot == slot }
    private var binding: HotKeyBinding { model.settings[keyPath: slot.keyPath] }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 4) {
                    if recording {
                        Text(L10n.text("按下新快捷键…")).font(InterfaceTypography.localized(12)).foregroundColor(Theme.accent)
                            .padding(.horizontal, 8).frame(minHeight: 24)
                    } else if !binding.enabled {
                        Text(L10n.text("未设置")).font(InterfaceTypography.localized(12)).foregroundColor(Theme.tertiary)
                            .padding(.horizontal, 8).frame(minHeight: 24)
                    } else {
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in Keycap(label: label) }
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .circular).stroke(recording ? Theme.accent : Color.clear, lineWidth: 1.5))
            }
            .buttonStyle(FlatActionButtonStyle())
            .help(L10n.text("Esc 取消，Delete 清除。"))
            if let problem = model.hotkeyProblems[slot.name], !recording {
                Text(problem).font(Theme.captionFont).foregroundColor(Theme.warning)
            }
        }
        .onChange(of: recording) { _, recording in
            if !recording { removeMonitor() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notice in
            if (notice.object as? NSWindow)?.identifier == SettingsWindowController.identifier { stop() }
        }
        .onDisappear { stop() }
    }

    private var labels: [String] {
        if binding.isFn { return ["fn"] }
        if let chord = binding.fnChord { return ["Fn", chord.keyLabel] }
        var out: [String] = []
        if binding.modifiers & 4096 != 0 { out.append("⌃") }
        if binding.modifiers & 2048 != 0 { out.append("⌥") }
        if binding.modifiers & 512 != 0 { out.append("⇧") }
        if binding.modifiers & 256 != 0 { out.append("⌘") }
        out.append(HotKeyCentre.keyName(binding.keyCode).lowercased() == "space" ? "space" : HotKeyCentre.keyName(binding.keyCode))
        return out
    }

    private func start() {
        removeMonitor()
        fnTap = FnTapDetector()
        activeSlot = slot
        FnKeyMonitor.shared.capturingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard recording else { return event }
            if event.type == .flagsChanged {
                captureFlags(event)
                return event
            }
            fnTap.otherInput()
            switch Int(event.keyCode) {
            case 53: // Esc cancels
                stop()
            case 51, 117: // Delete clears (not for the main dictation key)
                if slot != .main {
                    var cleared = binding
                    cleared.enabled = false
                    save(cleared)
                } else { stop() }
            default:
                if event.modifierFlags.contains(.function) {
                    if UInt32(event.keyCode) == FnChord.space.rawValue, FnChord.matches(.space, flags: event.modifierFlags) {
                        save(FnChord.space.binding)
                    } else { NSSound.beep() }
                    return nil
                }
                let modifiers = HotKeyCentre.carbonModifiers(from: event.modifierFlags)
                // A bare letter would hijack normal typing; require a modifier or a function key.
                let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
                guard modifiers != 0 || functionKeys.contains(event.keyCode) else { NSSound.beep(); return nil }
                save(HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers, enabled: true,
                                   name: HotKeyCentre.describe(keyCode: UInt32(event.keyCode), modifiers: modifiers)))
            }
            return nil
        }
    }

    private func captureFlags(_ event: NSEvent) {
        if event.keyCode == FnKeyMonitor.keyCode {
            if event.modifierFlags.contains(.function) {
                let otherModifiers = event.modifierFlags.intersection(FnChord.standardModifiers)
                fnTap.fnDown(at: Date(), otherModifiersHeld: !otherModifiers.isEmpty)
            } else if fnTap.fnUp(at: Date()), slot == .main || slot == .alt {
                save(.fnDefault)
            }
        } else {
            fnTap.otherInput()
            if UInt32(event.keyCode) == FnChord.leftShift.rawValue, FnChord.matches(.leftShift, flags: event.modifierFlags) {
                save(FnChord.leftShift.binding)
            }
        }
    }

    private func save(_ value: HotKeyBinding) {
        if value.enabled && value.isFn {
            if slot == .alt && model.settings.hotkeyMain.enabled && model.settings.hotkeyMain.isFn {
                NSSound.beep()
                stop()
                return
            }
            if slot == .main && model.settings.hotkeyAlt.enabled && model.settings.hotkeyAlt.isFn {
                model.settings.hotkeyAlt = .unset
            }
        }
        model.settings[keyPath: slot.keyPath] = value
        model.actions?.registerHotKeys()
        model.objectWillChange.send()
        stop()
    }

    private func stop() {
        if recording {
            activeSlot = nil
            FnKeyMonitor.shared.capturingShortcut = false
        }
        removeMonitor()
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}


// MARK: - cleanup model (the user's own API key)

/// Any OpenAI-compatible service with the user's own key (stored in the Keychain).
struct ModelSection: View {
    @EnvironmentObject var model: AppModel
    @State private var keyDraft = ""
    @State private var models: [String] = []
    @State private var status = ""
    @State private var statusOK = true
    @State private var busy = false
    @State private var requests = FormRequest<[String]>()

    private var settings: Settings { model.settings }
    private var keySaved: Bool { model.llmKeyPresence == true }
    private var keyLocked: Bool { preset.needsKey && model.credentialsLocked }
    private var keyLoading: Bool { preset.needsKey && !keyLocked && model.llmKeyPresence == nil }
    private var preset: LLMPreset { LLMPreset.find(settings.llmPresetID) }
    private var normalizedKeyDraft: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var requestContext: [String] { [settings.llmPresetID, settings.llmBaseURL, settings.llmModel, normalizedKeyDraft] }

    var body: some View {
        SettingsSection(title: L10n.text("整理模型")) {
                SettingRow(title: L10n.text("服务商"), detail: nil) {
                    HStack(spacing: 8) {
                        if !preset.keyPage.isEmpty, !keyLocked, !keySaved, let url = URL(string: preset.keyPage) {
                            Link(L10n.text(preset.needsKey ? "获取 API Key" : "官网"), destination: url)
                                .font(Theme.captionFont)
                        }
                        Picker("", selection: Binding(get: { settings.llmPresetID }, set: { id in
                            settings.llmPresetID = id
                            reloadForPreset()
                        })) {
                            ForEach(LLMPreset.all) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                }
                SettingRow(title: L10n.text("接口地址"), detail: LLMPreset.isAllowedBaseURL(settings.llmBaseURL) ? nil : L10n.text("需要 https（本机可用 http://127.0.0.1）")) {
                    TextField("https://…/v1", text: model.setting(\.llmBaseURL))
                        .textFieldStyle(.plain).capsuleInput()
                        .frame(width: 300)
                }
                if preset.needsKey {
                    SettingRow(title: "API Key", detail: nil, loading: keyLoading) {
                        HStack(spacing: 8) {
                            SecureField(keyLocked ? L10n.text("钥匙串已锁定") : keySaved ? L10n.text("已保存，留空保持不变") : "sk-…", text: $keyDraft)
                                .textFieldStyle(.plain).capsuleInput()
                                .frame(width: 220)
                            // Deletion is an explicit action; a blank draft keeps the saved key.
                            Button(normalizedKeyDraft.isEmpty && keySaved ? L10n.text("删除") : L10n.text("保存")) {
                                saveKey(deleting: normalizedKeyDraft.isEmpty && keySaved)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(keyLoading || (normalizedKeyDraft.isEmpty && !keySaved))
                        }
                        .disabled(keyLocked)
                    }
                }
                SettingRow(title: L10n.text("模型"), detail: nil) {
                    HStack(spacing: 8) {
                        TextField(preset.modelHint, text: model.setting(\.llmModel))
                            .textFieldStyle(.plain).capsuleInput()
                            .frame(width: 200)
                        if !models.isEmpty {
                            Menu(L10n.text("选择")) {
                                ForEach(models, id: \.self) { id in
                                    Button(id) { model.setting(\.llmModel).wrappedValue = id }
                                }
                            }
                            .frame(width: 70)
                        }
                        Button(L10n.text("获取列表")) { fetchModels() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(busy || keyLocked)
                    }
                }
                if settings.supportsCleanupThinking {
                    ToggleRow(title: L10n.text("完整整理时开启思考"), detail: nil, isOn: model.setting(\.cleanupThinking))
                    if settings.cleanupThinking {
                        SettingRow(title: L10n.text("推理强度"), detail: nil) {
                            Picker("", selection: model.setting(\.cleanupReasoningEffort)) {
                                ForEach(CleanupReasoningEffort.allCases, id: \.self) { effort in
                                    Text(effort.label).tag(effort)
                                }
                            }
                            .labelsHidden().frame(width: 180)
                        }
                    }
                }
                ToggleRow(title: L10n.text("服务故障时自动切换"), detail: L10n.text("文字会发给备用服务商。"), isOn: model.setting(\.automaticProviderFallback))
                HStack(spacing: 10) {
                    if busy { LoadingCircularProgress(size: 20) }
                    Button(busy ? L10n.text("测试中…") : L10n.text("测试连接")) { test() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(busy || !canTestRoute)
                    if !status.isEmpty {
                        Text(status).font(InterfaceTypography.localized(12)).foregroundColor(statusOK ? Theme.success : Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                if !keyLocked && !keyLoading && !model.llmConfigured {
                    Text(missingParts() + L10n.text("。可以听写，但不整理。"))
                        .font(Theme.captionFont).foregroundColor(Theme.warning)
                }
        }
        .onAppear { reloadForPreset() }
        .onChange(of: requestContext) { _ in
            if requests.isActive { invalidateRequest() }
        }
        .onChange(of: settings.llmBaseURL) { _ in models = [] }
        .onDisappear { invalidateRequest() }
    }

    private func invalidateRequest() {
        requests.invalidate()
        busy = false
        status = ""
    }

    private func reloadForPreset() {
        invalidateRequest()
        keyDraft = ""
        models = []
        status = ""
        model.refreshLLMKeyPresence()
    }

    /// Rendering the page only uses saved-state metadata, never the key value.
    private var canTestRoute: Bool {
        !keyLocked && LLMPreset.isAllowedBaseURL(settings.llmBaseURL) && !settings.llmModel.isEmpty
            && (!preset.needsKey || !normalizedKeyDraft.isEmpty || keySaved)
    }

    private func keyForRequest() -> String {
        let draft = normalizedKeyDraft
        if !draft.isEmpty { return draft }
        return preset.needsKey ? settings.llmAPIKey : (KeychainStore.readSilently(account: settings.llmPresetID) ?? "")
    }

    /// Read a saved key only after the user asks to use it.
    private func draftRoute() -> LLMRoute? {
        let base = settings.llmBaseURL
        guard LLMPreset.isAllowedBaseURL(base), !settings.llmModel.isEmpty else { return nil }
        let key = keyForRequest()
        if preset.needsKey && key.isEmpty { return nil }
        return LLMRoute(baseURL: base, model: settings.llmModel, apiKey: key)
    }

    private func fetchModels() {
        let base = settings.llmBaseURL
        guard LLMPreset.isAllowedBaseURL(base) else { status = L10n.text("接口地址错误"); statusOK = false; return }
        let key = keyForRequest()
        guard !preset.needsKey || !key.isEmpty else {
            status = L10n.text(keySaved ? "无法读取已保存的 API Key。" : "没有 Key")
            statusOK = false
            return
        }
        let route = LLMRoute(baseURL: base, model: "", apiKey: key)
        let context = requestContext
        let request = requests.begin(context: context)
        busy = true
        status = L10n.text("正在获取…")
        statusOK = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ServiceClient.shared.listModelsSync(route: route) }
            DispatchQueue.main.async {
                guard requests.finish(request, context: requestContext) else { return }
                busy = false
                switch result {
                case .success(let ids) where !ids.isEmpty:
                    models = ids
                    status = L10n.text("找到 {0} 个模型", ids.count)
                    statusOK = true
                case .success:
                    status = L10n.text("此服务商没有模型列表，请手动填模型 ID")
                    statusOK = false
                case .failure(let error):
                    status = Self.describe(error)
                    statusOK = false
                    DiagnosticsLog.write("llm.models.fail", ["host": URL(string: base)?.host ?? "?",
                                                             "error": (error as? ServiceError)?.description ?? error.localizedDescription])
                }
            }
        }
    }

    /// Which part of the own-key route is still missing, in plain words.
    private func missingParts() -> String {
        var missing: [String] = []
        if !LLMPreset.isAllowedBaseURL(settings.llmBaseURL) { missing.append(L10n.text("接口地址错误")) }
        if preset.needsKey && !keySaved {
            missing.append(keyDraft.isEmpty ? L10n.text("没有 Key") : L10n.text("Key 未保存，请点「保存」"))
        }
        if settings.llmModel.isEmpty { missing.append(L10n.text("没有模型")) }
        return missing.isEmpty ? L10n.text("设置未完成") : missing.joined(separator: "、")
    }

    /// Store the key; say so honestly when the Keychain refuses.
    @discardableResult
    private func saveKey(quiet: Bool = false, deleting: Bool = false) -> Bool {
        let value = deleting ? "" : normalizedKeyDraft
        guard deleting || !value.isEmpty else { return keySaved }
        let ok = KeychainStore.write(value, account: settings.llmPresetID)
        if ok {
            keyDraft = ""
        }
        if !ok {
            status = L10n.text("Key 无法存入钥匙串（错误码 ") + String(KeychainStore.lastStatus) + "）"
            statusOK = false
            DiagnosticsLog.write("keychain.write.fail", ["status": String(KeychainStore.lastStatus)])
        } else if !quiet {
            status = deleting ? L10n.text("Key 已删除") : L10n.text("Key 已保存")
            statusOK = true
        }
        settings.notifyChanged()
        model.objectWillChange.send()
        return ok
    }

    private func test() {
        guard let route = draftRoute() else {
            if preset.needsKey && keySaved {
                status = L10n.text("无法读取已保存的 API Key。")
                statusOK = false
            }
            return
        }
        let context = requestContext
        let request = requests.begin(context: context)
        busy = true
        status = L10n.text("正在测试…")
        statusOK = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ServiceClient.shared.testLLMSync(route: route) }
            DispatchQueue.main.async {
                guard requests.finish(request, context: requestContext) else { return }
                busy = false
                switch result {
                case .success(let answer) where answer.ok:
                    let saved = normalizedKeyDraft.isEmpty || normalizedKeyDraft == KeychainStore.cached(account: settings.llmPresetID) || saveKey(quiet: true)
                    let thinks = answer.code == "thinking"
                    status = L10n.text("连接成功，用时 ") + String(Int(answer.ms ?? 0)) + L10n.text(" 毫秒") + (saved ? L10n.text("，Key 已保存") : L10n.text("，但 Key 无法存入钥匙串"))
                        + (thinks ? L10n.text("。此模型先思考，整理较慢") : "")
                    statusOK = saved
                    DiagnosticsLog.write("llm.test.ok", ["host": URL(string: route.baseURL)?.host ?? "?", "model": route.model])
                case .success(let answer):
                    status = Self.explain(code: answer.code, message: answer.error)
                    statusOK = false
                    DiagnosticsLog.write("llm.test.fail", ["host": URL(string: route.baseURL)?.host ?? "?", "model": route.model,
                                                           "code": answer.code ?? "?", "error": answer.error ?? ""])
                case .failure(let error):
                    let d = error as? ServiceError
                    status = d?.serviceUnavailable == true
                        ? L10n.text("本地服务未就绪，请稍后重试")
                        : Self.describe(error)
                    statusOK = false
                    DiagnosticsLog.write("llm.test.error", ["error": d?.description ?? error.localizedDescription])
                }
            }
        }
    }

    private static func explain(code: String?, message: String?) -> String {
        switch code ?? "" {
        case "HTTP_401", "HTTP_403": return L10n.text("Key 无效或没有权限（{0}）", code ?? "")
        case "HTTP_400": return L10n.text("模型 ID 可能有误（HTTP 400），请点「获取列表」选择")
        case "HTTP_404": return L10n.text("地址或模型 ID 错误（HTTP 404）")
        case "NETWORK": return L10n.text("连不上服务商：") + (message ?? "") + L10n.text("。请检查网络或代理")
        case "HTTP_500", "HTTP_502", "HTTP_503", "HTTP_504": return L10n.text("服务商出错（{0}），请稍后重试", code ?? "")
        case "HTTP_402": return L10n.text("余额不足（HTTP 402）")
        case "HTTP_429": return L10n.text("请求太多或额度用完（HTTP 429）")
        case "invalid-route": return L10n.text("请检查地址、Key 和模型")
        case "timeout": return L10n.text("超时无响应")
        default: return L10n.text("失败：") + (message ?? code ?? L10n.text("未知错误"))
        }
    }

    private static func describe(_ error: Error) -> String {
        if case ServiceError.http(let status, _, _)? = error as? ServiceError {
            return explain(code: "HTTP_" + String(status), message: nil)
        }
        return L10n.text("连不上服务商：") + ((error as? ServiceError)?.description ?? error.localizedDescription) + L10n.text("。请检查网络或代理")
    }
}

/// Opens the same document that will be read for the next request.
private struct PromptFileRow: View {
    let kind: PromptKind
    let title: String
    var detail: String? = nil
    @State private var codeEditor: URL?
    @State private var message: String?
    @State private var restoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRow(title: title, detail: detail) {
                Menu(L10n.text("打开编辑")) {
                    Button(L10n.text("使用系统默认编辑器")) { open() }
                    if let codeEditor {
                        Button("Visual Studio Code") { open(in: codeEditor) }
                    }
                    Button(L10n.text("选择其他应用…")) { chooseEditor() }
                    Divider()
                    Button(L10n.text("恢复默认…")) { restoring = true }
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel(L10n.text("编辑 {0}", title))
            }
            if let message {
                Text(message).font(Theme.captionFont).foregroundColor(Theme.secondary)
            }
        }
        .onAppear {
            codeEditor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")
        }
        .confirmationDialog(L10n.text("恢复默认提示词？"), isPresented: $restoring, titleVisibility: .visible) {
            Button(L10n.text("恢复默认"), role: .destructive) { restore() }
        }
    }

    private func open(in editor: URL? = nil) {
        do {
            let file = try Settings.shared.preparePrompt(kind)
            message = nil
            if let editor {
                NSWorkspace.shared.open([file], withApplicationAt: editor, configuration: .init()) { _, error in
                    if error != nil {
                        DispatchQueue.main.async { message = L10n.text("无法打开提示词文件。") }
                    }
                }
            } else if !NSWorkspace.shared.open(file) {
                message = L10n.text("无法打开提示词文件。")
            }
        } catch {
            message = L10n.text("无法准备提示词文件。")
        }
    }

    private func chooseEditor() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择编辑器")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.begin { response in
            if response == .OK, let editor = panel.url { open(in: editor) }
        }
    }

    private func restore() {
        do {
            try Settings.shared.restorePrompt(kind)
            message = L10n.text("已恢复默认提示词。")
        } catch {
            message = L10n.text("无法恢复默认提示词。")
        }
    }
}

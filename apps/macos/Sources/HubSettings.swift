import SwiftUI
import AppKit
import ServiceManagement

// HubSettings.swift - the Settings page in three tabs: 听写 (shortcuts, language, audio, cleanup
// options), 模型 (cleanup model, speech model) and 通用 (general, privacy, permissions, updates,
// and 高级 for the local service and download sources), as titled sections of cards.

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var meter = MicMeter()
    @State private var devices: [AudioInputDevice] = []
    @State private var loginError = ""

    private let categories = ["听写", "模型", "通用"]

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L10n.text("设置"))
            HStack(spacing: 2) {
                ForEach(categories.indices, id: \.self) { index in
                    FlexibleSegment(label: L10n.text(categories[index]), selected: model.settingsCategory == index) {
                        model.settingsCategory = index
                    }
                }
            }.padding(3).background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .padding(.horizontal, 36).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.settingsCategory {
                    case 0: shortcuts; language; audio; cleanup
                    case 1: ModelSection(); speech
                    default: general; privacy; permissions; updates; advanced
                    }
                }
                .padding(.horizontal, 36).padding(.bottom, 32)
            }
            .id(model.settingsCategory)
        }
        .onChange(of: model.settingsCategory) { _ in meter.stop() }
        .onAppear {
            devices = AudioDevices.inputs()
            model.refreshPermissions()
        }
        .onDisappear { meter.stop() }
    }

    // MARK: sections

    private var shortcuts: some View {
        SettingsSection(title: L10n.text("快捷键")) {
            SettingRow(title: L10n.text("听写"), detail: L10n.text("按一下录音，再按一下结束并整理")) {
                HStack(spacing: 8) {
                    HotkeyField(slot: .main)
                    HotkeyField(slot: .alt)
                }
            }
            SettingRow(title: L10n.text("翻译"), detail: L10n.text("按一下开始，再按一下结束，插入{0}译文。", TranslateLanguage(rawValue: model.settings.translateTarget)?.label ?? "English")) {
                HotkeyField(slot: .translate)
            }
            SettingRow(title:L10n.text("提示词模式"),detail:L10n.text("先说清能读哪些资料、能否联网，以及是创新还是重复的工作。")) {
                HotkeyField(slot:.assistant)
            }
            SettingRow(title: L10n.text("粘贴上一条"), detail: nil) {
                HotkeyField(slot: .pasteLast)
            }
            SettingRow(title: L10n.text("取消听写"), detail: L10n.text("按 Esc，或点语音条上的 ✕")) {
                Keycap(label: "esc")
            }
            if model.settings.hotkeyMain.isFn || model.settings.hotkeyAlt.isFn {
                NoteRow(symbol: "globe",
                        text: L10n.text("Fn 需要辅助功能权限，并在「系统设置 › 键盘」把「按下 🌐 键时」设为「无操作」。"),
                        action: L10n.text("打开键盘设置")) { model.actions?.openKeyboardSettings() }
            }
        }
    }

    private var cleanup: some View {
        SettingsSection(title: L10n.text("整理选项")) {
            ToggleRow(title: L10n.text("参考光标附近的文字"), detail: nil,
                      isOn: model.setting(\.readFieldContext))
            ToggleRow(title: L10n.text("自动加词"), detail: L10n.text("粘贴后你改过的词加入词典。"),
                      isOn: model.setting(\.autoLearn))
            ToggleRow(title: L10n.text("选中提示词时拆解"), detail: L10n.text("选中一长段文字后，旁边出现拆解按钮。点了才发送。"),
                      isOn: model.setting(\.selectionBreakdown))
        }
    }

    private var dictationLanguage: Binding<String> {
        Binding(get: {
            let saved = Settings.shared.language
            return model.speech?.languages?.contains(saved) == false || model.speech?.canSetLanguage == false ? "auto" : saved
        }, set: { model.setting(\.language).wrappedValue = $0 })
    }
    private var language: some View {
        SettingsSection(title: L10n.text("语言")) {
            SettingRow(title: L10n.text("听写语言"), detail: nil) {
                Picker("", selection: dictationLanguage) {
                    ForEach(VoiceLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue).disabled(model.speech?.languages?.contains($0.rawValue) == false) }
                }
                .disabled(model.speech?.canSetLanguage == false)
                .labelsHidden()
                .frame(width: 150)
            }
            SettingRow(title: L10n.text("翻译成"), detail: nil) {
                Picker("", selection: model.setting(\.translateTarget)) {
                    ForEach(TranslateLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }.labelsHidden().frame(width: 150)
            }
            SettingRow(title: L10n.text("中文字形"), detail: nil) {
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
        SettingsSection(title: L10n.text("通用")) {
            SettingRow(title: L10n.text("界面语言"), detail: L10n.text("重启后生效。")) {
                Picker("", selection: model.setting(\.interfaceLanguage)) {
                    Text(L10n.text("跟随系统")).tag("system")
                    Text("简体中文").tag("zh-Hans")
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
                }.padding(3).background(RoundedRectangle(cornerRadius: 9).fill(Theme.window))
                    .frame(width: 220)
            }
            ToggleRow(title: L10n.text("开机启动"), detail: loginDetail,
                      isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { setLogin($0) }))
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
            NoteRow(symbol: "lock", text: L10n.text("音频不出本机。只有文字发给模型，密码和密钥先去掉。"), action: nil, perform: nil)
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
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
    }

    private var updates: some View {
        SettingsSection(title: L10n.text("版本与更新")) {
            SettingRow(title: L10n.text("当前版本 ") + Updater.currentVersion, detail: L10n.text("一键更新，权限保留。")) {
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
                        .textFieldStyle(.roundedBorder)
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
                Text(L10n.text("服务版本 ") + version + " · App " + Updater.currentVersion).font(.system(size: 11)).foregroundColor(Theme.tertiary)
            }
        }
    }

    private var speechDetail: String {
        let problem = AppDelegate.speechProblem(model.speech)
        return problem.isEmpty ? L10n.text("就绪，音频不出本机") : problem
    }

    private var loginDetail: String {
        if !loginError.isEmpty { return loginError }
        // Switched off under System Settings → Login Items: only the user can allow it again there.
        if SMAppService.mainApp.status == .requiresApproval { return L10n.text("请在「系统设置 → 通用 → 登录项」允许 TypeLeast") }
        return ""
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            model.settings.launchAtLogin = on
            loginError = ""
        } catch {
            loginError = L10n.text("无法修改：") + error.localizedDescription
        }
        // Registering again does not undo the user's switch in System Settings: send them there.
        if on, SMAppService.mainApp.status == .requiresApproval {
            loginError = ""
            SMAppService.openSystemSettingsLoginItems()
        }
        model.objectWillChange.send()
    }
}

// MARK: - building blocks

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.secondary)
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.card))
        }
    }
}

struct SettingRow<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder var trailing: Trailing

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
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
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn).toggleStyle(StateSwitchStyle()).labelsHidden()
        }
    }
}

/// A switch whose track shows the state by colour: green when on, grey when off
/// (the system switch follows the accent colour, which can look the same either way).
struct StateSwitchStyle: ToggleStyle {
    static let onColor = Theme.success
    static let offColor = Color(nsColor: .systemGray).opacity(0.45)

    func makeBody(configuration: Configuration) -> some View {
        ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule()
                .fill(configuration.isOn ? Self.onColor : Self.offColor)
                .frame(width: 36, height: 20)
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                .frame(width: 16, height: 16)
                .padding(2)
        }
        .frame(width: 36, height: 20)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? L10n.text("开") : L10n.text("关"))
        .accessibilityAction { configuration.isOn.toggle() }
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
            Text(text).font(.system(size: 12)).foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action = action, let perform = perform {
                Button(action, action: perform).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.window.opacity(0.7)))
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
            Text(title).font(.system(size: 13.5, weight: .medium))
            Spacer()
            if granted {
                Text(L10n.text("已允许")).font(.system(size: 12)).foregroundColor(Theme.secondary)
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
    @State private var recording = false
    @State private var monitor: Any?

    private var binding: HotKeyBinding { model.settings[keyPath: slot.keyPath] }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stop() : start()
            } label: {
                HStack(spacing: 4) {
                    if recording {
                        Text(L10n.text("按下新快捷键…")).font(.system(size: 12)).foregroundColor(Theme.accent)
                            .padding(.horizontal, 8).frame(minHeight: 24)
                    } else if !binding.enabled {
                        Text(L10n.text("未设置")).font(.system(size: 12)).foregroundColor(Theme.tertiary)
                            .padding(.horizontal, 8).frame(minHeight: 24)
                    } else {
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in Keycap(label: label) }
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9).stroke(recording ? Theme.accent : Color.clear, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .help(L10n.text("Esc 取消，Delete 清除。"))
            if let problem = model.hotkeyProblems[slot.name], !recording {
                Text(problem).font(.system(size: 11.5)).foregroundColor(Theme.warning)
            }
        }
        .onDisappear { stop() }
    }

    private var labels: [String] {
        if binding.isFn { return ["fn"] }
        var out: [String] = []
        if binding.modifiers & 4096 != 0 { out.append("⌃") }
        if binding.modifiers & 2048 != 0 { out.append("⌥") }
        if binding.modifiers & 512 != 0 { out.append("⇧") }
        if binding.modifiers & 256 != 0 { out.append("⌘") }
        out.append(HotKeyCentre.keyName(binding.keyCode).lowercased() == "space" ? "space" : HotKeyCentre.keyName(binding.keyCode))
        return out
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                // Fn alone is a dictation key only; 翻译 needs a real shortcut.
                if event.keyCode == FnKeyMonitor.keyCode, !event.modifierFlags.contains(.function), slot != .translate && slot != .assistant {
                    save(HotKeyBinding.fnDefault)
                }
                return event
            }
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

    private func save(_ value: HotKeyBinding) {
        model.settings[keyPath: slot.keyPath] = value
        model.actions?.registerHotKeys()
        model.objectWillChange.send()
        stop()
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}


// MARK: - cleanup model (the user's own API key)

/// Any OpenAI-compatible service with the user's own key (stored in the Keychain).
struct ModelSection: View {
    @EnvironmentObject var model: AppModel
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var models: [String] = []
    @State private var status = ""
    @State private var statusOK = true
    @State private var busy = false

    private var settings: Settings { model.settings }
    private var preset: LLMPreset { LLMPreset.find(settings.llmPresetID) }

    var body: some View {
        SettingsSection(title: L10n.text("整理模型")) {
                SettingRow(title: L10n.text("服务商"), detail: preset.keyPage.isEmpty ? nil : L10n.text("在这里创建 Key：") + preset.keyPage) {
                    Picker("", selection: Binding(get: { settings.llmPresetID }, set: { id in
                        settings.llmPresetID = id
                        reloadForPreset()
                    })) {
                        ForEach(LLMPreset.all) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                SettingRow(title: L10n.text("接口地址"), detail: LLMPreset.isAllowedBaseURL(settings.llmBaseURL) ? nil : L10n.text("需要 https（本机可用 http://127.0.0.1）")) {
                    TextField("https://…/v1", text: model.setting(\.llmBaseURL))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                if preset.needsKey {
                    SettingRow(title: "API Key", detail: keySaved ? L10n.text("已存入钥匙串") : (keyDraft.isEmpty ? L10n.text("粘贴 Key，再保存或测试。") : L10n.text("未保存。请点「保存」或测试"))) {
                        HStack(spacing: 8) {
                            SecureField("sk-…", text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            // An emptied field with a saved key deletes it from the Keychain.
                            Button(keyDraft.isEmpty && keySaved ? L10n.text("删除") : L10n.text("保存")) { saveKey() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(keyDraft.isEmpty && !keySaved)
                        }
                    }
                }
                SettingRow(title: L10n.text("模型"), detail: models.isEmpty ? L10n.text("填模型 ID，或点「获取列表」") : L10n.text("共 {0} 个", models.count)) {
                    HStack(spacing: 8) {
                        TextField(preset.modelHint, text: model.setting(\.llmModel))
                            .textFieldStyle(.roundedBorder)
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
                            .disabled(busy)
                    }
                }
                HStack(spacing: 10) {
                    Button(busy ? L10n.text("测试中…") : L10n.text("测试连接")) { test() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(busy || draftRoute() == nil)
                    if !status.isEmpty {
                        Text(status).font(.system(size: 12)).foregroundColor(statusOK ? Theme.success : Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                if !settings.llmRouteReady {
                    Text(missingParts() + L10n.text("。可以听写，但不整理。"))
                        .font(.system(size: 11.5)).foregroundColor(Theme.warning)
                }
        }
        .onAppear { reloadForPreset() }
    }

    private func reloadForPreset() {
        let stored = settings.llmAPIKey
        keyDraft = stored
        keySaved = !stored.isEmpty
        models = []
        status = ""
        model.objectWillChange.send()
    }

    /// The route as currently typed, with the key from the field (saved or not).
    private func draftRoute() -> LLMRoute? {
        let base = settings.llmBaseURL
        guard LLMPreset.isAllowedBaseURL(base), !settings.llmModel.isEmpty else { return nil }
        let key = keyDraft.isEmpty ? settings.llmAPIKey : keyDraft
        if preset.needsKey && key.isEmpty { return nil }
        return LLMRoute(baseURL: base, model: settings.llmModel, apiKey: key)
    }

    private func fetchModels() {
        let base = settings.llmBaseURL
        guard LLMPreset.isAllowedBaseURL(base) else { status = L10n.text("接口地址错误"); statusOK = false; return }
        let route = LLMRoute(baseURL: base, model: "", apiKey: keyDraft.isEmpty ? settings.llmAPIKey : keyDraft)
        busy = true
        status = L10n.text("正在获取…")
        statusOK = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ServiceClient.shared.listModelsSync(route: route) }
            DispatchQueue.main.async {
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
        if preset.needsKey && settings.llmAPIKey.isEmpty {
            missing.append(keyDraft.isEmpty ? L10n.text("没有 Key") : L10n.text("Key 未保存，请点「保存」"))
        }
        if settings.llmModel.isEmpty { missing.append(L10n.text("没有模型")) }
        return missing.isEmpty ? L10n.text("设置未完成") : missing.joined(separator: "、")
    }

    /// Store the key; say so honestly when the Keychain refuses.
    @discardableResult
    private func saveKey(quiet: Bool = false) -> Bool {
        let ok = KeychainStore.write(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines), account: settings.llmPresetID)
        keySaved = ok && !keyDraft.isEmpty
        if !ok {
            status = L10n.text("Key 无法存入钥匙串（错误码 ") + String(KeychainStore.lastStatus) + "）"
            statusOK = false
            DiagnosticsLog.write("keychain.write.fail", ["status": String(KeychainStore.lastStatus)])
        } else if !quiet {
            status = keyDraft.isEmpty ? L10n.text("Key 已删除") : L10n.text("Key 已保存")
            statusOK = true
        }
        settings.notifyChanged()
        model.objectWillChange.send()
        return ok
    }

    private func test() {
        guard let route = draftRoute() else { return }
        busy = true
        status = L10n.text("正在测试…")
        statusOK = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ServiceClient.shared.testLLMSync(route: route) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let answer) where answer.ok:
                    let saved = keyDraft.isEmpty || keyDraft == settings.llmAPIKey || saveKey(quiet: true)
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

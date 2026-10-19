import SwiftUI
import AppKit
import ServiceManagement

// HubSettings.swift - the Settings page: Keyboard shortcuts, Cleanup, Language, Audio,
// Insertion, General, Privacy, Permissions and Service, in Reference's section style.

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var meter = MicMeter()
    @State private var devices: [AudioInputDevice] = []
    @State private var loginError = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: L10n.text("设置"))
                VStack(alignment: .leading, spacing: 26) {
                    shortcuts
                    ModelSection()
                    cleanup
                    PromptifySection()
                    language
                    audio
                    insertion
                    general
                    privacy
                    permissions
                    service
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            // Opening Settings must never open the microphone: the meter starts only
            // from the "测试麦克风" button below.
            devices = AudioDevices.inputs()
            model.refreshPermissions()
        }
        .onDisappear { meter.stop() }
    }

    // MARK: sections

    private var shortcuts: some View {
        SettingsSection(title: L10n.text("快捷键")) {
            SettingRow(title: L10n.text("听写"), detail: L10n.text("按一下开始说话，再按一下结束并整理")) {
                HStack(spacing: 8) {
                    HotkeyField(slot: .main)
                    HotkeyField(slot: .alt)
                }
            }
            SettingRow(title: L10n.text("粘贴上一条转写"), detail: L10n.text("文字没粘进去时，用它再贴一次")) {
                HotkeyField(slot: .pasteLast)
            }
            SettingRow(title: L10n.text("取消听写"), detail: L10n.text("录音时按 Esc，或点语音条上的 ✕")) {
                Keycap(label: "esc")
            }
            if model.settings.hotkeyMain.isFn || model.settings.hotkeyAlt.isFn {
                NoteRow(symbol: "globe",
                        text: L10n.text("使用 Fn 需要辅助功能权限；并在「系统设置 › 键盘」里把「按下 🌐 键时」设为「无操作」，否则按 Fn 会同时弹出表情或切换输入法。"),
                        action: L10n.text("打开键盘设置")) { model.actions?.openKeyboardSettings() }
            }
        }
    }

    private var cleanup: some View {
        SettingsSection(title: L10n.text("整理")) {
            VStack(spacing: 8) {
                ForEach(VoiceStrength.allCases, id: \.self) { strength in
                    StrengthOption(strength: strength,
                                   selected: model.settings.strength == strength.rawValue) {
                        model.setting(\.strength).wrappedValue = strength.rawValue
                    }
                }
            }
            .padding(.vertical, 4)
            ToggleRow(title: L10n.text("参考输入框里的内容"), detail: L10n.text("听写开始时读取光标附近的文字，用来纠正同音字、人名和术语。密码框和密码管理器不会读取。"),
                      isOn: model.setting(\.readFieldContext))
            ToggleRow(title: L10n.text("自动学习我的更正"), detail: L10n.text("听写后你改过的词，会作为「自动添加」放进词典。"),
                      isOn: model.setting(\.autoLearn))
            ToggleRow(title: L10n.text("列表粘贴为真正的列表"), detail: L10n.text("整理结果里有 1. 2. 3. 编号时，在备忘录、邮件、Pages、Word 里粘贴成带格式的列表。"),
                      isOn: model.setting(\.richTextLists))
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
            SettingRow(title: L10n.text("界面语言"), detail: L10n.text("重启应用后生效；不会改变听写或输出语言。")) {
                Picker("", selection: model.setting(\.interfaceLanguage)) {
                    Text(L10n.text("跟随系统")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }.labelsHidden().frame(width: 150)
            }
            SettingRow(title: L10n.text("听写语言"), detail: model.speech?.canSetLanguage == false ? L10n.text("当前模型自动检测语言，不能强制指定。") : L10n.text("可选择当前模型支持的语言；不支持的语言设置使用自动识别。")) {
                Picker("", selection: dictationLanguage) {
                    ForEach(VoiceLanguage.allCases, id: \.self) { Text($0.label).tag($0.rawValue).disabled(model.speech?.languages?.contains($0.rawValue) == false) }
                }
                .disabled(model.speech?.canSetLanguage == false)
                .labelsHidden()
                .frame(width: 150)
            }
        }
    }

    private var audio: some View {
        SettingsSection(title: L10n.text("音频")) {
            SettingRow(title: L10n.text("麦克风"), detail: meter.running
                       ? (meter.heardVoice ? L10n.text("听到你了（{0} 秒后自动关闭麦克风）", Int(MicMeter.maxSeconds)) : L10n.text("正在听…说句话，条变蓝就说明能收到声音"))
                       : L10n.text("点「测试麦克风」才会打开麦克风")) {
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
            ToggleRow(title: L10n.text("提示音"), detail: L10n.text("开始和结束听写时播放提示音"), isOn: model.setting(\.soundEnabled))
            ToggleRow(title: L10n.text("听写时静音其他声音"), detail: L10n.text("录音期间把正在播放的声音静音，结束后恢复"), isOn: model.setting(\.muteWhileDictating))
        }
    }

    private var insertion: some View {
        SettingsSection(title: L10n.text("插入")) {
            SettingRow(title: L10n.text("整理好的文字"), detail: nil) {
                Picker("", selection: model.setting(\.insertionMode)) {
                    ForEach(InsertionMode.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 190)
            }
            ToggleRow(title: L10n.text("粘贴后恢复剪贴板"), detail: L10n.text("粘贴完把你原来复制的内容放回剪贴板"), isOn: model.setting(\.restoreClipboard))
        }
    }

    private var general: some View {
        SettingsSection(title: L10n.text("通用")) {
            SettingRow(title: L10n.text("外观"), detail: nil) {
                Picker("", selection: model.setting(\.appearance, then: { model.actions?.applyGeneralSettings() })) {
                    ForEach(AppearancePreference.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            ToggleRow(title: L10n.text("开机时启动"), detail: loginError.isEmpty ? L10n.text("登录后自动在后台运行") : loginError,
                      isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { setLogin($0) }))
            ToggleRow(title: L10n.text("在 Dock 中显示"), detail: L10n.text("关闭后只在菜单栏显示图标"),
                      isOn: model.setting(\.showInDock, then: { model.actions?.applyGeneralSettings() }))
            ToggleRow(title: L10n.text("在桌面显示语音条"), detail: L10n.text("屏幕底部常驻一个小语音条，点它也能开始听写"),
                      isOn: model.setting(\.showIdleBar, then: { model.actions?.applyGeneralSettings() }))
            SettingRow(title: L10n.text("新手引导"), detail: L10n.text("重新走一遍权限和麦克风设置")) {
                Button(L10n.text("打开")) { model.actions?.showOnboarding() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var privacy: some View {
        SettingsSection(title: L10n.text("隐私与数据")) {
            SettingRow(title: L10n.text("保留历史"), detail: L10n.text("历史只保存在这台电脑上")) {
                Picker("", selection: model.setting(\.historyRetention, then: {
                    HistoryStore.shared.applyRetention(Settings.shared.historyRetention)
                })) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            ToggleRow(title: L10n.text("保留录音 24 小时"), detail: L10n.text("可以在历史里用同一段录音重试；24 小时后自动删除"),
                      isOn: model.setting(\.keepAudio24h))
            NoteRow(symbol: "lock", text: L10n.text("录音只在本机转写，不会上传。发给整理模型服务商的只有文字，并且会先抹掉密码和密钥。"), action: nil, perform: nil)
        }
    }

    private var permissions: some View {
        SettingsSection(title: L10n.text("权限")) {
            PermissionRow(title: L10n.text("麦克风"), granted: model.micStatus == .authorized,
                          action: model.micStatus == .notDetermined ? L10n.text("允许") : L10n.text("打开设置")) {
                if model.micStatus == .notDetermined { model.actions?.requestMicrophone() } else { model.actions?.openMicrophoneSettings() }
            }
            PermissionRow(title: L10n.text("辅助功能（自动粘贴、Fn 键）"), granted: model.accessibilityTrusted, action: L10n.text("授权")) {
                model.actions?.requestAccessibility()
            }
        }
    }

    private var service: some View {
        SettingsSection(title: L10n.text("本地服务")) {
            SettingRow(title: model.serviceSummary,
                       detail: model.nodeDescription.isEmpty ? L10n.text("识别和整理都由本机的 TypeLeast 服务完成，它需要 Node.js 22 或更新版本") : "Node.js " + model.nodeDescription) {
                HStack(spacing: 8) {
                    if model.serviceState.needsNode {
                        Button(L10n.text("下载 Node.js")) { NSWorkspace.shared.open(URL(string: "https://nodejs.org/zh-cn/download")!) }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    Button(L10n.text("选择 Node.js…")) { model.actions?.chooseNode() }.buttonStyle(SecondaryButtonStyle())
                    Button(L10n.text("重新启动")) { model.actions?.restartService() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            SpeechModelOptions()
            SettingRow(title: L10n.text("模型下载镜像（可选）"),
                       detail: L10n.text("huggingface.co 下载慢或打不开时，填一个镜像地址，例如 https://hf-mirror.com。每个文件都会校验 SHA-256，镜像改不了内容。")) {
                TextField("https://huggingface.co", text: model.setting(\.modelMirror))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
            SettingRow(title: L10n.text("版本与更新"), detail: L10n.text("当前版本 ") + Updater.currentVersion + L10n.text("。点「检查更新」，有新版本时一键更新，权限不需要重新授予。")) {
                Button(L10n.text("检查更新")) { model.actions?.checkForUpdates(interactive: true) }.buttonStyle(SecondaryButtonStyle())
            }
            if let version = model.health?.version {
                Text(L10n.text("服务版本 ") + version + " · App " + Updater.currentVersion).font(.system(size: 11)).foregroundColor(Theme.tertiary)
            }
        }
    }

    private var speechDetail: String {
        let problem = AppDelegate.speechProblem(model.speech)
        return problem.isEmpty ? L10n.text("已就绪，识别完全在本机进行，音频不出这台 Mac") : problem
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            model.settings.launchAtLogin = on
            loginError = ""
        } catch {
            loginError = L10n.text("无法修改：") + error.localizedDescription
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
            if let detail = detail {
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
                Text(L10n.text("已授权")).font(.system(size: 12)).foregroundColor(Theme.secondary)
            } else {
                Button(action, action: perform).buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

private struct StrengthOption: View {
    let strength: VoiceStrength
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundColor(selected ? Theme.ink : Theme.tertiary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(strength.label).font(.system(size: 13.5, weight: .semibold))
                        if strength == .prompt { Badge(text: L10n.text("推荐")) }
                    }
                    Text(strength.detail).font(.system(size: 12)).foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.window : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Theme.ink.opacity(0.85) : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - shortcut recorder

enum HotkeySlot {
    case main, alt, pasteLast

    var keyPath: ReferenceWritableKeyPath<Settings, HotKeyBinding> {
        switch self {
        case .main: return \.hotkeyMain
        case .alt: return \.hotkeyAlt
        case .pasteLast: return \.hotkeyPasteLast
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
                        Text(L10n.text("按下新的快捷键…")).font(.system(size: 12)).foregroundColor(Theme.accent)
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
            .help(L10n.text("点击后按下新的快捷键；Esc 取消；Delete 清除"))
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
                if event.keyCode == FnKeyMonitor.keyCode, !event.modifierFlags.contains(.function) {
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
            Text(L10n.text("用你自己的 API Key 调用大模型，把识别出的话整理成通顺的书面语。Key 只存在这台 Mac 的钥匙串里，只发给本机的 TypeLeast 服务。"))
                .font(.system(size: 12)).foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                SettingRow(title: L10n.text("服务商"), detail: preset.keyPage.isEmpty ? nil : L10n.text("Key 在这里创建：") + preset.keyPage) {
                    Picker("", selection: Binding(get: { settings.llmPresetID }, set: { id in
                        settings.llmPresetID = id
                        reloadForPreset()
                    })) {
                        ForEach(LLMPreset.all) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                SettingRow(title: L10n.text("接口地址"), detail: LLMPreset.isAllowedBaseURL(settings.llmBaseURL) ? nil : L10n.text("需要 https 地址（本机服务可以用 http://127.0.0.1）")) {
                    TextField("https://…/v1", text: model.setting(\.llmBaseURL))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                if preset.needsKey {
                    SettingRow(title: "API Key", detail: keySaved ? L10n.text("已保存在钥匙串") : (keyDraft.isEmpty ? L10n.text("粘贴 Key，再点保存或测试连接") : L10n.text("还没保存：点保存，或测试连接成功后自动保存"))) {
                        HStack(spacing: 8) {
                            SecureField("sk-…", text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            Button(L10n.text("保存")) { saveKey() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(keyDraft.isEmpty)
                        }
                    }
                }
                SettingRow(title: L10n.text("模型"), detail: models.isEmpty ? L10n.text("填模型 ID，或者点「获取列表」") : L10n.text("共 {0} 个可选", models.count)) {
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
                if settings.activeLLMRoute == nil {
                    Text(missingParts() + L10n.text("。在此之前听写照常可用：只去掉口水词，不改写。"))
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
        guard LLMPreset.isAllowedBaseURL(base) else { status = L10n.text("接口地址不对"); statusOK = false; return }
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
                    status = L10n.text("获取到 {0} 个模型", ids.count)
                    statusOK = true
                case .success:
                    status = L10n.text("这个服务没有提供模型列表，请手动填模型 ID")
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
        if !LLMPreset.isAllowedBaseURL(settings.llmBaseURL) { missing.append(L10n.text("接口地址不对")) }
        if preset.needsKey && settings.llmAPIKey.isEmpty {
            missing.append(keyDraft.isEmpty ? L10n.text("还没填 Key") : L10n.text("Key 还没保存（点「保存」）"))
        }
        if settings.llmModel.isEmpty { missing.append(L10n.text("还没填模型")) }
        return missing.isEmpty ? L10n.text("还没配置完成") : missing.joined(separator: "、")
    }

    /// Store the key; say so honestly when the Keychain refuses.
    @discardableResult
    private func saveKey(quiet: Bool = false) -> Bool {
        let ok = KeychainStore.write(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines), account: settings.llmPresetID)
        keySaved = ok && !keyDraft.isEmpty
        if !ok {
            status = L10n.text("Key 没能存进钥匙串（错误码 ") + String(KeychainStore.lastStatus) + "）"
            statusOK = false
            DiagnosticsLog.write("keychain.write.fail", ["status": String(KeychainStore.lastStatus)])
        } else if !quiet {
            status = keyDraft.isEmpty ? L10n.text("已删除 Key") : L10n.text("Key 已保存")
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
                    status = L10n.text("连接成功，用时 ") + String(Int(answer.ms ?? 0)) + L10n.text(" 毫秒") + (saved ? L10n.text("，Key 已保存") : L10n.text("，但 Key 没能存进钥匙串"))
                        + (thinks ? L10n.text("。这个模型会先思考再回答，整理会慢一些") : "")
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
                        ? L10n.text("本地服务还没就绪（测试要经过它）。等首页显示就绪后再点一次")
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
        case "HTTP_400": return L10n.text("服务商拒绝了请求：多半是模型 ID 不对（HTTP 400）。点「获取列表」选一个")
        case "HTTP_404": return L10n.text("地址或模型 ID 不对（HTTP 404）")
        case "NETWORK": return L10n.text("连不上服务商：") + (message ?? "") + L10n.text("。请检查网络或代理")
        case "HTTP_500", "HTTP_502", "HTTP_503", "HTTP_504": return L10n.text("服务商那边暂时出错（{0}），稍后再试", code ?? "")
        case "HTTP_402": return L10n.text("账户余额不足（HTTP 402）")
        case "HTTP_429": return L10n.text("请求太频繁或额度用完（HTTP 429）")
        case "invalid-route": return L10n.text("地址、Key 或模型没填对")
        case "timeout": return L10n.text("超时没有回应")
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

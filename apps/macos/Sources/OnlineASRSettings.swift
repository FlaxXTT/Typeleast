import SwiftUI

extension OnlineASRProvider {
    var label: String {
        switch self {
        case .local: return L10n.text("本地模型")
        case .doubao: return L10n.text("豆包 ASR 2.0")
        case .funASR: return L10n.text("阿里云 Fun-ASR Realtime")
        }
    }

    var keychainAccount: String { "asr." + rawValue }

    var recordingPrivacyText: String {
        self == .local ? L10n.text("录音在本机识别。") : L10n.text("录音发往 {0}。", label)
    }
}

struct OnlineASRSettings: View {
    var dictationOnly = false
    @EnvironmentObject private var model: AppModel
    @State private var showsVocabularyTables = false

    private var cloudProviders: [OnlineASRProvider] {
        let dictation = model.settings.onlineASRProvider
        if dictationOnly { return dictation == .local ? [] : [dictation] }
        let meeting = model.settings.meetingASRProvider
        return (dictation == meeting ? [dictation] : [dictation, meeting]).filter { $0 != .local }
    }

    var body: some View {
        SettingsSection(title: L10n.text("语音识别来源"), tiltOnHover: true) {
            SettingRow(title: L10n.text("听写模型"),
                       detail: dictationUploadDetail) {
                ASRProviderPicker(selection: model.setting(\.onlineASRProvider))
            }
            if !dictationOnly {
                SettingRow(title: L10n.text("会议模型"),
                           detail: model.settings.meetingASRProvider == .local ? nil : L10n.text("录音结束或导入后上传，可能按用量计费。")) {
                    ASRProviderPicker(selection: model.setting(\.meetingASRProvider), localLabel: "MOSS · " + L10n.text("本地"),
                                      doubaoLabel: DoubaoMeetingASR.modelName)
                }
            }
            ForEach(cloudProviders, id: \.self) { provider in
                OnlineASRCredentials(provider: provider)
                if provider == .doubao && !dictationOnly {
                    ToggleRow(title: L10n.text("豆包语义顺滑"),
                              detail: L10n.text("在识别时去除中文和英文的语气词与重复。"),
                              isOn: model.setting(\.doubaoSpeechSmoothing))
                    Button(L10n.text("管理词表")) {
                        model.settingsPresented = false
                        model.navigate(to: .vocabulary)
                    }
                    .buttonStyle(FlatActionButtonStyle())
                    .foregroundStyle(Theme.accent)
                    DisclosureGroup(L10n.text("豆包控制台词表"), isExpanded: $showsVocabularyTables) {
                        vocabularyTable(L10n.text("热词表 ID"), consolePath: "hotword",
                                        value: model.setting(\.doubaoHotwordTableID))
                        vocabularyTable(L10n.text("替换词表 ID"), consolePath: "correctword",
                                        value: model.setting(\.doubaoReplacementTableID))
                    }
                }
            }
        }
    }

    private func vocabularyTable(_ title: String, consolePath: String, value: Binding<String>) -> some View {
        SettingRow(title: title, detail: nil) {
            HStack(spacing: 8) {
                Link(destination: URL(string: "https://console.volcengine.com/speech/" + consolePath)!) {
                    Image(systemName: "arrow.up.right.square").accessibilityLabel(L10n.text("打开豆包控制台"))
                }
                TextField(title, text: value)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 225)
            }
        }
    }

    private var dictationUploadDetail: String? {
        switch model.settings.onlineASRProvider {
        case .local: return nil
        case .doubao: return L10n.text("录音时上传，结束后返回最终转写。可能按用量计费。")
        case .funASR: return L10n.text("录音结束后上传，可能按用量计费。")
        }
    }
}

struct ASRProviderPicker: View {
    @Binding var selection: OnlineASRProvider
    var localLabel: String? = nil
    var doubaoLabel: String? = nil

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(OnlineASRProvider.allCases, id: \.self) { option in
                Text(label(for: option)).tag(option)
            }
        }
        .labelsHidden()
        .frame(width: doubaoLabel == nil ? 225 : 285)
        .hoverFeedback(.fixed)
    }

    private func label(for option: OnlineASRProvider) -> String {
        switch option {
        case .local: return localLabel ?? option.label
        case .doubao: return doubaoLabel ?? option.label
        case .funASR: return option.label
        }
    }
}

private struct OnlineASRCredentials: View {
    @EnvironmentObject private var model: AppModel
    let provider: OnlineASRProvider
    @State private var apiKey = ""
    @State private var workspaceID = ""
    @State private var saveMessage = ""
    @State private var connectionTest: Task<Void, Never>?
    @State private var testMessage = ""
    @State private var testFailed = false

    private var keyDraft: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var workspaceDraft: String { workspaceID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var workspaceChanged: Bool {
        provider == .funASR && workspaceDraft != model.settings.funASRWorkspaceID
    }
    private var canTest: Bool {
        !model.credentialsLocked && (!keyDraft.isEmpty || model.asrKeyPresence(for: provider) == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            SettingRow(title: provider.label + " · API Key",
                       detail: model.asrKeyPresence(for: provider) == true ? L10n.text("已保存在本机钥匙串") : nil) {
                SecureField(model.credentialsLocked ? L10n.text("钥匙串已锁定") : "API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 225)
                    .disabled(model.credentialsLocked)
            }
            if provider == .funASR {
                SettingRow(title: L10n.text("百炼业务空间 ID"), detail: L10n.text("北京默认业务空间可留空。")) {
                    TextField("Workspace ID", text: $workspaceID)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 225)
                }
            }
            HStack {
                if !testMessage.isEmpty {
                    Text(testMessage).font(Theme.captionFont)
                        .foregroundColor(testFailed ? Theme.warning : Theme.secondary)
                } else if !saveMessage.isEmpty {
                    Text(saveMessage).font(Theme.captionFont).foregroundColor(Theme.secondary)
                }
                Spacer()
                Button(L10n.text(connectionTest == nil ? "测试连接" : "测试中…")) { test() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!canTest || connectionTest != nil)
                Button(L10n.text("保存")) { save() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.credentialsLocked || (keyDraft.isEmpty && !workspaceChanged))
            }
        }
        .onChange(of: provider, initial: true) { _, _ in
            clearTest()
            apiKey = ""
            workspaceID = model.settings.funASRWorkspaceID
            saveMessage = ""
            model.refreshOnlineASRKeyPresence()
        }
        .onChange(of: keyDraft) { _, _ in clearTest() }
        .onChange(of: workspaceDraft) { _, _ in clearTest() }
        .onChange(of: model.credentialsLocked) { _, locked in
            if locked { clearTest() }
        }
        .onDisappear { clearTest() }
    }

    private func test() {
        let provider = provider
        let key = keyDraft
        let workspace = workspaceDraft
        let tables = model.settings.doubaoVocabularyTables
        saveMessage = ""
        testMessage = ""
        testFailed = false
        connectionTest = Task { @MainActor in
            let probe = Task.detached(priority: .userInitiated) {
                let credential = key.isEmpty ? (KeychainStore.read(account: provider.keychainAccount) ?? "") : key
                try Task.checkCancellation()
                return try await OnlineASR.testConnection(configuration: OnlineASRConfiguration(
                    provider: provider, apiKey: credential, workspaceID: workspace, doubaoTables: tables
                ))
            }
            do {
                let milliseconds = try await withTaskCancellationHandler {
                    try await probe.value
                } onCancel: { probe.cancel() }
                guard !Task.isCancelled else { return }
                testMessage = L10n.text("连接成功，用时 ") + String(milliseconds) + L10n.text(" 毫秒")
            } catch {
                guard !Task.isCancelled else { return }
                testMessage = error.localizedDescription
                testFailed = true
            }
            connectionTest = nil
        }
    }

    private func clearTest() {
        connectionTest?.cancel()
        connectionTest = nil
        testMessage = ""
        testFailed = false
    }

    private func save() {
        if !keyDraft.isEmpty, !KeychainStore.write(keyDraft, account: provider.keychainAccount) {
            saveMessage = L10n.text("无法将 API Key 保存到钥匙串。")
            return
        }
        if workspaceChanged { model.settings.funASRWorkspaceID = workspaceDraft }
        clearTest()
        apiKey = ""
        saveMessage = L10n.text("已保存")
        model.refreshOnlineASRKeyPresence()
    }
}

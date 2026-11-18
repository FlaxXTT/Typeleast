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
    @EnvironmentObject private var model: AppModel
    @State private var apiKey = ""
    @State private var workspaceID = ""
    @State private var saveMessage = ""

    private var provider: OnlineASRProvider { model.settings.onlineASRProvider }
    private var keyDraft: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var workspaceDraft: String { workspaceID.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var workspaceChanged: Bool {
        provider == .funASR && workspaceDraft != model.settings.funASRWorkspaceID
    }

    var body: some View {
        SettingsSection(title: L10n.text("语音识别来源")) {
            SettingRow(title: L10n.text("听写模型"),
                       detail: L10n.text("选用联网模型后，听写录音会在结束时发送给所选服务商，并按其规则计费。")) {
                Picker("", selection: model.setting(\.onlineASRProvider)) {
                    ForEach(OnlineASRProvider.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 225)
            }
            if provider != .local {
                SettingRow(title: "API Key",
                           detail: model.onlineASRKeyPresence == true ? L10n.text("已保存在本机钥匙串") : nil) {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 225)
                }
                if provider == .funASR {
                    SettingRow(title: L10n.text("百炼业务空间 ID"), detail: L10n.text("北京默认业务空间可留空。")) {
                        TextField("Workspace ID", text: $workspaceID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 225)
                    }
                }
                HStack {
                    if !saveMessage.isEmpty {
                        Text(saveMessage).font(Theme.captionFont).foregroundColor(Theme.secondary)
                    }
                    Spacer()
                    Button(L10n.text("保存")) { save() }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(keyDraft.isEmpty && !workspaceChanged)
                }
            }
        }
        .onChange(of: provider, initial: true) { _, _ in
            apiKey = ""
            workspaceID = model.settings.funASRWorkspaceID
            saveMessage = ""
            model.refreshOnlineASRKeyPresence()
        }
    }

    private func save() {
        if !keyDraft.isEmpty, !KeychainStore.write(keyDraft, account: provider.keychainAccount) {
            saveMessage = L10n.text("无法将 API Key 保存到钥匙串。")
            return
        }
        if workspaceChanged { model.settings.funASRWorkspaceID = workspaceDraft }
        apiKey = ""
        saveMessage = L10n.text("已保存")
        model.refreshOnlineASRKeyPresence()
    }
}

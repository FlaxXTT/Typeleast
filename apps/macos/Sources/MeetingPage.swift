import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MeetingPage.swift - the Meetings page: record or import, wait, copy or save.

struct MeetingsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Conference")
            VStack(alignment: .leading, spacing: 14) {
                MeetingControls()
                if model.settings.meetingASRProvider == .local && meeting.modelInstalled == false { MeetingModelCard() }
                if let transcript = meeting.transcript {
                    MeetingTranscriptView(result: transcript.result, seconds: transcript.seconds, elapsed: transcript.elapsed)
                        .id(transcript.id)
                } else if meeting.usesLivePreview &&
                            (meeting.stage == .recording ||
                             ([.transcribing, .failed].contains(meeting.stage) && (!meeting.liveTranscript.isEmpty || meeting.liveWarning))) {
                    MeetingLiveTranscriptView()
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, Theme.pageInset)
            .padding(.bottom, 24)
        }
        .onChange(of: model.settings.meetingASRProvider, initial: true) { _, provider in
            if provider == .local { meeting.refreshModel() }
        }
    }
}

private struct MeetingLiveTranscriptView: View {
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("实时文字"))
                .font(InterfaceTypography.localized(14, weight: .medium))
            if meeting.liveWarning {
                Text(L10n.text("实时转写不完整，录音结束后会重新转写。"))
                    .font(InterfaceTypography.localized(12)).foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if meeting.liveTranscript.isEmpty {
                Text(L10n.text("等待实时文字…"))
                    .font(InterfaceTypography.localized(14)).foregroundColor(Theme.secondary)
                Spacer()
            } else {
                HubScrollView(showsChrome: false, followsBottom: true) {
                    Text(meeting.liveTranscript)
                        .font(InterfaceTypography.localized(14)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct MeetingModelCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        Card(padding: 24) {
            HStack(spacing: 12) {
                Text("MOSS · 0.65 GB").font(InterfaceTypography.localized(14))
                Spacer()
                if let download = meeting.download {
                    Text(L10n.text("正在下载 {0}%", download.total > 0 ? Int(Double(download.received) * 100 / Double(download.total)) : 0))
                        .font(InterfaceTypography.localized(14)).foregroundColor(Theme.secondary)
                } else {
                    Button(L10n.text("下载模型")) { meeting.downloadModel(mirror: model.settings.modelMirror) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }
}

enum DoubaoMeetingSetup: Equatable {
    case locked, missingKey, missingStorage, configured

    init(locked: Bool, hasKey: Bool, hasStorage: Bool) {
        if locked { self = .locked }
        else if !hasKey { self = .missingKey }
        else if !hasStorage { self = .missingStorage }
        else { self = .configured }
    }

    var guidance: String? {
        switch self {
        case .locked: return L10n.text("解锁钥匙串后可开始录音或导入。")
        case .missingKey: return L10n.text("保存豆包语音 API Key 后可继续配置会议转写。")
        case .missingStorage: return L10n.text("开始录音或导入前，请先配置私有 TOS 上传。")
        case .configured: return nil
        }
    }

    var actionTitle: String {
        switch self {
        case .locked: return L10n.text("解锁钥匙串")
        case .missingStorage: return L10n.text("配置音频上传")
        case .missingKey, .configured: return L10n.text("配置豆包会议转写")
        }
    }
}

private struct MeetingControls: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meeting: MeetingController

    @State private var configuringDoubao = false
    private var doubaoSetup: DoubaoMeetingSetup? {
        guard provider == .doubao else { return nil }
        return DoubaoMeetingSetup(locked: model.credentialsLocked, hasKey: !DoubaoMeetingASR.savedKey().isEmpty,
                                  hasStorage: DoubaoMeetingStorage.saved() != nil)
    }
    private var limit: Int { MeetingLimits.maxSeconds / 60 }
    private var provider: OnlineASRProvider { model.settings.meetingASRProvider }

    var body: some View {
        let setup = doubaoSetup
        let canStart = setup == nil || setup == .configured
        return Card(padding: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SettingRow(title: L10n.text("会议模型"),
                           detail: provider == .local ? nil : L10n.text("录音结束或导入后上传，可能按用量计费。")) {
                    ASRProviderPicker(selection: model.setting(\.meetingASRProvider), localLabel: "MOSS · " + L10n.text("本地"),
                                      doubaoLabel: DoubaoMeetingASR.modelName)
                        .disabled(meeting.busy)
                }
                if let setup {
                    HStack {
                        Button(setup.actionTitle) {
                            if setup == .locked { model.actions?.unlockCredentials() }
                            else { configuringDoubao = true }
                        }
                        .buttonStyle(FlatActionButtonStyle()).foregroundColor(Theme.accent)
                        Spacer()
                        if setup != .locked && setup != .missingKey { DoubaoMeetingConnection() }
                    }
                    .disabled(meeting.busy)
                } else if provider != .local {
                    Button(L10n.text("管理模型")) {
                        model.settingsCategory = .models
                        model.navigate(to: .settings)
                    }
                    .buttonStyle(FlatActionButtonStyle()).foregroundColor(Theme.accent)
                }
                Divider().padding(.vertical, 4)
                HStack(spacing: 10) {
                    switch meeting.stage {
                    case .recording:
                        Circle().fill(Color.red).frame(width: 8, height: 8).opacity(0.4 + Double(meeting.level) * 0.6)
                        Text(L10n.text("正在录音 {0} / {1}", MeetingFormat.clock(meeting.seconds), MeetingFormat.clock(Double(MeetingLimits.maxSeconds))))
                            .font(InterfaceTypography.localized(14, weight: .medium)).monospacedDigit()
                        Spacer()
                        Button(L10n.text("放弃")) { meeting.cancel() }.buttonStyle(SecondaryButtonStyle(feedback: .fixed))
                        Button(L10n.text("结束录音")) { meeting.stopRecording() }.buttonStyle(PrimaryButtonStyle(feedback: .fixed))
                    case .converting:
                        LoadingCircularProgress(size: 20, color: Theme.ink)
                        Text(L10n.text("正在读取音频…")).font(InterfaceTypography.localized(14, weight: .medium))
                        Spacer()
                        Button(L10n.text("取消转写")) { meeting.cancel() }.buttonStyle(SecondaryButtonStyle(feedback: .fixed))
                    case .transcribing:
                        LoadingCircularProgress(size: 20, color: Theme.ink)
                        Text(L10n.text("正在转写 {0} 的录音，已用 {1}", MeetingFormat.clock(meeting.seconds), MeetingFormat.clock(meeting.elapsed)))
                            .font(InterfaceTypography.localized(14, weight: .medium)).monospacedDigit()
                        Spacer()
                        Button(L10n.text("取消转写")) { meeting.cancel() }.buttonStyle(SecondaryButtonStyle(feedback: .fixed))
                    case .idle, .done, .failed:
                        if meeting.canRetry { Button(L10n.text("重试")) { meeting.retry() }.buttonStyle(SecondaryButtonStyle()).disabled(!canStart) }
                        Spacer()
                        Button(L10n.text("导入音频")) { chooseFile() }.buttonStyle(SecondaryButtonStyle()).disabled(!canStart)
                        Button(L10n.text("开始录音")) { meeting.startRecording(deviceUID: model.settings.inputDeviceUID) }
                            .buttonStyle(PrimaryButtonStyle(feedback: .magnetic)).disabled(!canStart)
                    }
                }
                if !meeting.message.isEmpty {
                    Text(meeting.message).font(InterfaceTypography.localized(14)).foregroundColor(Color.red)
                }
                if !meeting.busy {
                    if let guidance = setup?.guidance {
                        Label(guidance, systemImage: "info.circle")
                            .font(Theme.captionFont).foregroundStyle(Theme.secondary)
                    } else {
                        Text(L10n.text("仅录麦克风 · 最长 {0} 分钟", limit))
                            .font(Theme.captionFont).foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .task(id: provider == .doubao && !model.credentialsLocked) {
            if provider == .doubao && !model.credentialsLocked { meeting.checkDoubaoConnection() }
        }
        .sheet(isPresented: $configuringDoubao) {
            DoubaoMeetingSettings(storageFirst: setup == .missingStorage)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { meeting.importFile(url) }
    }
}

private struct DoubaoMeetingConnection: View {
    @EnvironmentObject private var meeting: MeetingController

    var body: some View {
        switch meeting.doubaoConnection {
        case .untested: EmptyView()
        case .testing: ProgressView().controlSize(.small).accessibilityLabel(L10n.text("测试连接"))
        case .connected:
            Label(L10n.text("API Key 已验证"), systemImage: "checkmark.circle").foregroundStyle(Theme.secondary)
        case .failed:
            Link(L10n.text("豆包接口验证失败 · 前往官网"), destination: DoubaoMeetingASR.activationURL)
                .foregroundStyle(Theme.accent)
        }
    }
}

private struct DoubaoMeetingSettings: View {
    let storageFirst: Bool
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var meeting: MeetingController
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var bucket = ""
    @State private var region = ""
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var message: String?

    private var key: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var storageDraft: DoubaoMeetingStorage {
        DoubaoMeetingStorage(bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                             region: region.trimmingCharacters(in: .whitespacesAndNewlines),
                             accessKey: accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
                             secretKey: secretKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(DoubaoMeetingASR.modelName).font(.headline)
            if model.credentialsLocked {
                Button(L10n.text("解锁钥匙串")) { model.actions?.unlockCredentials() }.buttonStyle(SecondaryButtonStyle())
            } else if storageFirst {
                storageControls
                Divider()
                keyControls
            } else {
                keyControls
                Divider()
                storageControls
            }
            if let message { Text(message).foregroundStyle(Theme.secondary) }
            HStack {
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(22).frame(width: 440)
        .task(id: model.credentialsLocked) {
            if !model.credentialsLocked { meeting.checkDoubaoConnection() }
        }
    }

    private var keyControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            let hasKey = !DoubaoMeetingASR.savedKey().isEmpty
            SecureField(hasKey ? L10n.text("豆包语音 API Key 已保存") : "API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("API Key")
            HStack {
                Button(L10n.text("保存")) {
                    guard KeychainStore.write(key, account: DoubaoMeetingASR.keyAccount) else {
                        message = L10n.text("无法保存到钥匙串。")
                        return
                    }
                    apiKey = ""
                    message = nil
                    meeting.checkDoubaoConnection(force: true)
                }.disabled(key.isEmpty)
                Button(L10n.text("测试连接")) { meeting.checkDoubaoConnection(force: true) }
                    .disabled(!hasKey || meeting.doubaoConnection == .testing)
                Spacer()
                DoubaoMeetingConnection()
            }
        }
    }

    private var storageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("会议录音 · 私有 TOS 桶")).font(.subheadline.weight(.semibold))
            Text(L10n.text("豆包通过限时链接读取录音。"))
                .font(Theme.captionFont).foregroundStyle(Theme.secondary)
            if let saved = DoubaoMeetingStorage.saved() {
                Text(saved.bucket + " · " + saved.region).foregroundStyle(Theme.secondary)
            }
            HStack {
                TextField(L10n.text("桶名"), text: $bucket)
                TextField(L10n.text("地域（如 cn-beijing）"), text: $region)
            }
            TextField("Access Key ID", text: $accessKey)
            SecureField("Secret Access Key", text: $secretKey)
            HStack {
                Link(L10n.text("打开 TOS 控制台"), destination: URL(string: "https://console.volcengine.com/tos")!)
                Spacer()
                Button(L10n.text("保存")) {
                    guard storageDraft.save() else { message = L10n.text("无法保存到钥匙串。"); return }
                    accessKey = ""
                    secretKey = ""
                    message = L10n.text("TOS 配置已保存。")
                }.disabled(!storageDraft.isValid)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}

struct MeetingTranscriptView: View {
    let result: MeetingResult
    let seconds: Double
    let elapsed: Double
    @State private var copyFeedback: UUID?

    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    private func color(_ speaker: String) -> Color {
        Self.palette[(result.speakers.firstIndex(of: speaker) ?? 0) % Self.palette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(result.speakers.isEmpty
                     ? L10n.text("{0} 的录音，用时 {1}", MeetingFormat.clock(seconds), MeetingFormat.clock(elapsed))
                     : L10n.text("{0} 位说话人 · {1} 的录音，用时 {2}", result.speakers.count, MeetingFormat.clock(seconds), MeetingFormat.clock(elapsed)))
                    .font(InterfaceTypography.localized(14, weight: .medium))
                Spacer()
                Button(L10n.text(copyFeedback == nil ? "复制" : "已复制")) {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(MeetingFormat.text(result), forType: .string) {
                        copyFeedback = UUID()
                    }
                }.buttonStyle(SecondaryButtonStyle()).disabled(result.segments.isEmpty)
                Button(L10n.text("保存")) { save() }.buttonStyle(SecondaryButtonStyle()).disabled(result.segments.isEmpty)
            }
            if result.truncated == true {
                Text(L10n.text("结果在中途被截断，后面的内容缺失。")).font(InterfaceTypography.localized(14)).foregroundColor(Color.red)
            }
            if result.segments.isEmpty {
                Text(L10n.text("未检测到语音")).font(InterfaceTypography.localized(14)).foregroundColor(Theme.secondary)
                Spacer()
            } else {
                HubScrollView(showsChrome: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(result.segments) { turn in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(MeetingFormat.clock(turn.start)).font(InterfaceTypography.localized(12)).monospacedDigit().foregroundColor(Theme.secondary).frame(width: 52, alignment: .leading)
                                if !result.speakers.isEmpty {
                                    Text(turn.speaker).font(InterfaceTypography.localized(12, weight: .semibold)).foregroundColor(color(turn.speaker)).frame(width: 34, alignment: .leading)
                                }
                                Text(turn.text).font(InterfaceTypography.localized(14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .resetCopyFeedback($copyFeedback)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "meeting.txt"
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "srt") ?? .plainText]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let content = url.pathExtension.lowercased() == "srt" ? MeetingFormat.srt(result) : MeetingFormat.text(result)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

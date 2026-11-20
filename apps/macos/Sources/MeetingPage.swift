import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MeetingPage.swift - the Meetings page: record or import, wait, copy or save.

struct MeetingsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Meetings")
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

private struct MeetingControls: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meeting: MeetingController

    private var limit: Int { MeetingLimits.maxSeconds / 60 }
    private var provider: OnlineASRProvider { model.settings.meetingASRProvider }

    var body: some View {
        Card(padding: 24) {
            VStack(alignment: .leading, spacing: 8) {
                SettingRow(title: L10n.text("会议模型"),
                           detail: provider == .local ? nil : L10n.text("录音结束或导入后上传，可能按用量计费。")) {
                    ASRProviderPicker(selection: model.setting(\.meetingASRProvider), localLabel: "MOSS · " + L10n.text("本地"))
                        .disabled(meeting.busy)
                }
                if provider != .local {
                    Button(L10n.text("管理模型")) {
                        model.settingsCategory = .models
                        model.navigate(to: .settings)
                    }
                    .buttonStyle(.link)
                }
                Divider().padding(.vertical, 4)
                HStack(spacing: 10) {
                    switch meeting.stage {
                    case .recording:
                        Circle().fill(Color.red).frame(width: 8, height: 8).opacity(0.4 + Double(meeting.level) * 0.6)
                        Text(L10n.text("正在录音 {0} / {1}", MeetingFormat.clock(meeting.seconds), MeetingFormat.clock(Double(MeetingLimits.maxSeconds))))
                            .font(InterfaceTypography.localized(14, weight: .medium)).monospacedDigit()
                        Spacer()
                        Button(L10n.text("放弃")) { meeting.cancel() }.buttonStyle(SecondaryButtonStyle())
                        Button(L10n.text("结束录音")) { meeting.stopRecording() }.buttonStyle(PrimaryButtonStyle())
                    case .converting:
                        LoadingCircularProgress(size: 20, color: Theme.ink)
                        Text(L10n.text("正在读取音频…")).font(InterfaceTypography.localized(14, weight: .medium))
                        Spacer()
                        Button(L10n.text("取消转写")) { meeting.cancel() }.buttonStyle(SecondaryButtonStyle())
                    case .transcribing:
                        LoadingCircularProgress(size: 20, color: Theme.ink)
                        Text(L10n.text("正在转写 {0} 的录音，已用 {1}", MeetingFormat.clock(meeting.seconds), MeetingFormat.clock(meeting.elapsed)))
                            .font(InterfaceTypography.localized(14, weight: .medium)).monospacedDigit()
                        Spacer()
                        Button(L10n.text("取消转写")) { meeting.cancel() }.buttonStyle(SecondaryButtonStyle())
                    case .idle, .done, .failed:
                        if meeting.canRetry { Button(L10n.text("重试")) { meeting.retry() }.buttonStyle(SecondaryButtonStyle()) }
                        Spacer()
                        Button(L10n.text("导入音频")) { chooseFile() }.buttonStyle(SecondaryButtonStyle())
                        Button(L10n.text("开始录音")) { meeting.startRecording(deviceUID: model.settings.inputDeviceUID) }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                if !meeting.message.isEmpty {
                    Text(meeting.message).font(InterfaceTypography.localized(14)).foregroundColor(Color.red)
                }
                if !meeting.busy {
                    Text(L10n.text("仅录麦克风 · 最长 {0} 分钟", limit))
                        .font(Theme.captionFont).foregroundColor(Theme.secondary)
                }
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { meeting.importFile(url) }
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

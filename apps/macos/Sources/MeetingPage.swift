import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MeetingPage.swift - the Meetings page: record or import, wait, copy or save.

struct MeetingsPage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: L10n.text("会议"), subtitle: L10n.text("录音时查看实时文字，结束后按说话人整理。"))
            VStack(alignment: .leading, spacing: 14) {
                if meeting.modelInstalled == false { MeetingModelCard() }
                MeetingControls()
                if let result = meeting.result {
                    MeetingTranscriptView(result: result)
                } else if meeting.stage == .recording ||
                            ([.transcribing, .failed].contains(meeting.stage) && (!meeting.liveTranscript.isEmpty || meeting.liveWarning)) {
                    MeetingLiveTranscriptView()
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
        }
        .onAppear { meeting.refreshModel() }
    }
}

private struct MeetingLiveTranscriptView: View {
    @EnvironmentObject var meeting: MeetingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("实时文字"))
                .font(.system(size: 13, weight: .medium))
            Text(L10n.text("这是临时结果，结束录音后会替换为按说话人整理的完整记录。"))
                .font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if meeting.liveWarning {
                Text(L10n.text("部分实时文字未能转写，结束后仍会尝试完整转写。"))
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if meeting.liveTranscript.isEmpty {
                Text(L10n.text("等待实时文字…"))
                    .font(.system(size: 13)).foregroundColor(Theme.secondary)
                Spacer()
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(meeting.liveTranscript)
                                .font(.system(size: 13.5)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                            Color.clear.frame(height: 1).id("meeting-live-end")
                        }
                    }
                    .onChange(of: meeting.liveTranscript) { _, _ in
                        scroll.scrollTo("meeting-live-end", anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct MeetingModelCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meeting: MeetingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 12) {
                Text(L10n.text("转写用 MOSS 模型，需要下载 0.65 GB。听写模型不变。")).font(.system(size: 13))
                Spacer()
                if let download = meeting.download {
                    Text(L10n.text("正在下载 {0}%", download.total > 0 ? Int(Double(download.received) * 100 / Double(download.total)) : 0))
                        .font(.system(size: 13)).foregroundColor(Theme.secondary)
                } else {
                    Button(L10n.text("下载模型")) { meeting.downloadModel(mirror: model.settings.modelMirror) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.accent.opacity(hovering ? 0.7 : 0), lineWidth: hovering ? 2 : 0)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct MeetingControls: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var meeting: MeetingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var limit: Int { MeetingLimits.maxSeconds / 60 }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    switch meeting.stage {
                    case .recording:
                        Circle().fill(Color.red).frame(width: 8, height: 8).opacity(0.4 + Double(meeting.level) * 0.6)
                        Text(L10n.text("正在录音 {0} / {1}", MeetingFormat.clock(meeting.seconds), MeetingFormat.clock(Double(MeetingLimits.maxSeconds))))
                            .font(.system(size: 13, weight: .medium)).monospacedDigit()
                        Spacer()
                        Button(L10n.text("放弃")) { meeting.cancel() }.buttonStyle(SecondaryButtonStyle())
                        Button(L10n.text("结束录音")) { meeting.stopRecording() }.buttonStyle(PrimaryButtonStyle())
                    case .converting:
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在读取音频…")).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button(L10n.text("取消转写")) { meeting.cancel() }.buttonStyle(SecondaryButtonStyle())
                    case .transcribing:
                        ProgressView().controlSize(.small)
                        Text(L10n.text("正在转写 {0} 的录音，已用 {1}", MeetingFormat.clock(meeting.seconds), MeetingFormat.clock(meeting.elapsed)))
                            .font(.system(size: 13, weight: .medium)).monospacedDigit()
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
                    Text(meeting.message).font(.system(size: 13)).foregroundColor(Color.red)
                }
                Text(meeting.stage == .transcribing ? L10n.text("可以关闭这个窗口，别退出 TypeLeast。听写不受影响。")
                     : L10n.text("只录麦克风。戴耳机开会时，对方的声音录不到，请导入会议软件的录音。上限 {0} 分钟，M5 Pro 上转完约需 5 分钟。", limit))
                    .font(.system(size: 11.5)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .stroke(Theme.accent.opacity(hovering ? 0.55 : 0), lineWidth: hovering ? 2 : 0)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { meeting.importFile(url) }
    }
}

struct MeetingTranscriptView: View {
    @EnvironmentObject var meeting: MeetingController
    let result: MeetingResult

    private static let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]

    private func color(_ speaker: String) -> Color {
        Self.palette[(result.speakers.firstIndex(of: speaker) ?? 0) % Self.palette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.text("{0} 位说话人 · {1} 的录音，用时 {2}", result.speakers.count, MeetingFormat.clock(meeting.seconds), MeetingFormat.clock(meeting.elapsed)))
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button(L10n.text("复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MeetingFormat.text(result), forType: .string)
                }.buttonStyle(SecondaryButtonStyle()).disabled(result.segments.isEmpty)
                Button(L10n.text("保存")) { save() }.buttonStyle(SecondaryButtonStyle()).disabled(result.segments.isEmpty)
            }
            if result.truncated == true {
                Text(L10n.text("结果在中途被截断，后面的内容缺失。")).font(.system(size: 13)).foregroundColor(Color.red)
            }
            if result.segments.isEmpty {
                Text(L10n.text("这段录音里没有听到说话。")).font(.system(size: 13)).foregroundColor(Theme.secondary)
                Spacer()
            } else {
                Text(L10n.text("说话人标签只区分这一段录音里的声音，可能有误，不代表真实身份。")).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(result.segments) { turn in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(MeetingFormat.clock(turn.start)).font(.system(size: 11.5)).monospacedDigit().foregroundColor(Theme.secondary).frame(width: 52, alignment: .leading)
                                Text(turn.speaker).font(.system(size: 12, weight: .semibold)).foregroundColor(color(turn.speaker)).frame(width: 34, alignment: .leading)
                                Text(turn.text).font(.system(size: 13.5)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
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

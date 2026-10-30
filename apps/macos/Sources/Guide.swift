import SwiftUI
import AppKit

// Guide.swift - help for new users: where the settings people look for live (home-page card
// and a setup step), and what to do when the speech model cannot be downloaded.

/// The settings people most often cannot find. `category` is the Settings tab (0 听写, 1 模型,
/// 2 通用); a nil page means the sidebar itself.
enum SettingsGuide {
    struct Entry: Identifiable {
        let title: String
        let place: String
        let page: HubPage?
        var category = 0
        var id: String { title }
    }

    static var entries: [Entry] {
        [
            Entry(title: L10n.text("提示词模式"), place: L10n.text("侧栏"), page: nil),
            Entry(title: L10n.text("API Key"), place: L10n.text("设置 › 模型"), page: .settings, category: 1),
            Entry(title: L10n.text("快捷键"), place: L10n.text("设置 › 听写"), page: .settings, category: 0),
            Entry(title: L10n.text("语音模型"), place: L10n.text("设置 › 模型"), page: .settings, category: 1),
            Entry(title: L10n.text("麦克风和辅助功能"), place: L10n.text("设置 › 通用"), page: .settings, category: 2),
        ]
    }

    static func open(_ entry: Entry, in model: AppModel) {
        guard let page = entry.page else { return }
        if page == .settings { model.settingsCategory = entry.category }
        model.page = page
    }
}

/// The guide as rows: what, where, and (when `open` is given) a button that goes there.
struct GuideList: View {
    var open: ((SettingsGuide.Entry) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SettingsGuide.entries) { entry in
                HStack(spacing: 10) {
                    Text(entry.title).font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 8)
                    Text(entry.place).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                    if let open, entry.page != nil {
                        Button(L10n.text("前往")) { open(entry) }.buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
    }
}

/// 「设置在哪」on the home page until the user says they know.
struct GuideCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.text("设置位置")).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button(L10n.text("好")) { model.dismissGuide() }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                }
                GuideList { SettingsGuide.open($0, in: model) }
            }
        }
    }
}

/// Speech models come from huggingface.co, which some networks block or slow down.
enum ModelMirror {
    static let suggested = "https://hf-mirror.com"
}

extension SpeechStatus {
    /// A download that failed on the network (not a checksum or disk problem).
    var networkFailure: Bool {
        if operation?.phase == "error", operation?.error == "download-failed" { return true }
        guard phase == "error", let error else { return false }
        return ["could not reach", "was interrupted", " answered HTTP "].contains { error.contains($0) }
    }
}

/// For a failed model download: the likely cause, and a mirror to copy or retry with.
struct MirrorHint: View {
    @EnvironmentObject var model: AppModel
    /// Downloads again (with the mirror now saved in the settings).
    let retry: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("下载失败？网络可能连不上 Hugging Face，请用镜像："))
                .font(.system(size: 12.5)).foregroundColor(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(ModelMirror.suggested).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                Button(copied ? L10n.text("已复制") : L10n.text("复制")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ModelMirror.suggested, forType: .string)
                    copied = true
                }.buttonStyle(SecondaryButtonStyle())
                Button(L10n.text("用镜像重试")) {
                    model.setting(\.modelMirror).wrappedValue = ModelMirror.suggested
                    retry()
                }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.10)))
    }
}

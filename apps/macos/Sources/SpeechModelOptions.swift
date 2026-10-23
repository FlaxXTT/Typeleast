import SwiftUI

struct SpeechModelOptions: View {
    @EnvironmentObject var model: AppModel

    static func detail(_ id: String) -> String {
        switch id {
        case "fireredasr2-ctc": return L10n.text("偏向中文与方言，也支持英文；自动检测语言。")
        case "fun-asr-nano": return L10n.text("适合中英混合听写，也支持日语。")
        case "qwen3-asr-0.6b": return L10n.text("多语言识别；体积和资源需求高于默认模型。")
        default: return L10n.text("默认模型，小而快，支持中、英、粤、日、韩。")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("识别模型")).font(.headline)
            if let catalog = model.speechCatalog {
                if catalog.notice != nil {
                    Text(L10n.text("原选择的模型不可用，正在尝试默认模型。"))
                        .foregroundColor(Theme.warning).font(.caption)
                }
                ForEach(catalog.models) { entry in
                    let selected = catalog.activeModelId == entry.id && model.speech?.ready == true
                    let operation = catalog.operation?.modelId == entry.id ? catalog.operation : nil
                    let busy = catalog.operation?.running == true
                    let download = !entry.installed || operation?.error == "checksum-mismatch"
                    VStack(alignment: .leading, spacing: 7) {
                        SettingRow(title: entry.name, detail: Self.detail(entry.id)) {
                            Button(selected ? L10n.text("正在使用") : download ? L10n.text("下载并启用") : L10n.text("使用")) {
                                model.actions?.manageSpeechModel(id: entry.id, download: download, cancel: false)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(selected || busy || model.phase != .idle)
                            .opacity(selected || busy || model.phase != .idle ? 0.55 : 1)
                        }
                        HStack(spacing: 12) {
                            Text(String(format: "%.2f GB", locale: L10n.locale, entry.modelBytes / 1_000_000_000))
                            if entry.installed { Text(L10n.text("已下载")) }
                            if let url = URL(string: entry.sourceUrl) { Link(L10n.text("模型来源与下载链接"), destination: url) }
                        }.font(.caption).foregroundColor(Theme.secondary)
                        if let operation {
                            if operation.running {
                                HStack {
                                    Text(operation.phase == "downloading" ? L10n.text("正在下载…") : L10n.text("等待或加载中…"))
                                    if operation.phase == "downloading", operation.total > 0 {
                                        ProgressView(value: min(operation.received, operation.total), total: operation.total).frame(width: 100)
                                        Text(String(Int(min(1, operation.received / operation.total) * 100)) + "%")
                                    }
                                    if operation.phase != "loading" {
                                        Button(operation.phase == "downloading" ? L10n.text("取消下载") : L10n.text("取消")) { model.actions?.manageSpeechModel(id: entry.id, download: false, cancel: true) }
                                    }
                                }.font(.caption)
                            } else if operation.phase == "error" {
                                Text(operation.problem)
                                    .font(.caption).foregroundColor(Theme.warning)
                                if operation.error == "download-failed" {
                                    MirrorHint { model.actions?.manageSpeechModel(id: entry.id, download: true, cancel: false) }
                                }
                            } else if operation.phase == "cancelled" {
                                Text(L10n.text("下载已取消，已校验的文件可复用。"))
                                    .font(.caption).foregroundColor(Theme.secondary)
                            }
                        }
                    }
                    if entry.id != catalog.models.last?.id { Divider() }
                }
            } else {
                Button(L10n.text("读取模型目录")) { model.actions?.recheckHealth() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

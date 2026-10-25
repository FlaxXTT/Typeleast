import SwiftUI

struct SpeechModelOptions: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("语音模型")).font(.headline)
            if let catalog = model.speechCatalog {
                if catalog.notice != nil {
                    Text(L10n.text("所选模型不可用，正在尝试默认模型。"))
                        .foregroundColor(Theme.warning).font(.caption)
                }
                ForEach(catalog.models) { entry in
                    let selected = catalog.activeModelId == entry.id && model.speech?.ready == true
                    let operation = catalog.operation?.modelId == entry.id ? catalog.operation : nil
                    let busy = catalog.operation?.running == true
                    let download = !entry.installed || operation?.error == "checksum-mismatch"
                    VStack(alignment: .leading, spacing: 7) {
                        SettingRow(title: entry.name, detail: nil) {
                            Button(selected ? L10n.text("使用中") : download ? L10n.text("下载并使用") : L10n.text("使用")) {
                                model.actions?.manageSpeechModel(id: entry.id, download: download, cancel: false)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(selected || busy || model.phase != .idle)
                            .opacity(selected || busy || model.phase != .idle ? 0.55 : 1)
                        }
                        HStack(spacing: 12) {
                            Text(String(format: "%.2f GB", locale: L10n.locale, entry.modelBytes / 1_000_000_000))
                            if entry.installed { Text(L10n.text("已下载")) }
                            if let url = URL(string: entry.sourceUrl) { Link(L10n.text("模型来源与下载"), destination: url) }
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
                                Text(L10n.text("下载已取消。已校验的文件下次可用。"))
                                    .font(.caption).foregroundColor(Theme.secondary)
                            }
                        }
                    }
                    if entry.id != catalog.models.last?.id { Divider() }
                }
            } else {
                Button(L10n.text("读取模型列表")) { model.actions?.recheckHealth() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

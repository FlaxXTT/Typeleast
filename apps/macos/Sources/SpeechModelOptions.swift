import SwiftUI

struct SpeechModelOptions: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("语音模型")).font(.headline)
            if let catalog = model.speechCatalog {
                let dictationModels = catalog.models.filter { $0.category != "meeting" }
                if dictationModels.contains(where: { $0.id.hasPrefix("mlx-") && !$0.installed }) {
                    Text(L10n.text("MLX 模型需重新下载。旧模型文件会保留，但不能用于 MLX 识别。"))
                        .font(.caption).foregroundColor(Theme.secondary)
                }
                if catalog.notice != nil {
                    Text(L10n.text("所选模型不可用，请重新选择。"))
                        .foregroundColor(Theme.warning).font(.caption)
                }
                ForEach(dictationModels) { entry in
                    modelRow(entry, catalog: catalog)
                }
            } else {
                Button(L10n.text("读取模型列表")) { model.actions?.recheckHealth() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    @ViewBuilder private func modelRow(_ entry: SpeechModelOption, catalog: SpeechModelCatalog) -> some View {
        let selected = catalog.activeModelId == entry.id && model.speech?.ready == true
        let operation = catalog.operation?.modelId == entry.id ? catalog.operation : nil
        let download = !entry.installed || operation?.error == "checksum-mismatch"
        VStack(alignment: .leading, spacing: 7) {
            SettingRow(title: entry.name, detail: nil) {
                if entry.installed || entry.downloadable == true {
                    Button(selected ? L10n.text("使用中") : download ? L10n.text("下载并使用") : L10n.text("使用")) {
                        model.actions?.manageSpeechModel(id: entry.id, download: download, cancel: false)
                    }.buttonStyle(SecondaryButtonStyle())
                        .disabled(selected || catalog.operation?.running == true || model.phase != .idle)
                }
            }
            if entry.id == "mlx-fun-asr-nano-bf16" {
                Text(L10n.text("中英日 · 混说 · 自动识别")).font(.caption)
            } else if entry.id == "mlx-qwen3-asr-0.6b-bf16" {
                Text(L10n.text("多语种 · 中英混说 · 较小体积")).font(.caption)
            } else if entry.id == "mlx-qwen3-asr-1.7b-bf16" {
                Text(L10n.text("多语种 · 中英混说 · 较大容量")).font(.caption)
            }
            HStack(spacing: 10) {
                if let precision = entry.precision { Text(precision.uppercased()) }
                Text(String(format: "%.2f GB", locale: L10n.locale, entry.modelBytes / 1_000_000_000))
                if entry.installed { Text(L10n.text("已下载")) }
                if !entry.sourceUrl.isEmpty, let url = URL(string: entry.sourceUrl) {
                    Link(L10n.text("模型来源与下载"), destination: url)
                }
            }.font(.caption).foregroundColor(Theme.secondary)
            if let op = operation {
                if op.running {
                    HStack {
                        Text(op.phase == "downloading" ? L10n.text("正在下载…") : L10n.text("等待或加载中…"))
                        if op.phase == "downloading", op.total > 0 {
                            ProgressView(value: min(op.received, op.total), total: op.total).frame(width: 100)
                        }
                        if op.phase != "committing" {
                            Button(L10n.text("取消")) { model.actions?.manageSpeechModel(id: entry.id, download: false, cancel: true) }
                        }
                    }.font(.caption)
                } else if op.phase == "error" {
                    Text(op.problem).font(.caption).foregroundColor(Theme.warning)
                }
            }
            Divider()
        }
    }
}

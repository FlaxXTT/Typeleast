import SwiftUI

struct SpeechModelOptions: View {
    @EnvironmentObject var model: AppModel
    @State private var deletion: SpeechStorageItem?
    @State private var partialOnly = false

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
                storageSection(catalog)
            } else {
                Button(L10n.text("读取模型列表")) { model.actions?.recheckHealth() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .alert(L10n.text("确认删除？"), isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), presenting: deletion) { item in
            Button(L10n.text("删除"), role: .destructive) {
                model.actions?.clearSpeechModelStorage(id: item.id, partialOnly: partialOnly)
                deletion = nil
            }
            Button(L10n.text("取消"), role: .cancel) { deletion = nil }
        } message: { item in
            Text(partialOnly
                 ? L10n.text("只删除 {0} 未完成的下载，下次可重新下载。", item.name)
                 : L10n.text("删除 {0} 的模型文件后，使用前需要重新下载。历史、录音、设置和密钥不受影响。", item.name))
        }
    }

    @ViewBuilder private func storageSection(_ catalog: SpeechModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("模型与存储")).font(.headline)
            Text(L10n.text("只显示应用管理的模型文件和未完成的下载。历史、录音、个人偏好、密钥和其他文件不会在这里删除。"))
                .font(.caption).foregroundColor(Theme.secondary)
            if let items = catalog.storage, !items.isEmpty {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                Text(item.active ? L10n.text("当前使用中，请先切换模型") : item.legacy ? L10n.text("旧版模型，可删除；以后使用需重新下载") : L10n.text("模型文件，可重新下载"))
                                    .font(.caption).foregroundColor(Theme.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).font(.caption)
                            if item.bytes > 0 {
                                Button(L10n.text("删除")) { partialOnly = false; deletion = item }
                                    .disabled(item.active || catalog.operation?.running == true || model.phase != .idle)
                            }
                        }
                        if item.partialBytes > 0 {
                            HStack {
                                Text(L10n.text("未完成的下载")).font(.caption)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(item.partialBytes), countStyle: .file)).font(.caption)
                                Button(L10n.text("清理")) { partialOnly = true; deletion = item }
                                    .disabled(catalog.operation?.running == true || model.phase != .idle)
                            }
                        }
                    }
                }
            } else {
                Text(L10n.text("没有可管理的模型文件。")).font(.caption).foregroundColor(Theme.secondary)
            }
            Text(L10n.text("会议模型和其他缓存未在此列出，不会被清理。"))
                .font(.caption).foregroundColor(Theme.secondary)
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
            } else if entry.id == "mlx-qwen3-asr-1.7b-bf16" || entry.id == "mlx-qwen3-asr-1.7b-8bit" {
                Text(L10n.text("多语种 · 中英混说 · 较大容量")).font(.caption)
            }
            if entry.id == "mlx-qwen3-asr-1.7b-8bit" {
                Text(L10n.text("尚未经本机识别验证")).font(.caption).foregroundColor(Theme.secondary)
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

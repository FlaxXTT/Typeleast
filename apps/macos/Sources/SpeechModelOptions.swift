import SwiftUI

struct SpeechModelOptions: View {
    @EnvironmentObject var model: AppModel
    @State private var deletion: SpeechStorageItem?
    @State private var partialOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("语音模型")).font(InterfaceTypography.localized(13, weight: .semibold))
            if let catalog = model.speechCatalog {
                let dictationModels = catalog.models.filter { $0.category != "meeting" }
                if catalog.notice != nil {
                    Text(L10n.text("所选模型不可用，请重新选择。"))
                        .foregroundColor(Theme.warning).font(Theme.captionFont)
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
                 ? L10n.text("清理 {0} 未完成的下载。", item.name)
                 : L10n.text("再次使用 {0} 前需重新下载。", item.name))
        }
    }

    @ViewBuilder private func storageSection(_ catalog: SpeechModelCatalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("本地听写模型文件")).font(InterfaceTypography.localized(13, weight: .semibold))
            if let items = catalog.storage, !items.isEmpty {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.name)
                                if item.active || item.legacy {
                                    Text(L10n.text(item.active ? "切换模型后可删除" : "旧版模型"))
                                        .font(Theme.captionFont).foregroundColor(Theme.secondary)
                                }
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).font(Theme.captionFont)
                            if item.bytes > 0 {
                                Button(L10n.text("删除")) { partialOnly = false; deletion = item }
                                    .buttonStyle(SecondaryButtonStyle(feedback: .fixed))
                                    .disabled(item.active || catalog.operation?.running == true || model.phase != .idle)
                            }
                        }
                        if item.partialBytes > 0 {
                            HStack {
                                Text(L10n.text("未完成的下载")).font(Theme.captionFont)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(item.partialBytes), countStyle: .file)).font(Theme.captionFont)
                                Button(L10n.text("清理")) { partialOnly = true; deletion = item }
                                    .buttonStyle(SecondaryButtonStyle(feedback: .fixed))
                                    .disabled(catalog.operation?.running == true || model.phase != .idle)
                            }
                        }
                    }
                }
            } else {
                Text(L10n.text("无本地文件")).font(Theme.captionFont).foregroundColor(Theme.secondary)
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
                Text(L10n.text("中英日 · 混说 · 自动识别")).font(Theme.captionFont)
            } else if entry.id == "mlx-qwen3-asr-0.6b-bf16" {
                Text(L10n.text("多语种 · 中英混说 · 较小体积")).font(Theme.captionFont)
            } else if entry.id == "mlx-qwen3-asr-1.7b-bf16" || entry.id == "mlx-qwen3-asr-1.7b-8bit" {
                Text(L10n.text("多语种 · 中英混说 · 较大容量")).font(Theme.captionFont)
            }
            HStack(spacing: 10) {
                if let precision = entry.precision { Text(precision.uppercased()) }
                Text(String(format: "%.2f GB", locale: L10n.locale, entry.modelBytes / 1_000_000_000))
                if entry.installed { Text(L10n.text("已下载")) }
                if !entry.sourceUrl.isEmpty, let url = URL(string: entry.sourceUrl) {
                    Link(L10n.text("模型来源与下载"), destination: url)
                        .hoverFeedback(.compact)
                }
            }.font(Theme.captionFont).foregroundColor(Theme.secondary)
            if let op = operation {
                if op.running {
                    HStack {
                        Text(op.phase == "downloading" ? L10n.text("正在下载…") : L10n.text("等待或加载中…"))
                        if op.phase == "downloading", op.total > 0 {
                            LoadingLinearProgress(value: min(op.received, op.total) / op.total).frame(width: 100)
                        }
                        if op.phase != "committing" {
                            Button(L10n.text("取消")) { model.actions?.manageSpeechModel(id: entry.id, download: false, cancel: true) }
                                .hoverFeedback(.fixed)
                        }
                    }.font(Theme.captionFont)
                } else if op.phase == "error" {
                    Text(op.problem).font(Theme.captionFont).foregroundColor(Theme.warning)
                }
            }
            Divider()
        }
    }
}

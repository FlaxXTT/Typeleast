import SwiftUI
import AppKit

struct SpeechModelOptions: View {
    @EnvironmentObject var model: AppModel
    @State private var otherExpanded = false
    @State private var importing = false
    @State private var localProblem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("语音模型")).font(.headline)
            Text(L10n.text("选择模型与精度后再下载。不会自动选择或下载。"))
                .font(.caption).foregroundColor(Theme.secondary)
            if let catalog = model.speechCatalog {
                if catalog.notice != nil { Text(L10n.text("所选模型不可用，请重新选择。" )).foregroundColor(Theme.warning).font(.caption) }
                ForEach(catalog.models.filter { $0.category == "primary" || $0.id == "qwen3-asr-0.6b" }) { entry in
                    modelRow(entry, catalog: catalog)
                }
                DisclosureGroup(isExpanded: $otherExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.text("自行下载兼容的 ONNX 文件，再选择目录配置。不会搬动或删除原文件。"))
                            .font(.caption).foregroundColor(Theme.secondary)
                        Button(L10n.text("导入本地模型")) { importing = true }
                            .buttonStyle(SecondaryButtonStyle()).disabled(model.phase != .idle || catalog.operation?.running == true)
                        ForEach(catalog.models.filter { $0.category == "other" || ($0.category == nil && $0.id != "qwen3-asr-0.6b") }) { entry in
                            modelRow(entry, catalog: catalog)
                        }
                    }.padding(.top, 8)
                } label: { Text(L10n.text("其他模型")) }
                if !localProblem.isEmpty { Text(localProblem).font(.caption).foregroundColor(Theme.warning) }
                if let op = catalog.operation, !catalog.models.contains(where: { $0.id == op.modelId }) {
                    Text(op.running ? L10n.text("等待或加载中…") : op.phase == "error" ? op.problem : L10n.text("配置完成。请在其他模型中选择使用。"))
                        .font(.caption).foregroundColor(Theme.secondary)
                }
            } else {
                Button(L10n.text("读取模型列表")) { model.actions?.recheckHealth() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .sheet(isPresented: $importing) { LocalSpeechModelImport(onClose: { importing = false }).environmentObject(model) }
    }

    @ViewBuilder private func modelRow(_ entry: SpeechModelOption, catalog: SpeechModelCatalog) -> some View {
        let selected = catalog.activeModelId == entry.id && model.speech?.ready == true
        let operation = catalog.operation?.modelId == entry.id ? catalog.operation : nil
        let primary = entry.category == "primary" || entry.id == "qwen3-asr-0.6b"
        let configured = primary || entry.registered == true || selected
        let download = primary && (!entry.installed || operation?.error == "checksum-mismatch")
        VStack(alignment: .leading, spacing: 7) {
            SettingRow(title: entry.name, detail: nil) {
                if configured || entry.installed {
                    Button(selected ? L10n.text("使用中") : !configured ? L10n.text("一键配置") : download ? L10n.text("下载并使用") : L10n.text("使用")) {
                        if configured { model.actions?.manageSpeechModel(id: entry.id, download: download, cancel: false) }
                        else { localAction("register-known", id: entry.id) }
                    }.buttonStyle(SecondaryButtonStyle())
                        .disabled(selected || catalog.operation?.running == true || model.phase != .idle)
                }
                if entry.registered == true && !selected {
                    Button(L10n.text("移除登记")) { localAction("local/remove", id: entry.id) }
                        .buttonStyle(SecondaryButtonStyle()).disabled(catalog.operation?.running == true || model.phase != .idle)
                }
            }
            if primary { Text(entry.id.contains("1.7b") ? L10n.text("多语种 · 中英混说 · 较大容量") : L10n.text("多语种 · 中英混说 · 较小体积")).font(.caption) }
            else {
                Text(entry.id == "sensevoice-small" ? L10n.text("轻量 · 快速 · 五语种") : entry.id == "fireredasr2-ctc" ? L10n.text("中文 · 方言 · CTC") : entry.id == "fun-asr-nano" ? L10n.text("中英日 · 混说 · 口音") : L10n.text("兼容导入 · 本地识别")).font(.caption)
            }
            if entry.precision == "fp16" { Text(L10n.text("Mac 实测加载峰值约 12.5 GiB；不同环境会变化。")).font(.caption).foregroundColor(Theme.secondary) }
            HStack(spacing: 10) {
                Text(entry.precision == "local" ? L10n.text("本地文件") : entry.precision == "fp16" ? L10n.text("FP16（前端 FP32）") : "INT8")
                Text(String(format: "%.2f GB", locale: L10n.locale, entry.modelBytes / 1_000_000_000))
                if entry.installed { Text(L10n.text("已下载")) }
                if !entry.sourceUrl.isEmpty, let url = URL(string: entry.sourceUrl) { Link(L10n.text("模型来源与下载"), destination: url) }
            }.font(.caption).foregroundColor(Theme.secondary)
            if let op = operation {
                if op.running {
                    HStack {
                        Text(op.phase == "downloading" ? L10n.text("正在下载…") : L10n.text("等待或加载中…"))
                        if op.phase == "downloading", op.total > 0 { ProgressView(value: min(op.received, op.total), total: op.total).frame(width: 100) }
                        if op.phase != "loading" { Button(L10n.text("取消")) { model.actions?.manageSpeechModel(id: entry.id, download: false, cancel: true) } }
                    }.font(.caption)
                } else if op.phase == "error" { Text(op.problem).font(.caption).foregroundColor(Theme.warning) }
            }
            Divider()
        }
    }
    private func localAction(_ path: String, id: String) {
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try ServiceClient().localModelActionSync(path: path, body: ["modelId": id])
                DispatchQueue.main.async { model.actions?.recheckHealth() }
            } catch { DispatchQueue.main.async { localProblem = L10n.text("模型操作失败，请重试。当前模型保留。") } }
        }
    }
}

private struct LocalSpeechModelImport: View {
    @EnvironmentObject var model: AppModel
    let onClose: () -> Void
    @State private var name = ""
    @State private var directory = ""
    @State private var family = "qwen3-asr-0.6b"
    @State private var files = ["convFrontend": "conv_frontend.onnx", "encoder": "encoder.int8.onnx", "decoder": "decoder.int8.onnx", "tokenizer": "tokenizer"]
    @State private var busy = false
    @State private var problem = ""
    private let families = ["qwen3-asr-0.6b", "sensevoice-small", "fireredasr2-ctc", "fun-asr-nano"]
    private func defaults(_ id: String) -> [String: String] {
        switch id {
        case "sensevoice-small", "fireredasr2-ctc": return ["model": "model.int8.onnx", "tokens": "tokens.txt"]
        case "fun-asr-nano": return ["encoderAdaptor": "encoder_adaptor.int8.onnx", "llm": "llm.int8.onnx", "embedding": "embedding.int8.onnx", "tokenizer": "Qwen3-0.6B"]
        default: return ["convFrontend": "conv_frontend.onnx", "encoder": "encoder.int8.onnx", "decoder": "decoder.int8.onnx", "tokenizer": "tokenizer"]
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("导入本地模型")).font(.title2)
            Text(L10n.text("仅支持现有适配器兼容的 ONNX。模型来自本地，未经官方审核；加载成功不代表文件安全。"))
                .font(.caption).foregroundColor(Theme.secondary)
            TextField(L10n.text("模型名称"), text: $name)
            Picker(L10n.text("模型类型"), selection: $family) { ForEach(families, id: \.self) { Text($0 == "qwen3-asr-0.6b" ? "Qwen3-ASR (0.6B / 1.7B)" : $0).tag($0) } }
                .onChange(of: family) { files = defaults($0) }
            Button(L10n.text("选择模型文件夹")) {
                let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
                if panel.runModal() == .OK { directory = panel.url?.path ?? "" }
            }
            Text(directory).font(.caption).lineLimit(2)
            ForEach(files.keys.sorted(), id: \.self) { key in
                HStack { Text(key).frame(width: 100, alignment: .leading); TextField(key, text: Binding(get: { files[key] ?? "" }, set: { files[key] = $0 })) }
            }
            Text(L10n.text("文件路径相对于所选目录。配置不调用整理模型。" )).font(.caption)
            if !problem.isEmpty { Text(problem).font(.caption).foregroundColor(Theme.warning) }
            HStack {
                Button(L10n.text("取消"), action: onClose).disabled(busy)
                Spacer()
                Button(busy ? L10n.text("等待或加载中…") : L10n.text("检查并配置")) { submit() }
                    .disabled(busy || directory.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 520)
    }
    private func submit() {
        busy = true
        let input: [String: Any] = ["name": name, "family": family, "directory": directory, "files": files]
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try ServiceClient().localModelActionSync(path: "local/inspect", body: input)
                _ = try ServiceClient().localModelActionSync(path: "local/register", body: input)
                DispatchQueue.main.async { model.actions?.recheckHealth(); onClose() }
            } catch { DispatchQueue.main.async { busy = false; problem = L10n.text("模型文件不兼容或路径无效。当前模型保留。") } }
        }
    }
}

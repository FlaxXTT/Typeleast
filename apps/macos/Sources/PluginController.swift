import Foundation
import AppKit
import UniformTypeIdentifiers

// PluginController.swift - the Extensions page's state and actions. The service checks,
// stores and applies plugins; this only asks it, and asks the official catalog through it
// only when the market tab is opened or refreshed.

/// A plugin waiting for the user to confirm, with where it came from.
struct PendingPlugin: Identifiable {
    enum Origin { case file(Data), catalog }
    let summary: PluginSummary
    let origin: Origin
    let installedVersion: String?
    var id: String { summary.id }
    var fromCatalog: Bool { if case .catalog = origin { return true } else { return false } }
}

final class PluginController: ObservableObject {
    @Published private(set) var state = PluginState(plugins: [], style: nil, problems: [])
    @Published private(set) var catalog: PluginCatalog?
    @Published private(set) var catalogLoading = false
    @Published var pending: PendingPlugin?
    @Published var message: String?

    private let client: ServiceClient

    init(client: ServiceClient = .shared) { self.client = client }

    /// Show a given state without asking the service (renders and tests).
    func preview(state: PluginState, catalog: PluginCatalog? = nil) {
        self.state = state
        self.catalog = catalog
    }

    var styles: [PluginSummary] { state.plugins.filter(\.isStyle) }
    var selectedStyle: PluginSummary? { state.plugins.first { $0.id == state.style } }

    /// Run `work` off the main thread; apply its result (or show its error) on the main thread.
    private func run<T>(_ work: @escaping (ServiceClient) throws -> T, then: @escaping (T) -> Void) {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work(client) }
            DispatchQueue.main.async { [weak self] in
                switch result {
                case .success(let value): self?.message = nil; then(value)
                case .failure(let error): self?.message = PluginController.describe(error)
                }
            }
        }
    }

    func refresh() { run({ try $0.pluginsSync() }) { [weak self] in self?.state = $0 } }

    private func reloadCatalog() { openMarket() }

    /// The user opened the market tab or pressed refresh: one catalog read.
    func openMarket() {
        guard !catalogLoading else { return }
        catalogLoading = true
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try client.pluginCatalogSync() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.catalogLoading = false
                switch result {
                case .success(let catalog):
                    self.catalog = catalog
                    self.message = catalog.ok ? nil : PluginController.describe(code: catalog.code)
                case .failure(let error):
                    self.message = PluginController.describe(error)
                }
            }
        }
    }

    func importFile(_ url: URL) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 256 * 1024,
              let data = try? Data(contentsOf: url) else {
            message = L10n.text("这不是有效的插件文件")
            return
        }
        run({ try $0.inspectPluginSync(data) }) { [weak self] inspection in
            self?.pending = PendingPlugin(summary: inspection.plugin, origin: .file(data), installedVersion: inspection.installedVersion)
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "typeleast-plugin"), .json].compactMap { $0 }
        panel.message = L10n.text("选择 .typeleast-plugin 插件文件")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    func askToInstall(_ summary: PluginSummary) {
        pending = PendingPlugin(summary: summary, origin: .catalog, installedVersion: summary.installedVersion)
    }

    /// The user confirmed the pending plugin; `enable` turns a pack on or selects a style.
    func confirm(enable: Bool) {
        guard let pending else { return }
        self.pending = nil
        let digest = pending.summary.digest ?? ""
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> PluginState in
                switch pending.origin {
                case .file(let data): return try client.installPluginSync(data, enable: enable, digest: digest)
                case .catalog: return try client.installCatalogPluginSync(id: pending.id, enable: enable, digest: digest)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let state): self.message = nil; self.installed(state)
                case .failure(let error):
                    self.message = PluginController.describe(error)
                    // The catalog changed after the confirmation was shown: show the new content.
                    if case .http(_, "plugin-changed", _) = error as? ServiceError, pending.fromCatalog { self.reloadCatalog() }
                }
            }
        }
    }

    private func installed(_ state: PluginState) {
        self.state = state
        if let catalog {
            let versions = Dictionary(state.plugins.map { ($0.id, $0.version) }, uniquingKeysWith: { a, _ in a })
            var updated = catalog
            for i in updated.plugins.indices { updated.plugins[i].installedVersion = versions[updated.plugins[i].id] }
            self.catalog = updated
        }
    }

    func setEnabled(_ id: String, _ enabled: Bool) { run({ try $0.setPluginEnabledSync(id: id, enabled: enabled) }) { [weak self] in self?.state = $0 } }
    func selectStyle(_ id: String?) { run({ try $0.selectStyleSync(id: id) }) { [weak self] in self?.state = $0 } }
    func remove(_ id: String) { run({ try $0.removePluginSync(id: id) }) { [weak self] in self?.installed($0) } }

    static func describe(_ error: Error) -> String {
        if case .http(_, let code, _) = error as? ServiceError { return describe(code: code) }
        return L10n.text("本地服务还没就绪，稍后再试")
    }

    static func describe(code: String?) -> String {
        switch code {
        case "plugin-invalid": return L10n.text("这不是有效的插件文件")
        case "plugin-terms-limit": return L10n.text("启用的词库加起来不能超过 10000 个词")
        case "plugin-aliases-limit": return L10n.text("启用的读音提示不能超过 1000 条")
        case "plugin-not-found": return L10n.text("找不到这个插件，请刷新")
        case "plugin-changed": return L10n.text("插件内容变了，请重新查看后再安装")
        case "market-protocol-unsupported": return L10n.text("插件目录格式不对，可能要更新 TypeLeast")
        case "market-too-large": return L10n.text("插件目录太大，无法读取")
        case "market-offline": return L10n.text("连不上插件目录，请检查网络")
        default: return L10n.text("操作没有完成，请重试")
        }
    }
}

import Foundation

// PluginController.swift - the bundled technical-terms pack's switch on the Dictionary page.
// The service stores and applies the pack; this only asks it.

final class PluginController: ObservableObject {
    @Published private(set) var state = PluginState(plugins: [], style: nil, problems: [])
    @Published var message: String?

    private let client: ServiceClient

    init(client: ServiceClient = .shared) { self.client = client }

    /// Show a given state without asking the service (renders and tests).
    func preview(state: PluginState) { self.state = state }

    /// The bundled 「技术术语」 pack, once the service has reported it.
    var techTerms: PluginSummary? { state.plugins.first { $0.id == "typeleast.tech-terms" } }

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

    func setEnabled(_ id: String, _ enabled: Bool) { run({ try $0.setPluginEnabledSync(id: id, enabled: enabled) }) { [weak self] in self?.state = $0 } }

    static func describe(_ error: Error) -> String {
        if case .http(_, let code, _) = error as? ServiceError { return describe(code: code) }
        return L10n.text("本地服务未就绪，请稍后重试")
    }

    static func describe(code: String?) -> String {
        switch code {
        case "plugin-terms-limit": return L10n.text("已启用的词库合计最多 10000 个词")
        case "plugin-aliases-limit": return L10n.text("已启用的读音提示合计最多 1000 条")
        case "plugin-not-found": return L10n.text("找不到插件，请刷新")
        default: return L10n.text("没有完成，请重试")
        }
    }
}

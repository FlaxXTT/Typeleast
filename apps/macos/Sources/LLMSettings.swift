import Foundation
import Security

// LLMSettings.swift - which model cleans up dictations, and the user's own API key.
//
// Any OpenAI-compatible service works with the user's own key (presets below).
// The key is stored in the macOS Keychain, never in UserDefaults. It is sent only
// to the local TypeLeast service on 127.0.0.1 with each dictation, which uses it
// for that call alone. Without a key, dictation still works: the recognised text
// is inserted with filler words removed, but not rewritten.

/// A provider the Settings page offers, with the values a user would otherwise look up.
struct LLMPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let baseURL: String
    /// Shown as the model field's placeholder; "获取模型列表" fills real ids.
    let modelHint: String
    /// Local servers (Ollama) work without a key.
    let needsKey: Bool
    /// Where to create a key.
    let keyPage: String

    static let all: [LLMPreset] = [
        LLMPreset(id: "deepseek", name: "DeepSeek 官方 API", baseURL: "https://api.deepseek.com/v1",
                  modelHint: "deepseek-chat", needsKey: true, keyPage: "https://platform.deepseek.com/api_keys"),
        LLMPreset(id: "zhipu", name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4",
                  modelHint: "glm-4-flash", needsKey: true, keyPage: "https://open.bigmodel.cn/usercenter/apikeys"),
        LLMPreset(id: "moonshot", name: "Kimi（月之暗面）", baseURL: "https://api.moonshot.cn/v1",
                  modelHint: "moonshot-v1-8k", needsKey: true, keyPage: "https://platform.moonshot.cn/console/api-keys"),
        LLMPreset(id: "qwen", name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                  modelHint: "qwen-plus", needsKey: true, keyPage: "https://dashscope.console.aliyun.com/apiKey"),
        LLMPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                  modelHint: "deepseek/deepseek-chat", needsKey: true, keyPage: "https://openrouter.ai/keys"),
        LLMPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                  modelHint: "gpt-4o-mini", needsKey: true, keyPage: "https://platform.openai.com/api-keys"),
        LLMPreset(id: "ollama", name: "本机 Ollama", baseURL: "http://127.0.0.1:11434/v1",
                  modelHint: "qwen2.5:7b", needsKey: false, keyPage: "https://ollama.com"),
        LLMPreset(id: "custom", name: "自定义（OpenAI 兼容）", baseURL: "",
                  modelHint: "模型 ID", needsKey: true, keyPage: ""),
    ]

    static func find(_ id: String) -> LLMPreset { all.first { $0.id == id } ?? all[0] }

    /// Whether a base URL may carry a key: https, or http to this Mac only.
    static func isAllowedBaseURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
    }
}

/// Generic-password items in the login Keychain, one per provider preset.
enum KeychainStore {
    static let service = "TypeLeast.llm-api-key"
    /// OSStatus of the last write, for diagnostics and for telling the user why saving failed.
    private(set) static var lastStatus: OSStatus = errSecSuccess
    /// Screenshot/test seam: when set, the Keychain is never touched.
    static var stub: [String: String]?

    static func read(account: String) -> String? {
        if let stub = stub { return stub[account] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        if stub != nil {
            stub?[account] = value.isEmpty ? nil : value
            return true
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        lastStatus = SecItemAdd(item as CFDictionary, nil)
        return lastStatus == errSecSuccess
    }
}

extension Settings {
    var llmPresetID: String {
        get { UserDefaults.standard.string(forKey: "llm.preset") ?? "deepseek" }
        set { UserDefaults.standard.set(newValue, forKey: "llm.preset"); notifyChanged() }
    }

    /// Base URL and model are remembered per preset, so switching back keeps them.
    var llmBaseURL: String {
        get { UserDefaults.standard.string(forKey: "llm.baseURL." + llmPresetID) ?? LLMPreset.find(llmPresetID).baseURL }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "llm.baseURL." + llmPresetID); notifyChanged() }
    }

    var llmModel: String {
        get { UserDefaults.standard.string(forKey: "llm.model." + llmPresetID) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "llm.model." + llmPresetID); notifyChanged() }
    }

    var llmAPIKey: String {
        get { KeychainStore.read(account: llmPresetID) ?? "" }
        set { KeychainStore.write(newValue.trimmingCharacters(in: .whitespacesAndNewlines), account: llmPresetID); notifyChanged() }
    }

    /// The route to send with a dictation, or nil when it is not complete yet
    /// (then the service inserts the tidied transcript, reason no-api-key).
    var activeLLMRoute: LLMRoute? {
        let preset = LLMPreset.find(llmPresetID)
        let key = llmAPIKey
        guard !llmModel.isEmpty, LLMPreset.isAllowedBaseURL(llmBaseURL), !(preset.needsKey && key.isEmpty) else { return nil }
        return LLMRoute(baseURL: llmBaseURL, model: llmModel, apiKey: key)
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}

/// The one-time code the user must type before the default can be replaced.
enum PromptifyGuard {
    static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    static func matches(typed: String, code: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == code
    }
}

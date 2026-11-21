import Foundation
import Security
import LocalAuthentication

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
        LLMPreset(id: "deepseek", name: L10n.text("DeepSeek 官方 API"), baseURL: "https://api.deepseek.com",
                  modelHint: "deepseek-flash", needsKey: true, keyPage: "https://platform.deepseek.com/api_keys"),
        LLMPreset(id: "zhipu", name: L10n.text("智谱 GLM"), baseURL: "https://open.bigmodel.cn/api/paas/v4",
                  modelHint: "glm-4-flash", needsKey: true, keyPage: "https://open.bigmodel.cn/usercenter/apikeys"),
        LLMPreset(id: "moonshot", name: L10n.text("Kimi（月之暗面）"), baseURL: "https://api.moonshot.cn/v1",
                  modelHint: "moonshot-v1-8k", needsKey: true, keyPage: "https://platform.moonshot.cn/console/api-keys"),
        LLMPreset(id: "qwen", name: L10n.text("通义千问"), baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
                  modelHint: "qwen-plus", needsKey: true, keyPage: "https://dashscope.console.aliyun.com/apiKey"),
        LLMPreset(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                  modelHint: "deepseek/deepseek-chat", needsKey: true, keyPage: "https://openrouter.ai/keys"),
        LLMPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                  modelHint: "gpt-4o-mini", needsKey: true, keyPage: "https://platform.openai.com/api-keys"),
        LLMPreset(id: "ollama", name: L10n.text("本机 Ollama"), baseURL: "http://127.0.0.1:11434/v1",
                  modelHint: "qwen2.5:7b", needsKey: false, keyPage: "https://ollama.com"),
        LLMPreset(id: "custom", name: L10n.text("自定义（OpenAI 兼容）"), baseURL: "",
                  modelHint: L10n.text("模型 ID"), needsKey: true, keyPage: ""),
    ]

    static func find(_ id: String) -> LLMPreset { all.first { $0.id == id } ?? all[0] }

    /// Whether a base URL may carry a key: https, or http to this Mac only.
    static func isAllowedBaseURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
    }
}

/// Credential access through TypeLeast's Touch ID vault or the legacy login Keychain.
enum KeychainStore {
    static let service = "TypeLeast.llm-api-key"
    /// OSStatus of the last write, for diagnostics and for telling the user why saving failed.
    private(set) static var lastStatus: OSStatus = errSecSuccess
    /// Screenshot/test seam: when set, the Keychain is never touched.
    static var stub: [String: String]? { didSet { invalidatePresence() } }
    /// Tests can count attribute queries without touching real credentials.
    static var presenceQueryOverride: ((String) -> Bool)?
    private static var presence: [String: Bool] = [:]

    static var requiresUnlock: Bool {
        stub == nil && TouchIDVault.shared.isConfigured && !TouchIDVault.shared.isUnlocked
    }

    /// Call on app activation so edits in Keychain Access are reflected. Values
    /// already authorized in this process remain separate from display metadata.
    static func invalidatePresence() { lock.withLock { presence.removeAll() } }

    private static var cache: [String: String] = [:]
    private static let lock = NSLock()
    // A login-keychain ACL can open a SecurityAgent password dialog independently
    // of LocalAuthentication. Keep every legacy operation noninteractive.
    private static var promptPolicyStatus: OSStatus { TouchIDVault.noPasswordUI }

    static func read(account: String) -> String? { readSilently(account: account) }

    /// A fallback may use only a key already read in this process; never open Keychain here.
    static func cached(account: String) -> String? {
        if let stub = stub { return stub[account] }
        if TouchIDVault.shared.isConfigured { return TouchIDVault.shared.read(account) }
        return lock.withLock { cache[account] }
    }

    /// Access already-authorized items without showing a system authentication prompt.
    static func readSilently(account: String) -> String? {
        if let value = cached(account: account) { return value }
        guard stub == nil, !TouchIDVault.shared.isConfigured, promptPolicyStatus == errSecSuccess else { return nil }
        let (status, result) = legacyRead(account: account)
        guard status == errSecSuccess, let value = result else { return nil }
        lock.withLock { cache[account] = value; presence[account] = true }
        return value
    }

    private static func legacyRead(account: String, allowInteraction: Bool = false) -> (OSStatus, String?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, (item as? Data).flatMap { String(data: $0, encoding: .utf8) })
    }

    /// Whether an item exists, from its attributes only: never opens a password dialog.
    static func exists(account: String) -> Bool {
        if stub == nil, TouchIDVault.shared.isConfigured { return TouchIDVault.shared.read(account) != nil }
        if let hit = lock.withLock({ presence[account] }) { return hit }
        let found: Bool
        if let query = presenceQueryOverride { found = query(account) }
        else if let stub { found = stub[account] != nil }
        else { found = queryPresence(account: account) }
        lock.withLock { presence[account] = found }
        return found
    }

    private static func queryPresence(account: String) -> Bool {
        guard promptPolicyStatus == errSecSuccess else { return false }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// The accounts this app keeps (attributes only, no dialog).
    static var stubAccountError = false
    static func accounts() -> [String]? {
        if let stub = stub { return stubAccountError ? nil : stub.keys.sorted() }
        if TouchIDVault.shared.isConfigured { return TouchIDVault.shared.accounts() }
        guard promptPolicyStatus == errSecSuccess else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let list = items as? [[String: Any]] else { return nil }
        let accounts = list.compactMap { $0[kSecAttrAccount as String] as? String }
        guard accounts.count == list.count else { return nil }
        return Array(Set(accounts)).sorted()
    }

    /// Test seam: accounts the stub refuses to create, like a locked Keychain.
    static var stubRefuses: Set<String> = []

    /// Add an item only when none exists (never replaces one that this build cannot read).
    static func create(_ value: String, account: String) -> Bool {
        if stub != nil {
            guard stub?[account] == nil, !stubRefuses.contains(account) else { return false }
            stub?[account] = value
            return true
        }
        if TouchIDVault.shared.isConfigured {
            lastStatus = TouchIDVault.shared.write(value, account: account, onlyIfAbsent: true)
            return lastStatus == errSecSuccess
        }
        guard promptPolicyStatus == errSecSuccess else { lastStatus = promptPolicyStatus; return false }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        lastStatus = SecItemAdd(item as CFDictionary, nil)
        if lastStatus == errSecSuccess { lock.withLock { cache[account] = value; presence[account] = true } }
        return lastStatus == errSecSuccess
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        if stub != nil {
            guard !stubRefuses.contains(account) else { return false }
            stub?[account] = value.isEmpty ? nil : value
            return true
        }
        if TouchIDVault.shared.isConfigured {
            lastStatus = TouchIDVault.shared.write(value.isEmpty ? nil : value, account: account)
            return lastStatus == errSecSuccess
        }
        guard promptPolicyStatus == errSecSuccess else { lastStatus = promptPolicyStatus; return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            lastStatus = SecItemDelete(base as CFDictionary)
            guard lastStatus == errSecSuccess || lastStatus == errSecItemNotFound else { return false }
            lock.withLock { cache[account] = nil; presence[account] = false }
            return true
        }
        // Update in place: a refused/failed save must leave the working key intact.
        let changes = [kSecValueData as String: Data(value.utf8)]
        lastStatus = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if lastStatus == errSecItemNotFound { return create(value, account: account) }
        if lastStatus == errSecSuccess { lock.withLock { cache[account] = value; presence[account] = true } }
        return lastStatus == errSecSuccess
    }

    /// Delete an item this build can reach; false when it is not there or not ours to delete.
    @discardableResult
    static func remove(account: String) -> Bool {
        if stub != nil { return stub?.removeValue(forKey: account) != nil }
        if TouchIDVault.shared.isConfigured {
            guard TouchIDVault.shared.read(account) != nil else { return false }
            return TouchIDVault.shared.write(nil, account: account) == errSecSuccess
        }
        guard promptPolicyStatus == errSecSuccess else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        lock.withLock { cache[account] = nil; presence[account] = nil }
        return SecItemDelete(base as CFDictionary) == errSecSuccess
    }

    private struct LegacyMigrationItems {
        var values: [String: String] = [:]
        var unreadable: [String] = []
    }

    /// This diagnostics mode produces only counts and never opens a Keychain dialog.
    static func reportTouchIDMigrationReadiness() throws {
        let items = try legacyMigrationItems()
        print("Readable credentials: \(items.values.count). Denied credentials: \(items.unreadable.count).")
        print("History key readable: \(items.values[HistorySeal.account] != nil).")
        print("Active cleanup key readable: \(items.values[Settings.shared.llmPresetID] != nil).")
    }

    /// Invoked in the standalone migration process, which alone may allow legacy UI.
    static func migrateToTouchID(authorizationLimit: Int) async throws -> Int {
        var items = try legacyMigrationItems()
        if let historyIndex = items.unreadable.firstIndex(of: HistorySeal.account) {
            items.unreadable.swapAt(0, historyIndex)
        }
        var authorizations = 0
        for account in items.unreadable {
            var (status, value) = legacyRead(account: account)
            if value == nil && authorizations < authorizationLimit {
                authorizations += 1
                print("Requesting legacy authorization for item \(authorizations).")
                (status, value) = legacyReadWithConsent(account: account)
            }
            guard status == errSecSuccess, let value else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status == errSecSuccess ? errSecDecode : status))
            }
            items.values[account] = value
        }
        if let historyKey = items.values[HistorySeal.account] {
            guard Data(base64Encoded: historyKey)?.count == 32 else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
            }
        }
        try await TouchIDVault.shared.provision(values: items.values)
        return items.values.count
    }

    private static func legacyMigrationItems() throws -> LegacyMigrationItems {
        guard !TouchIDVault.shared.isConfigured, let accounts = accounts() else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecNotAvailable))
        }
        var items = LegacyMigrationItems()
        for account in accounts {
            let (_, value) = legacyRead(account: account)
            if let value { items.values[account] = value } else { items.unreadable.append(account) }
        }
        return items
    }

    private static func legacyReadWithConsent(account: String) -> (OSStatus, String?) {
        let status = SecKeychainSetUserInteractionAllowed(true)
        guard status == errSecSuccess else { return (status, nil) }
        defer { SecKeychainSetUserInteractionAllowed(false) }
        return legacyRead(account: account, allowInteraction: true)
    }

}

/// Compatibility with older updaters. Account-name handoffs are acknowledged
/// without reading Keychain items; credentials already persist across replacement.
/// Value-bearing payloads from much older versions can still restore missing items.
enum KeychainHandoff {
    static let receiveFlag = "--receive-keychain-handoff"
    /// Test seam: where the old hand-over file is looked for.
    static var fileOverride: URL?
    static var fileURL: URL {
        fileOverride ?? URL(fileURLWithPath: ServiceClient.stateDirectory).appendingPathComponent("keychain-handoff.json")
    }

    /// Older updaters wait for this response before replacing the app. Do not
    /// request credential access from their temporary copy of the new app.
    static func receive(data: Data = FileHandle.standardInput.readDataToEndOfFile()) -> Int32 {
        guard data.count <= 1 << 20 else { return 2 }
        if let accounts = try? JSONDecoder().decode([String].self, from: data) {
            guard accounts.count <= 128 else { return 2 }
            return 0
        }
        guard let legacy = try? JSONDecoder().decode([String: String].self, from: data),
              legacy.count <= 128 else { return 2 }
        var failed = false
        for (account, value) in legacy where !value.isEmpty {
            if KeychainStore.exists(account: account) { continue }
            if !KeychainStore.create(value, account: account) { failed = true }
        }
        return failed ? 1 : 0
    }

    /// Whether an old hand-over file still holds `account` (it could not be recreated yet).
    static func pending(account: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return false }
        return !(values[account] ?? "").isEmpty
    }

    /// Run first thing at launch: recreate the items an older version handed over in a file.
    static func restoreIfPresent(file: URL = fileURL) {
        guard let data = FileManager.default.contents(atPath: file.path) else { return }
        guard let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            wipe(file, bytes: data.count)
            return
        }
        var notRecreated = 0
        for (account, value) in values where !value.isEmpty {
            // An item left behind (the old copy could not delete it) stays as it is.
            if KeychainStore.exists(account: account) { continue }
            if !KeychainStore.create(value, account: account) {
                notRecreated += 1
                DiagnosticsLog.write("keychain.handoff.fail", ["status": String(KeychainStore.lastStatus)])
            }
        }
        // Wiping the file now would lose a key for good; it is tried again at the next launch.
        if notRecreated == 0 { wipe(file, bytes: data.count) }
    }

    /// Overwrite before deleting, so the keys are not left in a free block either.
    private static func wipe(_ file: URL, bytes: Int) {
        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.write(contentsOf: Data(count: bytes))
            try? handle.synchronize()
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: file)
    }
}

extension Settings {
    /// Allow configured providers to handle a dictation if the active provider is unavailable.
    var automaticProviderFallback: Bool {
        get { (UserDefaults.standard.object(forKey: "llm.automaticProviderFallback") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "llm.automaticProviderFallback"); notifyChanged() }
    }

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

    /// Whether cleanup is set up, for display: checks that a key exists without reading it,
    /// so drawing the window never opens a Keychain dialog.
    var llmRouteReady: Bool {
        let preset = LLMPreset.find(llmPresetID)
        guard !llmModel.isEmpty, LLMPreset.isAllowedBaseURL(llmBaseURL) else { return false }
        return !preset.needsKey || KeychainStore.exists(account: llmPresetID)
    }

    /// The route to send with a dictation, or nil when it is not complete yet
    /// (then the service inserts the tidied transcript, reason no-api-key).
    var activeLLMRoute: LLMRoute? { silentLLMRoute }

    var cleanupThinkingCapability: LLMThinkingCapability? {
        LLMThinkingCache().capabilities(for: llmBaseURL)[llmModel.lowercased()]
    }

    private var cleanupThinkingKey: String {
        let endpoint = LLMThinkingCache.endpoint(llmBaseURL)
        let defaultEndpoint = LLMThinkingCache.endpoint(LLMPreset.find(llmPresetID).baseURL)
        let suffix = endpoint == defaultEndpoint ? "" : "." + endpoint
        return "llm.cleanupThinking." + llmPresetID + "." + llmModel.lowercased() + suffix
    }

    var cleanupThinking: Bool {
        get { UserDefaults.standard.bool(forKey: cleanupThinkingKey) }
        set { UserDefaults.standard.set(newValue, forKey: cleanupThinkingKey); notifyChanged() }
    }

    var cleanupReasoningEffort: String {
        get {
            let saved = UserDefaults.standard.string(forKey: cleanupThinkingKey + ".effort")
            if let saved, cleanupThinkingCapability?.effortLevels?.contains(saved) == true { return saved }
            return ""
        }
        set { UserDefaults.standard.set(newValue, forKey: cleanupThinkingKey + ".effort"); notifyChanged() }
    }

    var cleanupLLMRoute: LLMRoute? {
        activeLLMRoute.map { configuredCleanupRoute($0, full: true) }
    }

    /// Brief cleanup keeps the lightweight behavior, independent of the full cleanup control.
    func configuredCleanupRoute(_ original: LLMRoute, full: Bool) -> LLMRoute {
        var route = original
        let capability = LLMThinkingCache().capabilities(for: route.baseURL)[route.model.lowercased()]
        route.thinkingMode = .providerDefault
        route.thinkingControl = capability?.control
        if capability?.mode == .toggle {
            route.thinkingMode = full && cleanupThinking ? .enabled : .disabled
        }
        if full && (route.thinkingMode == .enabled || capability?.mode == .alwaysOn) {
            let effort = cleanupReasoningEffort
            if !effort.isEmpty { route.reasoningEffort = effort }
        }
        return route
    }

    /// Background work must not open a password dialog.
    var silentLLMRoute: LLMRoute? {
        savedLLMRoute(presetID: llmPresetID, model: llmModel)
    }

    func savedLLMRoute(presetID: String, model: String) -> LLMRoute? {
        let preset = LLMPreset.find(presetID)
        let base = UserDefaults.standard.string(forKey: "llm.baseURL." + presetID) ?? preset.baseURL
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, LLMPreset.isAllowedBaseURL(base) else { return nil }
        let key = KeychainStore.readSilently(account: presetID) ?? ""
        guard !preset.needsKey || !key.isEmpty else { return nil }
        return LLMRoute(baseURL: base, model: name, apiKey: key)
    }

    /// Saved keys are used if macOS permits access without an authentication prompt.
    var hasConfiguredBackupProviders: Bool {
        guard automaticProviderFallback else { return false }
        return !backupPresets(excludingSelected: true).isEmpty
    }

    private func backupPresets(excludingSelected: Bool) -> [LLMPreset] {
        guard automaticProviderFallback else { return [] }
        let selected = llmPresetID
        return LLMPreset.all.filter { preset in
            guard (!excludingSelected || preset.id != selected), preset.needsKey,
                  let model = UserDefaults.standard.string(forKey: "llm.model." + preset.id)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return false }
            let base = (UserDefaults.standard.string(forKey: "llm.baseURL." + preset.id) ?? preset.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
            return LLMPreset.isAllowedBaseURL(base) && !(KeychainStore.readSilently(account: preset.id) ?? "").isEmpty
        }
    }

    /// No authentication prompt is allowed while selecting backup routes.
    func backupLLMRoutes(excluding current: LLMRoute?) -> [LLMRoute] {
        backupPresets(excludingSelected: false).compactMap { preset in
            guard let model = UserDefaults.standard.string(forKey: "llm.model." + preset.id)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty,
                  (UserDefaults.standard.string(forKey: "llm.baseURL." + preset.id) ?? preset.baseURL).trimmingCharacters(in: .whitespacesAndNewlines) != current?.baseURL || model != current?.model else { return nil }
            let base = (UserDefaults.standard.string(forKey: "llm.baseURL." + preset.id) ?? preset.baseURL).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key = KeychainStore.readSilently(account: preset.id), !key.isEmpty else { return nil }
            return LLMRoute(baseURL: base, model: model, apiKey: key)
        }
    }

    func notifyChanged() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}

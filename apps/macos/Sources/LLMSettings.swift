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

/// Generic-password items in the login Keychain, one per provider preset.
enum KeychainStore {
    static let service = "TypeLeast.llm-api-key"
    /// OSStatus of the last write, for diagnostics and for telling the user why saving failed.
    private(set) static var lastStatus: OSStatus = errSecSuccess
    /// Screenshot/test seam: when set, the Keychain is never touched.
    static var stub: [String: String]?

    // Each item is read from the Keychain at most once per launch. macOS asks the user
    // whenever a build it has not seen reads an item, so reading on every redraw meant
    // one password dialog after another after each update.
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func read(account: String) -> String? {
        if let stub = stub { return stub[account] }
        if let hit = lock.withLock({ cache[account] }) { return hit }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let text = status == errSecSuccess ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        // A refused or cancelled dialog is remembered too: no second dialog this launch.
        lock.withLock { cache[account] = .some(text) }
        return text
    }

    /// A fallback may use only a key already read in this process; never open Keychain here.
    static func cached(account: String) -> String? {
        if let stub = stub { return stub[account] }
        return lock.withLock { cache[account] ?? nil }
    }

    /// Access already-authorized items without showing a system authentication prompt.
    static func readSilently(account: String) -> String? {
        if let value = cached(account: account) { return value }
        if stub != nil { return nil }
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
        lock.withLock { cache[account] = .some(value) }
        return value
    }

    /// Whether an item exists, from its attributes only: never opens a password dialog.
    static func exists(account: String) -> Bool {
        if let stub = stub { return stub[account] != nil }
        if let hit = lock.withLock({ cache[account] }) { return hit != nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// The accounts this app keeps (attributes only, no dialog).
    static var stubAccountError = false
    static func accounts() -> [String]? {
        if let stub = stub { return stubAccountError ? nil : stub.keys.sorted() }
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
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        lastStatus = SecItemAdd(item as CFDictionary, nil)
        if lastStatus == errSecSuccess { lock.withLock { cache[account] = .some(value) } }
        return lastStatus == errSecSuccess
    }

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        if stub != nil {
            guard !stubRefuses.contains(account) else { return false }
            stub?[account] = value.isEmpty ? nil : value
            return true
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            lastStatus = SecItemDelete(base as CFDictionary)
            guard lastStatus == errSecSuccess || lastStatus == errSecItemNotFound else { return false }
            lock.withLock { cache[account] = .some(nil) }
            return true
        }
        // Update in place: a refused/failed save must leave the working key intact.
        let changes = [kSecValueData as String: Data(value.utf8)]
        lastStatus = SecItemUpdate(base as CFDictionary, changes as CFDictionary)
        if lastStatus == errSecItemNotFound { return create(value, account: account) }
        if lastStatus == errSecSuccess { lock.withLock { cache[account] = .some(value) } }
        return lastStatus == errSecSuccess
    }

    /// Delete an item this build can reach; false when it is not there or not ours to delete.
    @discardableResult
    static func remove(account: String) -> Bool {
        if stub != nil { return stub?.removeValue(forKey: account) != nil }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        lock.withLock { cache[account] = nil }
        return SecItemDelete(base as CFDictionary) == errSecSuccess
    }

}

/// The verified replacement requests access to existing Keychain items before the
/// running app exits. New senders pass account names only and never remove the items.
/// macOS can request consent for the replacement; refusal stops installation.
/// The receiver also accepts the older value-bearing protocol so upgrades from old
/// versions can recover items already removed by their sender, without overwriting any.
///
/// Versions up to 1.17.2 handed the items over in an owner-only file instead. That file is
/// still restored once at launch, and it is kept, not wiped, while any item in it could not
/// be recreated: it is then the only copy of that key (the history key above all).
enum KeychainHandoff {
    static let receiveFlag = "--receive-keychain-handoff"
    /// Test seam: where the old hand-over file is looked for.
    static var fileOverride: URL?
    static var fileURL: URL {
        fileOverride ?? URL(fileURLWithPath: ServiceClient.stateDirectory).appendingPathComponent("keychain-handoff.json")
    }

    // MARK: the copy being replaced

    /// The code hash (hex) of a signed app or executable: what a `cdhash H"…"` requirement names.
    static func cdhash(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let unique = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether the running process `pid` is exactly the code with this code hash.
    static func process(_ pid: pid_t, hasCDHash cdhash: String) -> Bool {
        guard cdhash.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return false }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(cdhash)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// Ask the verified replacement to authorize access to existing items. Never delete
    /// an item to change its owner: a failed receiver must not destroy the history key.
    @discardableResult
    static func transfer(toExecutable executable: URL, cdhash: String) -> Bool {
        guard let accounts = KeychainStore.accounts() else { return false }
        guard !accounts.isEmpty else { return true }
        guard let data = try? JSONEncoder().encode(accounts) else { return false }
        let child = Process()
        child.executableURL = executable
        child.arguments = [receiveFlag]
        let input = Pipe()
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return false }
        guard process(child.processIdentifier, hasCDHash: cdhash) else {
            child.terminate(); child.waitUntilExit()
            return false
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
        } catch {
            child.terminate(); child.waitUntilExit()
            return false
        }
        let deadline = Date().addingTimeInterval(120)
        while child.isRunning && Date() < deadline { usleep(20_000) }
        if child.isRunning { child.terminate(); child.waitUntilExit() }
        return child.terminationReason == .exit && child.terminationStatus == 0
    }

    /// New senders pass account names. Legacy senders already removed their items:
    /// restore only missing ones with add-only writes, never replace existing values.
    static func receive(data: Data = FileHandle.standardInput.readDataToEndOfFile()) -> Int32 {
        guard data.count <= 1 << 20 else { return 2 }
        if let accounts = try? JSONDecoder().decode([String].self, from: data) {
            guard accounts.count <= 128 else { return 2 }
            for account in accounts {
                guard KeychainStore.read(account: account) != nil else { return 1 }
            }
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
    var activeLLMRoute: LLMRoute? {
        let preset = LLMPreset.find(llmPresetID)
        let key = llmAPIKey
        guard !llmModel.isEmpty, LLMPreset.isAllowedBaseURL(llmBaseURL), !(preset.needsKey && key.isEmpty) else { return nil }
        return LLMRoute(baseURL: llmBaseURL, model: llmModel, apiKey: key)
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

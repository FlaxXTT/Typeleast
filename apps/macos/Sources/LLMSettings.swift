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
    static func accounts() -> [String] {
        if let stub = stub { return stub.keys.sorted() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return Array(Set(list.compactMap { $0[kSecAttrAccount as String] as? String })).sorted()
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
            stub?[account] = value.isEmpty ? nil : value
            return true
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        lock.withLock { cache[account] = .some(nil) }
        guard !value.isEmpty else { return true }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        lastStatus = SecItemAdd(item as CFDictionary, nil)
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

    /// Test seam: forget what was read.
    static func resetCache() { lock.withLock { cache = [:] } }
}

/// In-app updates without password dialogs. macOS lets only the build that created a
/// Keychain item (identified by its code hash when, as here, there is no Apple team ID)
/// read it without asking; every update is a new build. So the running copy, which can
/// read its items, hands them straight to the next one: just before it quits, it starts the
/// new copy's own executable with --receive-keychain-handoff, checks by code hash that the
/// process is the code it has just verified and signed, deletes its items and writes them
/// to that process's standard input; the new copy creates them again as its own. Nothing
/// is written to disk, where any program of this user could read it. If anything fails,
/// the items are put back as they were, and the new copy asks once.
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

    /// Hand every item to the new copy's `executable`, whose code hash was taken when it was
    /// signed. Returns true when the new copy now owns them all.
    @discardableResult
    static func transfer(toExecutable executable: URL, cdhash: String) -> Bool {
        var values: [String: String] = [:]
        for account in KeychainStore.accounts() {
            guard let value = KeychainStore.read(account: account) else { return false }
            values[account] = value
        }
        guard !values.isEmpty else { return true }
        guard let data = try? JSONEncoder().encode(values) else { return false }
        let child = Process()
        child.executableURL = executable
        child.arguments = [receiveFlag]
        let input = Pipe()
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return false }
        // Only the code that was downloaded, verified and signed gets the keys, not anything
        // put in its place since.
        guard process(child.processIdentifier, hasCDHash: cdhash) else {
            child.terminate()
            child.waitUntilExit()
            DiagnosticsLog.write("keychain.handoff.fail", ["code": "identity"])
            return false
        }
        for account in values.keys { KeychainStore.remove(account: account) }
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(20)
        while child.isRunning && Date() < deadline { usleep(20_000) }
        if child.isRunning { child.terminate(); child.waitUntilExit() }
        let received = child.terminationReason == .exit && child.terminationStatus == 0
        // Whatever the new copy did not take is put back as this copy's own (create never replaces).
        var lost = 0
        for (account, value) in values where !KeychainStore.exists(account: account) {
            if !KeychainStore.create(value, account: account) { lost += 1 }
        }
        if !received || lost > 0 { DiagnosticsLog.write("keychain.handoff.fail", ["code": received ? "restore" : "transfer", "status": String(lost)]) }
        return received && lost == 0
    }

    // MARK: the new copy

    /// `TypeLeast --receive-keychain-handoff`, started by the copy being replaced: create the
    /// items written to standard input as this build's own. Exit status 0 when all exist.
    static func receive() -> Int32 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 1 << 20, let values = try? JSONDecoder().decode([String: String].self, from: data) else { return 2 }
        var failed = 0
        for (account, value) in values where !value.isEmpty {
            if KeychainStore.exists(account: account) { continue }
            if !KeychainStore.create(value, account: account) { failed += 1 }
        }
        return failed == 0 ? 0 : 1
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
            handle.write(Data(count: bytes))
            try? handle.synchronize()
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: file)
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

    func notifyChanged() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}

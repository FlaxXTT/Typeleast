import CryptoKit
import Foundation

// ServiceClient.swift - HTTP client for the TypeLeast local service
// (service/ in this repository: local speech recognition plus cleanup with the
// user's own model). The app starts that service itself (ServiceManager.swift).
// Foundation only: shared by the app target and the test-harness target.

// MARK: - Errors

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ServiceError: Error, CustomStringConvertible, Equatable {
    case noToken(String)
    case transport(String)
    case http(status: Int, code: String?, message: String)
    case decoding(String)
    /// Something answers on the service's port but could not prove it is the service this app started.
    case untrusted

    var description: String {
        switch self {
        case .noToken(let p): return "token unavailable: " + p
        case .transport(let m): return "service unreachable: " + m
        case .http(let s, let c, let m): return "HTTP " + String(s) + " " + (c ?? "") + " " + m
        case .decoding(let m): return "bad response: " + m
        case .untrusted: return "the local service could not prove its identity"
        }
    }

    /// Frozen contract: /health non-200 or any transport error means "service not running".
    var serviceUnavailable: Bool {
        switch self {
        case .noToken, .transport, .untrusted: return true
        case .http(let s, _, _): return s == 401 || s == 403 || s == 404 || s >= 500
        case .decoding: return false
        }
    }

    var statusCode: Int? {
        if case .http(let s, _, _) = self { return s }
        return nil
    }

    var isUnauthorized: Bool { statusCode == 401 }
}

@inline(__always)
func lenient<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ t: T.Type, _ k: K) -> T? {
    (try? c.decodeIfPresent(t, forKey: k)) ?? nil
}

struct SpeechModelOperation: Codable, Equatable {
    var modelId: String
    var phase: String
    var received: Double
    var total: Double
    var error: String?
    var running: Bool { ["downloading", "waiting", "loading"].contains(phase) }
    var problem: String {
        switch error {
        case "checksum-mismatch": return L10n.text("文件校验失败，请重新下载。")
        case "download-failed": return L10n.text("下载失败。请检查网络或镜像后重试。")
        case "model-not-installed": return L10n.text("模型文件不完整，请重新下载。")
        case "model-load-failed": return L10n.text("模型加载失败。请重试或换一个模型。")
        case "ENOSPC": return L10n.text("磁盘空间不足。请释放空间后重试。")
        case "EACCES", "EPERM": return L10n.text("无法保存模型设置。请检查文件权限。")
        default: return L10n.text("模型操作失败，请重试。当前模型保留。")
        }
    }
}
struct SpeechModelOption: Codable, Identifiable {
    var id: String
    var name: String
    var modelBytes: Double
    var sourceUrl: String
    var licenseUrl: String
    var canSetLanguage: Bool
    var installed: Bool
    var family: String?
    var precision: String?
    var category: String?
    var registered: Bool?
    var downloadable: Bool?
}
struct SpeechModelCatalog: Codable {
    var activeModelId: String
    var models: [SpeechModelOption]
    var operation: SpeechModelOperation?
    var notice: String?
}

struct SpeechStatus: Codable, Equatable {
    var providerId: String?
    var modelId: String?
    var modelName: String?
    var displayName: String { (modelName?.isEmpty == false ? modelName : nil) ?? L10n.text("未选择语音模型") }
    var canSetLanguage: Bool?
    var languages: [String]?
    var operation: SpeechModelOperation?
    var notice: String?
    var ready: Bool?
    /// loading | ready | missing-model | downloading | error
    var phase: String?
    var error: String?
    /// Bytes so far while the models download.
    var downloadReceived: Double?
    var downloadTotal: Double?
    /// Size of the whole model set, for "下载语音模型（241 MB）".
    var modelBytes: Double?

    enum CodingKeys: String, CodingKey { case providerId, ready, phase, error, download, modelBytes, modelId, modelName, canSetLanguage, operation, notice, languages }
    enum DownloadKeys: String, CodingKey { case received, total }
    init() {}
    init(providerId: String?, ready: Bool?, phase: String?) {
        self.providerId = providerId
        self.ready = ready
        self.phase = phase
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerId = lenient(c, String.self, .providerId)
        modelId = lenient(c, String.self, .modelId)
        modelName = lenient(c, String.self, .modelName)
        canSetLanguage = lenient(c, Bool.self, .canSetLanguage)
        languages = lenient(c, [String].self, .languages)
        operation = lenient(c, SpeechModelOperation.self, .operation)
        notice = lenient(c, String.self, .notice)
        ready = lenient(c, Bool.self, .ready)
        phase = lenient(c, String.self, .phase)
        error = lenient(c, String.self, .error)
        modelBytes = lenient(c, Double.self, .modelBytes)
        if let d = try? c.nestedContainer(keyedBy: DownloadKeys.self, forKey: .download) {
            downloadReceived = lenient(d, Double.self, .received)
            downloadTotal = lenient(d, Double.self, .total)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(providerId, forKey: .providerId)
        try c.encodeIfPresent(modelId, forKey: .modelId)
        try c.encodeIfPresent(modelName, forKey: .modelName)
        try c.encodeIfPresent(canSetLanguage, forKey: .canSetLanguage)
        try c.encodeIfPresent(languages, forKey: .languages)
        try c.encodeIfPresent(operation, forKey: .operation)
        try c.encodeIfPresent(notice, forKey: .notice)
        try c.encodeIfPresent(ready, forKey: .ready)
        try c.encodeIfPresent(phase, forKey: .phase)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(modelBytes, forKey: .modelBytes)
    }

    var modelsMissing: Bool { phase == "missing-model" }
    var downloading: Bool { phase == "downloading" }
    /// 0...1 while downloading, else nil.
    var downloadFraction: Double? {
        guard downloading, let r = downloadReceived, let t = downloadTotal, t > 0 else { return nil }
        return min(1, max(0, r / t))
    }

    var summary: String {
        let p = providerId ?? "?"
        let r = (ready ?? false) ? "ready" : "not-ready"
        if let ph = phase, !ph.isEmpty { return p + " / " + r + " / " + ph }
        return p + " / " + r
    }
}

struct HealthResponse: Codable, Equatable {
    var ok: Bool = false
    /// "typeleast" for this project's service.
    var service: String?
    var version: String?
    var provider: String?
    var model: String?
    var speech: SpeechStatus?
    var pid: Int?

    enum CodingKeys: String, CodingKey { case ok, service, version, provider, model, speech, pid }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = lenient(c, Bool.self, .ok) ?? false
        service = lenient(c, String.self, .service)
        version = lenient(c, String.self, .version)
        provider = lenient(c, String.self, .provider)
        model = lenient(c, String.self, .model)
        speech = lenient(c, SpeechStatus.self, .speech)
        pid = lenient(c, Int.self, .pid)
    }

    var speechReady: Bool { speech?.ready ?? false }
    var speechPhase: String { speech?.phase ?? "" }
}

// MARK: - Response models (frozen contract)

/// ms is either a number (history) or an object {transcribe,polish,total} (dictate).
struct MSBreakdown: Codable, Equatable {
    var transcribe: Double?
    var polish: Double?
    var total: Double?
    var raw: [String: Double]?

    enum CodingKeys: String, CodingKey { case transcribe, polish, total }
    init() {}
    init(transcribe: Double?, polish: Double?, total: Double?) {
        self.transcribe = transcribe
        self.polish = polish
        self.total = total
    }
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let n = try? single.decode(Double.self) {
            total = n
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transcribe = lenient(c, Double.self, .transcribe)
        polish = lenient(c, Double.self, .polish)
        total = lenient(c, Double.self, .total)
        if let dyn = try? decoder.container(keyedBy: DynKey.self) {
            var m: [String: Double] = [:]
            for k in dyn.allKeys {
                if let v = try? dyn.decode(Double.self, forKey: k) { m[k.stringValue] = v }
            }
            if !m.isEmpty { raw = m }
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(transcribe, forKey: .transcribe)
        try c.encodeIfPresent(polish, forKey: .polish)
        try c.encodeIfPresent(total, forKey: .total)
    }
    var summary: String {
        guard let t = total else { return "-" }
        return String(format: "%.0fms", t)
    }
}

struct DynKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

/// Prompt Beta: questions to answer before the prompt is written, or what the review did.
struct BetaInfo: Codable, Equatable {
    var sessionId: String?
    var questions: [String]?
    var confirmed: [String]?
    var round: Int?
    var ready: Bool?
    var notice: String?
    var issues: Int?
    var patched: Bool?
}

/// Optional service-computed dictionary suggestion. Older services omit the field.
struct SuggestionCandidate: Codable, Equatable {
    let word: String
    let heardAs: String
    enum CodingKeys: String, CodingKey { case word, heardAs }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        word = (try? c?.decode(String.self, forKey: .word)) ?? ""
        heardAs = (try? c?.decode(String.self, forKey: .heardAs)) ?? ""
    }
    var isValid: Bool {
        WordSuggestions.validCandidate(word: word, heardAs: heardAs)
    }
}

struct NameClarification: Codable, Equatable {
    let question: String
    let evidence: String
    var target: String?
    var kind: String?
    var markerId: String?
}

struct ExplanationReceipt: Codable, Equatable {
    let used: Bool
    let segments: Int
    let markerId: String
}

struct DictateResponse: Codable, Equatable {
    var requestId: String?
    var text: String = ""
    var raw: String = ""
    var fallback: Bool = false
    var fallbackReason: String?
    var model: String?
    var provider: String?
    var ms: MSBreakdown?
    var contextOnly: Bool = false
    var explanation: ExplanationReceipt?
    var clarification: NameClarification?
    var beta: BetaInfo?
    var suggestions: [SuggestionCandidate] = []
    /// 翻译模式: the target language the text was written in.
    var translated: String?
    /// Prompt Beta asked questions: nothing to insert yet.
    var betaWaiting: Bool { beta?.sessionId?.isEmpty == false }
    var betaQuestions: [String] { beta?.sessionId == nil ? [] : (beta?.questions ?? []) }

    enum CodingKeys: String, CodingKey {
        case requestId, text, raw, fallback, fallbackReason, model, provider, ms, beta, translated, suggestions, clarification, contextOnly, explanation
    }
    init() {}
    init(text: String, raw: String, fallback: Bool) {
        self.text = text
        self.raw = raw
        self.fallback = fallback
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = lenient(c, String.self, .requestId)
        text = lenient(c, String.self, .text) ?? ""
        raw = lenient(c, String.self, .raw) ?? ""
        fallback = lenient(c, Bool.self, .fallback) ?? false
        fallbackReason = lenient(c, String.self, .fallbackReason)
        model = lenient(c, String.self, .model)
        provider = lenient(c, String.self, .provider)
        ms = lenient(c, MSBreakdown.self, .ms)
        beta = lenient(c, BetaInfo.self, .beta)
        clarification = lenient(c, NameClarification.self, .clarification)
        contextOnly = lenient(c, Bool.self, .contextOnly) ?? false
        explanation = lenient(c, ExplanationReceipt.self, .explanation)
        translated = lenient(c, String.self, .translated)
        suggestions = Array((lenient(c, [SuggestionCandidate].self, .suggestions) ?? []).prefix(8)).filter(\.isValid)
    }

    /// When fallback is true the service has ALREADY substituted the raw transcript into
    /// "text". Guard anyway against a service that only flips the flag.
    var insertableText: String {
        if betaWaiting || clarification != nil || contextOnly { return "" }
        if !text.isEmpty { return text }
        return raw
    }
}

struct ApiErrorBody: Codable, Equatable {
    var error: String?
    var code: String?
    enum CodingKeys: String, CodingKey { case error, code }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        error = lenient(c, String.self, .error)
        code = lenient(c, String.self, .code)
    }
}

// MARK: - Client

final class ServiceClient {
    static let shared = ServiceClient()

    /// The service's state folder: ~/Library/Application Support/TypeLeast
    /// (TYPELEAST_HOME overrides it, as it does for the service).
    static var stateDirectory: String {
        if let override = ProcessInfo.processInfo.environment["TYPELEAST_HOME"], !override.isEmpty { return override }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("TypeLeast", isDirectory: true).path
    }

    /// Base URL of the local service.
    ///
    /// The service binds an **OS-assigned port that changes on every start**. The
    /// app learns it from the service's ready line (ServiceManager calls `usePort`),
    /// and otherwise from the runtime file below; `healthSync()` re-reads the file
    /// once if a request fails. Until a port is known this points at port 1,
    /// where nothing listens.
    var baseURL: URL = URL(string: "http://127.0.0.1:1")!

    /// Descriptor published by the service: `{ port, pid, version, startedAt }`.
    var runtimePath: String = (ServiceClient.stateDirectory as NSString).appendingPathComponent("runtime.json")

    /// Last port discovery outcome, for diagnostics in the menu.
    private(set) var lastDiscoveredPort: Int?
    var tokenPath: String = (ServiceClient.stateDirectory as NSString).appendingPathComponent("api-token")
    /// Test seam: when set, the token file is not read.
    var tokenOverride: String?
    var healthTimeout: TimeInterval = 3
    var dictateTimeout: TimeInterval = 120

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldUsePipelining = false
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    private final class Box {
        var data: Data?
        var response: HTTPURLResponse?
        var error: Error?
    }

    // MARK: token (contract 1: read at request time)

    func loadToken() -> String? {
        if let t = tokenOverride {
            let v = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        guard let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) else { return nil }
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    func tokenFileExists() -> Bool { FileManager.default.fileExists(atPath: tokenPath) }

    // MARK: port discovery

    /// Port the service published, or nil when the file is absent or malformed.
    func publishedPort() -> Int? {
        guard let data = FileManager.default.contents(atPath: runtimePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["port"] as? Int,
              port > 0, port < 65_536
        else { return nil }
        return port
    }

    /// Point `baseURL` at the published port.
    /// @returns true when a port was published and applied.
    @discardableResult
    func discoverBaseURL() -> Bool {
        guard let port = publishedPort() else { return false }
        usePort(port)
        return true
    }

    /// Point `baseURL` at a port the service reported (its ready line).
    func usePort(_ port: Int) {
        guard port > 0, port < 65_536 else { return }
        lastDiscoveredPort = port
        baseURL = URL(string: "http://127.0.0.1:" + String(port))!
    }

    /// The service this app started has stopped: point nowhere and forget that its port
    /// proved itself. Another program may take that port before the service is back, so
    /// whatever answers there next must answer the challenge again.
    func invalidatePort() {
        proofLock.withLock {
            verifiedBase = nil
            baseURL = URL(string: "http://127.0.0.1:1")!
        }
    }

    /// Run one request, and on a transport failure re-read the published port and
    /// retry exactly once.
    ///
    /// A transport failure here almost always means "the service restarted and got
    /// a new port", so one rediscovery recovers without restarting the app.
    /// A decoding or HTTP error is a real answer and is not retried.
    private func withPortRetry<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as ServiceError {
            guard case .transport = error else { throw error }
            let before = baseURL
            guard discoverBaseURL(), baseURL != before else { throw error }
            return try body()
        }
    }

    // MARK: plumbing

    private func makeRequest(path: String, method: String, token: String,
                             headers: [String: String] = [:], body: Data? = nil,
                             timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw ServiceError.transport("bad url " + baseURL.absoluteString + path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = body {
            req.httpBody = b
            req.setValue(String(b.count), forHTTPHeaderField: "Content-Length")
        }
        return req
    }

    @discardableResult
    private func performSync(_ request: URLRequest, timeout: TimeInterval) throws -> (Data, HTTPURLResponse) {
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        let task = session.dataTask(with: request) { d, r, e in
            box.data = d
            box.response = r as? HTTPURLResponse
            box.error = e
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw ServiceError.transport("timeout after " + String(format: "%.0fs", timeout))
        }
        if let e = box.error { throw ServiceError.transport(e.localizedDescription) }
        guard let r = box.response else { throw ServiceError.transport("no response") }
        return (box.data ?? Data(), r)
    }

    private func httpError(_ resp: HTTPURLResponse, _ data: Data) -> ServiceError {
        let body = (try? JSONDecoder().decode(ApiErrorBody.self, from: data)) ?? ApiErrorBody()
        return .http(status: resp.statusCode, code: body.code, message: body.error ?? "")
    }

    /// Contract: token is read at request time; after a 401 re-read it once and retry.
    func withTokenRetry<T>(_ op: (String) throws -> T) throws -> T {
        guard let t1 = loadToken() else { throw ServiceError.noToken(tokenPath) }
        do {
            try ensureVerified(token: t1)
            return try op(t1)
        } catch let e as ServiceError where e.isUnauthorized {
            guard let t2 = loadToken(), t2 != t1 else { throw e }
            try ensureVerified(token: t2)
            return try op(t2)
        }
    }

    // MARK: service identity

    /// The secret this app gave the service it started (hex), or nil when it started none
    /// (tests, a service run by hand): then nothing is checked.
    var proofKey: String? {
        get { proofLock.withLock { proofKeyValue } }
        set { proofLock.withLock { proofKeyValue = newValue; verifiedBase = nil } }
    }
    private var proofKeyValue: String?
    private var verifiedBase: URL?
    private let proofLock = NSLock()

    /// HMAC-SHA256(key, challenge) in hex, as the service computes it.
    static func proof(key: String, challenge: String) -> String? {
        guard let keyData = Data(hexString: key) else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(challenge.utf8), using: SymmetricKey(data: keyData))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Before anything (an API key above all) goes to a port read from runtime.json, the
    /// listener there must answer a fresh challenge with the secret only our own child has.
    private func ensureVerified(token: String) throws {
        let (key, base, verified) = proofLock.withLock { (proofKeyValue, baseURL, verifiedBase) }
        guard let key, verified != base else { return }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ServiceError.untrusted }
        let challenge = bytes.map { String(format: "%02x", $0) }.joined()
        let req = try makeRequest(path: "/api/voice-polish/health", method: "GET", token: token,
                                  headers: ["x-typeleast-challenge": challenge], timeout: healthTimeout)
        let (data, resp) = try performSync(req, timeout: healthTimeout)
        guard resp.statusCode == 200 else { throw httpError(resp, data) }
        let answer = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["proof"] as? String
        guard let answer, let expected = ServiceClient.proof(key: key, challenge: challenge),
              answer.count == expected.count, answer.lowercased() == expected else { throw ServiceError.untrusted }
        proofLock.withLock { if baseURL == base { verifiedBase = base } }
    }

    // MARK: endpoints

    func healthSync() throws -> HealthResponse {
        try withPortRetry { try healthOnce() }
    }

    func healthOnce() throws -> HealthResponse {
        try withTokenRetry { token in
            let req = try makeRequest(path: "/api/voice-polish/health", method: "GET",
                                      token: token, timeout: healthTimeout)
            let (data, resp) = try performSync(req, timeout: healthTimeout)
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            do { return try JSONDecoder().decode(HealthResponse.self, from: data) }
            catch { throw ServiceError.decoding(String(describing: error)) }
        }
    }

    /// Upper bound for the encoded field context header; the service refuses anything larger.
    static let maxContextHeaderBytes = 8 * 1024

    /// Field context travels as base64(JSON) in `x-voice-context`: header values must be
    /// ASCII, and the WAV body stays a plain WAV so the frozen body contract is untouched.
    static func encodeContextHeader(_ json: Data?) -> String? {
        guard let json = json, !json.isEmpty else { return nil }
        let encoded = json.base64EncodedString()
        return encoded.utf8.count <= maxContextHeaderBytes ? encoded : nil
    }

    /// The user's own model route travels as base64(JSON) in `x-voice-llm`. It carries the
    /// API key, so it only ever goes to the local service on 127.0.0.1, which uses it
    /// for that one request and stores nothing.
    static func encodeRouteHeader(_ route: LLMRoute?) -> String? {
        guard let route = route, let json = try? JSONEncoder().encode(route) else { return nil }
        return json.base64EncodedString()
    }

    /// `dictionary`: the Dictionary page's entries ("word" or "heard=word"), sent with every
    /// dictation; the service keeps no copy, so there is nothing to keep in sync.
    func dictateSync(wav: Data, language: String, appBundleId: String, strength: String,
                     fieldContext: Data? = nil, llm: LLMRoute? = nil, betaSession: String? = nil,
                     translateTo: String? = nil, variants: String? = nil, dictionary: [String] = [],
                     localOnly: [String] = [], clarificationSource: String? = nil, clarificationEvidence: String? = nil, explanationMarkers: String? = nil, preferenceExamples: [[String: Any]] = []) throws -> DictateResponse {
        try withPortRetry { try dictateOnce(wav: wav, language: language, appBundleId: appBundleId,
                                            strength: strength, fieldContext: fieldContext,
                                            llm: llm, betaSession: betaSession,
                                            translateTo: translateTo, variants: variants, dictionary: dictionary, localOnly: localOnly, clarificationSource: clarificationSource, clarificationEvidence: clarificationEvidence, explanationMarkers: explanationMarkers, preferenceExamples: preferenceExamples) }
    }

    /// The body of /dictate: the dictionary as JSON (its length in x-voice-dictionary-bytes), then the WAV.
    /// Entries marked 「不发给模型」 go as {"local": entry}; the service never passes those to a model.
    static func dictateBody(wav: Data, dictionary: [String], localOnly: [String] = [], clarificationSource: String? = nil, clarificationEvidence: String? = nil, preferenceExamples: [[String: Any]] = []) -> (body: Data, dictionaryBytes: Int) {
        var entries: [Any] = dictionary + localOnly.map { ["local": $0] }
        if let source = clarificationSource { entries.append(["clarificationSource": source, "clarificationEvidence": clarificationEvidence ?? ""]) }
        var selected: [[String: Any]] = []
        for candidate in preferenceExamples.prefix(20) {
            let next = selected + [candidate]
            guard let block = try? JSONSerialization.data(withJSONObject: next), block.count <= 32768,
                  let trial = try? JSONSerialization.data(withJSONObject: entries + [["preferenceExamples": next]]), trial.count <= 256 * 1024 else { continue }
            selected = next
        }
        if !selected.isEmpty { entries.append(["preferenceExamples": selected]) }
        guard !entries.isEmpty, let json = try? JSONSerialization.data(withJSONObject: entries) else { return (wav, 0) }
        return (json + wav, json.count)
    }

    func polishSync(text: String, language: String, strength: String, llm: LLMRoute?, translateTo: String?, variants: String?, dictionary: [String], localOnly: [String], fieldContext: Data? = nil, explanationMarkers: String? = nil, preferenceExamples: [[String: Any]] = []) throws -> DictateResponse {
        try withPortRetry { try withTokenRetry { token in
            let entries: [Any] = dictionary + localOnly.map { ["local": $0] }
            var body: [String: Any] = ["text": text, "language": language, "strength": strength, "supportsClarification": true,
                                       "dictionary": entries]
            if let llm, let data = try? JSONEncoder().encode(llm), let route = try? JSONSerialization.jsonObject(with: data) { body["llm"] = route }
            if let fieldContext, let context = try? JSONSerialization.jsonObject(with: fieldContext) { body["fieldContext"] = context }
            if let translateTo { body["translateTo"] = translateTo }
            if let variants { body["variants"] = variants }
            if let explanationMarkers { body["explanationMarkers"] = explanationMarkers }
            var selected: [[String: Any]] = []
            for candidate in preferenceExamples.prefix(20) {
                let next = selected + [candidate]
                var trial = body; trial["preferenceExamples"] = next
                guard let data = try? JSONSerialization.data(withJSONObject: next), data.count <= 32768,
                      let payload = try? JSONSerialization.data(withJSONObject: trial), payload.count <= 256 * 1024 else { continue }
                selected = next
            }
            if !selected.isEmpty { body["preferenceExamples"] = selected }
            let req = try makeRequest(path: "/api/voice-polish/polish", method: "POST", token: token,
                                      headers: ["content-type": "application/json"], body: JSONSerialization.data(withJSONObject: body), timeout: dictateTimeout)
            let (data, response) = try performSync(req, timeout: dictateTimeout)
            guard response.statusCode == 200 else { throw httpError(response, data) }
            return try JSONDecoder().decode(DictateResponse.self, from: data)
        } }
    }

    /// Prompt Beta: write the prompt without answering the questions (skip), or forget them (cancel).
    func betaSync(sessionId: String, skip: Bool, appBundleId: String, llm: LLMRoute?,
                  variants: String? = nil) throws -> DictateResponse {
        try withPortRetry { try withTokenRetry { token in
            var headers = ["content-type": "application/json", "x-voice-app": appBundleId]
            if let variants { headers["x-voice-variants"] = variants }
            if let route = ServiceClient.encodeRouteHeader(llm) { headers["x-voice-llm"] = route }
            let body = try JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
            let path = "/api/voice-polish/prompts/beta/" + (skip ? "finish" : "cancel")
            let req = try makeRequest(path: path, method: "POST", token: token, headers: headers, body: body,
                                      timeout: max(dictateTimeout, 300))
            let (data, resp) = try performSync(req, timeout: max(dictateTimeout, 300))
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            if !skip { return DictateResponse() }
            do { return try JSONDecoder().decode(DictateResponse.self, from: data) }
            catch { throw ServiceError.decoding(String(describing: error)) }
        } }
    }

    private func dictateOnce(wav: Data, language: String, appBundleId: String, strength: String,
                             fieldContext: Data?, llm: LLMRoute?, betaSession: String?,
                             translateTo: String?, variants: String?, dictionary: [String], localOnly: [String], clarificationSource: String?, clarificationEvidence: String?, explanationMarkers: String?, preferenceExamples: [[String: Any]]) throws -> DictateResponse {
        try withTokenRetry { token in
            var headers: [String: String] = [
                "content-type": "audio/wav",
                "x-voice-language": language,
                "x-voice-app": appBundleId,
                "x-voice-strength": strength,
                "x-voice-clarification": "1",
            ]
            if let context = ServiceClient.encodeContextHeader(fieldContext) {
                headers["x-voice-context"] = context
            }
            if let route = ServiceClient.encodeRouteHeader(llm) {
                headers["x-voice-llm"] = route
            }
            if let explanationMarkers { headers["x-voice-explanation-markers"] = explanationMarkers }
            if let betaSession { headers["x-voice-beta-session"] = betaSession }
            if let translateTo { headers["x-voice-translate"] = translateTo }
            if let variants { headers["x-voice-variants"] = variants }
            // Prompt Beta makes up to four model calls in one request.
            let timeout = strength == "promptbeta" ? max(dictateTimeout, 300) : dictateTimeout
            let payload = ServiceClient.dictateBody(wav: wav, dictionary: dictionary, localOnly: localOnly, clarificationSource: clarificationSource, clarificationEvidence: clarificationEvidence, preferenceExamples: preferenceExamples)
            headers["x-voice-dictionary-bytes"] = String(payload.dictionaryBytes)
            let req = try makeRequest(path: "/api/voice-polish/dictate", method: "POST",
                                      token: token, headers: headers, body: payload.body, timeout: timeout)
            let (data, resp) = try performSync(req, timeout: timeout)
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            do { return try JSONDecoder().decode(DictateResponse.self, from: data) }
            catch { throw ServiceError.decoding(String(describing: error)) }
        }
    }

    /// Start the one-time model download (about 241 MB); progress shows in /health.
    func downloadModelsSync(endpoint: String? = nil) throws {
        try withPortRetry {
            try withTokenRetry { token in
                var object: [String: Any] = [:]
                // Always sent: an empty mirror means huggingface.co, so clearing it needs no service restart.
                object["endpoint"] = endpoint ?? ""
                let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
                let req = try makeRequest(path: "/api/voice-polish/models/download", method: "POST", token: token,
                                          headers: ["content-type": "application/json"], body: body, timeout: healthTimeout)
                let (data, resp) = try performSync(req, timeout: healthTimeout)
                guard resp.statusCode == 202 || resp.statusCode == 200 else { throw httpError(resp, data) }
            }
        }
    }

    func speechModelsSync() throws -> SpeechModelCatalog {
        try withPortRetry { try withTokenRetry { token in
            let req = try makeRequest(path: "/api/voice-polish/models", method: "GET", token: token, timeout: healthTimeout)
            let (data, response) = try performSync(req, timeout: healthTimeout)
            guard response.statusCode == 200 else { throw httpError(response, data) }
            return try JSONDecoder().decode(SpeechModelCatalog.self, from: data)
        } }
    }

    func localModelActionSync(path: String, body: [String: Any]) throws -> Data {
        try withPortRetry { try withTokenRetry { token in
            let payload = try JSONSerialization.data(withJSONObject: body)
            let request = try makeRequest(path: "/api/voice-polish/models/" + path, method: "POST", token: token,
                headers: ["content-type": "application/json"], body: payload, timeout: 60)
            let (data, response) = try performSync(request, timeout: 60)
            guard response.statusCode == 200 || response.statusCode == 202 else { throw httpError(response, data) }
            return data
        } }
    }

    func speechModelActionSync(id: String, download: Bool = false, cancel: Bool = false, endpoint: String = "") throws {
        try withPortRetry { try withTokenRetry { token in
            let path = cancel ? "/models/download/cancel" : download ? "/models/download" : "/models/active"
            let object: [String: Any] = ["modelId": id, "activate": true, "endpoint": endpoint]
            let body = try JSONSerialization.data(withJSONObject: object)
            let req = try makeRequest(path: "/api/voice-polish" + path, method: download || cancel ? "POST" : "PUT", token: token,
                headers: ["content-type": "application/json"], body: body, timeout: healthTimeout)
            let (data, response) = try performSync(req, timeout: healthTimeout)
            guard response.statusCode == 202 else { throw httpError(response, data) }
        } }
    }

    /// Ask the service to make one tiny call with this route (nothing is recorded).
    func testLLMSync(route: LLMRoute) throws -> LLMTestResult {
        try withPortRetry {
            try withTokenRetry { token in
                let object: [String: Any] = ["llm": ["baseURL": route.baseURL, "model": route.model, "apiKey": route.apiKey]]
                let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
                let req = try makeRequest(path: "/api/voice-polish/test-llm", method: "POST", token: token,
                                          headers: ["content-type": "application/json"], body: body, timeout: 20)
                let (data, resp) = try performSync(req, timeout: 20)
                guard resp.statusCode == 200 || resp.statusCode == 400 else { throw httpError(resp, data) }
                do { return try JSONDecoder().decode(LLMTestResult.self, from: data) }
                catch { throw ServiceError.decoding(String(describing: error)) }
            }
        }
    }

    /// The word a fix right after a paste teaches, judged by the service (the same rule as
    /// on Windows); nil when it was not a spelling fix. The text is only compared there.
    func learnedWordSync(inserted: String, edited: String) throws -> String? {
        try withPortRetry {
            try withTokenRetry { token in
                let body = (try? JSONSerialization.data(withJSONObject: ["inserted": inserted, "edited": edited])) ?? Data()
                let req = try makeRequest(path: "/api/voice-polish/learned-word", method: "POST", token: token,
                                          headers: ["content-type": "application/json"], body: body, timeout: healthTimeout)
                let (data, resp) = try performSync(req, timeout: healthTimeout)
                guard resp.statusCode == 200 else { throw httpError(resp, data) }
                do { return try JSONDecoder().decode(LearnedWordResult.self, from: data).word }
                catch { throw ServiceError.decoding(String(describing: error)) }
            }
        }
    }

    // MARK: plugins (data files the service checks, stores and applies)

    private func pluginRequest<T: Decodable>(_ method: String, _ path: String, body: Data? = nil,
                                             timeout: TimeInterval = 10, as type: T.Type) throws -> T {
        try withPortRetry {
            try withTokenRetry { token in
                let req = try makeRequest(path: "/api/voice-polish/plugins" + path, method: method, token: token,
                                          headers: body == nil ? [:] : ["content-type": "application/json"], body: body, timeout: timeout)
                let (data, resp) = try performSync(req, timeout: timeout)
                guard resp.statusCode == 200 else { throw httpError(resp, data) }
                do { return try JSONDecoder().decode(T.self, from: data) }
                catch { throw ServiceError.decoding(String(describing: error)) }
            }
        }
    }

    func pluginsSync() throws -> PluginState { try pluginRequest("GET", "", as: PluginState.self) }

    /// Check a plugin file without installing it.
    func inspectPluginSync(_ file: Data) throws -> PluginInspection {
        try pluginRequest("POST", "/inspect", body: file, as: PluginInspection.self)
    }

    /// Install the file the confirmation showed; `digest` is its fingerprint from the inspection.
    func installPluginSync(_ file: Data, enable: Bool, digest: String) throws -> PluginState {
        try pluginRequest("POST", "?enable=" + (enable ? "1" : "0") + "&digest=" + digest, body: file, as: PluginState.self)
    }

    /// Install the catalog entry the confirmation showed; a changed entry is refused (plugin-changed).
    func installCatalogPluginSync(id: String, enable: Bool, digest: String) throws -> PluginState {
        let body = (try? JSONSerialization.data(withJSONObject: ["id": id, "enable": enable, "digest": digest])) ?? Data()
        return try pluginRequest("POST", "/catalog/install", body: body, as: PluginState.self)
    }

    func setPluginEnabledSync(id: String, enabled: Bool) throws -> PluginState {
        let body = (try? JSONSerialization.data(withJSONObject: ["enabled": enabled])) ?? Data()
        return try pluginRequest("PUT", "/" + id, body: body, as: PluginState.self)
    }

    func selectStyleSync(id: String?) throws -> PluginState {
        let body = (try? JSONSerialization.data(withJSONObject: ["id": id as Any? ?? NSNull()])) ?? Data()
        return try pluginRequest("PUT", "/style", body: body, as: PluginState.self)
    }

    func removePluginSync(id: String) throws -> PluginState { try pluginRequest("DELETE", "/" + id, as: PluginState.self) }

    /// Read the catalog once: official addresses first, public mirrors as `sources` (the
    /// 更新来源 setting: auto, github or mirror) allows.
    func pluginCatalogSync(sources: String) throws -> PluginCatalog {
        try pluginRequest("GET", "/catalog?sources=" + sources, timeout: 30, as: PluginCatalog.self)
    }

    /// The provider's model ids, from its OpenAI-compatible `GET /models`. Called
    /// directly (not through the local service), because it needs nothing but the key.
    func listModelsSync(route: LLMRoute) throws -> [String] {
        guard let url = URL(string: route.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            throw ServiceError.transport("bad url")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if !route.apiKey.isEmpty { req.setValue("Bearer " + route.apiKey, forHTTPHeaderField: "Authorization") }
        let (data, resp) = try performSync(req, timeout: 10)
        guard resp.statusCode == 200 else { throw ServiceError.http(status: resp.statusCode, code: nil, message: "") }
        return LLMRoute.modelIDs(from: data)
    }

    func isReachable() -> Bool { (try? healthSync()) != nil }
}

/// A model reached with the user's own key over the OpenAI-compatible protocol.
struct LLMRoute: Codable, Equatable {
    var baseURL: String
    var model: String
    var apiKey: String

    /// Model ids from an OpenAI-compatible `/models` body: `{"data": [{"id": …}]}`.
    static func modelIDs(from data: Data) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { $0["id"] as? String }.sorted()
    }
}

/// Answer of `POST /test-llm`.
struct LLMTestResult: Codable, Equatable {
    var ok: Bool
    var ms: Double?
    var code: String?
    var error: String?
    var sample: String?
}

/// A plugin as the service describes it: installed (source, enabled), in the catalog
/// (installedVersion) or being inspected before install.
struct PluginSummary: Codable, Equatable, Identifiable {
    var id: String
    /// Fingerprint of the whole content; sent back when installing what was shown.
    var digest: String? = nil
    var version: String
    var type: String
    var name: [String: String]
    var description: [String: String]
    var author: String
    var license: String
    var homepage: String?
    var termCount: Int?
    var termsPreview: [String]?
    var aliasCount: Int? = nil
    var aliasesPreview: [PluginAliasPreview]? = nil
    var instructions: String?
    var source: String?
    var enabled: Bool?
    var installedVersion: String?

    var isStyle: Bool { type == "style" }
    var title: String { name[L10n.language == "en" ? "en" : "zh-Hans"] ?? id }
    var summary: String { description[L10n.language == "en" ? "en" : "zh-Hans"] ?? "" }
}

struct PluginAliasPreview: Codable, Equatable {
    var heard: String
    var term: String
    var cues: [String]
    var blockers: [String]?
}

/// Answer of `GET /plugins` and of every change.
struct PluginState: Codable, Equatable {
    var plugins: [PluginSummary]
    var style: String?
    var problems: [String]?
}

/// Answer of `GET /plugins/catalog`; on failure `plugins` is the last catalog read.
struct PluginCatalog: Codable, Equatable {
    var ok: Bool
    var code: String?
    var source: String?
    /// Read through a public mirror rather than an official address.
    var mirrored: Bool?
    var fetchedAt: String?
    var plugins: [PluginSummary]
}

/// Answer of `POST /plugins/inspect`.
struct PluginInspection: Codable, Equatable {
    var plugin: PluginSummary
    var installedVersion: String?
}

/// Answer of `POST /learned-word`.
struct LearnedWordResult: Codable, Equatable {
    var word: String?
}

enum BetaMessages {
    static func notice(_ code: String) -> String {
        switch code {
        case "empty-transcript": return L10n.text("没听清，请再说一次。之前的回答保留。")
        case "beta-input-limit": return L10n.text("太长了。说短一些，或现在生成。")
        case "beta-validation": return L10n.text("结果没通过检查，未插入。可继续补充或重新生成。")
        default: return L10n.text("这一轮没完成，之前的回答保留。请重说或生成。")
        }
    }
}


extension Data {
    /// Bytes from a hex string; nil when it is not one.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

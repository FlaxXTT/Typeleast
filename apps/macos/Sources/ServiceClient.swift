import Foundation

// ServiceClient.swift - HTTP client for the TypeLeast local service
// (service/ in this repository: local speech recognition plus cleanup with the
// user's own model). The app starts that service itself (ServiceManager.swift).
// Foundation only: shared by the app target and the test-harness target.

// MARK: - Errors

enum ServiceError: Error, CustomStringConvertible, Equatable {
    case noToken(String)
    case transport(String)
    case http(status: Int, code: String?, message: String)
    case decoding(String)

    var description: String {
        switch self {
        case .noToken(let p): return "token unavailable: " + p
        case .transport(let m): return "service unreachable: " + m
        case .http(let s, let c, let m): return "HTTP " + String(s) + " " + (c ?? "") + " " + m
        case .decoding(let m): return "bad response: " + m
        }
    }

    /// Frozen contract: /health non-200 or any transport error means "service not running".
    var serviceUnavailable: Bool {
        switch self {
        case .noToken, .transport: return true
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

struct SpeechStatus: Codable, Equatable {
    var providerId: String?
    var ready: Bool?
    /// loading | ready | missing-model | downloading | error
    var phase: String?
    var error: String?
    /// Bytes so far while the models download.
    var downloadReceived: Double?
    var downloadTotal: Double?
    /// Size of the whole model set, for "下载语音模型（241 MB）".
    var modelBytes: Double?

    enum CodingKeys: String, CodingKey { case providerId, ready, phase, error, download, modelBytes }
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

struct DictateResponse: Codable, Equatable {
    var requestId: String?
    var text: String = ""
    var raw: String = ""
    var fallback: Bool = false
    var fallbackReason: String?
    var model: String?
    var provider: String?
    var ms: MSBreakdown?

    enum CodingKeys: String, CodingKey {
        case requestId, text, raw, fallback, fallbackReason, model, provider, ms
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
    }

    /// When fallback is true the service has ALREADY substituted the raw transcript into
    /// "text". Guard anyway against a service that only flips the flag.
    var insertableText: String {
        if !text.isEmpty { return text }
        return raw
    }
}

struct HistoryItem: Codable, Equatable, Identifiable {
    var id: String
    var ts: String?
    var tsNumber: Double?
    var app: String?
    var language: String?
    var raw: String?
    var text: String?
    var fallback: Bool
    var reason: String?
    var model: String?
    var ms: MSBreakdown?
    var strength: String?

    enum CodingKeys: String, CodingKey {
        case id, ts, app, language, raw, text, fallback, reason, model, ms, strength
    }
    init() { id = UUID().uuidString; fallback = false }
    init(id: String, text: String?, raw: String?, fallback: Bool, app: String?, ts: String?) {
        self.id = id
        self.text = text
        self.raw = raw
        self.fallback = fallback
        self.app = app
        self.ts = ts
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = lenient(c, String.self, .id) ?? UUID().uuidString
        if let s = lenient(c, String.self, .ts) {
            ts = s
        } else if let n = lenient(c, Double.self, .ts) {
            tsNumber = n
            ts = String(format: "%.0f", n)
        }
        app = lenient(c, String.self, .app)
        language = lenient(c, String.self, .language)
        raw = lenient(c, String.self, .raw)
        text = lenient(c, String.self, .text)
        fallback = lenient(c, Bool.self, .fallback) ?? false
        reason = lenient(c, String.self, .reason)
        model = lenient(c, String.self, .model)
        ms = lenient(c, MSBreakdown.self, .ms)
        strength = lenient(c, String.self, .strength)
    }
}

struct HistoryResponse: Codable, Equatable {
    var items: [HistoryItem] = []
    enum CodingKeys: String, CodingKey { case items }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = lenient(c, [HistoryItem].self, .items) ?? []
    }
}

struct DictEntry: Codable, Equatable, Identifiable {
    var from: String
    var to: String
    var id: String { from + "\u{1}" + to }
    init(from: String, to: String) { self.from = from; self.to = to }
}

struct LearnResponse: Codable, Equatable {
    var ok: Bool = false
    var dictionary: [DictEntry] = []
    enum CodingKeys: String, CodingKey { case ok, dictionary }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = lenient(c, Bool.self, .ok) ?? false
        if let entries = lenient(c, [DictEntry].self, .dictionary) {
            dictionary = entries
        } else if let strings = lenient(c, [String].self, .dictionary) {
            dictionary = strings.map { DictEntry(from: $0, to: $0) }
        }
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
        return URLSession(configuration: cfg)
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
            return try op(t1)
        } catch let e as ServiceError where e.isUnauthorized {
            guard let t2 = loadToken(), t2 != t1 else { throw e }
            return try op(t2)
        }
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

    func dictateSync(wav: Data, language: String, appBundleId: String, strength: String,
                     fieldContext: Data? = nil, llm: LLMRoute? = nil) throws -> DictateResponse {
        try withPortRetry { try dictateOnce(wav: wav, language: language, appBundleId: appBundleId,
                                            strength: strength, fieldContext: fieldContext,
                                            llm: llm) }
    }

    private func dictateOnce(wav: Data, language: String, appBundleId: String, strength: String,
                             fieldContext: Data?, llm: LLMRoute?) throws -> DictateResponse {
        try withTokenRetry { token in
            var headers: [String: String] = [
                "content-type": "audio/wav",
                "x-voice-language": language,
                "x-voice-app": appBundleId,
                "x-voice-strength": strength,
            ]
            if let context = ServiceClient.encodeContextHeader(fieldContext) {
                headers["x-voice-context"] = context
            }
            if let route = ServiceClient.encodeRouteHeader(llm) {
                headers["x-voice-llm"] = route
            }
            let req = try makeRequest(path: "/api/voice-polish/dictate", method: "POST",
                                      token: token, headers: headers, body: wav, timeout: dictateTimeout)
            let (data, resp) = try performSync(req, timeout: dictateTimeout)
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            do { return try JSONDecoder().decode(DictateResponse.self, from: data) }
            catch { throw ServiceError.decoding(String(describing: error)) }
        }
    }

    func historySync(limit: Int = 20) throws -> [HistoryItem] {
        try withPortRetry { try historyOnce(limit: limit) }
    }

    private func historyOnce(limit: Int) throws -> [HistoryItem] {
        try withTokenRetry { token in
            let req = try makeRequest(path: "/api/voice-polish/history?limit=" + String(limit), method: "GET",
                                      token: token, timeout: healthTimeout)
            let (data, resp) = try performSync(req, timeout: healthTimeout)
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            do { return try JSONDecoder().decode(HistoryResponse.self, from: data).items }
            catch { throw ServiceError.decoding(String(describing: error)) }
        }
    }

    func learnSync(from: String, to: String) throws -> LearnResponse {
        try withTokenRetry { token in
            let obj: [String: String] = ["from": from, "to": to]
            let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            let req = try makeRequest(path: "/api/voice-polish/learn", method: "POST", token: token,
                                      headers: ["content-type": "application/json"], body: body,
                                      timeout: healthTimeout)
            let (data, resp) = try performSync(req, timeout: healthTimeout)
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            do { return try JSONDecoder().decode(LearnResponse.self, from: data) }
            catch { throw ServiceError.decoding(String(describing: error)) }
        }
    }

    /// Replace the service's learned dictionary with exactly these entries ("word" or "heard=word").
    /// A service that predates this endpoint answers 404; callers treat that as "not supported".
    func putDictionarySync(entries: [String]) throws -> [String] {
        try withPortRetry { try putDictionaryOnce(entries: entries) }
    }

    private func putDictionaryOnce(entries: [String]) throws -> [String] {
        try withTokenRetry { token in
            let body = (try? JSONSerialization.data(withJSONObject: ["entries": entries])) ?? Data()
            let req = try makeRequest(path: "/api/voice-polish/dictionary", method: "PUT", token: token,
                                      headers: ["content-type": "application/json"], body: body,
                                      timeout: healthTimeout)
            let (data, resp) = try performSync(req, timeout: healthTimeout)
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (object?["dictionary"] as? [String]) ?? []
        }
    }

    /// Start the one-time model download (about 241 MB); progress shows in /health.
    func downloadModelsSync(endpoint: String? = nil) throws {
        try withPortRetry {
            try withTokenRetry { token in
                var object: [String: Any] = [:]
                if let endpoint = endpoint, !endpoint.isEmpty { object["endpoint"] = endpoint }
                let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
                let req = try makeRequest(path: "/api/voice-polish/models/download", method: "POST", token: token,
                                          headers: ["content-type": "application/json"], body: body, timeout: healthTimeout)
                let (data, resp) = try performSync(req, timeout: healthTimeout)
                guard resp.statusCode == 202 || resp.statusCode == 200 else { throw httpError(resp, data) }
            }
        }
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

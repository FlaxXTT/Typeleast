import Foundation

// DshClient.swift - frozen HTTP contract client for the DSH voice-polish host.
// Foundation only: shared by the app target and the test-harness target.

// MARK: - Errors

enum DshError: Error, CustomStringConvertible, Equatable {
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
func dshLenient<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ t: T.Type, _ k: K) -> T? {
    (try? c.decodeIfPresent(t, forKey: k)) ?? nil
}

struct SpeechStatus: Codable, Equatable {
    var providerId: String?
    var ready: Bool?
    var phase: String?

    enum CodingKeys: String, CodingKey { case providerId, ready, phase }
    init() {}
    init(providerId: String?, ready: Bool?, phase: String?) {
        self.providerId = providerId
        self.ready = ready
        self.phase = phase
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerId = dshLenient(c, String.self, .providerId)
        ready = dshLenient(c, Bool.self, .ready)
        phase = dshLenient(c, String.self, .phase)
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
    var version: String?
    var provider: String?
    var model: String?
    var speech: SpeechStatus?
    var pid: Int?

    enum CodingKeys: String, CodingKey { case ok, version, provider, model, speech, pid }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = dshLenient(c, Bool.self, .ok) ?? false
        version = dshLenient(c, String.self, .version)
        provider = dshLenient(c, String.self, .provider)
        model = dshLenient(c, String.self, .model)
        speech = dshLenient(c, SpeechStatus.self, .speech)
        pid = dshLenient(c, Int.self, .pid)
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
        transcribe = dshLenient(c, Double.self, .transcribe)
        polish = dshLenient(c, Double.self, .polish)
        total = dshLenient(c, Double.self, .total)
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
        requestId = dshLenient(c, String.self, .requestId)
        text = dshLenient(c, String.self, .text) ?? ""
        raw = dshLenient(c, String.self, .raw) ?? ""
        fallback = dshLenient(c, Bool.self, .fallback) ?? false
        fallbackReason = dshLenient(c, String.self, .fallbackReason)
        model = dshLenient(c, String.self, .model)
        provider = dshLenient(c, String.self, .provider)
        ms = dshLenient(c, MSBreakdown.self, .ms)
    }

    /// When fallback is true the host has ALREADY substituted the raw transcript into
    /// "text". Guard anyway against a host that only flips the flag.
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
        id = dshLenient(c, String.self, .id) ?? UUID().uuidString
        if let s = dshLenient(c, String.self, .ts) {
            ts = s
        } else if let n = dshLenient(c, Double.self, .ts) {
            tsNumber = n
            ts = String(format: "%.0f", n)
        }
        app = dshLenient(c, String.self, .app)
        language = dshLenient(c, String.self, .language)
        raw = dshLenient(c, String.self, .raw)
        text = dshLenient(c, String.self, .text)
        fallback = dshLenient(c, Bool.self, .fallback) ?? false
        reason = dshLenient(c, String.self, .reason)
        model = dshLenient(c, String.self, .model)
        ms = dshLenient(c, MSBreakdown.self, .ms)
        strength = dshLenient(c, String.self, .strength)
    }
}

struct HistoryResponse: Codable, Equatable {
    var items: [HistoryItem] = []
    enum CodingKeys: String, CodingKey { case items }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = dshLenient(c, [HistoryItem].self, .items) ?? []
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
        ok = dshLenient(c, Bool.self, .ok) ?? false
        if let entries = dshLenient(c, [DictEntry].self, .dictionary) {
            dictionary = entries
        } else if let strings = dshLenient(c, [String].self, .dictionary) {
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
        error = dshLenient(c, String.self, .error)
        code = dshLenient(c, String.self, .code)
    }
}

// MARK: - Client

final class DshClient {
    static let shared = DshClient()

    /// Base URL of the DSH host. The app never starts its own server.
    ///
    /// DSH binds an **OS-assigned port that changes on every launch**, so a fixed
    /// URL cannot work: the app would report "service not started" while the
    /// service was running perfectly on a different port. The host publishes its
    /// live port to the runtime file below; `discoverBaseURL()` reads it before
    /// each session and `healthSync()` re-reads it once if a request fails.
    /// Until a port is discovered this points at port 1, where nothing listens.
    var baseURL: URL = URL(string: "http://127.0.0.1:1")!

    /// Descriptor published by the host: `{ port, pid, version, startedAt }`.
    var runtimePath: String = ("~/.dsh/voice-polish/runtime.json" as NSString).expandingTildeInPath

    /// Last port discovery outcome, for diagnostics in the menu.
    private(set) var lastDiscoveredPort: Int?
    var tokenPath: String = ("~/.dsh/voice-polish/api-token" as NSString).expandingTildeInPath
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

    /// Port the host published, or nil when the file is absent or malformed.
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
        lastDiscoveredPort = port
        baseURL = URL(string: "http://127.0.0.1:" + String(port))!
        return true
    }

    /// Loopback ports the DSH host is listening on, discovered from the process
    /// table when the runtime file is missing.
    ///
    /// Needed because the host plugin only publishes the runtime file after it has
    /// been (re)loaded: until DSH restarts, an older plugin instance is serving the
    /// route and nothing has written the file. Asking `lsof` for this user's
    /// listening sockets recovers the port anyway, and across a DSH restart it is
    /// the only signal available.
    /// @returns candidate ports, most likely first.
    func processTablePorts() -> [Int] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-c", "DeepSeek"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var ports: [Int] = []
        let pattern = try? NSRegularExpression(pattern: "127\\.0\\.0\\.1:(\\d{2,5})")
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern?.matches(in: text, range: range) ?? [] {
            guard let captured = Range(match.range(at: 1), in: text),
                  let port = Int(text[captured]), port > 0, port < 65_536,
                  !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    /// Try every candidate port until one answers the voice-polish health route.
    ///
    /// A 401 from the web app root is ambiguous (any DSH port answers that), so
    /// only a 200 with a decodable health body proves the port; the bearer token is
    /// sent, which is what distinguishes our route from the rest of the host.
    /// @returns true when `baseURL` was repointed at a working server.
    @discardableResult
    func adoptWorkingPort() -> Bool {
        var candidates: [Int] = []
        if let published = publishedPort() { candidates.append(published) }
        for port in processTablePorts() where !candidates.contains(port) { candidates.append(port) }
        for port in candidates {
            let previous = baseURL
            baseURL = URL(string: "http://127.0.0.1:" + String(port))!
            if (try? healthOnce()) != nil {
                lastDiscoveredPort = port
                return true
            }
            baseURL = previous
        }
        return false
    }

    /// Run one request, and on a transport failure re-read the published port and
    /// retry exactly once.
    ///
    /// A transport failure here almost always means "DSH restarted and got a new
    /// port", so one rediscovery recovers without the user restarting the app.
    /// A decoding or HTTP error is a real answer and is not retried.
    private func withPortRetry<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as DshError {
            guard case .transport = error else { throw error }
            guard discoverBaseURL() || adoptWorkingPort() else { throw error }
            return try body()
        }
    }

    // MARK: plumbing

    private func makeRequest(path: String, method: String, token: String,
                             headers: [String: String] = [:], body: Data? = nil,
                             timeout: TimeInterval) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path) else {
            throw DshError.transport("bad url " + baseURL.absoluteString + path)
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
            throw DshError.transport("timeout after " + String(format: "%.0fs", timeout))
        }
        if let e = box.error { throw DshError.transport(e.localizedDescription) }
        guard let r = box.response else { throw DshError.transport("no response") }
        return (box.data ?? Data(), r)
    }

    private func httpError(_ resp: HTTPURLResponse, _ data: Data) -> DshError {
        let body = (try? JSONDecoder().decode(ApiErrorBody.self, from: data)) ?? ApiErrorBody()
        return .http(status: resp.statusCode, code: body.code, message: body.error ?? "")
    }

    /// Contract: token is read at request time; after a 401 re-read it once and retry.
    func withTokenRetry<T>(_ op: (String) throws -> T) throws -> T {
        guard let t1 = loadToken() else { throw DshError.noToken(tokenPath) }
        do {
            return try op(t1)
        } catch let e as DshError where e.isUnauthorized {
            guard let t2 = loadToken(), t2 != t1 else { throw e }
            return try op(t2)
        }
    }

    // MARK: endpoints

    func healthSync() throws -> HealthResponse {
        do {
            return try healthOnce()
        } catch let error as DshError {
            // A transport failure is most often "DSH restarted and got a new
            // port". Re-read the published port and try exactly once more, so a
            // DSH restart does not require restarting this app.
            guard case .transport = error else { throw error }
            // Prefer the published file, then fall back to the process table, so a
            // DSH restart (which reassigns the port) needs no app restart either.
            guard discoverBaseURL() || adoptWorkingPort() else { throw error }
            return try healthOnce()
        }
    }

    private func healthOnce() throws -> HealthResponse {
        try withTokenRetry { token in
            let req = try makeRequest(path: "/api/voice-polish/health", method: "GET",
                                      token: token, timeout: healthTimeout)
            let (data, resp) = try performSync(req, timeout: healthTimeout)
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            do { return try JSONDecoder().decode(HealthResponse.self, from: data) }
            catch { throw DshError.decoding(String(describing: error)) }
        }
    }

    /// Upper bound for the encoded field context header; the host refuses anything larger.
    static let maxContextHeaderBytes = 8 * 1024

    /// Field context travels as base64(JSON) in `x-voice-context`: header values must be
    /// ASCII, and the WAV body stays a plain WAV so the frozen body contract is untouched.
    static func encodeContextHeader(_ json: Data?) -> String? {
        guard let json = json, !json.isEmpty else { return nil }
        let encoded = json.base64EncodedString()
        return encoded.utf8.count <= maxContextHeaderBytes ? encoded : nil
    }

    /// The user's own model route travels as base64(JSON) in `x-voice-llm`. It carries the
    /// API key, so it only ever goes to the loopback host, which uses it for that one
    /// request and stores nothing.
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
            if let context = DshClient.encodeContextHeader(fieldContext) {
                headers["x-voice-context"] = context
            }
            if let route = DshClient.encodeRouteHeader(llm) {
                headers["x-voice-llm"] = route
            }
            let req = try makeRequest(path: "/api/voice-polish/dictate", method: "POST",
                                      token: token, headers: headers, body: wav, timeout: dictateTimeout)
            let (data, resp) = try performSync(req, timeout: dictateTimeout)
            guard resp.statusCode == 200 else { throw httpError(resp, data) }
            do { return try JSONDecoder().decode(DictateResponse.self, from: data) }
            catch { throw DshError.decoding(String(describing: error)) }
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
            catch { throw DshError.decoding(String(describing: error)) }
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
            catch { throw DshError.decoding(String(describing: error)) }
        }
    }

    /// Replace the host's learned dictionary with exactly these entries ("word" or "heard=word").
    /// Hosts that predate this endpoint answer 404; callers treat that as "not supported".
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

    /// Ask the host to make one tiny call with this route (nothing is recorded).
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
                catch { throw DshError.decoding(String(describing: error)) }
            }
        }
    }

    /// The provider's model ids, from its OpenAI-compatible `GET /models`. Called
    /// directly (not through DSH), because it needs nothing but the key.
    func listModelsSync(route: LLMRoute) throws -> [String] {
        guard let url = URL(string: route.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            throw DshError.transport("bad url")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if !route.apiKey.isEmpty { req.setValue("Bearer " + route.apiKey, forHTTPHeaderField: "Authorization") }
        let (data, resp) = try performSync(req, timeout: 10)
        guard resp.statusCode == 200 else { throw DshError.http(status: resp.statusCode, code: nil, message: "") }
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

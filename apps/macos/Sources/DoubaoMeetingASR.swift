import CryptoKit
import Foundation

struct DoubaoMeetingStorage: Codable, Sendable {
    static let account = "asr.doubao.meeting.storage"
    let bucket: String
    let region: String
    let accessKey: String
    let secretKey: String

    var isValid: Bool {
        bucket.range(of: #"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"#, options: .regularExpression) != nil &&
            region.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)+$"#, options: .regularExpression) != nil &&
            !accessKey.isEmpty && !secretKey.isEmpty
    }

    static func saved() -> Self? {
        guard let key = KeychainStore.read(account: account),
              let value = try? JSONDecoder().decode(Self.self, from: Data(key.utf8)), value.isValid else { return nil }
        return value
    }

    func save() -> Bool {
        guard isValid, let data = try? JSONEncoder().encode(self) else { return false }
        return KeychainStore.write(String(decoding: data, as: UTF8.self), account: Self.account)
    }

    func signedURL(method: String, object: String, validFor seconds: Int, now: Date = Date()) -> URL {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let date = format.string(from: now)
        let day = String(date.prefix(8))
        let scope = "\(day)/\(region)/tos/request"
        let host = "\(bucket).tos-\(region).volces.com"
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: unreserved)! }
        let path = "/" + object.split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
        let fields = [
            "X-Tos-Algorithm": "TOS4-HMAC-SHA256",
            "X-Tos-Credential": "\(accessKey)/\(scope)",
            "X-Tos-Date": date,
            "X-Tos-Expires": String(seconds),
            "X-Tos-SignedHeaders": "host"
        ]
        let query = fields.keys.sorted().map { "\(encode($0))=\(encode(fields[$0]!))" }.joined(separator: "&")
        let canonical = [method, path, query, "host:\(host)\n", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let signingText = ["TOS4-HMAC-SHA256", date, scope, hash].joined(separator: "\n")
        let signingKey = [day, region, "tos", "request"].reduce(SymmetricKey(data: Data(secretKey.utf8))) { key, value in
            SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key))
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingText.utf8), using: signingKey)
            .map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://\(host)\(path)?\(query)&X-Tos-Signature=\(signature)")!
    }
}

struct DoubaoMeetingASR: Sendable {
    enum Failure: LocalizedError, Equatable {
        case missingKey, missingStorage, upload, cleanup, rejected(String), invalidResponse, timeout, silent, network

        var errorDescription: String? {
            switch self {
            case .missingKey: return L10n.text("请填写豆包语音 API Key。")
            case .missingStorage: return L10n.text("请先配置会议录音的私有 TOS 桶。")
            case .upload: return L10n.text("无法上传会议录音，请检查 TOS 桶和写入权限。")
            case .cleanup: return L10n.text("无法清理 TOS 上的临时录音，请检查删除权限和过期规则。")
            case .rejected(let code): return L10n.text("豆包录音文件识别失败（{0}）。", code)
            case .invalidResponse: return L10n.text("豆包没有返回可用的会议转写。")
            case .timeout: return L10n.text("豆包转写等待超时。")
            case .silent: return L10n.text("豆包没有检测到人声。")
            case .network: return L10n.text("联网会议转写失败，可以重试。")
            }
        }
    }

    private struct FileResult: Decodable {
        struct Result: Decodable {
            struct Utterance: Decodable {
                struct Additions: Decodable { let speaker: String? }
                let text: String
                let start_time: Int
                let end_time: Int?
                let additions: Additions?
            }
            let text: String
            let utterances: [Utterance]?
        }
        let result: Result
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static var modelName: String { L10n.text("豆包录音文件识别模型 2.0") }
    static let keyAccount = "asr.doubao.meeting"
    static func savedKey() -> String {
        KeychainStore.read(account: keyAccount) ?? KeychainStore.read(account: OnlineASRProvider.doubao.keychainAccount) ?? ""
    }
    static let activationURL = URL(string: "https://console.volcengine.com/speech/overview")!
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    private static let fixture = URL(string: "https://lf3-static.bytednsdoc.com/obj/eden-cn/lm_hz_ihsph/ljhwZthlaukjlkulzlp/console/bigtts/zh_female_cancan_mars_bigtts.mp3")!
    let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let pause: @Sendable () async throws -> Void

    init(transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await session.data(for: $0) },
         pause: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }) {
        self.transport = transport
        self.pause = pause
    }

    func testConnection(apiKey: String) async throws {
        // A successful submission verifies authorization for this exact resource.
        // Use Volcengine’s public sample instead of reading a local recording.
        _ = try await submit(url: Self.fixture, format: "mp3", apiKey: apiKey, smoothing: false, hotwords: "")
    }

    func transcribe(wav: Data, configuration: OnlineASRConfiguration, storage: DoubaoMeetingStorage) async throws -> OnlineASRTranscript {
        let apiKey = try Self.validatedKey(configuration.apiKey)
        guard storage.isValid else { throw Failure.missingStorage }
        let object = "typeleast-meetings/" + UUID().uuidString.lowercased() + ".wav"
        let cleanup: @Sendable () async throws -> Void = {
            // Cleanup must also run when the calling transcription has been cancelled.
            try await Task.detached(priority: .utility) {
                var request = URLRequest(url: storage.signedURL(method: "DELETE", object: object, validFor: 300), timeoutInterval: 15)
                request.httpMethod = "DELETE"
                let (_, response) = try await transport(request)
                guard let status = (response as? HTTPURLResponse)?.statusCode,
                      (200..<300).contains(status) || status == 404 else { throw Failure.cleanup }
            }.value
        }
        var result: OnlineASRTranscript
        do {
            var request = URLRequest(url: storage.signedURL(method: "PUT", object: object, validFor: 1_800), timeoutInterval: 120)
            request.httpMethod = "PUT"
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            request.httpBody = wav
            let response: URLResponse
            do { (_, response) = try await transport(request) }
            catch { try Task.checkCancellation(); throw Failure.upload }
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { throw Failure.upload }
            try Task.checkCancellation()
            let url = storage.signedURL(method: "GET", object: object, validFor: 4 * 3_600)
            let id = try await submit(url: url, format: "wav", apiKey: apiKey,
                                      smoothing: configuration.doubaoSpeechSmoothing, hotwords: configuration.doubaoHotwords,
                                      tables: configuration.doubaoTables)
            result = try await poll(id: id, apiKey: apiKey)
        } catch {
            // A failed PUT can still have been committed if the response was lost.
            try? await cleanup()
            throw error
        }
        do { try await cleanup() } catch { result.temporaryAudioCleanupFailed = true }
        return result
    }

    private static func validatedKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw Failure.missingKey }
        return key
    }

    private func submit(url: URL, format: String, apiKey: String, smoothing: Bool, hotwords: String,
                        tables: DoubaoVocabularyTables = .init()) async throws -> String {
        let id = UUID().uuidString.lowercased()
        var options = OnlineASR.doubaoRequest(language: "auto", meeting: true, speechSmoothing: smoothing, hotwords: hotwords,
                                              tables: tables)["request"]
            as? [String: Any] ?? [:]
        options.removeValue(forKey: "result_type")
        let (status, _) = try await call("submit", id: id, apiKey: Self.validatedKey(apiKey), body: [
            "audio": ["url": url.absoluteString, "format": format],
            "request": options
        ])
        guard status == "20000000" else { throw Failure.rejected(status) }
        return id
    }

    private func poll(id: String, apiKey: String) async throws -> OnlineASRTranscript {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3 * 3_600))
        while clock.now < deadline {
            try await pause()
            try Task.checkCancellation()
            let (status, data) = try await call("query", id: id, apiKey: apiKey, body: [:])
            switch status {
            case "20000000":
                guard let result = try? JSONDecoder().decode(FileResult.self, from: data).result,
                      !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidResponse }
                return OnlineASRTranscript(text: result.text, utterances: (result.utterances ?? []).map {
                    OnlineASRUtterance(startMilliseconds: $0.start_time, endMilliseconds: $0.end_time,
                                       speakerID: $0.additions?.speaker, text: $0.text)
                })
            case "20000001", "20000002": continue
            case "20000003": throw Failure.silent
            default: throw Failure.rejected(status)
            }
        }
        throw Failure.timeout
    }

    private func call(_ action: String, id: String, apiKey: String, body: [String: Any]) async throws -> (String, Data) {
        var request = URLRequest(url: URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/" + action)!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("volc.seedasr.auc", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(id, forHTTPHeaderField: "X-Api-Request-Id")
        if action == "submit" { request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport(request) }
        catch { try Task.checkCancellation(); throw Failure.network }
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        let status = http.value(forHTTPHeaderField: "X-Api-Status-Code").flatMap { value in
            value.range(of: #"^[0-9]{8}$"#, options: .regularExpression) != nil ? value : nil
        }
        guard (200..<300).contains(http.statusCode), let status else { throw Failure.rejected(status ?? String(http.statusCode)) }
        return (status, data)
    }
}

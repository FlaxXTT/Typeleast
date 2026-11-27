import Foundation

enum OnlineASRProvider: String, CaseIterable, Codable, Sendable {
    case local, doubao, funASR
}

enum RecognitionFailure: String, Codable {
    case temporary, configuration, rateLimited, audio, unknown, cancelled

    var message: String {
        switch self {
        case .temporary: return L10n.text("语音识别暂时不可用")
        case .configuration: return L10n.text("请检查语音识别模型或授权")
        case .rateLimited: return L10n.text("语音识别请求过于频繁")
        case .audio: return L10n.text("录音格式或长度不受支持")
        case .unknown: return L10n.text("听写失败")
        case .cancelled: return L10n.text("已取消")
        }
    }
}

struct DoubaoVocabularyTables: Sendable {
    var hotwords = ""
    var replacements = ""
}

struct OnlineASRConfiguration: Sendable {
    let provider: OnlineASRProvider
    let apiKey: String
    let workspaceID: String
    var doubaoSpeechSmoothing = true
    var doubaoHotwords = ""
    var doubaoTables = DoubaoVocabularyTables()
}

struct OnlineASRUtterance: Sendable {
    let startMilliseconds: Int
    let endMilliseconds: Int?
    let speakerID: String?
    let text: String
}

struct OnlineASRTranscript: Sendable {
    var text: String
    var utterances: [OnlineASRUtterance] = []
    var temporaryAudioCleanupFailed = false
}

/// Each take has its own stop boundary. The recorder already stores the PCM for history.
final class DoubaoLiveAudio: @unchecked Sendable {
    private let recorder: Recorder
    private let lock = NSLock()
    private var finalByteCount: Int?
    private let completion = AsyncStream<Void>.makeStream()

    init(recorder: Recorder) { self.recorder = recorder }

    var endOfRecording: AsyncStream<Void> { completion.stream }

    func finish(byteCount: Int) {
        lock.withLock { finalByteCount = byteCount }
        completion.continuation.finish()
    }

    func send(_ chunk: (Data, Bool) async throws -> Void) async throws {
        let packetBytes = Recorder.bytesPerSecond / 10
        var offset = 0
        while true {
            try Task.checkCancellation()
            let end = lock.withLock { finalByteCount }
            let limit = min(offset + packetBytes, end ?? Int.max)
            let snapshot = recorder.pcmSnapshot(fromByteOffset: offset, endByteOffset: limit)
            let last = snapshot.nextByteOffset == end
            // Keep one sample in reserve while live so the final packet carries audio,
            // even when the take ends exactly on a packet boundary.
            if last || (snapshot.pcm.count == packetBytes && recorder.byteCount > limit) {
                try Task.checkCancellation()
                try await chunk(snapshot.pcm, last)
                offset = snapshot.nextByteOffset
                if last { return }
            } else {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
    }
}

enum OnlineASR {
    enum Failure: LocalizedError {
        case missingKey, invalidWorkspace, invalidAudio, invalidResponse, timedOut
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .missingKey: return L10n.text("请先设置云端语音识别的 API Key。")
            case .invalidWorkspace: return L10n.text("百炼工作空间 ID 格式不正确。")
            case .invalidAudio: return L10n.text("云端语音识别需要 16 kHz 单声道 PCM 音频。")
            case .invalidResponse: return L10n.text("云端语音识别返回了无效响应。")
            case .timedOut: return L10n.text("云端语音识别超时。")
            case .rejected(let code): return L10n.text("云端语音识别请求失败（{0}）。", code)
            }
        }
    }

    private typealias Socket = URLSessionWebSocketTask

    /// Measure the provider's authenticated session startup without sending audio.
    static func testConnection(configuration: OnlineASRConfiguration) async throws -> Int {
        let start = ProcessInfo.processInfo.systemUptime
        switch configuration.provider {
        case .local:
            throw Failure.invalidResponse
        case .doubao:
            let request = try doubaoConnection(configuration)
            try await connect(request, duration: 0, responseTimeout: 8) { socket in
                let first = try await beginDoubao(socket, language: "auto", meeting: false, configuration: configuration)
                guard !first.last else { throw Failure.invalidResponse }
                socket.cancel(with: .normalClosure, reason: nil)
            }
        case .funASR:
            let request = try funASRConnection(configuration)
            try await connect(request, duration: 0, responseTimeout: 8) { socket in
                _ = try await beginFunASR(socket, language: "auto", meeting: false)
                socket.cancel(with: .normalClosure, reason: nil)
            }
        }
        return Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded())
    }

    static func transcribe(wav: Data, language: String, configuration: OnlineASRConfiguration) async throws -> String {
        try await recognize(wav: wav, language: language, configuration: configuration, meeting: false).text
    }

    static func transcribeMeeting(wav: Data, configuration: OnlineASRConfiguration) async throws -> OnlineASRTranscript {
        try await recognize(wav: wav, language: "auto", configuration: configuration, meeting: true)
    }

    static func transcribeLive(audio: DoubaoLiveAudio, maxSeconds: Int,
                               language: String, configuration: OnlineASRConfiguration) async throws -> String {
        let request = try doubaoConnection(configuration)
        let result = try await connect(request, duration: Double(maxSeconds), endOfRecording: audio.endOfRecording) { socket in
            try await recognizeDoubao(socket, language: language, meeting: false,
                                      configuration: configuration) { send in
                try await audio.send(send)
            }
        }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Retry with the same route once. The caller owns the WAV and supplies the
    /// replay operation, which can replace a failed live stream.
    static func retryRecording<T>(provider: OnlineASRProvider, initial: () async throws -> T,
                                  replay: () async throws -> T,
                                  onFailure: (_ code: String, _ retrying: Bool) -> Void) async throws -> T {
        try Task.checkCancellation()
        do {
            return try await initial()
        } catch {
            try Task.checkCancellation()
            let failure = recognitionFailure(error, provider: provider)
            let retrying = failure.kind == .temporary
            onFailure(failure.code, retrying)
            guard retrying else { throw error }
            try Task.checkCancellation()
            return try await replay()
        }
    }

    static func recognitionFailure(_ error: Error, provider: OnlineASRProvider) -> (kind: RecognitionFailure, code: String) {
        if error is CancellationError { return (.cancelled, "cancelled") }
        if let failure = error as? Failure {
            switch failure {
            case .timedOut: return (.temporary, "timeout")
            case .missingKey: return (.configuration, "missing-key")
            case .invalidWorkspace: return (.configuration, "invalid-workspace")
            case .invalidAudio: return (.audio, "invalid-audio")
            case .invalidResponse: return (.unknown, "invalid-response")
            case .rejected(let status):
                if provider == .doubao {
                    switch status {
                    case "55000000", "55000001", "55000031", "55001010", "45000081":
                        return (.temporary, "rejected-" + status)
                    case "45000002", "45000151": return (.audio, "rejected-" + status)
                    default: break
                    }
                }
                if provider == .funASR {
                    switch status {
                    case "InternalAsrError", "InternalError", "InternalError.Timeout":
                        return (.temporary, status)
                    default: break
                    }
                }
                switch status {
                case "401", "403": return (.configuration, "authorization")
                case "429": return (.rateLimited, "rate-limit")
                case "500", "502", "503", "504": return (.temporary, "http-" + status)
                default: return (.unknown, Int(status).map { "rejected-" + String($0) } ?? "rejected")
                }
            }
        }
        if provider == .local, let error = error as? ServiceError {
            switch error {
            case .transport("cancelled"): return (.cancelled, "cancelled")
            case .transport: return (.temporary, "local-transport")
            case .http(let status, let code, _):
                switch code {
                case "speech-not-ready", "model-not-installed", "invalid-model", "speech-model-changed":
                    return (.configuration, code ?? "model-not-ready")
                case "model-failed", "model-load-failed", "model-timeout":
                    return (.temporary, code ?? "model-failed")
                case "invalid-audio", "audio-too-large", "payload-too-large":
                    return (.audio, code ?? "invalid-audio")
                default: break
                }
                switch status {
                case 401, 403: return (.configuration, "authorization")
                case 429: return (.rateLimited, "rate-limit")
                case 502, 503, 504: return (.temporary, "http-" + String(status))
                default: return (.unknown, "http-" + String(status))
                }
            default: return (.unknown, "local-error")
            }
        }
        if let code = (error as? URLError)?.code {
            switch code {
            case .timedOut: return (.temporary, "timeout")
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
                return (.temporary, "connection")
            case .userAuthenticationRequired: return (.configuration, "authorization")
            case .cancelled: return (.cancelled, "cancelled")
            default: return (.unknown, "url" + String(code.rawValue))
            }
        }
        if let code = (error as? POSIXError)?.code {
            switch code {
            case .ETIMEDOUT: return (.temporary, "timeout")
            case .ECONNRESET, .ECONNABORTED, .ENOTCONN, .EPIPE: return (.temporary, "connection")
            default: return (.unknown, "posix-" + String(code.rawValue))
            }
        }
        return (.unknown, "other")
    }

    private static func recognize(wav: Data, language: String, configuration: OnlineASRConfiguration,
                                  meeting: Bool) async throws -> OnlineASRTranscript {
        guard configuration.provider != .local else { throw Failure.missingKey }
        _ = try validatedKey(configuration.apiKey)
        guard Wav.isCanonical(wav), wav.count > 44 else { throw Failure.invalidAudio }
        let pcm = wav.dropFirst(44)

        var result: OnlineASRTranscript
        switch configuration.provider {
        case .local:
            throw Failure.missingKey
        case .doubao:
            let request = try doubaoConnection(configuration)
            result = try await connect(request, duration: duration(pcm)) { socket in
                try await recognizeDoubao(socket, language: language, meeting: meeting,
                                          configuration: configuration) { send in
                    try await sendPCM(pcm, send: send)
                }
            }
        case .funASR:
            let request = try funASRConnection(configuration)
            result = try await connect(request, duration: duration(pcm)) { socket in
                try await recognizeFunASR(socket, pcm: pcm, language: language, meeting: meeting)
            }
        }
        result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    private static func duration(_ pcm: Data) -> Double { Double(pcm.count) / 32_000 }

    private static func validatedKey(_ input: String) throws -> String {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw Failure.missingKey }
        return key
    }

    private static func connect<Value: Sendable>(_ request: URLRequest, duration: Double,
                                                 endOfRecording: AsyncStream<Void>? = nil,
                                                 responseTimeout: TimeInterval = 30,
                                                 run: @escaping @Sendable (Socket) async throws -> Value) async throws -> Value {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(20, responseTimeout)
        configuration.timeoutIntervalForResource = duration + responseTimeout
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        socket.resume()
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    do { return try await run(socket) }
                    catch {
                        if let status = (socket.response as? HTTPURLResponse)?.statusCode, status >= 400 {
                            throw Failure.rejected(String(status))
                        }
                        if (error as? URLError)?.code == .timedOut { throw Failure.timedOut }
                        throw error
                    }
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask {
                if let endOfRecording {
                    for await _ in endOfRecording {}
                    try Task.checkCancellation()
                }
                try await Task.sleep(for: .seconds(endOfRecording == nil ? duration + responseTimeout : responseTimeout))
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw Failure.invalidResponse }
            return result
        }
    }

    /// Both protocols send audio while the server can be producing recognition results.
    private static func exchange(_ socket: Socket,
                                 send: @escaping @Sendable () async throws -> Void,
                                 receive: @escaping @Sendable () async throws -> OnlineASRTranscript) async throws -> OnlineASRTranscript {
        try await withThrowingTaskGroup(of: OnlineASRTranscript?.self) { group in
            group.addTask { try await send(); return nil }
            group.addTask { try await receive() }
            defer {
                group.cancelAll()
                socket.cancel(with: .normalClosure, reason: nil)
            }
            while let response = try await group.next() {
                if let result = response { return result }
            }
            throw Failure.invalidResponse
        }
    }

    /// Pace chunks at the rate in the providers' WebSocket examples.
    private static func sendPCM(_ pcm: Data, send: (Data, Bool) async throws -> Void) async throws {
        let chunkBytes = 3_200
        var offset = pcm.startIndex
        while offset < pcm.endIndex {
            try Task.checkCancellation()
            let end = min(offset + chunkBytes, pcm.endIndex)
            try await send(pcm.subdata(in: offset..<end), end == pcm.endIndex)
            offset = end
            if offset < pcm.endIndex { try await Task.sleep(for: .milliseconds(100)) }
        }
    }

    private static func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private static func receiveData(_ socket: Socket) async throws -> Data {
        switch try await socket.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let data): return data
        @unknown default: throw Failure.invalidResponse
        }
    }

    // MARK: Doubao ASR 2.0

    private static func doubaoConnection(_ configuration: OnlineASRConfiguration) throws -> URLRequest {
        guard configuration.provider == .doubao else { throw Failure.missingKey }
        let key = try validatedKey(configuration.apiKey)
        // This endpoint accepts PCM throughout capture and preserves language selection,
        // hotwords and smoothing when returning the finalized text.
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")!)
        let requestID = UUID().uuidString
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue("volc.seedasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        return request
    }

    static func doubaoRequest(language: String, meeting: Bool, speechSmoothing: Bool, hotwords: String = "",
                              tables: DoubaoVocabularyTables = .init()) -> [String: Any] {
        var audio: [String: Any] = ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1]
        let locales = ["zh": "zh-CN", "en": "en-US", "yue": "yue-CN", "ja": "ja-JP", "ko": "ko-KR"]
        if let locale = locales[language] { audio["language"] = locale }
        var options: [String: Any] = [
            "model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
            "enable_ddc": speechSmoothing && ["auto", "zh", "en"].contains(language),
            "result_type": "full"
        ]
        let words = Vocabulary.hotwords(from: hotwords).prefix(5_000)
        var corpus: [String: String] = [:]
        if !words.isEmpty, let context = try? json(["hotwords": words.map { ["word": $0] }]) {
            corpus["context"] = String(decoding: context, as: UTF8.self)
        }
        let boostID = tables.hotwords.trimmingCharacters(in: .whitespacesAndNewlines)
        let correctID = tables.replacements.trimmingCharacters(in: .whitespacesAndNewlines)
        if !boostID.isEmpty { corpus["boosting_table_id"] = boostID }
        if !correctID.isEmpty { corpus["correct_table_id"] = correctID }
        if !corpus.isEmpty { options["corpus"] = corpus }
        if meeting {
            options["show_utterances"] = true
            options["enable_speaker_info"] = true
        }
        return ["audio": audio, "request": options]
    }

    private static func beginDoubao(_ socket: Socket, language: String, meeting: Bool,
                                    configuration: OnlineASRConfiguration) async throws -> (result: DoubaoEnvelope.Result?, last: Bool) {
        let request = doubaoRequest(language: language, meeting: meeting,
                                    speechSmoothing: configuration.doubaoSpeechSmoothing, hotwords: configuration.doubaoHotwords,
                                    tables: configuration.doubaoTables)
        try await socket.send(.data(doubaoFrame(type: 0x10, serialization: 0x10,
                                               payload: json(request))))
        return try await doubaoResult(socket)
    }

    private static func recognizeDoubao(_ socket: Socket, language: String, meeting: Bool,
                                        configuration: OnlineASRConfiguration,
                                        sendAudio: @escaping @Sendable ((Data, Bool) async throws -> Void) async throws -> Void) async throws -> OnlineASRTranscript {
        let first = try await beginDoubao(socket, language: language, meeting: meeting, configuration: configuration)
        let initial = first.result?.transcript ?? OnlineASRTranscript(text: "")
        if first.last { return initial }

        return try await exchange(socket, send: {
            try await sendAudio { chunk, last in
                try await socket.send(.data(doubaoFrame(type: last ? 0x22 : 0x20, serialization: 0, payload: chunk)))
            }
        }, receive: {
            var transcript = initial
            while true {
                let response = try await doubaoResult(socket)
                if let result = response.result, result.text != nil || (meeting && result.utterances?.isEmpty == false) {
                    let next = meeting ? result.transcript : OnlineASRTranscript(text: result.text ?? "")
                    if next.text != transcript.text || !next.utterances.isEmpty { transcript = next }
                }
                if response.last { return transcript }
            }
        })
    }

    private static func doubaoFrame(type: UInt8, serialization: UInt8, payload: Data) -> Data {
        // Version 1, four-byte header, no compression. The server responds with the same compression setting.
        var frame = Data([0x11, type, serialization, 0])
        var count = UInt32(payload.count).bigEndian
        Swift.withUnsafeBytes(of: &count) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    private static func doubaoResult(_ socket: Socket) async throws -> (result: DoubaoEnvelope.Result?, last: Bool) {
        let frame = try await receiveData(socket)
        guard frame.count >= 8, frame[0] >> 4 == 1 else { throw Failure.invalidResponse }
        let headerSize = Int(frame[0] & 0x0f) * 4
        let type = frame[1] >> 4
        let flags = frame[1] & 0x0f
        guard headerSize >= 4, headerSize <= frame.count - 4 else { throw Failure.invalidResponse }
        if type == 0x0f { throw Failure.rejected(String(bigEndian32(frame, at: headerSize))) }
        guard type == 0x09, frame[2] & 0x0f == 0 else { throw Failure.invalidResponse }
        let sizeOffset = headerSize + (flags & 1 != 0 ? 4 : 0)
        guard sizeOffset <= frame.count - 4 else { throw Failure.invalidResponse }
        let size = Int(bigEndian32(frame, at: sizeOffset))
        let start = sizeOffset + 4
        guard size == frame.count - start else { throw Failure.invalidResponse }
        let last = flags & 2 != 0
        if size == 0 { return (nil, last) }
        let response = try JSONDecoder().decode(DoubaoEnvelope.self, from: frame.subdata(in: start..<frame.count))
        return (response.result, last)
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    struct DoubaoEnvelope: Decodable {
        struct Result: Decodable {
            struct Utterance: Decodable {
                struct Additions: Decodable {
                    let speakerID: String?
                    enum CodingKeys: String, CodingKey { case speakerID = "speaker_id" }

                    init(from decoder: Decoder) throws {
                        let values = try decoder.container(keyedBy: CodingKeys.self)
                        speakerID = (try? values.decode(String.self, forKey: .speakerID))
                            ?? (try? values.decode(Int.self, forKey: .speakerID)).map(String.init)
                    }
                }
                let start: Int?
                let end: Int?
                let text: String?
                let additions: Additions?
                enum CodingKeys: String, CodingKey {
                    case start = "start_time", end = "end_time", text, additions
                }
                var timed: OnlineASRUtterance? {
                    guard let start, let text else { return nil }
                    return OnlineASRUtterance(startMilliseconds: start, endMilliseconds: end,
                                              speakerID: additions?.speakerID, text: text)
                }
            }
            let text: String?
            let utterances: [Utterance]?
            enum CodingKeys: String, CodingKey { case text, utterances }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                text = try values.decodeIfPresent(String.self, forKey: .text)
                utterances = try? values.decode([Utterance].self, forKey: .utterances)
            }

            var transcript: OnlineASRTranscript {
                let turns = utterances ?? []
                let spans = turns.compactMap(\.timed)
                return OnlineASRTranscript(text: text ?? spans.map(\.text).joined(separator: "\n"),
                                           utterances: spans.count == turns.count ? spans : [])
            }
        }
        let result: Result?
    }

    // MARK: Alibaba Cloud Fun-ASR Realtime

    private static func funASRConnection(_ configuration: OnlineASRConfiguration) throws -> URLRequest {
        let key = try validatedKey(configuration.apiKey)
        let workspace = configuration.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host: String
        if workspace.isEmpty {
            host = "dashscope.aliyuncs.com"
        } else {
            guard workspace.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil
            else { throw Failure.invalidWorkspace }
            host = workspace + ".cn-beijing.maas.aliyuncs.com"
        }
        var request = URLRequest(url: URL(string: "wss://\(host)/api-ws/v1/inference")!)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return request
    }

    private static func beginFunASR(_ socket: Socket, language: String, meeting: Bool) async throws -> String {
        let id = UUID().uuidString.lowercased()
        var parameters: [String: Any] = ["format": "pcm", "sample_rate": 16_000, "disfluency_removal_enabled": true]
        if meeting { parameters["heartbeat"] = true }
        switch language {
        case "zh", "en", "ja", "ko": parameters["language_hints"] = [language]
        case "yue": parameters["language_hints"] = ["zh"]
        default: break
        }
        let start = try funASRCommand("run-task", id: id, payload: [
            "task_group": "audio", "task": "asr", "function": "recognition", "model": "fun-asr-realtime",
            "parameters": parameters, "input": [String: Any]()
        ])
        try await socket.send(start)
        let started = try await funASREvent(socket, id: id)
        guard started.header.event == "task-started" else { throw Failure.invalidResponse }
        return id
    }

    private static func recognizeFunASR(_ socket: Socket, pcm: Data, language: String,
                                       meeting: Bool) async throws -> OnlineASRTranscript {
        let id = try await beginFunASR(socket, language: language, meeting: meeting)
        let finish = try funASRCommand("finish-task", id: id, payload: ["input": [String: Any]()])
        return try await exchange(socket, send: {
            try await sendPCM(pcm) { chunk, _ in try await socket.send(.data(chunk)) }
            try await socket.send(finish)
        }, receive: {
            var sentences: [Int: (text: String, start: Int?, end: Int?)] = [:]
            while true {
                let message = try await funASREvent(socket, id: id)
                switch message.header.event {
                case "result-generated":
                    if let sentence = message.payload?.output?.sentence,
                       sentence.heartbeat != true, sentence.sentenceEnd ?? (sentence.endTime != nil),
                       let position = sentence.sentenceID ?? sentence.beginTime,
                       let text = sentence.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        sentences[position] = (text, sentence.beginTime, sentence.endTime)
                    }
                case "task-finished":
                    let ordered = sentences.keys.sorted().compactMap { sentences[$0] }
                    let text = ordered.reduce(into: "") { text, sentence in
                        if text.last?.isASCII == true && sentence.text.first?.isASCII == true { text += " " }
                        text += sentence.text
                    }
                    let utterances: [OnlineASRUtterance] = meeting ? ordered.compactMap { sentence in
                        guard let start = sentence.start else { return nil }
                        return OnlineASRUtterance(startMilliseconds: start, endMilliseconds: sentence.end,
                                                  speakerID: nil, text: sentence.text)
                    } : []
                    return OnlineASRTranscript(text: text, utterances: utterances.count == ordered.count ? utterances : [])
                default: continue
                }
            }
        })
    }

    private static func funASRCommand(_ action: String, id: String, payload: [String: Any]) throws -> Socket.Message {
        let body = try json(["header": ["action": action, "task_id": id, "streaming": "duplex"], "payload": payload])
        return .string(String(decoding: body, as: UTF8.self))
    }

    private static func funASREvent(_ socket: Socket, id: String) async throws -> FunASREnvelope {
        let event = try JSONDecoder().decode(FunASREnvelope.self, from: await receiveData(socket))
        guard event.header.taskID.caseInsensitiveCompare(id) == .orderedSame else { throw Failure.invalidResponse }
        if event.header.event == "task-failed" {
            let code = event.header.errorCode ?? "ASR_ERROR"
            let safeCode = code.range(of: #"^[A-Za-z0-9_.-]{1,48}$"#, options: .regularExpression) != nil
            throw Failure.rejected(safeCode ? code : "ASR_ERROR")
        }
        return event
    }

    private struct FunASREnvelope: Decodable {
        struct Header: Decodable {
            let taskID: String
            let event: String
            let errorCode: String?

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id", event, errorCode = "error_code"
            }
        }

        struct Payload: Decodable {
            struct Output: Decodable {
                struct Sentence: Decodable {
                    let beginTime: Int?
                    let endTime: Int?
                    let sentenceID: Int?
                    let sentenceEnd: Bool?
                    let heartbeat: Bool?
                    let text: String?

                    enum CodingKeys: String, CodingKey {
                        case beginTime = "begin_time", endTime = "end_time"
                        case sentenceID = "sentence_id", sentenceEnd = "sentence_end", heartbeat, text
                    }
                }
                let sentence: Sentence?
            }
            let output: Output?
        }

        let header: Header
        let payload: Payload?
    }
}

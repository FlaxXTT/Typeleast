import Foundation

enum OnlineASRProvider: String, CaseIterable, Sendable {
    case local, doubao, funASR
}

struct OnlineASRConfiguration: Sendable {
    let provider: OnlineASRProvider
    let apiKey: String
    let workspaceID: String
    var doubaoSpeechSmoothing = true
    var doubaoHotwords = ""
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
}

enum OnlineASR {
    private enum Failure: LocalizedError {
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

    static func transcribe(wav: Data, language: String, configuration: OnlineASRConfiguration) async throws -> String {
        try await recognize(wav: wav, language: language, configuration: configuration, meeting: false).text
    }

    static func transcribeMeeting(wav: Data, configuration: OnlineASRConfiguration) async throws -> OnlineASRTranscript {
        try await recognize(wav: wav, language: "auto", configuration: configuration, meeting: true)
    }

    private static func recognize(wav: Data, language: String, configuration: OnlineASRConfiguration,
                                  meeting: Bool) async throws -> OnlineASRTranscript {
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.provider != .local, !key.isEmpty,
              key.utf8.allSatisfy({ (0x21...0x7e).contains($0) })
        else { throw Failure.missingKey }
        guard Wav.isCanonical(wav), wav.count > 44 else { throw Failure.invalidAudio }
        let pcm = wav.dropFirst(44)

        switch configuration.provider {
        case .local:
            throw Failure.missingKey
        case .doubao:
            var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")!)
            let requestID = UUID().uuidString
            request.setValue(key, forHTTPHeaderField: "X-Api-Key")
            request.setValue("volc.seedasr.sauc.duration", forHTTPHeaderField: "X-Api-Resource-Id")
            request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
            request.setValue(requestID, forHTTPHeaderField: "X-Api-Connect-Id")
            request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
            return try await connect(request, duration: duration(pcm)) { socket in
                try await recognizeDoubao(socket, pcm: pcm, language: language, meeting: meeting,
                                          speechSmoothing: configuration.doubaoSpeechSmoothing, hotwords: configuration.doubaoHotwords)
            }
        case .funASR:
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
            return try await connect(request, duration: duration(pcm)) { socket in
                try await recognizeFunASR(socket, pcm: pcm, language: language, meeting: meeting)
            }
        }
    }

    private static func duration(_ pcm: Data) -> Double { Double(pcm.count) / 32_000 }

    private static func connect(_ request: URLRequest, duration: Double,
                                run: @escaping @Sendable (Socket) async throws -> OnlineASRTranscript) async throws -> OnlineASRTranscript {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = duration + 30
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        defer { session.invalidateAndCancel() }
        try Task.checkCancellation()
        socket.resume()
        return try await withThrowingTaskGroup(of: OnlineASRTranscript.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await run(socket)
                } onCancel: {
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(duration + 30))
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            guard var result = try await group.next() else { throw Failure.invalidResponse }
            result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    static func doubaoRequest(language: String, meeting: Bool, speechSmoothing: Bool, hotwords: String = "") -> [String: Any] {
        var audio: [String: Any] = ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1]
        let locales = ["zh": "zh-CN", "en": "en-US", "yue": "yue-CN", "ja": "ja-JP", "ko": "ko-KR"]
        if let locale = locales[language] { audio["language"] = locale }
        var options: [String: Any] = [
            "model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
            "enable_ddc": speechSmoothing && ["auto", "zh", "en"].contains(language),
            "result_type": "full"
        ]
        var seen = Set<String>()
        let words = hotwords.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(5_000)
        if !words.isEmpty, let context = try? json(["hotwords": words.map { ["word": $0] }]) {
            options["corpus"] = ["context": String(decoding: context, as: UTF8.self)]
        }
        if meeting {
            options["show_utterances"] = true
            options["enable_speaker_info"] = true
        }
        return ["audio": audio, "request": options]
    }

    private static func recognizeDoubao(_ socket: Socket, pcm: Data, language: String,
                                        meeting: Bool, speechSmoothing: Bool, hotwords: String) async throws -> OnlineASRTranscript {
        let request = doubaoRequest(language: language, meeting: meeting, speechSmoothing: speechSmoothing, hotwords: hotwords)
        try await socket.send(.data(doubaoFrame(type: 0x10, serialization: 0x10,
                                               payload: json(request))))
        let first = try await doubaoResult(socket)
        let initial = first.result?.transcript ?? OnlineASRTranscript(text: "")
        if first.last { return initial }

        return try await exchange(socket, send: {
            try await sendPCM(pcm) { chunk, last in
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

    private static func recognizeFunASR(_ socket: Socket, pcm: Data, language: String,
                                       meeting: Bool) async throws -> OnlineASRTranscript {
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
        let finish = try funASRCommand("finish-task", id: id, payload: ["input": [String: Any]()])
        try await socket.send(start)
        let started = try await funASREvent(socket, id: id)
        guard started.header.event == "task-started" else { throw Failure.invalidResponse }

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
            let safeCode = code.range(of: #"^[A-Za-z0-9_-]{1,48}$"#, options: .regularExpression) != nil
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

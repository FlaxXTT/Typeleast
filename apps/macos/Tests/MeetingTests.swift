import AVFoundation
import Foundation

/// Writes `seconds` of a stereo tone in another format, as an imported file would be.
private func writeTone(to url: URL, seconds: Double, settings: [String: Any]) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(seconds * 44100)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<2 {
        for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = 0.2 * sin(Float(frame) * 0.05) }
    }
    try file.write(from: buffer)
}

func meetingTests() {
    checkEq("a verified API key without TOS still needs upload setup",
            DoubaoMeetingSetup(locked: false, hasKey: true, hasStorage: false), .missingStorage)
    checkEq("a configured private bucket enables meeting actions when a key is saved",
            DoubaoMeetingSetup(locked: false, hasKey: true, hasStorage: true), .configured)
    checkEq("a locked vault takes precedence over missing Doubao settings",
            DoubaoMeetingSetup(locked: true, hasKey: false, hasStorage: false), .locked)
    let contextual = VocabularyRule(original: "Cloud Code", replacement: "Claude Code", context: "Anthropic")
    let generic = VocabularyRule(original: "code", replacement: "text")
    checkEq("a spoken brand can be corrected only in the intended sentence",
            Vocabulary.applying([contextual], to: "我用 Anthropic 的 CLOUD CODE。Google Cloud Code 可以调试。"),
            "我用 Anthropic 的 Claude Code。Google Cloud Code 可以调试。")
    checkEq("literal replacements respect Latin word boundaries even next to Chinese",
            Vocabulary.applying([generic], to: "用code和decode，以及code2。"), "用text和decode，以及code2。")
    let next = VocabularyRule(original: "Claude Code", replacement: "Codex")
    checkEq("replacement output is not fed into another rule",
            Vocabulary.applying([contextual, next, generic], to: "Anthropic 的 Cloud Code。"),
            "Anthropic 的 Claude Code。")
    let sameSpan = VocabularyRule(original: "Cloud Code", replacement: "Cloud Workspace")
    checkEq("a matching contextual rule wins over an unconditional rule on the same phrase",
            Vocabulary.applying([sameSpan, contextual], to: "Anthropic 的 Cloud Code。"),
            "Anthropic 的 Claude Code。")
    checkEq("editing hotwords uses the same deduplication as the Doubao request",
            Vocabulary.hotwords(from: " Claude Code\nTypeLeast\nClaude Code "), ["Claude Code", "TypeLeast"])
    let result = MeetingResult(segments: [
        MeetingSegment(start: 75.2, end: 80, speaker: "S01", text: "先看日志。"),
        MeetingSegment(start: 3700.5, end: nil, speaker: "S02", text: "已经回滚了。"),
    ], speakers: ["S01", "S02"], truncated: true)
    let renamed = result.applyingVocabulary([VocabularyRule(original: "日志", replacement: "运行日志")])
    checkEq("meeting export uses replaced text and keeps speaker timestamps",
            renamed.segments.first, MeetingSegment(start: 75.2, end: 80, speaker: "S01", text: "先看运行日志。"))
    checkEq("meeting text keeps time and speaker on every line", MeetingFormat.text(result), "[01:15] S01: 先看日志。\n[1:01:40] S02: 已经回滚了。\n")
    checkEq("meeting subtitles keep the speaker; a missing end gets three seconds", MeetingFormat.srt(result),
            "1\n00:01:15,200 --> 00:01:20,000\nS01: 先看日志。\n\n2\n01:01:40,500 --> 01:01:43,500\nS02: 已经回滚了。\n")

    let status = try? JSONDecoder().decode(MeetingStatus.self, from: Data(#"{"id":"a","phase":"done","seconds":6,"elapsedMs":900,"result":{"segments":[{"start":0.1,"end":null,"speaker":"S01","text":"x"}],"speakers":["S01"],"text":"x","truncated":true}}"#.utf8))
    checkEq("a finished status carries labelled turns", status?.result?.segments.first?.speaker, "S01")

    let doubaoPayload = Data(#"""
        {"result":{"text":"Hello. Thanks. Yes.","utterances":[
          {"text":"Hello.","start_time":300,"end_time":900,"additions":{"speaker_id":"0"}},
          {"text":"Thanks.","start_time":900,"end_time":1400,"additions":{"speaker_id":"1"}},
          {"text":"Yes.","start_time":1500,"end_time":1900,"additions":{"speaker_id":"0"}}
        ]}}
        """#.utf8)
    let doubao = try? JSONDecoder().decode(OnlineASR.DoubaoEnvelope.self, from: doubaoPayload)
    let speakerTurns = doubao?.result.map { MeetingResult.online($0.transcript, duration: 2) }
    checkEq("Doubao meeting speaker labels remain stable", speakerTurns?.segments.map(\.speaker), ["S01", "S02", "S01"])
    checkEq("Doubao meeting turns preserve timestamps", speakerTurns?.segments.map(\.start), [0.3, 0.9, 1.5])
    let smoothingOff = OnlineASR.doubaoRequest(language: "auto", meeting: true, speechSmoothing: false)["request"] as? [String: Any]
    checkEq("Doubao requests explicitly disable smoothing", smoothingOff?["enable_ddc"] as? Bool, false)
    checkEq("smoothing off keeps automatic punctuation", smoothingOff?["enable_punc"] as? Bool, true)
    checkEq("smoothing off keeps speaker information", smoothingOff?["enable_speaker_info"] as? Bool, true)
    let smoothingOn = OnlineASR.doubaoRequest(language: "en", meeting: false, speechSmoothing: true)["request"] as? [String: Any]
    checkEq("Doubao sends smoothing for English when enabled", smoothingOn?["enable_ddc"] as? Bool, true)
    checkEq("Doubao uses automatic punctuation by default", smoothingOn?["enable_punc"] as? Bool, true)
    checkEq("Doubao uses numeric normalization by default", smoothingOn?["enable_itn"] as? Bool, true)
    check("Doubao leaves out an empty hotword list", smoothingOn?["corpus"] == nil)
    let withHotwords = OnlineASR.doubaoRequest(language: "auto", meeting: false, speechSmoothing: true,
                                             hotwords: " TypeLeast \n\n语音识别\nTypeLeast")["request"] as? [String: Any]
    let corpus = withHotwords?["corpus"] as? [String: String]
    let terms = corpus?["context"].flatMap { try? JSONDecoder().decode([String: [[String: String]]].self, from: Data($0.utf8)) }
    checkEq("Doubao sends the deduplicated hotwords inside a serialized corpus context", terms?["hotwords"],
            [["word": "TypeLeast"], ["word": "语音识别"]])
    let withTables = OnlineASR.doubaoRequest(language: "auto", meeting: true, speechSmoothing: true,
                                           hotwords: "Claude Code", tables: .init(hotwords: " boost ", replacements: " correct "))["request"]
        as? [String: Any]
    let configuredCorpus = withTables?["corpus"] as? [String: String]
    checkEq("Doubao sends a saved console hotword table ID", configuredCorpus?["boosting_table_id"], "boost")
    checkEq("Doubao sends a saved console replacement table ID", configuredCorpus?["correct_table_id"], "correct")
    check("configured tables leave direct hotwords in the request", configuredCorpus?["context"]?.contains("Claude Code") == true)
    let japanese = OnlineASR.doubaoRequest(language: "ja", meeting: false, speechSmoothing: true)["request"] as? [String: Any]
    checkEq("Doubao keeps smoothing off for Japanese", japanese?["enable_ddc"] as? Bool, false)
    let plainResult = MeetingResult.online(OnlineASRTranscript(text: "Full transcript."), duration: 3)
    checkEq("a provider result without timing keeps the full transcript", plainResult.segments,
            [MeetingSegment(start: 0, end: 3, speaker: "", text: "Full transcript.")])
    checkEq("copy without a speaker omits the label", MeetingFormat.text(plainResult), "[00:00] Full transcript.\n")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-tests-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let m4a = folder.appendingPathComponent("stereo.m4a")
        try writeTone(to: m4a, seconds: 3, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2])
        let wav = try MeetingAudio.canonicalWav(from: m4a)
        check("an imported m4a becomes the canonical WAV", Wav.isCanonical(wav), Wav.describe(wav))
        check("the import keeps the length", abs((Wav.parse(wav)?.durationSeconds ?? 0) - 3) < 0.2)
        onlineMeetingTest(importURL: m4a)

        let aiff = folder.appendingPathComponent("long.aiff")
        try writeTone(to: aiff, seconds: 3, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false])
        do {
            _ = try MeetingAudio.canonicalWav(from: aiff, maxSeconds: 2)
            check("a file past the limit is refused", false)
        } catch { checkEq("a file past the limit is refused", error as? MeetingAudioError, .tooLong(3)) }

        let text = folder.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: text)
        do {
            _ = try MeetingAudio.canonicalWav(from: text)
            check("a file without audio is refused", false)
        } catch { checkEq("a file without audio is refused", error as? MeetingAudioError, .unreadable) }
    } catch { check("meeting import", false, String(describing: error)) }

    checkEq("main sidebar titles are in English", [HubPage.home, .history, .vocabulary, .meetings].map(\.title),
            ["Home", "History", "Vocabulary", "Conference"])
    checkEq("the client's limit matches the service's", MeetingLimits.maxSeconds, 600)
    checkEq("a missing model is explained", MeetingController.explain(code: "model-not-installed"), "还没有下载 MOSS 模型。")
    checkEq("meeting copy is translated", L10n.render("录音太短。", arguments: [], language: "en"), "The recording is too short.")
}

private func onlineMeetingTest(importURL: URL) {
    let suite = "typeleast-meeting-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = Settings(defaults: defaults)
    checkEq("existing settings keep Doubao smoothing on", settings.doubaoSpeechSmoothing, true)
    checkEq("existing settings keep AI cleanup on", settings.dictationCleanupEnabled, true)
    checkEq("dictation defaults to direct through 25 and brief through 100", settings.shortDictationCleanup,
            ShortDictationCleanup(maxUnits: 25, route: nil, fullAbove: 100))
    defaults.set("direct", forKey: "voice.shortDictationMode")
    checkEq("legacy direct preference adopts the three tiers", settings.shortDictationMode, .mainModel)
    settings.shortDictationMode = .smallModel
    checkEq("optional small model uses the same tier boundaries", settings.shortDictationCleanup?.useSmallModel, true)
    checkEq("the small model preference persists", Settings(defaults: defaults).shortDictationMode, .smallModel)
    settings.doubaoHotwords = "TypeLeast"
    checkEq("the user's Doubao hotwords persist", Settings(defaults: defaults).doubaoHotwords, "TypeLeast")
    settings.doubaoSpeechSmoothing = false
    settings.dictationCleanupEnabled = false
    checkEq("the master cleanup switch takes priority over short routing", settings.shortDictationCleanup, nil)
    checkEq("Doubao smoothing choice persists", Settings(defaults: defaults).doubaoSpeechSmoothing, false)
    checkEq("AI cleanup choice persists", Settings(defaults: defaults).dictationCleanupEnabled, false)
    checkEq("existing installations keep on-device meeting recognition", settings.meetingASRProvider, .local)
    settings.meetingASRProvider = .doubao
    checkEq("the meeting model keeps its own setting", Settings(defaults: defaults).meetingASRProvider, .doubao)
    checkEq("changing the meeting provider leaves dictation on device", settings.onlineASRProvider, .local)
    settings.funASRWorkspaceID = "test-workspace"

    enum ProviderFailure: LocalizedError {
        case unavailable, invalidConfiguration
        var errorDescription: String? {
            self == .unavailable ? "Fixture provider unavailable" : "Fixture invalid configuration"
        }
    }
    let meeting = MeetingController(settings: settings, recognizeCloud: { wav, configuration in
        if configuration.provider == .doubao {
            if configuration.doubaoSpeechSmoothing || configuration.doubaoHotwords != "TypeLeast" { throw ProviderFailure.invalidConfiguration }
            throw ProviderFailure.unavailable
        }
        guard configuration.provider == .funASR, configuration.apiKey == "fixture-funASR",
              configuration.workspaceID == "test-workspace", Wav.isCanonical(wav) else {
            throw ProviderFailure.invalidConfiguration
        }
        try await Task.sleep(for: .milliseconds(30))
        return OnlineASRTranscript(text: "Recognized.", utterances: [
            OnlineASRUtterance(startMilliseconds: 1200, endMilliseconds: 1800, speakerID: nil, text: "Recognized.")
        ])
    }, cloudKey: { "fixture-" + $0.rawValue })

    func wait(for stage: MeetingController.Stage) {
        let deadline = Date().addingTimeInterval(2)
        while meeting.stage != stage && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    meeting.importFile(importURL)
    settings.meetingASRProvider = .funASR
    wait(for: .failed)
    checkEq("meeting import uses the provider selected when it started", meeting.stage, .failed)
    checkEq("meeting uses the saved Doubao smoothing preference", meeting.message, "Fixture provider unavailable")
    check("online failure retains the audio for retry", meeting.canRetry)

    meeting.retry()
    checkEq("retry switches to the newly selected cloud provider", meeting.stage, .transcribing)
    check("cloud meetings do not use the local live preview", !meeting.usesLivePreview)
    wait(for: .done)
    checkEq("retry produces a timed online transcript", meeting.result?.segments.first,
            MeetingSegment(start: 1.2, end: 1.8, speaker: "", text: "Recognized."))
    checkEq("a provider without speaker attribution leaves the speaker list empty", meeting.result?.speakers, [])

    let prior = meeting.transcript?.id
    meeting.send(Wav.header(dataBytes: 32_000) + Data(count: 32_000))
    meeting.cancel()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    checkEq("cancelling online transcription returns to the prior result", meeting.stage, .done)
    checkEq("a cancelled online request cannot replace the prior result", meeting.transcript?.id, prior)
}

func doubaoFileMeetingTests() {
    let storage = DoubaoMeetingStorage(bucket: "examplebucket", region: "cn-beijing", accessKey: "testAK", secretKey: "testSK")
    let date = Date(timeIntervalSince1970: 1_640_995_200)
    let fixture = storage.signedURL(method: "GET", object: "exampleobject", validFor: 86_400, now: date)
    check("private meeting storage reproduces the official TOS signature",
          fixture.absoluteString.hasSuffix("X-Tos-Signature=353aa55583eceb222aad4bdcb70d4045a202a4af9a3096f25a656b82c8ec2f56"))

    final class Exchange: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        func append(_ request: URLRequest) -> Int {
            lock.withLock { requests.append(request); return requests.count }
        }
        func snapshot() -> [URLRequest] { lock.withLock { requests } }
    }

    let exchange = Exchange()
    let completed = DispatchSemaphore(value: 0)
    let result = NSLock()
    nonisolated(unsafe) var transcript: OnlineASRTranscript?
    let asr = DoubaoMeetingASR(transport: { request in
        let index = exchange.append(request)
        let status = index == 3 ? "20000002" : "20000000"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["X-Api-Status-Code": status])!
        let payload = #"{"result":{"text":"Ready","utterances":[{"text":"Ready","start_time":100,"end_time":900,"additions":{"speaker":"2"}}]}}"#
        return (Data(payload.utf8), response)
    }, pause: {})
    let audio = Data([1, 2, 3, 4])
    Task.detached {
        let value = try? await asr.transcribe(wav: audio, configuration: .init(provider: .doubao, apiKey: "fixture",
                                                                            workspaceID: "", doubaoTables: .init(replacements: "replacement-fixture")), storage: storage)
        result.withLock { transcript = value }
        completed.signal()
    }
    checkEq("file ASR fixture completes", completed.wait(timeout: .now() + 2), .success)
    let requests = exchange.snapshot()
    checkEq("file ASR uploads once, polls queued task to completion and deletes the object",
            requests.compactMap(\.httpMethod), ["PUT", "POST", "POST", "POST", "DELETE"])
    if requests.count == 5 {
        checkEq("TOS receives the original WAV bytes", requests[0].httpBody, audio)
        checkEq("TOS does not receive the Doubao credential", requests[0].value(forHTTPHeaderField: "X-Api-Key"), nil)
        checkEq("Doubao receives the standard 2.0 resource",
                requests[1].value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.seedasr.auc")
        checkEq("Doubao submit and query share a task identifier", requests[1].value(forHTTPHeaderField: "X-Api-Request-Id"),
                requests[3].value(forHTTPHeaderField: "X-Api-Request-Id"))
        let payload = try? JSONSerialization.jsonObject(with: requests[1].httpBody ?? Data()) as? [String: Any]
        let options = payload?["request"] as? [String: Any]
        checkEq("Doubao files send the same replacement table field",
                (options?["corpus"] as? [String: String])?["correct_table_id"], "replacement-fixture")
        let link = (payload?["audio"] as? [String: String])?["url"].flatMap(URL.init(string:))
        checkEq("the submitted signed URL points to the same private object", link?.path, requests[0].url?.path)
        checkEq("only that temporary object is deleted", requests[4].url?.path, requests[0].url?.path)
    }
    checkEq("file ASR reads speaker attribution", result.withLock { transcript?.utterances.first?.speakerID }, "2")
}

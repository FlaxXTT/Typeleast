import AVFoundation
import Foundation
import SwiftUI

// Meeting.swift - record or import one meeting, transcribe locally or online, and keep the
// speaker-labelled transcript for copying or saving. The transcript lives in memory and
// remains available while the app processes an imported file.

struct MeetingSegment: Codable, Equatable, Identifiable {
    var start: Double
    var end: Double?
    var speaker: String
    var text: String
    var id: String { speaker + String(start) }
    var labelledText: String { speaker.isEmpty ? text : speaker + ": " + text }
}

struct MeetingResult: Codable, Equatable {
    var segments: [MeetingSegment]
    var speakers: [String]
    var truncated: Bool?

    func applyingVocabulary(_ rules: [VocabularyRule]) -> Self {
        guard !rules.isEmpty else { return self }
        var result = self
        for index in result.segments.indices {
            result.segments[index].text = Vocabulary.applying(rules, to: result.segments[index].text)
        }
        return result
    }

    static func online(_ transcript: OnlineASRTranscript, duration: Double) -> Self {
        var speakerLabels: [String: String] = [:]
        var speakers: [String] = []
        var segments = transcript.utterances.sorted { $0.startMilliseconds < $1.startMilliseconds }.compactMap { item -> MeetingSegment? in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var speaker = ""
            if let id = item.speakerID, !id.isEmpty {
                if let existing = speakerLabels[id] {
                    speaker = existing
                } else {
                    speaker = String(format: "S%02d", speakers.count + 1)
                    speakerLabels[id] = speaker
                    speakers.append(speaker)
                }
            }
            let start = min(duration, max(0, Double(item.startMilliseconds) / 1000))
            let end = item.endMilliseconds.map { min(duration, max(start, Double($0) / 1000)) }
            return MeetingSegment(start: start, end: end, speaker: speaker, text: text)
        }
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segments.isEmpty, !text.isEmpty {
            segments = [MeetingSegment(start: 0, end: duration, speaker: "", text: text)]
        }
        return Self(segments: segments, speakers: speakers)
    }
}

/// Answer of `GET /meetings/status`.
struct MeetingStatus: Codable, Equatable {
    var id: String
    var phase: String
    var seconds: Double
    var elapsedMs: Double
    var code: String?
    var result: MeetingResult?
}

enum MeetingLimits {
    /// The service's MAX_MEETING_SECONDS (tasks/meeting.js).
    static let maxSeconds = 10 * 60
    static let modelID = "moss-transcribe-diarize"
}

enum MeetingFormat {
    /// 75.2 -> "01:15"; an hour or more -> "1:01:15".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    /// `[01:15] S02: text`, one turn per line.
    static func text(_ result: MeetingResult) -> String {
        result.segments.map { "[" + clock($0.start) + "] " + $0.labelledText }.joined(separator: "\n") + "\n"
    }

    private static func srtTime(_ seconds: Double) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60000 % 60, millis / 1000 % 60, millis % 1000)
    }

    /// Subtitles. A turn with no end time (the last one, when cut off) gets three seconds.
    static func srt(_ result: MeetingResult) -> String {
        result.segments.enumerated().map { index, turn in
            String(index + 1) + "\n" + srtTime(turn.start) + " --> " + srtTime(turn.end ?? turn.start + 3) + "\n" + turn.labelledText + "\n"
        }.joined(separator: "\n")
    }
}

enum MeetingAudioError: Error, Equatable {
    case tooLong(Double)
    case unreadable
    case tooShort
}

enum MeetingAudio {
    /// Any audio or video file AVFoundation can open -> canonical 16 kHz mono PCM16 WAV.
    static func canonicalWav(from url: URL, maxSeconds: Int = MeetingLimits.maxSeconds) throws -> Data {
        let asset = AVURLAsset(url: url)
        let seconds = asset.duration.seconds
        if seconds.isFinite, seconds > Double(maxSeconds) { throw MeetingAudioError.tooLong(seconds) }
        let tracks = asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty, let reader = try? AVAssetReader(asset: asset) else { throw MeetingAudioError.unreadable }
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw MeetingAudioError.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw MeetingAudioError.unreadable }
        var pcm = Data()
        let limit = maxSeconds * Recorder.bytesPerSecond
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length))
            if pcm.count > limit {
                reader.cancelReading()
                throw MeetingAudioError.tooLong(Double(pcm.count) / Double(Recorder.bytesPerSecond))
            }
        }
        guard reader.status == .completed else { throw MeetingAudioError.unreadable }
        guard pcm.count >= Recorder.bytesPerSecond else { throw MeetingAudioError.tooShort }
        return Wav.wrap(pcm: pcm)
    }
}

/// A preview can finish after the user cancels or starts another meeting.
private final class MeetingPreviewToken {
    private let lock = NSLock()
    private var cancelled = false
    private var finishing = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func requestFinish() { lock.lock(); finishing = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var shouldStop: Bool { lock.lock(); defer { lock.unlock() }; return cancelled || finishing }
}

/// What the Meetings page shows. The one meeting flow: audio in, job, transcript out.
final class MeetingController: ObservableObject {
    enum Stage: Equatable { case idle, recording, converting, transcribing, done, failed }
    enum DoubaoConnection: Equatable { case untested, testing, connected, failed }
    typealias CloudRecognizer = @Sendable (Data, OnlineASRConfiguration) async throws -> OnlineASRTranscript

    struct Transcript: Identifiable {
        let id: String
        let result: MeetingResult
        let seconds: Double
        let elapsed: Double
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var message = ""
    @Published private(set) var seconds: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var transcript: Transcript?
    /// Provisional text has no speaker identity: chunk-local speaker IDs cannot be joined.
    @Published private(set) var liveTranscript = ""
    @Published private(set) var liveWarning = false
    @Published private(set) var modelInstalled: Bool?
    @Published private(set) var download: SpeechModelOperation?
    @Published private(set) var doubaoConnection: DoubaoConnection = .untested

    private let client: ServiceClient
    private let settings: Settings
    private let recognizeCloud: CloudRecognizer
    private let cloudKey: @Sendable (OnlineASRProvider) -> String
    private let modelRefresh = CoalescingRefresh<SpeechModelCatalog>()
    private var modelPoll: DispatchWorkItem?
    let recorder = Recorder()
    private var meter: Timer?
    /// Kept until a transcript exists, so a failure (a missing model, say) can be retried.
    private var audio: Data?
    private var jobID: String?
    private var generation = 0
    private var liveQueue = MeetingLiveQueue()
    private let liveChunkBytes: Int
    private var liveToken: MeetingPreviewToken?
    private var finalToken: MeetingPreviewToken?
    private var liveJobID: String?
    private var finalAfterPreview: Data?
    private var provider: OnlineASRProvider = .local
    private var cloudTask: Task<Void, Never>?
    private var doubaoTest: Task<Void, Never>?
    var pollInterval: TimeInterval = 2

    init(client: ServiceClient = .shared, liveChunkBytes: Int = 320_000, settings: Settings = .shared,
         recognizeCloud: @escaping CloudRecognizer = { wav, configuration in
             if configuration.provider == .doubao {
                 guard !configuration.apiKey.isEmpty else { throw DoubaoMeetingASR.Failure.missingKey }
                 guard let storage = DoubaoMeetingStorage.saved() else { throw DoubaoMeetingASR.Failure.missingStorage }
                 return try await DoubaoMeetingASR().transcribe(wav: wav, configuration: configuration, storage: storage)
             }
             return try await OnlineASR.transcribeMeeting(wav: wav, configuration: configuration)
         },
         cloudKey: @escaping @Sendable (OnlineASRProvider) -> String = {
             $0 == .doubao ? DoubaoMeetingASR.savedKey() : KeychainStore.read(account: $0.keychainAccount) ?? ""
         }) {
        self.client = client
        self.settings = settings
        self.recognizeCloud = recognizeCloud
        self.cloudKey = cloudKey
        self.liveChunkBytes = liveChunkBytes
        self.liveQueue = MeetingLiveQueue(chunkBytes: liveChunkBytes)
    }

    var busy: Bool { [.recording, .converting, .transcribing].contains(stage) }
    var canRetry: Bool { stage == .failed && audio != nil }
    var result: MeetingResult? { transcript?.result }
    var usesLivePreview: Bool { provider == .local }

    @MainActor func checkDoubaoConnection(force: Bool = false) {
        guard force || doubaoConnection == .untested else { return }
        let key = cloudKey(.doubao)
        doubaoTest?.cancel()
        guard !key.isEmpty else { doubaoConnection = .untested; return }
        doubaoConnection = .testing
        doubaoTest = Task {
            do {
                try await DoubaoMeetingASR().testConnection(apiKey: key)
                if !Task.isCancelled { doubaoConnection = .connected }
            } catch {
                if !Task.isCancelled { doubaoConnection = .failed }
            }
        }
    }

    // MARK: model

    func refreshModel() {
        modelPoll?.cancel()
        modelPoll = nil
        modelRefresh.request(work: { [client] in try client.speechModelsSync() }) { [weak self] result in
            guard let self, case .success(let catalog) = result else { return }
            let operation = catalog.operation?.modelId == MeetingLimits.modelID ? catalog.operation : nil
            let installed = catalog.models.first { $0.id == MeetingLimits.modelID }?.installed ?? false
            if self.modelInstalled != installed { self.modelInstalled = installed }
            let download = operation?.phase == "downloading" ? operation : nil
            if self.download != download { self.download = download }
            if self.download != nil {
                let poll = DispatchWorkItem { [weak self] in self?.refreshModel() }
                self.modelPoll = poll
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: poll)
            }
        }
    }

    /// Downloads MOSS without changing the model dictation uses.
    func downloadModel(mirror: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.client.speechModelActionSync(id: MeetingLimits.modelID, download: true, endpoint: mirror, activate: false)
                DispatchQueue.main.async { self.refreshModel() }
            } catch { DispatchQueue.main.async { self.fail(L10n.text("模型下载没有开始，请重试。")) } }
        }
    }

    // MARK: recording

    func startRecording(deviceUID: String) {
        guard !busy else { return }
        if recorder.demoPCM == nil, Recorder.authorizationStatus() == .notDetermined {
            Recorder.requestMicrophoneAccess { [weak self] granted in
                if granted { self?.startRecording(deviceUID: deviceUID) } else { self?.fail(RecorderError.permissionDenied.description) }
            }
            return
        }
        let deviceID = AudioDevices.deviceID(forUID: deviceUID)
        recorder.prepareEngine = { engine in AudioInputSelector.apply(deviceID: deviceID, to: engine) }
        recorder.maxSeconds = MeetingLimits.maxSeconds
        recorder.onAutoStop = { [weak self] in self?.stopRecording() }
        do { try recorder.start() } catch { fail(String(describing: error)); return }
        reset()
        provider = settings.meetingASRProvider
        transcript = nil
        stage = .recording
        if usesLivePreview { liveToken = MeetingPreviewToken() }
        meter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.seconds = self.recorder.elapsed
            self.level = self.recorder.level()
            if self.usesLivePreview { self.updateLivePreview() }
        }
    }

    func stopRecording() {
        guard stage == .recording else { return }
        meter?.invalidate(); meter = nil
        do {
            let file = try recorder.finish()
            defer { recorder.cancel() }
            defer { try? FileManager.default.removeItem(at: file.url) }
            let wav = try Data(contentsOf: file.url)
            if liveQueue.isProcessing {
                // Finish the current small preview first; MOSS accepts only one job at a time.
                // Unprocessed preview audio remains in the complete recording below.
                audio = wav
                finalAfterPreview = wav
                stage = .transcribing
                elapsed = 0
                liveToken?.requestFinish()
                // A slow preview should not delay the final whole-meeting transcript.
                if let id = liveJobID {
                    DispatchQueue.global(qos: .utility).async { [client] in try? client.meetingCancelSync(id: id) }
                }
            } else {
                liveToken?.cancel()
                send(wav, provider: provider)
            }
        } catch { recorder.cancel(); fail(String(describing: error)) }
    }

    // MARK: import

    func importFile(_ url: URL) {
        guard !busy else { return }
        reset()
        let provider = settings.meetingASRProvider
        self.provider = provider
        stage = .converting
        let run = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let wav = try MeetingAudio.canonicalWav(from: url)
                DispatchQueue.main.async { if self?.generation == run { self?.send(wav, provider: provider) } }
            } catch {
                let text: String
                switch error as? MeetingAudioError {
                case .tooLong(let seconds): text = L10n.text("录音有 {0} 分钟，超过 {1} 分钟上限。请先分段。", Int(seconds / 60), MeetingLimits.maxSeconds / 60)
                case .tooShort: text = L10n.text("录音太短。")
                default: text = L10n.text("读不出这个文件里的音频。")
                }
                DispatchQueue.main.async { if self?.generation == run { self?.fail(text) } }
            }
        }
    }

    // MARK: job

    func retry() { if let audio, stage == .failed { send(audio) } }

    func cancel() {
        generation += 1
        cloudTask?.cancel()
        cloudTask = nil
        liveToken?.cancel()
        finalToken?.cancel()
        liveToken = nil
        finalToken = nil
        liveQueue.cancel()
        finalAfterPreview = nil
        meter?.invalidate(); meter = nil
        if stage == .recording { recorder.cancel() }
        let id = jobID
        let previewID = liveJobID
        jobID = nil
        liveJobID = nil
        audio = nil
        liveTranscript = ""
        liveWarning = false
        stage = transcript == nil ? .idle : .done
        message = ""
        if let id { DispatchQueue.global(qos: .utility).async { [client] in try? client.meetingCancelSync(id: id) } }
        if let previewID { DispatchQueue.global(qos: .utility).async { [client] in try? client.meetingCancelSync(id: previewID) } }
    }

    /// One local MOSS job at a time, while the microphone continues to capture audio.
    /// The completed whole recording is always analysed again to assign speaker labels.
    private func updateLivePreview() {
        guard stage == .recording, let token = liveToken, !token.isCancelled,
              let range = liveQueue.offer(availableBytes: recorder.byteCount) else { return }
        let snapshot = recorder.pcmSnapshot(fromByteOffset: range.startByte, endByteOffset: range.endByte)
        guard snapshot.nextByteOffset == range.endByte else {
            liveWarning = true
            liveQueue.complete()
            return
        }
        let wav = Wav.wrap(pcm: snapshot.pcm)
        let run = generation
        let requestID = UUID().uuidString.lowercased()
        liveJobID = requestID
        DispatchQueue.global(qos: .userInitiated).async { [weak self, client] in
            var preview: MeetingResult?
            var failed = false
            do {
                guard !token.shouldStop else { throw CancellationError() }
                let started = try client.meetingStartSync(wav: wav, timeout: 3, requestID: requestID)
                guard started == requestID else {
                    try? client.meetingCancelSync(id: started)
                    throw ServiceError.decoding("meeting request id")
                }
                var misses = 0
                while !token.shouldStop {
                    Thread.sleep(forTimeInterval: self?.pollInterval ?? 2)
                    if token.shouldStop { break }
                    do {
                        let status = try client.meetingStatusSync(id: started, timeout: 3)
                        misses = 0
                        if status.phase == "done" { preview = status.result; break }
                        if status.phase == "failed" || status.phase == "cancelled" { failed = true; break }
                    } catch {
                        misses += 1
                        if error.meetingJobIsGone || misses >= 3 { failed = true; break }
                    }
                }
            } catch { failed = true }
            // The service can cancel this client-chosen ID even if the start response was lost.
            try? client.meetingCancelSync(id: requestID)
            DispatchQueue.main.async {
                guard let self, self.generation == run, !token.isCancelled else { return }
                self.liveJobID = nil
                if (failed || preview?.truncated == true) && self.finalAfterPreview == nil { self.liveWarning = true }
                if let preview {
                    let text = preview.segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        if !self.liveTranscript.isEmpty { self.liveTranscript += "\n" }
                        self.liveTranscript += text
                    }
                }
                self.liveQueue.complete()
                if let final = self.finalAfterPreview {
                    self.finalAfterPreview = nil
                    token.cancel()
                    self.send(final, provider: .local)
                } else {
                    self.updateLivePreview()
                }
            }
        }
    }

    func send(_ wav: Data, provider selected: OnlineASRProvider? = nil) {
        audio = wav
        generation += 1
        let run = generation
        cloudTask?.cancel()
        cloudTask = nil
        meter?.invalidate()
        meter = nil
        finalToken?.cancel()
        finalToken = nil
        jobID = nil
        provider = selected ?? settings.meetingASRProvider
        seconds = Double(max(0, wav.count - 44)) / Double(Recorder.bytesPerSecond)
        elapsed = 0
        message = ""
        stage = .transcribing
        if provider != .local {
            sendCloud(wav, provider: provider, run: run)
            return
        }
        let token = MeetingPreviewToken()
        let rules = settings.vocabularyReplacements
        finalToken = token
        let requestID = UUID().uuidString.lowercased()
        jobID = requestID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                guard !token.isCancelled else { throw CancellationError() }
                let id = try self.client.meetingStartSync(wav: wav, requestID: requestID)
                guard id == requestID else { try? self.client.meetingCancelSync(id: id); throw ServiceError.decoding("meeting request id") }
                if token.isCancelled { try? self.client.meetingCancelSync(id: id); return }
                self.poll(id: id, run: run, token: token, rules: rules)
                if token.isCancelled { try? self.client.meetingCancelSync(id: id) }
            } catch {
                try? self.client.meetingCancelSync(id: requestID)
                DispatchQueue.main.async { if self.generation == run { self.fail(Self.explain(error)) } }
            }
        }
    }

    private func sendCloud(_ wav: Data, provider: OnlineASRProvider, run: Int) {
        let start = ProcessInfo.processInfo.systemUptime
        let duration = seconds
        let workspaceID = settings.funASRWorkspaceID
        let speechSmoothing = settings.doubaoSpeechSmoothing
        let hotwords = provider == .doubao ? settings.doubaoHotwords : ""
        let tables = settings.doubaoVocabularyTables
        let rules = settings.vocabularyReplacements
        let recognize = recognizeCloud
        let key = cloudKey
        meter?.invalidate()
        meter = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.elapsed = ProcessInfo.processInfo.systemUptime - start
        }
        cloudTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let configuration = OnlineASRConfiguration(provider: provider, apiKey: key(provider), workspaceID: workspaceID,
                                                           doubaoSpeechSmoothing: speechSmoothing, doubaoHotwords: hotwords,
                                                           doubaoTables: tables)
                try Task.checkCancellation()
                let response = try await recognize(wav, configuration)
                try Task.checkCancellation()
                let result = MeetingResult.online(response, duration: duration).applyingVocabulary(rules)
                await MainActor.run { [weak self] in
                    guard let self, self.generation == run else { return }
                    self.finishCloud(started: start)
                    self.transcript = Transcript(id: UUID().uuidString, result: result, seconds: duration, elapsed: self.elapsed)
                    self.audio = nil
                    if response.temporaryAudioCleanupFailed {
                        self.message = DoubaoMeetingASR.Failure.cleanup.localizedDescription
                    }
                    self.stage = .done
                }
            } catch {
                guard !Task.isCancelled else { return }
                let text = (error as? LocalizedError)?.errorDescription ?? L10n.text("联网会议转写失败，可以重试。")
                await MainActor.run { [weak self] in
                    guard let self, self.generation == run else { return }
                    self.finishCloud(started: start)
                    self.fail(text)
                }
            }
        }
    }

    private func finishCloud(started: TimeInterval) {
        meter?.invalidate()
        meter = nil
        cloudTask = nil
        elapsed = ProcessInfo.processInfo.systemUptime - started
    }

    private func poll(id: String, run: Int, token: MeetingPreviewToken, rules: [VocabularyRule]) {
        var misses = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 21 * 60
        while !token.isCancelled {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                try? client.meetingCancelSync(id: id)
                DispatchQueue.main.async { if self.generation == run { self.fail(Self.explain(code: "meeting-timeout")) } }
                return
            }
            Thread.sleep(forTimeInterval: pollInterval)
            if token.isCancelled { break }
            do {
                let status = try client.meetingStatusSync(id: id)
                let result = status.result?.applyingVocabulary(rules)
                misses = 0
                DispatchQueue.main.async {
                    guard self.generation == run else { return }
                    self.elapsed = status.elapsedMs / 1000
                    switch status.phase {
                    case "done":
                        guard let result else {
                            self.fail(Self.explain(code: status.code))
                            return
                        }
                        self.transcript = Transcript(id: id, result: result, seconds: self.seconds, elapsed: self.elapsed)
                        self.audio = nil
                        self.stage = .done
                    case "failed", "cancelled": self.fail(Self.explain(code: status.code))
                    default: break
                    }
                }
                if !["preparing", "transcribing"].contains(status.phase) {
                    // The transcript is here now; the service keeps no copy.
                    try? client.meetingCancelSync(id: id)
                    return
                }
            } catch {
                misses += 1
                // A restarted service has lost the job; a moment's trouble has not.
                if error.meetingJobIsGone || misses >= 15 {
                    DispatchQueue.main.async { if self.generation == run { self.fail(L10n.text("本地服务中断了转写。可以重试。")) } }
                    return
                }
            }
        }
    }

    private func reset() {
        generation += 1
        cloudTask?.cancel()
        cloudTask = nil
        liveToken?.cancel()
        finalToken?.cancel()
        liveToken = nil
        finalToken = nil
        liveQueue = MeetingLiveQueue(chunkBytes: liveChunkBytes)
        liveJobID = nil
        finalAfterPreview = nil
        liveTranscript = ""
        liveWarning = false
        audio = nil
        jobID = nil
        message = ""
        seconds = 0
        elapsed = 0
    }

    private func fail(_ text: String) {
        message = text
        stage = .failed
    }

    static func explain(code: String?) -> String {
        switch code {
        case "model-not-installed": return L10n.text("还没有下载 MOSS 模型。")
        case "meeting-timeout": return L10n.text("会议转写超时，处理已停止。可以重试或缩短录音。")
        case "meeting-unavailable": return L10n.text("MOSS 引擎启动失败。")
        case "busy": return L10n.text("另一场会议正在转写。")
        default: return L10n.text("转写失败。可以重试。")
        }
    }

    static func explain(_ error: Error) -> String {
        if let error = error as? ServiceError, case .http(_, let code, _) = error { return explain(code: code) }
        return explain(code: nil)
    }
}

private extension Error {
    var meetingJobIsGone: Bool {
        if let error = self as? ServiceError, case .http(let status, _, _) = error { return status == 404 }
        return false
    }
}

extension ServiceClient {
    /// Long enough to hand the largest recording to the service on this computer.
    private static let meetingUploadTimeout: TimeInterval = 120

    func meetingStartSync(wav: Data, language: String = "auto", timeout: TimeInterval? = nil, requestID: String? = nil) throws -> String {
        var headers = ["content-type": "audio/wav", "x-voice-language": language]
        if let requestID { headers["x-meeting-request-id"] = requestID }
        return try sendMeeting(path: "/meetings", body: wav, headers: headers, timeout: timeout ?? Self.meetingUploadTimeout) { data in
            guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else { throw ServiceError.decoding("meeting id") }
            return id
        }
    }

    func meetingStatusSync(id: String, timeout: TimeInterval = 10) throws -> MeetingStatus {
        let query = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? ""
        return try sendMeeting(path: "/meetings/status?id=" + query, body: nil, headers: [:], timeout: timeout) { data in
            do { return try JSONDecoder().decode(MeetingStatus.self, from: data) }
            catch { throw ServiceError.decoding(String(describing: error)) }
        }
    }

    func meetingCancelSync(id: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["id": id])
        _ = try sendMeeting(path: "/meetings/cancel", body: body, headers: ["content-type": "application/json"], timeout: 10) { _ in true }
    }
}

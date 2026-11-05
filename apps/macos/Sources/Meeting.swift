import AVFoundation
import Foundation
import SwiftUI

// Meeting.swift - record or import one meeting, send it to the service's MOSS job, and keep the
// speaker-labelled transcript for copying or saving. The transcript lives in memory until the
// next meeting: it is not added to History.

struct MeetingSegment: Codable, Equatable, Identifiable {
    var start: Double
    var end: Double?
    var speaker: String
    var text: String
    var id: String { speaker + String(start) }
}

struct MeetingResult: Codable, Equatable {
    var segments: [MeetingSegment]
    var speakers: [String]
    var truncated: Bool?
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
        result.segments.map { "[" + clock($0.start) + "] " + $0.speaker + ": " + $0.text }.joined(separator: "\n") + "\n"
    }

    private static func srtTime(_ seconds: Double) -> String {
        let millis = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60000 % 60, millis / 1000 % 60, millis % 1000)
    }

    /// Subtitles. A turn with no end time (the last one, when cut off) gets three seconds.
    static func srt(_ result: MeetingResult) -> String {
        result.segments.enumerated().map { index, turn in
            String(index + 1) + "\n" + srtTime(turn.start) + " --> " + srtTime(turn.end ?? turn.start + 3) + "\n" + turn.speaker + ": " + turn.text + "\n"
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

/// What the Meetings page shows. The one meeting flow: audio in, job, transcript out.
final class MeetingController: ObservableObject {
    enum Stage: Equatable { case idle, recording, converting, transcribing, done, failed }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var message = ""
    @Published private(set) var seconds: Double = 0
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var result: MeetingResult?
    @Published private(set) var modelInstalled: Bool?
    @Published private(set) var download: SpeechModelOperation?

    private let client: ServiceClient
    let recorder = Recorder()
    private var meter: Timer?
    /// Kept until a transcript exists, so a failure (a missing model, say) can be retried.
    private var audio: Data?
    private var jobID: String?
    private var generation = 0
    var pollInterval: TimeInterval = 2

    init(client: ServiceClient = .shared) { self.client = client }

    var busy: Bool { [.recording, .converting, .transcribing].contains(stage) }
    var canRetry: Bool { stage == .failed && audio != nil }

    // MARK: model

    func refreshModel() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let catalog = try? self.client.speechModelsSync() else { return }
            let operation = catalog.operation?.modelId == MeetingLimits.modelID ? catalog.operation : nil
            let installed = catalog.models.first { $0.id == MeetingLimits.modelID }?.installed ?? false
            DispatchQueue.main.async {
                self.modelInstalled = installed
                self.download = operation?.phase == "downloading" ? operation : nil
                if self.download != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refreshModel() }
                }
            }
        }
    }

    /// Downloads MOSS without changing the model dictation uses.
    func downloadModel(mirror: String) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.client.speechModelActionSync(id: MeetingLimits.modelID, download: true, endpoint: mirror, activate: false)
                self.refreshModel()
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
        stage = .recording
        meter = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.seconds = self.recorder.elapsed
            self.level = self.recorder.level()
        }
    }

    func stopRecording() {
        guard stage == .recording else { return }
        meter?.invalidate(); meter = nil
        do {
            let file = try recorder.finish()
            defer { try? FileManager.default.removeItem(at: file.url) }
            let wav = try Data(contentsOf: file.url)
            send(wav)
        } catch { fail(String(describing: error)) }
    }

    // MARK: import

    func importFile(_ url: URL) {
        guard !busy else { return }
        reset()
        stage = .converting
        let run = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let wav = try MeetingAudio.canonicalWav(from: url)
                DispatchQueue.main.async { if self?.generation == run { self?.send(wav) } }
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
        meter?.invalidate(); meter = nil
        if stage == .recording { recorder.cancel() }
        let id = jobID
        jobID = nil
        audio = nil
        stage = .idle
        message = ""
        if let id { DispatchQueue.global(qos: .utility).async { [client] in try? client.meetingCancelSync(id: id) } }
    }

    func send(_ wav: Data) {
        audio = wav
        generation += 1
        let run = generation
        seconds = Double(max(0, wav.count - 44)) / Double(Recorder.bytesPerSecond)
        elapsed = 0
        message = ""
        result = nil
        stage = .transcribing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let id = try self.client.meetingStartSync(wav: wav)
                DispatchQueue.main.async { if self.generation == run { self.jobID = id } }
                self.poll(id: id, run: run)
            } catch {
                DispatchQueue.main.async { if self.generation == run { self.fail(Self.explain(error)) } }
            }
        }
    }

    private func poll(id: String, run: Int) {
        var misses = 0
        while generation == run {
            Thread.sleep(forTimeInterval: pollInterval)
            do {
                let status = try client.meetingStatusSync(id: id)
                misses = 0
                DispatchQueue.main.async {
                    guard self.generation == run else { return }
                    self.elapsed = status.elapsedMs / 1000
                    switch status.phase {
                    case "done":
                        self.result = status.result
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
        result = nil
        audio = nil
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

    func meetingStartSync(wav: Data, language: String = "auto") throws -> String {
        try sendMeeting(path: "/meetings", body: wav, headers: ["content-type": "audio/wav", "x-voice-language": language], timeout: Self.meetingUploadTimeout) { data in
            guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else { throw ServiceError.decoding("meeting id") }
            return id
        }
    }

    func meetingStatusSync(id: String) throws -> MeetingStatus {
        let query = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-"))) ?? ""
        return try sendMeeting(path: "/meetings/status?id=" + query, body: nil, headers: [:], timeout: 10) { data in
            do { return try JSONDecoder().decode(MeetingStatus.self, from: data) }
            catch { throw ServiceError.decoding(String(describing: error)) }
        }
    }

    func meetingCancelSync(id: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["id": id])
        _ = try sendMeeting(path: "/meetings/cancel", body: body, headers: ["content-type": "application/json"], timeout: 10) { _ in true }
    }
}

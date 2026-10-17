import AVFoundation
import Foundation

// Recorder.swift - AVAudioEngine input -> 16 kHz mono PCM16 in memory -> temp WAV.

enum RecorderError: Error, CustomStringConvertible {
    case busy
    case noInputDevice
    case permissionDenied
    case permissionNotDetermined
    case converterUnavailable
    case engineFailed(String)
    case tooShort(Double)

    var description: String {
        switch self {
        case .busy: return "已经在录音中"
        case .noInputDevice: return "找不到可用的麦克风输入"
        case .permissionDenied: return "麦克风权限被拒绝"
        case .permissionNotDetermined: return "尚未授予麦克风权限"
        case .converterUnavailable: return "无法创建 16kHz 单声道转换器"
        case .engineFailed(let m): return "音频引擎启动失败：" + m
        case .tooShort(let s): return String(format: "录音太短（%.2f 秒）", s)
        }
    }
}

final class Recorder {
    static let targetSampleRate: Double = 16000
    static let bytesPerSecond = 32000      // 16000 Hz * 2 bytes * 1 channel

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var pcm = Data()
    private var converter: AVAudioConverter?
    private var outFormat: AVAudioFormat?
    private var capTimer: Timer?
    private var smoothedLevel: Float = 0

    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var truncated = false

    /// Hard cap; auto-finalises when reached (contract: <= 120 s).
    var maxSeconds: Int = 120
    var onAutoStop: (() -> Void)?
    /// Called with the engine just before each recording starts.
    var prepareEngine: ((AVAudioEngine) -> Void)?

    /// Demo input (TYPELEAST_DEMO_WAV): 16 kHz mono PCM16 fed in at real-time pace
    /// instead of the microphone, so a screen recording shows the real pipeline
    /// (waveform, local recognition, cleanup, paste) without anyone's voice.
    /// Never set in normal use.
    var demoPCM: Data?
    private var demoTimer: Timer?
    private var demoOffset = 0

    var elapsed: Double {
        guard let s = startedAt else { return 0 }
        return Date().timeIntervalSince(s)
    }

    var byteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pcm.count
    }

    // MARK: live level

    /// Smoothed loudness of the most recent capture buffers, 0...1 (see loudness(rms:)).
    /// Never blocks.
    func level() -> Float {
        lock.lock(); defer { lock.unlock() }
        return smoothedLevel
    }

    /// Weight of a louder buffer in smoothLevel(): rises fast so speech peaks show.
    static let levelAttack: Float = 0.6
    /// Weight of a quieter buffer in smoothLevel(): falls more gently, without jitter.
    static let levelRelease: Float = 0.3

    /// Quietest level that still registers (room noise sits below it).
    static let loudnessFloorDb: Float = -52
    /// Level treated as full scale (a raised voice close to the microphone).
    static let loudnessCeilingDb: Float = -14

    /// Maps any reading into a usable 0...1 level (NaN / infinite / negative -> 0).
    static func clampLevel(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// Linear RMS -> 0...1 on a decibel scale. Linear RMS puts ordinary speech at
    /// 0.01-0.1, which barely moves a meter and makes quiet and loud look alike;
    /// decibels spread room noise (0), quiet, normal and loud speech (1) apart.
    static func loudness(rms: Float) -> Float {
        let value = clampLevel(rms)
        guard value > 0 else { return 0 }
        let db = 20 * log10(value)
        return clampLevel((db - loudnessFloorDb) / (loudnessCeilingDb - loudnessFloorDb))
    }

    /// Asymmetric exponential smoothing: fast attack, gentle release.
    static func smoothLevel(previous: Float, sample: Float) -> Float {
        let fresh = clampLevel(sample)
        let old = clampLevel(previous)
        let weight = fresh > old ? Recorder.levelAttack : Recorder.levelRelease
        return clampLevel(old + weight * (fresh - old))
    }

    /// Pure RMS (0...1) of one tap buffer across all channels. Never throws; a buffer
    /// with no readable samples, or only NaN/infinite samples, reads as 0.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        let channels = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        let rows = interleaved ? 1 : channels
        let perRow = interleaved ? frames * channels : frames
        var sum = 0.0
        var counted = 0

        if let data = buffer.floatChannelData {
            for r in 0..<rows {
                let row = data[r]
                for i in 0..<perRow {
                    let v = Double(row[i])
                    if v.isFinite { sum += v * v; counted += 1 }
                }
            }
        } else if let data = buffer.int16ChannelData {
            for r in 0..<rows {
                let row = data[r]
                for i in 0..<perRow {
                    let v = Double(row[i]) / 32768.0
                    sum += v * v; counted += 1
                }
            }
        } else if let data = buffer.int32ChannelData {
            for r in 0..<rows {
                let row = data[r]
                for i in 0..<perRow {
                    let v = Double(row[i]) / 2147483648.0
                    sum += v * v; counted += 1
                }
            }
        } else {
            return 0
        }
        guard counted > 0 else { return 0 }
        return clampLevel(Float((sum / Double(counted)).squareRoot()))
    }

    // MARK: permission

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestMicrophoneAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    // MARK: lifecycle

    func start() throws {
        guard !isRecording else { throw RecorderError.busy }
        if let demo = demoPCM {
            startDemo(demo)
            return
        }
        let status = Recorder.authorizationStatus()
        if status == .denied || status == .restricted { throw RecorderError.permissionDenied }
        if status == .notDetermined { throw RecorderError.permissionNotDetermined }

        // Host hook, e.g. to select a non-default microphone, before the input format is read.
        prepareEngine?(engine)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let target = AudioConvert.targetFormat(),
              let conv = AudioConvert.makeConverter(from: inFormat) else {
            throw RecorderError.converterUnavailable
        }
        converter = conv
        outFormat = target
        lock.lock(); pcm = Data(); smoothedLevel = 0; lock.unlock()
        truncated = false

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            converter = nil
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        isRecording = true
        startedAt = Date()
        capTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording else { return }
            if self.elapsed >= Double(self.maxSeconds) {
                self.onAutoStop?()
            }
        }
    }

    /// Returns the finished WAV, or throws if nothing usable was captured.
    @discardableResult
    func finish() throws -> (url: URL, bytes: Int, seconds: Double, truncated: Bool) {
        guard isRecording else { throw RecorderError.tooShort(0) }
        capTimer?.invalidate()
        capTimer = nil
        if demoPCM != nil {
            demoTimer?.invalidate()
            demoTimer = nil
        } else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRecording = false
        let seconds = elapsed
        startedAt = nil
        converter = nil

        lock.lock(); let data = pcm; lock.unlock()
        let audioSeconds = Double(data.count) / Double(Recorder.bytesPerSecond)
        guard data.count >= Recorder.bytesPerSecond / 5, audioSeconds > 0.15 else {
            throw RecorderError.tooShort(audioSeconds)
        }
        let name = "dsh-voice-" + String(Int(Date().timeIntervalSince1970 * 1000)) + ".wav"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try Wav.write(pcm: data, to: url)
        _ = seconds
        return (url, data.count, audioSeconds, truncated)
    }

    func cancel() {
        capTimer?.invalidate()
        capTimer = nil
        demoTimer?.invalidate()
        demoTimer = nil
        if isRecording && demoPCM == nil {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        isRecording = false
        startedAt = nil
        converter = nil
        lock.lock(); pcm = Data(); smoothedLevel = 0; lock.unlock()
    }

    // MARK: demo input

    private func startDemo(_ demo: Data) {
        lock.lock(); pcm = Data(); smoothedLevel = 0; lock.unlock()
        truncated = false
        demoOffset = 0
        isRecording = true
        startedAt = Date()
        let chunkBytes = Recorder.bytesPerSecond / 20   // 50 ms
        var trailingTicks = 0
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self = self, self.isRecording else { timer.invalidate(); return }
            if self.demoOffset < demo.count {
                let end = min(demo.count, self.demoOffset + chunkBytes)
                let chunk = demo.subdata(in: demo.startIndex + self.demoOffset ..< demo.startIndex + end)
                self.demoOffset = end
                var sum = 0.0
                let count = chunk.count / 2
                chunk.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let v = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768.0
                        sum += v * v
                    }
                }
                let rms = count > 0 ? Float((sum / Double(count)).squareRoot()) : 0
                self.lock.lock()
                self.pcm.append(chunk)
                self.smoothedLevel = Recorder.smoothLevel(previous: self.smoothedLevel, sample: Recorder.loudness(rms: rms))
                self.lock.unlock()
            } else {
                // A moment of quiet after the last word, like a person about to press stop.
                self.lock.lock(); self.smoothedLevel = Recorder.smoothLevel(previous: self.smoothedLevel, sample: 0); self.lock.unlock()
                trailingTicks += 1
                if trailingTicks == 8 {
                    timer.invalidate()
                    self.onAutoStop?()
                }
            }
        }
    }

    // MARK: capture

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let conv = converter, let target = outFormat else { return }
        guard let chunk = AudioConvert.convert(buffer, using: conv, to: target) else { return }
        let sample = Recorder.rms(of: buffer)
        let maxBytes = Recorder.bytesPerSecond * maxSeconds
        lock.lock()
        smoothedLevel = Recorder.smoothLevel(previous: smoothedLevel, sample: Recorder.loudness(rms: sample))
        if pcm.count < maxBytes {
            let room = min(chunk.count, maxBytes - pcm.count)
            pcm.append(chunk.prefix(room))
            if room < chunk.count { truncated = true }
        } else {
            truncated = true
        }
        lock.unlock()
    }
}

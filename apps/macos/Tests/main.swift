import Foundation
import Darwin
import AVFoundation
import AppKit

KeychainStore.stub = [:]
L10n.language = "zh-Hans"
setbuf(stdout, nil)

// main.swift (Tests) - unit/acceptance proofs for ServiceClient against the local service's contract.

var passed = 0
var failed = 0

func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    if cond {
        passed += 1
        print("PASS " + name)
    } else {
        failed += 1
        print("FAIL " + name + (detail.isEmpty ? "" : " :: " + detail))
    }
}

func checkEq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    check(name, got == want, "got=" + String(describing: got) + " want=" + String(describing: want))
}

if CommandLine.arguments.contains("--live-health") {
    let c = ServiceClient()
    if let t = ProcessInfo.processInfo.environment["TYPELEAST_TOKEN"], !t.isEmpty { c.tokenOverride = t }
    c.discoverBaseURL()
    print("LIVE PROBE -> GET " + c.baseURL.absoluteString + "/api/voice-polish/health")
    print("LIVE PROBE -> token file " + c.tokenPath + " exists=" + String(c.tokenFileExists()))
    do {
        let h = try c.healthSync()
        print("LIVE OK ok=" + String(h.ok) + " version=" + String(describing: h.version)
              + " provider=" + String(describing: h.provider) + " model=" + String(describing: h.model)
              + " speech=" + String(describing: h.speech?.summary) + " pid=" + String(describing: h.pid))
    } catch let e as ServiceError {
        print("LIVE ERROR " + e.description + " serviceUnavailable=" + String(e.serviceUnavailable))
    } catch {
        print("LIVE ERROR " + String(describing: error))
    }
    exit(0)
}

final class StubState {
    var mode = "health"
    var tokenFilePath = ""
    var oldToken = ""
    var newToken = ""
    var requestCount = 0
    var lastRequest: StubServer.Request?
}

let healthJSON = """
{"ok":true,"version":"1.0.0","provider":"openai","model":"gpt-4o-mini","speech":{"providerId":"whisper","ready":true,"phase":"idle"},"pid":12345}
"""

let dictateJSON = """
{"requestId":"req-1","text":"Polish done.","raw":"polish done","fallback":false,"model":"gpt-4o-mini","provider":"openai","ms":{"transcribe":120.5,"polish":80.25,"total":200.75}}
"""

let fallbackJSON = """
{"requestId":"req-2","text":"raw fallback text","raw":"raw fallback text","fallback":true,"fallbackReason":"polish_timeout","model":"gpt-4o-mini","provider":"openai","ms":{"transcribe":90,"polish":0,"total":90}}
"""

let historyJSON = """
{"items":[{"id":"h1","ts":1700000000000,"app":"com.apple.TextEdit","language":"zh","raw":"ni hao","text":"你好","fallback":false,"reason":null,"model":"gpt-4o-mini","ms":210,"strength":"prompt"}]}
"""

let state = StubState()
let tokenPath = NSTemporaryDirectory() + "dsh-voice-test-token.txt"
state.tokenFilePath = tokenPath
state.oldToken = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
state.newToken = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
try? state.oldToken.write(toFile: tokenPath, atomically: true, encoding: .utf8)

let server = try StubServer { req in
    state.requestCount += 1
    state.lastRequest = req
    let auth = req.header("Authorization")
    if state.mode == "auth" && req.path == "/api/voice-polish/health" {
        if auth == "Bearer " + state.oldToken {
            try? state.newToken.write(toFile: state.tokenFilePath, atomically: true, encoding: .utf8)
            return .json("{\"error\":\"token rotated\",\"code\":\"unauthorized\"}", status: 401)
        }
    }
    if req.path.hasPrefix("/api/voice-polish/health") { return .json(healthJSON) }
    if req.path.hasPrefix("/api/voice-polish/dictate") {
        if state.mode == "dictateError" {
            return .json("{\"error\":\"speech not ready\",\"code\":\"speech_not_ready\"}", status: 503)
        }
        if state.mode == "fallback" { return .json(fallbackJSON) }
        return .json(dictateJSON)
    }
    if req.path.hasPrefix("/api/voice-polish/history") { return .json(historyJSON) }
    if req.path.hasPrefix("/api/voice-polish/learn") {
        var from = "?"
        var to = "?"
        if let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: String] {
            from = obj["from"] ?? "?"
            to = obj["to"] ?? "?"
        }
        let body = "{\"ok\":true,\"dictionary\":[{\"from\":\"" + from + "\",\"to\":\"" + to + "\"}]}"
        return .json(body)
    }
    return .json("{\"error\":\"not found\",\"code\":\"not_found\"}", status: 404)
}

server.start()
print("stub server listening on " + server.baseURL.absoluteString)
check("stub server is listening", server.port != 0)

let client = ServiceClient()
client.baseURL = server.baseURL
client.tokenPath = tokenPath

// MARK: 1. health happy path

do {
    let h = try client.healthSync()
    print("health parsed -> ok=" + String(h.ok) + " version=" + String(describing: h.version)
          + " provider=" + String(describing: h.provider) + " model=" + String(describing: h.model)
          + " speech.providerId=" + String(describing: h.speech?.providerId)
          + " speech.ready=" + String(describing: h.speech?.ready)
          + " speech.phase=" + String(describing: h.speech?.phase)
          + " pid=" + String(describing: h.pid))
    checkEq("health.ok", h.ok, true)
    checkEq("health.version", h.version, "1.0.0")
    checkEq("health.provider", h.provider, "openai")
    checkEq("health.model", h.model, "gpt-4o-mini")
    checkEq("health.speech.providerId", h.speech?.providerId, "whisper")
    checkEq("health.speech.ready", h.speech?.ready, true)
    checkEq("health.speech.phase", h.speech?.phase, "idle")
    checkEq("health.pid", h.pid, 12345)
    checkEq("health.speechReady", h.speechReady, true)
    checkEq("health auth header", state.lastRequest?.header("Authorization"), "Bearer " + state.oldToken)
} catch {
    check("health happy path", false, String(describing: error))
}

// MARK: 2. service not running

do {
    let dead = ServiceClient()
    dead.baseURL = URL(string: "http://127.0.0.1:1")!
    dead.tokenPath = tokenPath
    dead.healthTimeout = 2
    _ = try dead.healthSync()
    check("health closed port throws", false, "no error thrown")
} catch let e as ServiceError {
    check("health closed port throws", true)
    checkEq("health closed port serviceUnavailable", e.serviceUnavailable, true)
} catch {
    check("health closed port throws ServiceError", false, String(describing: error))
}

// MARK: 3. 401 -> token re-read once

state.mode = "auth"
state.requestCount = 0
try? state.oldToken.write(toFile: tokenPath, atomically: true, encoding: .utf8)
do {
    let h = try client.healthSync()
    checkEq("401 retry succeeded", h.ok, true)
    checkEq("401 retry used exactly 2 requests", state.requestCount, 2)
    checkEq("401 retry sent new token", state.lastRequest?.header("Authorization"), "Bearer " + state.newToken)
} catch {
    check("401 retry succeeded", false, String(describing: error))
}
state.mode = "health"
try? state.oldToken.write(toFile: tokenPath, atomically: true, encoding: .utf8)

// MARK: WAV canonical (contract: 16 kHz mono PCM16, 44-byte header, <= 4 MiB)

let samples = Data(repeating: 0, count: 3200)   // 0.1 s of silence
let wav = Wav.wrap(pcm: samples)
print("wav -> " + Wav.describe(wav))
checkEq("wav total bytes", wav.count, 3244)
checkEq("wav RIFF magic", String(data: wav.subdata(in: 0..<4), encoding: .ascii), "RIFF")
checkEq("wav WAVE magic", String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
check("wav is canonical 16k mono PCM16 44-byte header", Wav.isCanonical(wav))
checkEq("wav duration 0.1s", Wav.parse(wav)?.durationSeconds ?? -1, 0.1)
let maxWav = Wav.wrap(pcm: Data(repeating: 0, count: 32000 * 120))
checkEq("wav 120 s byte size", maxWav.count, 3840044)
check("120 s of 16 kHz mono PCM16 stays under the 4 MiB contract cap", maxWav.count <= Wav.maxBytes,
      "size=" + String(maxWav.count) + " cap=" + String(Wav.maxBytes))
check("400 MiB cap would allow >131 s, so the 120 s limit is the binding one", 32000 * 131 < Wav.maxBytes)

// MARK: 3b. resampling path: 48 kHz stereo float -> 16 kHz mono PCM16 (the Recorder pipeline)

do {
    let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    let totalFrames = 48000                                   // exactly 1.0 s
    let src = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(totalFrames))!
    src.frameLength = AVAudioFrameCount(totalFrames)
    if let ch = src.floatChannelData {
        for i in 0..<totalFrames {
            let v = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 48000.0)) * 0.5
            ch[0][i] = v
            ch[1][i] = v
        }
    }
    guard let conv = AudioConvert.makeConverter(from: inFormat), let target = AudioConvert.targetFormat() else {
        check("resampler creation", false, "AudioConvert.makeConverter returned nil")
        exit(1)
    }
    var pcm = Data()
    var offset = 0
    while offset < totalFrames {                              // feed 4096-frame taps like the real engine
        let n = min(4096, totalFrames - offset)
        let chunk = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(n))!
        chunk.frameLength = AVAudioFrameCount(n)
        if let dst = chunk.floatChannelData, let s = src.floatChannelData {
            memcpy(dst[0], UnsafeRawPointer(s[0] + offset), n * 4)
            memcpy(dst[1], UnsafeRawPointer(s[1] + offset), n * 4)
        }
        if let d = AudioConvert.convert(chunk, using: conv, to: target) { pcm.append(d) }
        offset += n
    }
    let expected = 32000                                      // 16000 Hz * 2 bytes * 1 s
    print("resample -> input 48000 frames stereo float32, output " + String(pcm.count) + " bytes (expected ~" + String(expected) + ")")
    check("resample byte count is even (16-bit samples)", pcm.count % 2 == 0)
    check("resample produces ~1 s at 16 kHz mono PCM16", abs(pcm.count - expected) < 2000,
          "bytes=" + String(pcm.count))
    let wav2 = Wav.wrap(pcm: pcm)
    print("resampled wav -> " + Wav.describe(wav2))
    check("resampled WAV is canonical 16 kHz mono PCM16 with 44-byte header", Wav.isCanonical(wav2))
    let parsed = Wav.parse(wav2)
    check("resampled WAV duration ~1.0 s", abs((parsed?.durationSeconds ?? 0) - 1.0) < 0.06,
          "dur=" + String(describing: parsed?.durationSeconds))
    var peak: Int16 = 0
    pcm.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Int16.self)
        for v in p { if abs(Int(v)) > Int(abs(peak)) { peak = v } }
    }
    check("resampled PCM16 carries real signal (peak > 8000)", abs(Int(peak)) > 8000, "peak=" + String(peak))
} catch {
    check("resample pipeline", false, String(describing: error))
}

// MARK: 4. dictate happy path

state.mode = "health"
state.requestCount = 0
do {
    let d = try client.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.TextEdit", strength: "conservative")
    print("dictate parsed -> requestId=" + String(describing: d.requestId) + " text=" + d.text
          + " raw=" + d.raw + " fallback=" + String(d.fallback)
          + " model=" + String(describing: d.model) + " provider=" + String(describing: d.provider)
          + " ms=" + String(describing: d.ms?.transcribe) + "/" + String(describing: d.ms?.polish)
          + "/" + String(describing: d.ms?.total))
    let r = state.lastRequest
    checkEq("dictate method", r?.method, "POST")
    checkEq("dictate path", r?.path, "/api/voice-polish/dictate")
    checkEq("dictate content-type", r?.header("content-type"), "audio/wav")
    checkEq("dictate x-voice-language", r?.header("x-voice-language"), "zh")
    checkEq("dictate x-voice-app", r?.header("x-voice-app"), "com.apple.TextEdit")
    checkEq("dictate x-voice-strength", r?.header("x-voice-strength"), "conservative")
    checkEq("dictate content-length", r?.header("content-length"), String(wav.count))
    check("dictate body is byte-exact WAV", r?.body == wav)
    checkEq("dictate.requestId", d.requestId, "req-1")
    checkEq("dictate.text", d.text, "Polish done.")
    checkEq("dictate.raw", d.raw, "polish done")
    checkEq("dictate.fallback", d.fallback, false)
    checkEq("dictate.model", d.model, "gpt-4o-mini")
    checkEq("dictate.provider", d.provider, "openai")
    checkEq("dictate.ms.transcribe", d.ms?.transcribe, 120.5)
    checkEq("dictate.ms.polish", d.ms?.polish, 80.25)
    checkEq("dictate.ms.total", d.ms?.total, 200.75)
} catch {
    check("dictate happy path", false, String(describing: error))
}

// MARK: 5. fallback substituted raw text

state.mode = "fallback"
do {
    let d = try client.dictateSync(wav: wav, language: "auto", appBundleId: "", strength: "prompt")
    checkEq("fallback flag", d.fallback, true)
    checkEq("fallback insertableText uses substituted text", d.insertableText, "raw fallback text")
    checkEq("fallback fallbackReason", d.fallbackReason, "polish_timeout")
    checkEq("empty x-voice-app allowed", state.lastRequest?.header("x-voice-app"), "")
} catch {
    check("fallback path", false, String(describing: error))
}

// MARK: 6. dictate error mapping

state.mode = "dictateError"
do {
    _ = try client.dictateSync(wav: wav, language: "auto", appBundleId: "", strength: "prompt")
    check("dictate 503 throws", false, "no error")
} catch let e as ServiceError {
    checkEq("dictate 503 status", e.statusCode, 503)
    if case .http(let s, let code, let msg) = e {
        checkEq("dictate 503 statusCode", s, 503)
        checkEq("dictate 503 code", code, "speech_not_ready")
        checkEq("dictate 503 message", msg, "speech not ready")
    } else {
        check("dictate 503 is ServiceError.http", false, String(describing: e))
    }
} catch {
    check("dictate 503 is ServiceError", false, String(describing: error))
}
state.mode = "health"

// MARK: 7. history

do {
    let items = try client.historySync(limit: 20)
    checkEq("history count", items.count, 1)
    let i = items.first
    checkEq("history id", i?.id, "h1")
    checkEq("history app", i?.app, "com.apple.TextEdit")
    checkEq("history language", i?.language, "zh")
    checkEq("history raw", i?.raw, "ni hao")
    checkEq("history text", i?.text, "你好")
    checkEq("history fallback", i?.fallback, false)
    checkEq("history model", i?.model, "gpt-4o-mini")
    checkEq("history strength", i?.strength, "prompt")
    checkEq("history ms (bare number)", i?.ms?.total, 210)
    checkEq("history ts (epoch number)", i?.ts, "1700000000000")
    checkEq("history limit query", state.lastRequest?.path, "/api/voice-polish/history?limit=20")
} catch {
    check("history path", false, String(describing: error))
}

// MARK: 8. learn

do {
    let r = try client.learnSync(from: "张三", to: "张三丰")
    checkEq("learn ok", r.ok, true)
    checkEq("learn dictionary count", r.dictionary.count, 1)
    checkEq("learn dictionary from (utf8)", r.dictionary.first?.from, "张三")
    checkEq("learn dictionary to (utf8)", r.dictionary.first?.to, "张三丰")
    checkEq("learn content-type", state.lastRequest?.header("content-type"), "application/json")
} catch {
    check("learn path", false, String(describing: error))
}

// MARK: 9. missing token

do {
    let noTok = ServiceClient()
    noTok.baseURL = server.baseURL
    noTok.tokenPath = NSTemporaryDirectory() + "dsh-voice-does-not-exist"
    _ = try noTok.healthSync()
    check("missing token throws", false, "no error")
} catch let e as ServiceError {
    check("missing token throws", true)
    checkEq("missing token serviceUnavailable", e.serviceUnavailable, true)
    if case .noToken = e { check("missing token is ServiceError.noToken", true) }
    else { check("missing token is ServiceError.noToken", false, String(describing: e)) }
} catch {
    check("missing token is ServiceError", false, String(describing: error))
}

// MARK: 10. RecordingBar pill - formatting, waveform history, show/hide state machine

do {
    // elapsed time as m:ss
    checkEq("pill elapsed 0", RecordingBarFormat.elapsed(0), "0:00")
    checkEq("pill elapsed truncates 5.9", RecordingBarFormat.elapsed(5.9), "0:05")
    checkEq("pill elapsed 61", RecordingBarFormat.elapsed(61), "1:01")
    checkEq("pill elapsed 600", RecordingBarFormat.elapsed(600), "10:00")
    checkEq("pill elapsed negative", RecordingBarFormat.elapsed(-3), "0:00")
    checkEq("pill elapsed nan", RecordingBarFormat.elapsed(Double.nan), "0:00")
    checkEq("pill elapsed infinite", RecordingBarFormat.elapsed(Double.infinity), "0:00")

    // result summary
    checkEq("pill summary passes short text", RecordingBarFormat.summary("你好，世界"), "你好，世界")
    checkEq("pill summary collapses newlines", RecordingBarFormat.summary("第一行\n第二行"), "第一行 第二行")
    let longWord = String(repeating: "字", count: 60)
    checkEq("pill summary cuts to 40 chars + ellipsis",
            RecordingBarFormat.summary(longWord), String(repeating: "字", count: 40) + "…")
    checkEq("pill summary honours a custom limit", RecordingBarFormat.summary("abcdef", limit: 3), "abc…")
    checkEq("pill summary of empty text", RecordingBarFormat.summary(""), "")

    // level -> bar height mapping
    checkEq("pill clamp nan", RecordingBarFormat.clampLevel(Float.nan), 0)
    checkEq("pill clamp negative", RecordingBarFormat.clampLevel(-2), 0)
    checkEq("pill clamp above one", RecordingBarFormat.clampLevel(3), 1)
    checkEq("pill clamp inside range", RecordingBarFormat.clampLevel(0.25), 0.25)
    checkEq("pill bar floor on silence", RecordingBarFormat.barHeight(for: 0), RecordingBarFormat.silenceFloor)
    checkEq("pill bar saturates at one", RecordingBarFormat.barHeight(for: 1), 1)
    checkEq("pill bar ignores nan", RecordingBarFormat.barHeight(for: Float.nan), RecordingBarFormat.silenceFloor)
    // The user must be able to tell quiet speech from loud speech at a glance.
    let quietBar = RecordingBarFormat.barHeight(for: Recorder.loudness(rms: 0.01))   // about -40 dBFS
    let loudBar = RecordingBarFormat.barHeight(for: Recorder.loudness(rms: 0.1))     // about -20 dBFS
    check("pill bar for loud speech is at least 3x the bar for quiet speech (\(quietBar) vs \(loudBar))",
          loudBar >= quietBar * 3)
    check("pill bar for quiet speech is still visibly above silence",
          quietBar > RecordingBarFormat.silenceFloor * 1.5)
    check("pill bar for room noise stays at the silence floor",
          RecordingBarFormat.barHeight(for: Recorder.loudness(rms: 0.002)) == RecordingBarFormat.silenceFloor)
    check("pill bar height grows with the level",
          RecordingBarFormat.barHeight(for: 0.05) < RecordingBarFormat.barHeight(for: 0.5)
          && RecordingBarFormat.barHeight(for: 0.5) <= RecordingBarFormat.barHeight(for: 1))
    check("pill bar height stays within 0...1",
          [Float(0), 0.01, 0.2, 0.7, 1].allSatisfy { RecordingBarFormat.barHeight(for: $0) >= 0 && RecordingBarFormat.barHeight(for: $0) <= 1 })

    // waveform history
    var history = LevelHistory(capacity: 4)
    checkEq("waveform starts empty", history.count, 0)
    checkEq("waveform latest when empty", history.latest, 0)
    history.append(0.1)
    history.append(0.2)
    history.append(-1)
    history.append(Float.nan)
    history.append(0.9)
    checkEq("waveform keeps only the newest samples", history.count, 4)
    checkEq("waveform clamps and slides", history.samples, [0.2, 0, 0, 0.9])
    checkEq("waveform latest is newest", history.latest, 0.9)
    checkEq("waveform heights match samples", history.heights().count, 4)
    check("waveform heights stay within 0...1", history.heights().allSatisfy { $0 >= 0 && $0 <= 1 })
    history.reset()
    checkEq("waveform reset empties", history.count, 0)
    checkEq("waveform default capacity is 40 samples", LevelHistory.defaultCapacity, 40)

    // pill show/hide state machine
    var model = RecordingBarModel()
    checkEq("pill starts hidden", model.phase, RecordingBarModel.Phase.hidden)
    check("pill is invisible while hidden", !model.isVisible)
    model.update(level: 0.5, elapsed: 1)
    checkEq("pill ignores level ticks while hidden", model.history.count, 0)

    model.showRecording(destination: "com.apple.mail")
    checkEq("showRecording enters recording", model.phase, RecordingBarModel.Phase.recording)
    checkEq("showRecording keeps the destination", model.destination, "com.apple.mail")
    check("pill is visible while recording", model.isVisible)
    checkEq("showRecording resets the timer", model.elapsed, 0)
    for step in 1...45 {
        model.update(level: Float(step) / 45, elapsed: Double(step) / 20)
    }
    checkEq("level ticks fill the 40-sample window", model.history.count, 40)
    checkEq("newest level tick wins", model.level, 1)
    checkEq("newest elapsed tick wins", model.elapsed, 2.25)
    model.update(level: -4, elapsed: -9)
    checkEq("negative level tick clamps but elapsed is kept", model.history.latest, 0)

    model.showThinking(detail: "转写中")
    checkEq("showThinking enters thinking", model.phase, RecordingBarModel.Phase.thinking)
    checkEq("showThinking keeps the detail", model.detail, "转写中")
    check("pill stays visible while thinking", model.isVisible)
    let frozenElapsed = model.elapsed
    model.update(level: 1, elapsed: 99)
    checkEq("pill ignores level ticks while thinking", model.elapsed, frozenElapsed)

    model.showResult("完美的一句话", warning: false)
    checkEq("showResult enters result", model.phase, RecordingBarModel.Phase.result)
    checkEq("showResult keeps short text", model.resultText, "完美的一句话")
    checkEq("showResult clear flag", model.warning, false)
    model.showResult(String(repeating: "字", count: 99), warning: true)
    checkEq("showResult truncates long text", model.resultText.count, 41)
    checkEq("showResult warning flag", model.warning, true)

    model.hide()
    checkEq("hide returns to hidden", model.phase, RecordingBarModel.Phase.hidden)
    check("pill is invisible after hide", !model.isVisible)
    checkEq("hide clears the waveform", model.history.count, 0)
    checkEq("hide clears the level", model.level, 0)
    model.showRecording(destination: "com.apple.TextEdit")
    checkEq("pill can start again after hide", model.phase, RecordingBarModel.Phase.recording)
    model.hide()
}

// MARK: 11. Recorder live level - smoothing, clamping and RMS without a microphone

do {
    checkEq("recorder smoothing attack weight", Recorder.levelAttack, 0.6)
    checkEq("recorder smoothing release weight", Recorder.levelRelease, 0.3)
    checkEq("recorder smoothing attacks fast (0.6 of a rise)", Recorder.smoothLevel(previous: 0, sample: 1), 0.6)
    checkEq("recorder smoothing releases 0.7 previous", Recorder.smoothLevel(previous: 1, sample: 0), 0.7)
    checkEq("recorder smoothing clamps negative input", Recorder.smoothLevel(previous: 1, sample: -5), 0.7)
    checkEq("recorder smoothing survives nan input", Recorder.smoothLevel(previous: 0.5, sample: Float.nan), 0.35)
    checkEq("recorder clamp nan", Recorder.clampLevel(Float.nan), 0)
    checkEq("recorder clamp infinity", Recorder.clampLevel(Float.infinity), 0)
    checkEq("recorder clamp negative", Recorder.clampLevel(-0.4), 0)
    checkEq("recorder clamp above one", Recorder.clampLevel(1.4), 1)
    // loudness: linear RMS -> 0...1 on a decibel scale
    checkEq("loudness of silence", Recorder.loudness(rms: 0), 0)
    checkEq("loudness of nan", Recorder.loudness(rms: Float.nan), 0)
    checkEq("loudness below the noise floor", Recorder.loudness(rms: 0.001), 0)
    checkEq("loudness at full scale", Recorder.loudness(rms: 1), 1)
    check("loudness at the ceiling reads as one",
          abs(Recorder.loudness(rms: Float(pow(10.0, Double(Recorder.loudnessCeilingDb) / 20))) - 1) < 0.001)
    check("loudness grows with the voice",
          Recorder.loudness(rms: 0.005) < Recorder.loudness(rms: 0.02)
          && Recorder.loudness(rms: 0.02) < Recorder.loudness(rms: 0.08))
    check("ordinary speech (-30 dBFS) lands mid-scale, not near zero",
          (0.45...0.75).contains(Recorder.loudness(rms: 0.0316)))

    let idle = Recorder()
    checkEq("recorder level starts at zero", idle.level(), 0)
    checkEq("recorder level is stable before any capture", idle.level(), 0)

    if let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
       let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 1600) {
        buf.frameLength = 1600
        if let data = buf.floatChannelData {
            for i in 0..<1600 { data[0][i] = 0 }
        }
        checkEq("rms of silence is zero", Recorder.rms(of: buf), 0)
        if let data = buf.floatChannelData {
            for i in 0..<1600 {
                data[0][i] = Float(sin(2.0 * Double.pi * 440.0 * Double(i) / 16000.0))
            }
        }
        let sine = Recorder.rms(of: buf)
        print("rms -> full-scale 440 Hz sine = " + String(sine) + " (expected ~0.7071)")
        check("rms of a full-scale sine is ~0.7071", abs(sine - 0.7071) < 0.01, "rms=" + String(sine))
        if let data = buf.floatChannelData {
            for i in 0..<1600 { data[0][i] = Float.nan }
        }
        checkEq("rms ignores non-finite samples", Recorder.rms(of: buf), 0)
    } else {
        check("rms float fixture", false, "could not create AVAudioPCMBuffer")
    }

    if let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
       let empty = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 64) {
        empty.frameLength = 0
        checkEq("rms of an empty buffer is zero", Recorder.rms(of: empty), 0)
    }

    if let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
       let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 800) {
        buf.frameLength = 800
        if let data = buf.int16ChannelData {
            for i in 0..<800 { data[0][i] = 16384 }
        }
        let half = Recorder.rms(of: buf)
        check("rms reads int16 buffers (0.5 full scale)", abs(half - 0.5) < 0.001, "rms=" + String(half))
    }
}

// MARK: 12. RecordingBar panel - focus contract and idle invisibility (real panel, never shown)

do {
    let bar = RecordingBar()
    checkEq("pill is off screen while idle", bar.isVisible, false)
    checkEq("pill phase is hidden while idle", bar.phase, RecordingBarModel.Phase.hidden)

    let policy = bar.focusPolicy
    check("pill panel is non-activating", policy.nonactivating)
    check("pill panel becomes key only if needed", policy.becomesKeyOnlyIfNeeded)
    check("pill panel is a floating panel", policy.floatingPanel)
    check("pill panel floats at status-bar level", policy.level >= Int(NSWindow.Level.floating.rawValue),
          "level=" + String(policy.level))
    check("pill panel joins all spaces", policy.joinsAllSpaces)
    check("pill panel shows over full-screen apps", policy.fullScreenAuxiliary)
    check("pill panel cannot become key while idle", !policy.canBecomeKey)
    check("pill panel can never become main", !policy.canBecomeMain)
    check("pill panel reports itself off screen", !policy.onScreen)

    var cancelFired = false
    bar.onCancel = { cancelFired = true }
    check("pill cancel hook is inert without a press", !cancelFired)
    bar.hide()
    checkEq("pill stays off screen after hide", bar.isVisible, false)
}

// MARK: 13. field context travels as base64 JSON in x-voice-context

state.mode = "health"
do {
    let context = FieldContext(before: "Hi 张伟，", selected: "", after: "", windowTitle: "New Message")
    _ = try client.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.mail", strength: "prompt",
                               fieldContext: context.encoded())
    let header = state.lastRequest?.header("x-voice-context") ?? ""
    let decoded = Data(base64Encoded: header).flatMap { try? JSONDecoder().decode(FieldContext.self, from: $0) }
    checkEq("context header decodes to the field context", decoded, context)
    _ = try client.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.mail", strength: "prompt")
    checkEq("no context means no header", state.lastRequest?.header("x-voice-context") ?? "", "")
    checkEq("empty context encodes to nothing", FieldContext(before: "", selected: "", after: "", windowTitle: "").encoded(), nil)
    let huge = Data(repeating: 65, count: ServiceClient.maxContextHeaderBytes)
    checkEq("oversized context is dropped, not truncated", ServiceClient.encodeContextHeader(huge), nil)
} catch {
    check("field context header", false, String(describing: error))
}

// MARK: 14. Fn single-press recogniser

do {
    let t0 = Date(timeIntervalSince1970: 1000)
    // 🌐 gate: a tap that switched the keyboard input source must not start a dictation
    check("fn gate starts when the input source is unchanged",
          FnTapGate.shouldStart(sourceAtPress: "com.apple.keylayout.US", sourceAfter: "com.apple.keylayout.US"))
    check("fn gate refuses when the tap switched the input source",
          !FnTapGate.shouldStart(sourceAtPress: "com.apple.keylayout.US", sourceAfter: "com.apple.inputmethod.SCIM.ITABC"))
    check("fn gate never blocks when the source is unknown",
          FnTapGate.shouldStart(sourceAtPress: nil, sourceAfter: "x") && FnTapGate.shouldStart(sourceAtPress: "x", sourceAfter: nil))
    check("fn gate waits briefly, well under half a second", FnTapGate.settleSeconds > 0 && FnTapGate.settleSeconds < 0.5)
    var fn = FnTapDetector()
    fn.fnDown(at: t0, otherModifiersHeld: false)
    check("fn tap fires on a quick clean press", fn.fnUp(at: t0.addingTimeInterval(0.2)))
    fn.fnDown(at: t0, otherModifiersHeld: false)
    check("fn hold is not a tap", !fn.fnUp(at: t0.addingTimeInterval(1.5)))
    fn.fnDown(at: t0, otherModifiersHeld: false)
    fn.otherInput()
    check("fn + another key is a chord, not a tap", !fn.fnUp(at: t0.addingTimeInterval(0.2)))
    fn.fnDown(at: t0, otherModifiersHeld: true)
    check("⌘Fn is not a tap", !fn.fnUp(at: t0.addingTimeInterval(0.1)))
    check("an Fn release without a press does nothing", !fn.fnUp(at: t0))
    fn.otherInput()
    fn.fnDown(at: t0, otherModifiersHeld: false)
    check("keys typed before Fn do not spoil the next tap", fn.fnUp(at: t0.addingTimeInterval(0.3)))
}

// MARK: 15. learning from corrections

do {
    let pair = EditLearner.correction(inserted: "我在用得普西克写代码", edited: "我在用DeepSeek写代码")
    checkEq("correction finds the replaced span (from)", pair?.from, "得普西克")
    checkEq("correction finds the replaced span (to)", pair?.to, "DeepSeek")
    checkEq("latin fix grows to the whole word", EditLearner.correction(inserted: "use kubernetis now", edited: "use kubernetes now")?.to, "kubernetes")
    checkEq("a one-character CJK fix learns the word", EditLearner.correction(inserted: "这家公式很好", edited: "这家公司很好")?.to, "公司")
    checkEq("pure insertion is not a correction", EditLearner.correction(inserted: "开会", edited: "开个会")?.to, nil)
    checkEq("identical text is not a correction", EditLearner.correction(inserted: "好", edited: "好")?.to, nil)

    checkEq("sound-alike fix is learned", EditLearner.learnedWord(inserted: "我在用得普西克写代码", edited: "我在用DeepSeek写代码"), "DeepSeek")
    checkEq("homophone fix is learned", EditLearner.learnedWord(inserted: "这家公式很好", edited: "这家公司很好"), "公司")
    checkEq("content edit is not learned", EditLearner.learnedWord(inserted: "明天开会", edited: "后天开会"), nil)
    checkEq("typo fix is learned", EditLearner.learnedWord(inserted: "use kubernetis now", edited: "use kubernetes now"), "kubernetes")
    checkEq("rewriting a whole sentence is not learned",
            EditLearner.learnedWord(inserted: "我们下周把报告发出去", edited: "请在周五之前提交季度预算"), nil)
    check("acronym initials count as sound-alike", EditLearner.similarity(heard: "第四批", corrected: "DSH") >= EditLearner.minSimilarity)

    checkEq("edited region between the anchors", EditLearner.editedRegion(before: "Hi Emma, ", after: " Thanks", now: "Hi Emma, see you Friday. Thanks"), "see you Friday.")
    checkEq("edited region without anchors is the whole field", EditLearner.editedRegion(before: "", after: "", now: "全文"), "全文")
    checkEq("missing anchor means no region", EditLearner.editedRegion(before: "gone", after: "", now: "全文"), nil)
}

// MARK: 16. rich list pasting and pill sizing

do {
    let html = Inserter.listHTML(for: "我说三点：\n1. 要快\n2. 要准\n3. 要便宜")
    check("numbered lines become an ordered list", html?.contains("<ol><li>要快</li><li>要准</li><li>要便宜</li></ol>") == true, html ?? "nil")
    check("the lead-in stays a paragraph", html?.contains("<p>我说三点：</p>") == true)
    checkEq("prose produces no list HTML", Inserter.listHTML(for: "今天天气不错。"), nil)
    check("list HTML escapes markup", Inserter.listHTML(for: "1. a<b>\n2. c&d")?.contains("a&lt;b&gt;") == true)

    var m = RecordingBarModel()
    m.showRecording(destination: "x")
    let normal = PillView.width(for: m, limit: 120)
    m.update(level: 0.2, elapsed: 110)
    check("the pill widens for the last-seconds countdown", PillView.width(for: m, limit: 120) > normal)
    m.showResult(String(repeating: "很长的结果", count: 40), warning: false)
    check("a long result never exceeds the pill's maximum width", PillView.width(for: m, limit: 120) <= 360)
}

// MARK: 17. never paste into a different app; resting bar off by default

do {
    check("paste goes into the app the dictation started in",
          PasteTarget.matches(expected: "com.apple.Notes", frontmost: "com.apple.Notes"))
    check("no paste after switching to another app",
          !PasteTarget.matches(expected: "com.apple.Notes", frontmost: "com.googlecode.iterm2"))
    check("no paste when nothing is frontmost any more",
          !PasteTarget.matches(expected: "com.apple.Notes", frontmost: ""))
    check("an unknown starting app cannot be checked and is allowed",
          PasteTarget.matches(expected: "", frontmost: "com.apple.Notes"))
    UserDefaults.standard.removeObject(forKey: "ui.showIdleBar.v2")
    checkEq("the resting voice bar is off by default", Settings.shared.showIdleBar, false)
}

// MARK: 18. own API key: route header, model list, URL rules, completeness

do {
    let route = LLMRoute(baseURL: "https://api.example.com/v1", model: "chat-model", apiKey: "sk-test")
    let header = ServiceClient.encodeRouteHeader(route) ?? ""
    let decoded = Data(base64Encoded: header).flatMap { try? JSONDecoder().decode(LLMRoute.self, from: $0) }
    checkEq("route header decodes to the route", decoded, route)
    checkEq("no route means no header", ServiceClient.encodeRouteHeader(nil), nil)
    let body = Data(#"{"object":"list","data":[{"id":"b-model"},{"id":"a-model"},{"x":1}]}"#.utf8)
    checkEq("model ids come sorted from /models", LLMRoute.modelIDs(from: body), ["a-model", "b-model"])
    checkEq("a malformed /models body gives no ids", LLMRoute.modelIDs(from: Data("nope".utf8)), [String]())
    check("https base URLs may carry a key", LLMPreset.isAllowedBaseURL("https://api.deepseek.com/v1"))
    check("plain http to another host may not", !LLMPreset.isAllowedBaseURL("http://api.example.com/v1"))
    check("plain http to this Mac may (Ollama)", LLMPreset.isAllowedBaseURL("http://127.0.0.1:11434/v1"))
    check("every preset except custom has a usable base URL",
          LLMPreset.all.filter { $0.id != "custom" }.allSatisfy { LLMPreset.isAllowedBaseURL($0.baseURL) })

    // Never the real Keychain: a test must not read (or prompt for) the user's key.
    KeychainStore.stub = [:]
    let s = Settings.shared
    s.llmPresetID = "ollama"
    s.llmModel = ""
    checkEq("an incomplete route is not used", s.activeLLMRoute, nil)
    s.llmModel = "qwen2.5:7b"
    checkEq("a complete keyless local route is used", s.activeLLMRoute?.model, "qwen2.5:7b")
    checkEq("its base URL is the preset's", s.activeLLMRoute?.baseURL, "http://127.0.0.1:11434/v1")
    s.llmBaseURL = "http://example.com/v1"
    checkEq("an unsafe base URL disables the route", s.activeLLMRoute, nil)
    UserDefaults.standard.removeObject(forKey: "llm.baseURL.ollama")
    UserDefaults.standard.removeObject(forKey: "llm.model.ollama")
    s.llmPresetID = "deepseek"
    UserDefaults.standard.removeObject(forKey: "llm.model.deepseek")
    checkEq("no model yet means no route (dictation still works, unpolished)", s.activeLLMRoute, nil)
    UserDefaults.standard.set("maximal", forKey: "voice.strength")
    checkEq("a strength saved by an older build reads as Article", s.strength, "prompt")
    UserDefaults.standard.removeObject(forKey: "voice.strength")
    checkEq("Article, prompt mode and raw transcription are offered", VoiceStrength.allCases.map(\.rawValue), ["prompt", "promptify", "off"])
    UserDefaults.standard.set("promptify", forKey: "voice.strength")
    checkEq("prompt mode is remembered", s.strength, "promptify")
    UserDefaults.standard.removeObject(forKey: "voice.strength")
}

// MARK: 19. the local service: finding Node.js, the ready line, model status

do {
    check("v22.11.0 parses", ServiceLocator.parseNodeVersion("v22.11.0\n").map { $0.major == 22 && $0.minor == 11 } == true)
    check("garbage is not a version", ServiceLocator.parseNodeVersion("node: command not found") == nil)
    check("Node 22 is supported", ServiceLocator.isSupported("v22.0.0"))
    check("Node 24 is supported", ServiceLocator.isSupported("v24.5.1"))
    check("Node 20 is too old", !ServiceLocator.isSupported("v20.18.0"))

    checkEq("the ready line gives the port",
            ServiceLocator.parseReadyLine(#"{"event":"ready","port":51234,"pid":4321,"version":"0.2.0"}"#), 51234)
    checkEq("a log line is not a ready line", ServiceLocator.parseReadyLine("[typeleast] listening"), nil)
    checkEq("a ready line without a valid port is ignored", ServiceLocator.parseReadyLine(#"{"event":"ready","port":0}"#), nil)

    let home = "/Users/someone"
    let listing: [String: [String]] = [
        home + "/.nvm/versions/node": ["v20.10.0", "v22.3.0", "v24.1.0", "notes.txt"],
        home + "/.local/share/fnm/node-versions": ["v22.12.0"],
    ]
    let candidates = ServiceLocator.nodeCandidates(home: home, list: { listing[$0] ?? [] })
    checkEq("Homebrew on Apple silicon is tried first", candidates.first, "/opt/homebrew/bin/node")
    let nvm = candidates.filter { $0.contains("/.nvm/") }
    checkEq("nvm versions are tried newest first", nvm.first, home + "/.nvm/versions/node/v24.1.0/bin/node")
    checkEq("non-version folders are skipped", nvm.count, 3)
    check("fnm installs are found", candidates.contains(home + "/.local/share/fnm/node-versions/v22.12.0/installation/bin/node"))
    checkEq("the system node is the last resort", candidates.last, "/usr/bin/node")

    let exists: (String) -> Bool = { $0 == "/App/Contents/Resources/service/bin/typeleast-service.mjs" || $0 == "/dev/service/bin/typeleast-service.mjs" }
    checkEq("the bundled service is used",
            ServiceLocator.serviceDirectory(resources: "/App/Contents/Resources", environment: [:], exists: exists),
            "/App/Contents/Resources/service")
    checkEq("TYPELEAST_SERVICE_DIR wins for development",
            ServiceLocator.serviceDirectory(resources: "/App/Contents/Resources", environment: ["TYPELEAST_SERVICE_DIR": "/dev/service"], exists: exists),
            "/dev/service")
    checkEq("no service folder is reported as nil",
            ServiceLocator.serviceDirectory(resources: "/Other", environment: [:], exists: exists), nil)

    checkEq("a release build's own Node.js is found",
            ServiceLocator.bundledNode(resources: "/App/Contents/Resources", exists: { $0 == "/App/Contents/Resources/node/bin/node" }),
            "/App/Contents/Resources/node/bin/node")
    checkEq("a build from source has no bundled Node.js",
            ServiceLocator.bundledNode(resources: "/App/Contents/Resources", exists: { _ in false }), nil)
    checkEq("first restart after one second", ServiceLocator.restartDelay(attempt: 1), 1)
    checkEq("restarts back off", ServiceLocator.restartDelay(attempt: 4), 30)
    checkEq("then it gives up and says why", ServiceLocator.restartDelay(attempt: 5), nil)

    let downloading = Data(#"{"ok":false,"service":"typeleast","speech":{"providerId":"sensevoice-local","phase":"downloading","ready":false,"download":{"received":60000000,"total":240000000},"modelBytes":241357257}}"#.utf8)
    let h = try? JSONDecoder().decode(HealthResponse.self, from: downloading)
    checkEq("health names the TypeLeast service", h?.service, "typeleast")
    check("download progress is decoded", h?.speech?.downloadFraction.map { abs($0 - 0.25) < 0.0001 } == true)
    checkEq("the model size is decoded", h?.speech?.modelBytes, 241357257)
    let missing = Data(#"{"ok":false,"speech":{"phase":"missing-model","ready":false}}"#.utf8)
    checkEq("missing models are recognised",
            (try? JSONDecoder().decode(HealthResponse.self, from: missing))?.speech?.modelsMissing, true)
    check("the state folder is TypeLeast's own",
          ServiceClient.stateDirectory.hasSuffix("/TypeLeast") || ProcessInfo.processInfo.environment["TYPELEAST_HOME"] != nil)
    check("the token lives in the state folder", ServiceClient().tokenPath.hasSuffix("TypeLeast/api-token") || ProcessInfo.processInfo.environment["TYPELEAST_HOME"] != nil)
}

// MARK: 20. prompt mode settings

do {
    let code = PromptifyGuard.makeCode()
    check("the unlock code has six digits", code.count == 6 && code.allSatisfy(\.isNumber))
    check("the right code unlocks", PromptifyGuard.matches(typed: " " + code + "\n", code: code))
    check("a wrong code does not", !PromptifyGuard.matches(typed: "000000" == code ? "111111" : "000000", code: code))
    check("an empty answer does not", !PromptifyGuard.matches(typed: "", code: code))
    let body = Data(#"{"default":"默认","appendix":"追加","override":null,"modified":false,"effective":"默认\n\n# 补充要求\n追加"}"#.utf8)
    let s = try? JSONDecoder().decode(PromptifySettings.self, from: body)
    checkEq("prompt settings decode", s?.appendix, "追加")
    checkEq("no override means the default is in use", s?.override, nil)
}

// MARK: 21. the recording-start chime is short, bright and starts at once
do {
    let pcm = StartChime.pcm()
    let samples: [Int16] = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    let rate = Int(StartChime.sampleRate)
    check("the chime lasts about a quarter of a second", samples.count == Int(Double(rate) * 0.24))
    let peak = samples.map { abs(Int($0)) }.max() ?? 0
    check("the chime is audible but not clipped", peak > 8000 && peak < Int(Int16.max))
    let attack = samples.prefix(rate * 3 / 1000).map { abs(Int($0)) }.max() ?? 0
    check("the chime reaches full level within 3 ms (no slow fade-in)", attack > peak / 3)
    let first = Array(samples.prefix(rate * 70 / 1000))
    var crossings = 0
    for i in 1..<first.count where (first[i - 1] < 0) != (first[i] < 0) { crossings += 1 }
    check("the chime's pitch is above 1 kHz (bright, not dull)", crossings > 2 * 1000 * 70 / 1000)
    let tail = samples.suffix(rate / 100).map { abs(Int($0)) }.max() ?? 0
    check("the chime has died away by the end", tail < peak / 20)
    check("the chime is a valid WAV", Wav.parse(Wav.wrap(pcm: pcm, sampleRate: StartChime.sampleRate)) != nil)
}

// MARK: 22. in-app update: versions, the right download, checksums
do {
    checkEq("a leading v is dropped", Updater.version(fromTag: "v1.4.0\n"), "1.4.0")
    check("1.4.0 is newer than 1.3.0", Updater.isNewer("1.4.0", than: "1.3.0"))
    check("1.10.0 is newer than 1.9.3 (numbers, not text)", Updater.isNewer("1.10.0", than: "1.9.3"))
    check("the same version is not newer", !Updater.isNewer("1.3.0", than: "1.3.0"))
    check("1.3 equals 1.3.0", !Updater.isNewer("1.3", than: "1.3.0") && !Updater.isNewer("1.3.0", than: "1.3"))
    check("an older version is not offered", !Updater.isNewer("1.2.0", than: "1.3.0"))
    checkEq("Apple silicon downloads the AppleSilicon zip", Updater.assetName(version: "1.4.0", arch: "arm64"), "TypeLeast-1.4.0-macOS-AppleSilicon.zip")
    checkEq("Intel downloads the Intel zip", Updater.assetName(version: "1.4.0", arch: "x86_64"), "TypeLeast-1.4.0-macOS-Intel.zip")
    let sums = "AAAA1111  TypeLeast-1.4.0-macOS-AppleSilicon.dmg\nbbbb2222  TypeLeast-1.4.0-macOS-AppleSilicon.zip\ncccc3333 *TypeLeast-1.4.0-macOS-Intel.zip\n"
    checkEq("the zip's hash is found", Updater.checksum(for: "TypeLeast-1.4.0-macOS-AppleSilicon.zip", in: sums), "bbbb2222")
    checkEq("binary-mode lines work too", Updater.checksum(for: "TypeLeast-1.4.0-macOS-Intel.zip", in: sums), "cccc3333")
    checkEq("a missing file has no hash", Updater.checksum(for: "other.zip", in: sums), nil)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("typeleast-sha-" + UUID().uuidString)
    try? Data("abc".utf8).write(to: tmp)
    checkEq("SHA-256 of a file", try? Updater.sha256Hex(of: tmp), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    try? FileManager.default.removeItem(at: tmp)
    checkEq("gh is found where Homebrew puts it", Updater.findGH(home: "/Users/someone", exists: { $0 == "/usr/local/bin/gh" }, shellLookup: { nil }), "/usr/local/bin/gh")
    checkEq("gh in the user's ~/.local/bin is found", Updater.findGH(home: "/Users/someone", exists: { $0 == "/Users/someone/.local/bin/gh" }, shellLookup: { nil }), "/Users/someone/.local/bin/gh")
    checkEq("otherwise the login shell is asked", Updater.findGH(home: "/Users/someone", exists: { $0 == "/opt/tools/gh" }, shellLookup: { "/opt/tools/gh" }), "/opt/tools/gh")
    checkEq("no gh, no update source", Updater.findGH(home: "/Users/someone", exists: { _ in false }, shellLookup: { nil }), nil)
}

// UI language and privacy regressions.
do {
    checkEq("invalid UI preference follows system", L10n.normalized("bad"), "system")
    checkEq("Chinese system uses Simplified Chinese", L10n.resolve("system", preferred: ["zh-Hant-TW"]), "zh-Hans")
    checkEq("other systems use English", L10n.resolve(nil, preferred: ["ja-JP"]), "en")
    checkEq("manual English overrides system", L10n.resolve("en", preferred: ["zh-CN"]), "en")
    checkEq("manual Chinese overrides system", L10n.resolve("zh-Hans", preferred: ["en-US"]), "zh-Hans")
    checkEq("translated label", L10n.render("设置", arguments: [], language: "en"), "Settings")
    checkEq("content slots are not translated or expanded", L10n.render("常被识别成「{0}」", arguments: ["用户 {1}"], language: "en"), "Often recognized as “用户 {1}”")
    let previous = Settings.shared.interfaceLanguage
    Settings.shared.interfaceLanguage = "en"
    checkEq("language preference persists", UserDefaults.standard.string(forKey: L10n.preferenceKey), "en")
    checkEq("saving does not switch the running UI", L10n.language, "zh-Hans")
    Settings.shared.interfaceLanguage = previous
    check("URL credentials rejected", !LLMPreset.isAllowedBaseURL("https://someone:fake@api.example.com/v1"))
    check("URL query credentials rejected", !LLMPreset.isAllowedBaseURL("https://api.example.com/v1?key=fake"))
    checkEq("diagnostics omit raw error text", DiagnosticsLog.safeField("error", "fake-private-content"), "[omitted]")
    checkEq("diagnostics keep status", DiagnosticsLog.safeField("status", "-25293"), "-25293")
}

server.stop()
print("")
print("TESTS: " + String(passed) + " passed, " + String(failed) + " failed")
exit(failed == 0 ? 0 : 1)

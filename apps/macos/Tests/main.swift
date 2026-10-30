import Foundation
import Darwin
import AVFoundation
import AppKit
import SwiftUI

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

// Isolated visual regression fixture. It never loads the daily history or opens a service.
if let index = CommandLine.arguments.firstIndex(of:"--unified-ui-render"), CommandLine.arguments.count > index+1 {
    let output = CommandLine.arguments[index+1]
    guard output.hasPrefix("/private/tmp/"), let home = ProcessInfo.processInfo.environment["TYPELEAST_HOME"], home.hasPrefix("/private/tmp/"), Bundle.main.bundleIdentifier != "com.dsh.voice" else { exit(2) }
    try FileManager.default.createDirectory(atPath:output,withIntermediateDirectories:true)
    let app = NSApplication.shared
    func save(_ view:NSView,_ name:String) throws {
        view.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.15))
        if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output+"/"+name+".png"))
        }
    }
    for language in ["zh-Hans","en"] { for dark in [false,true] {
        L10n.language = language;app.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
        let name = language + (dark ? "-dark" : "-light")
        let model = AppModel()
        let rows = ["dictation","translation","assistant"].map { task -> LocalHistoryEntry in
            var entry=LocalHistoryEntry(id:task,ts:Date(timeIntervalSince1970:0),app:"fictional.editor",language:"zh",strength:"prompt",raw:"Fictional input",text:String(repeating:"虚构文本与 English names，预算 8000，条件必须保留。",count:3),fallback:false,inserted:false)
            entry.task=task;return entry
        }
        let history=NSHostingView(rootView:VStack(spacing:0){ForEach(rows){HistoryRow(entry:$0,compact:false)};Spacer()}.background(Theme.window).environmentObject(model).environment(\.colorScheme,dark ? .dark : .light))
        history.frame=NSRect(x:0,y:0,width:600,height:720)
        let window=NSWindow(contentRect:history.frame,styleMask:[.titled],backing:.buffered,defer:false);window.contentView=history
        try save(history,name+"-history");window.orderOut(nil)
    }}
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--history-ui-render"), CommandLine.arguments.count > index + 1 {
    let output = CommandLine.arguments[index + 1]
    guard output.hasPrefix("/private/tmp/"), let home = ProcessInfo.processInfo.environment["TYPELEAST_HOME"], home.hasPrefix("/private/tmp/"), Bundle.main.bundleIdentifier != "com.dsh.voice" else { exit(2) }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    let app = NSApplication.shared
    for dark in [false, true] {
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        for width in [520, 850] {
            let model = AppModel()
            var entry = LocalHistoryEntry(id: "fixture", ts: Date(timeIntervalSince1970: 0), app: "fictional.editor", language: "zh", strength: "concise", raw: "虚构识别原文", text: String(repeating: "这是虚构的长文本，保留数字 123、条件和 English words，用来验证换行后不会遮住来源和状态。", count: 3), fallback: true, inserted: false)
            entry.task = "dictation"
            let view = NSHostingView(rootView: VStack(spacing: 0) { HistoryRow(entry: entry, compact: false); Divider(); HistoryRow(entry: entry, compact: true); Spacer() }.background(Theme.window).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 430), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: width, height: 430)
            window.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + "/history-\(width)-\(dark ? "dark" : "light").png"))
            }
            window.orderOut(nil)
        }
    }
    exit(0)
}

// Developer-only UI fixture. No service, microphone, global shortcuts or real Keychain access.
if let index = CommandLine.arguments.firstIndex(of: "--model-ui-render"), CommandLine.arguments.count > index + 1 {
    let output = CommandLine.arguments[index + 1]
    guard output.hasPrefix("/private/tmp/"), let home = ProcessInfo.processInfo.environment["TYPELEAST_HOME"], home.hasPrefix("/private/tmp/"), Bundle.main.bundleIdentifier != "com.dsh.voice" else { exit(2) }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    let app = NSApplication.shared
    let fixture = #"{"activeModelId":"qwen3-asr-0.6b","models":[{"id":"qwen3-asr-0.6b","name":"Qwen3-ASR-0.6B","modelBytes":990000000,"sourceUrl":"https://example.com/model","licenseUrl":"https://example.com/license","canSetLanguage":true,"installed":true,"category":"primary","precision":"int8"},{"id":"qwen3-asr-1.7b-fp16","name":"Qwen3-ASR-1.7B","modelBytes":4731171333,"sourceUrl":"https://example.com/model","licenseUrl":"https://example.com/license","canSetLanguage":true,"installed":false,"category":"primary","precision":"fp16"},{"id":"sensevoice-small","name":"SenseVoice Small","modelBytes":240000000,"sourceUrl":"https://example.com/model","licenseUrl":"https://example.com/license","canSetLanguage":true,"installed":true,"category":"other","precision":"int8","registered":false}]}"#
    for language in ["zh-Hans", "en"] {
        L10n.language = language
        for dark in [false, true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let model = AppModel()
            model.speechCatalog = try JSONDecoder().decode(SpeechModelCatalog.self, from: Data(fixture.utf8))
            model.health = try JSONDecoder().decode(HealthResponse.self, from: Data(#"{"ok":true,"speech":{"ready":true,"phase":"ready","modelName":"Qwen3-ASR-0.6B"}}"#.utf8))
            let view = NSHostingView(rootView: ScrollView { SpeechModelOptions().padding(20) }.background(Theme.window).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 500, height: 700)
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + "/" + language + (dark ? "-dark.png" : "-light.png")))
            }
            window.orderOut(nil)
        }
    }
    exit(0)
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
    /// When set, /health answers a challenge like the real service.
    var proofKey: String?
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

let modelCatalogJSON = #"{"activeModelId":"sensevoice-small","models":[{"id":"fun-asr-nano","name":"Fun-ASR-Nano","modelBytes":1009605061,"sourceUrl":"https://huggingface.co/example/model","licenseUrl":"https://huggingface.co/example/source","canSetLanguage":true,"installed":true}],"operation":{"modelId":"fun-asr-nano","phase":"waiting","received":100,"total":100,"error":null},"notice":null}"#

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
    if req.path.hasPrefix("/api/voice-polish/health") {
        let challenge = req.header("x-typeleast-challenge")
        if let key = state.proofKey, !challenge.isEmpty, let proof = ServiceClient.proof(key: key, challenge: challenge) {
            return .json(String(healthJSON.dropLast()) + ",\"proof\":\"" + proof + "\"}")
        }
        return .json(healthJSON)
    }
    if req.path == "/api/voice-polish/models" { return .json(modelCatalogJSON) }
    if req.path.hasPrefix("/api/voice-polish/models/") { return .json("{\"ok\":true,\"phase\":\"accepted\"}", status: 202) }
    if req.path.hasPrefix("/api/voice-polish/dictate") {
        if state.mode == "slow-generation" { Thread.sleep(forTimeInterval:1) }
        if state.mode == "dictateError" {
            return .json("{\"error\":\"speech not ready\",\"code\":\"speech_not_ready\"}", status: 503)
        }
        if state.mode == "fallback" { return .json(fallbackJSON) }
        return .json(dictateJSON)
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

// MARK: 7. the learned description rides with each dictation

do {
    let wav = Data(repeating: 1, count: 64)
    let none = ServiceClient.dictateBody(wav: wav, profile: "")
    checkEq("no description: the body is the WAV", none.body, wav)
    checkEq("no description: zero bytes", none.metaBytes, 0)
    let some = ServiceClient.dictateBody(wav: wav, profile: "做 CFD 仿真的工程师")
    let json = some.body.prefix(some.metaBytes)
    checkEq("the description comes first, in a JSON object", (try? JSONSerialization.jsonObject(with: json)) as? [String: String], ["profile": "做 CFD 仿真的工程师"])
    checkEq("then the WAV", some.body.suffix(from: some.body.startIndex + some.metaBytes), wav)
    _ = try client.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.TextEdit", strength: "prompt", profile: "做 CFD 仿真的工程师")
    checkEq("its length is in the header", state.lastRequest?.header("x-voice-meta-bytes"), String(some.metaBytes))
} catch {
    check("description with dictation", false, String(describing: error))
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

    model.showRecording(destination: "com.apple.mail", badge: "自然整理")
    checkEq("showRecording enters recording", model.phase, RecordingBarModel.Phase.recording)
    checkEq("showRecording keeps the destination", model.destination, "com.apple.mail")
    checkEq("recording shows its cleanup mode", model.badge, "自然整理")
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
    checkEq("thinking keeps the same mode", model.badge, "自然整理")
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
    checkEq("hide clears the mode", model.badge, "")
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

// MARK: 15. update offers and progress

do {
    // The update offer rule and the ring's steps.
    check("a quiet check offers a new version once", Updater.shouldOffer(latest: "1.18.0", offered: nil, interactive: false, busy: false))
    check("…not again", !Updater.shouldOffer(latest: "1.18.0", offered: "1.18.0", interactive: false, busy: false))
    check("…nor while dictating or Prompt Beta is open", !Updater.shouldOffer(latest: "1.18.0", offered: nil, interactive: false, busy: true))
    check("asking by hand always offers", Updater.shouldOffer(latest: "1.18.0", offered: "1.18.0", interactive: true, busy: true))
    checkEq("five steps", UpdateStage.steps, ["下载", "校验", "签名", "Key", "安装"])
    checkEq("each stage has its step", [UpdateStage.preparing, .downloading(received: 1, total: 2, source: "GitHub"), .verifying, .signing, .handingOver, .installing].map(\.step), [0, 0, 1, 2, 3, 4])
    checkEq("the amount under the percentage", UpdateStage.downloading(received: 33 << 20, total: 52 << 20, source: "GitHub").amount, "33.0 / 52.0 MB")
    checkEq("no amount outside the download", UpdateStage.signing.amount, nil)

    // Update progress text.
    checkEq("download progress is a fraction", UpdateStage.downloading(received: 25 << 20, total: 50 << 20, source: "GitHub").fraction, 0.5)
    checkEq("an unknown size shows a moving bar", UpdateStage.downloading(received: 1, total: nil, source: "GitHub").fraction, nil)
    checkEq("later stages show a moving bar", UpdateStage.signing.fraction, nil)
    check("the download line shows megabytes and the source", UpdateStage.downloading(received: 25 << 20, total: 50 << 20, source: "ghfast.top").label.contains("25.0 / 50.0") && UpdateStage.downloading(received: 1, total: 2, source: "ghfast.top").label.contains("ghfast.top"))
    let official = URL(string: "https://github.com/FlaxXTT/Typeleast/releases/download/v1.17.8/TypeLeast-1.17.8-macOS-AppleSilicon.zip")!
    let auto = UpdateSources.list(for: official, mode: "auto")
    checkEq("auto tries GitHub first", auto.first?.1, "GitHub")
    checkEq("…then mirrors with the full GitHub address", auto.dropFirst().first?.0.absoluteString, "https://ghfast.top/" + official.absoluteString)
    checkEq("mirrors-first ends with GitHub", UpdateSources.list(for: official, mode: "mirror").last?.1, "GitHub")
    checkEq("GitHub only means one source", UpdateSources.list(for: official, mode: "github").count, 1)
    checkEq("other addresses are never sent to a mirror", UpdateSources.list(for: URL(string: "https://example.com/x.zip")!, mode: "mirror").count, 1)
}

// MARK: 16. rich list pasting and pill sizing

do {
    checkEq("a list after text on the same line starts on a new line", Inserter.separatingList("1. 第一项\n2. 第二项", before: "他说的话"), "\n1. 第一项\n2. 第二项")
    checkEq("…and after text that could not be read", Inserter.separatingList("1、第一项", before: nil), "\n1、第一项")
    checkEq("a list at the start of a line is left alone", Inserter.separatingList("1. 第一项", before: "上一段\n"), "1. 第一项")
    checkEq("…as is a list in an empty field", Inserter.separatingList("- 第一项", before: ""), "- 第一项")
    checkEq("a bullet after text starts on a new line", Inserter.separatingList("- 第一项", before: "前文"), "\n- 第一项")
    checkEq("ordinary text is never moved", Inserter.separatingList("2026 年的计划", before: "他说的话"), "2026 年的计划")
    checkEq("…nor a decimal at the start", Inserter.separatingList("3.5 万元的预算", before: "他说的话"), "3.5 万元的预算")
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
    UserDefaults.standard.removeObject(forKey: "voice.fieldContext")
    checkEq("reading the field around the cursor is off by default", Settings.shared.readFieldContext, false)
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
    checkEq("a strength saved by an older build reads as natural cleanup", s.strength, "prompt")
    UserDefaults.standard.removeObject(forKey: "voice.strength")
    checkEq("three cleanup modes are offered", VoiceStrength.allCases.map(\.rawValue), ["concise", "prompt", "promptbeta"])
    UserDefaults.standard.set("off", forKey: "voice.strength")
    checkEq("retired verbatim setting reads as natural cleanup", s.strength, "prompt")
    for retired in ["promptbrief", "promptify"] {
        UserDefaults.standard.set(retired, forKey: "voice.strength")
        checkEq("the retired prompt-mode tier " + retired + " reads as concise", s.strength, "concise")
    }
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
    checkEq("an environment variable cannot replace the bundled service",
            ServiceLocator.serviceDirectory(resources: "/App/Contents/Resources", environment: ["TYPELEAST_SERVICE_DIR": "/dev/service"], exists: exists),
            "/App/Contents/Resources/service")
    checkEq("TYPELEAST_SERVICE_DIR is used when nothing is bundled (development)",
            ServiceLocator.serviceDirectory(resources: "/Other", environment: ["TYPELEAST_SERVICE_DIR": "/dev/service"], exists: exists),
            "/dev/service")
    let childEnv = ServiceLocator.serviceEnvironment(["PATH": "/usr/bin", "NODE_OPTIONS": "--require /tmp/x.js", "node_path": "/tmp",
                                                      "NODE_TLS_REJECT_UNAUTHORIZED": "0", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
                                                      "NODE_EXTRA_CA_CERTS": "/etc/ca.pem", "TYPELEAST_HOME": "/tmp/h", "HTTPS_PROXY": "http://p"])
    checkEq("the service environment drops code-loading variables",
            childEnv.keys.sorted(), ["HTTPS_PROXY", "NODE_EXTRA_CA_CERTS", "PATH", "TYPELEAST_HOME"])
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

// MARK: 21. the cue sounds are a soft 登登: low, quiet, rising to start and falling to stop
do {
    func samples(_ pcm: Data) -> [Int16] { pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) } }
    let rate = Int(StartChime.sampleRate)
    /// Zero crossings over a window, as a rough pitch in Hz.
    func pitch(_ s: [Int16], from: Double, to: Double) -> Int {
        let part = Array(s[Int(from * Double(rate))..<Int(to * Double(rate))])
        var crossings = 0
        for i in 1..<part.count where (part[i - 1] < 0) != (part[i] < 0) { crossings += 1 }
        return Int(Double(crossings) / 2 / (to - from))
    }
    let start = samples(StartChime.pcm()), stop = samples(StartChime.stopPCM())
    check("the cues last under half a second", start.count == Int(Double(rate) * 0.46) && stop.count == start.count)
    let peak = start.map { abs(Int($0)) }.max() ?? 0
    check("the cues are audible but quiet", peak > 3000 && peak < Int(Int16.max) / 4)
    let low = pitch(start, from: 0.02, to: 0.08), high = pitch(start, from: 0.20, to: 0.28)
    check("the start cue rises", high > low)
    check("…and stays low, not shrill", low > 300 && high < 600)
    check("the stop cue falls", pitch(stop, from: 0.02, to: 0.08) > pitch(stop, from: 0.20, to: 0.28))
    let tail = start.suffix(rate / 100).map { abs(Int($0)) }.max() ?? 0
    check("the cues have died away by the end", tail < peak / 20)
    check("the cue is a valid WAV", Wav.parse(Wav.wrap(pcm: StartChime.pcm(), sampleRate: StartChime.sampleRate)) != nil)
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
    checkEq("Intel Macs get no new versions", Updater.intelDiscontinued(arch: "x86_64"), true)
    checkEq("Apple silicon keeps updating", Updater.intelDiscontinued(arch: "arm64"), false)
    let sums = "AAAA1111  TypeLeast-1.4.0-macOS-AppleSilicon.dmg\nbbbb2222  TypeLeast-1.4.0-macOS-AppleSilicon.zip\ncccc3333 *TypeLeast-1.4.0-macOS-Intel.zip\n"
    checkEq("the zip's hash is found", Updater.checksum(for: "TypeLeast-1.4.0-macOS-AppleSilicon.zip", in: sums), "bbbb2222")
    checkEq("binary-mode lines work too", Updater.checksum(for: "TypeLeast-1.4.0-macOS-Intel.zip", in: sums), "cccc3333")
    checkEq("a missing file has no hash", Updater.checksum(for: "other.zip", in: sums), nil)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("typeleast-sha-" + UUID().uuidString)
    try? Data("abc".utf8).write(to: tmp)
    checkEq("SHA-256 of a file", try? Updater.sha256Hex(of: tmp), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    try? FileManager.default.removeItem(at: tmp)
}

// UI language and privacy regressions.
do {
    checkEq("invalid UI preference follows system", L10n.normalized("bad"), "system")
    checkEq("Chinese system uses Simplified Chinese", L10n.resolve("system", preferred: ["zh-Hant-TW"]), "zh-Hans")
    checkEq("other systems use English", L10n.resolve(nil, preferred: ["ja-JP"]), "en")
    checkEq("manual English overrides system", L10n.resolve("en", preferred: ["zh-CN"]), "en")
    checkEq("manual Chinese overrides system", L10n.resolve("zh-Hans", preferred: ["en-US"]), "zh-Hans")
    checkEq("translated label", L10n.render("设置", arguments: [], language: "en"), "Settings")
    checkEq("content slots are not translated or expanded", L10n.render("常被识别成「{0}」", arguments: ["用户 {1}"], language: "en"), "Heard as “用户 {1}”")
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

do {
    let catalog = try client.speechModelsSync()
    checkEq("catalog request path", state.lastRequest?.path, "/api/voice-polish/models")
    checkEq("catalog preserves selected default", catalog.activeModelId, "sensevoice-small")
    checkEq("catalog decodes installed model", catalog.models.first?.installed, true)
    let formatCatalog = try JSONDecoder().decode(SpeechModelCatalog.self, from: Data(#"{"activeModelId":"","models":[{"id":"qwen3-asr-1.7b-fp16","name":"Qwen3-ASR-1.7B","modelBytes":4731171333,"sourceUrl":"https://huggingface.co/example/model","licenseUrl":"https://example.com/license","canSetLanguage":true,"installed":false,"category":"primary","precision":"fp16","downloadable":true}]}"#.utf8))
    checkEq("no model is implicitly selected", formatCatalog.activeModelId, "")
    checkEq("model precision survives decoding", formatCatalog.models.first?.precision, "fp16")
    checkEq("model category survives decoding", formatCatalog.models.first?.category, "primary")
    _ = try client.localModelActionSync(path: "register-known", body: ["modelId": "sensevoice-small"])
    checkEq("known model configuration path", state.lastRequest?.path, "/api/voice-polish/models/register-known")
    checkEq("catalog waiting blocks repeat actions", catalog.operation?.running, true)
    try client.speechModelActionSync(id: "fun-asr-nano", download: true, endpoint: "https://mirror.example.com")
    checkEq("candidate download method", state.lastRequest?.method, "POST")
    let body = try JSONSerialization.jsonObject(with: state.lastRequest!.body) as! [String: Any]
    checkEq("candidate download identifies model", body["modelId"] as? String, "fun-asr-nano")
    checkEq("candidate download requests activation", body["activate"] as? Bool, true)
    checkEq("candidate download retains mirror", body["endpoint"] as? String, "https://mirror.example.com")
    try client.speechModelActionSync(id: "qwen3-asr-0.6b")
    checkEq("installed model activation method", state.lastRequest?.method, "PUT")
    checkEq("installed model activation path", state.lastRequest?.path, "/api/voice-polish/models/active")
    try client.speechModelActionSync(id: "fun-asr-nano", cancel: true)
    checkEq("candidate cancel method", state.lastRequest?.method, "POST")
    checkEq("candidate cancel path", state.lastRequest?.path, "/api/voice-polish/models/download/cancel")
    let status = try JSONDecoder().decode(SpeechStatus.self, from: Data(#"{"modelId":"fun-asr-nano","modelName":"Fun-ASR-Nano","ready":true,"canSetLanguage":true,"languages":["auto","zh","en","ja"]}"#.utf8))
    checkEq("health identifies actual recognizer", status.modelName, "Fun-ASR-Nano")
    checkEq("health exposes language capabilities", status.languages, ["auto", "zh", "en", "ja"])
    checkEq("natural cleanup English label", L10n.render("自然整理", arguments: [], language: "en"), "Natural")
} catch { check("speech model client contract", false, String(describing: error)) }

// MARK: 23. Prompt Beta: questions come back with a session; the answer carries it
do {
    let asked = try JSONDecoder().decode(DictateResponse.self, from: Data(#"{"text":"","raw":"r","fallback":false,"beta":{"sessionId":"s-1","questions":["给谁看？","要多长？"]}}"#.utf8))
    checkEq("questions are read", asked.betaQuestions, ["给谁看？", "要多长？"])
    checkEq("session id is read", asked.beta?.sessionId, "s-1")
    let done = try JSONDecoder().decode(DictateResponse.self, from: Data(###"{"text":"## 目标","raw":"r","fallback":false,"beta":{"issues":2,"patched":true}}"###.utf8))
    checkEq("a finished prompt has no questions", done.betaQuestions, [String]())
    let plain = try JSONDecoder().decode(DictateResponse.self, from: Data(#"{"text":"x","raw":"x","fallback":false}"#.utf8))
    checkEq("older services without beta still decode", plain.betaQuestions, [String]())
    state.mode = "health"
    _ = try? client.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.TextEdit", strength: "promptbeta", betaSession: "s-1")
    checkEq("the answer carries the session", state.lastRequest?.header("x-voice-beta-session"), "s-1")
    checkEq("Prompt Beta strength is sent", state.lastRequest?.header("x-voice-strength"), "promptbeta")
    _ = try? client.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.TextEdit", strength: "prompt")
    checkEq("ordinary dictation sends no session", state.lastRequest?.header("x-voice-beta-session"), "")
} catch {
    check("Prompt Beta decoding", false, String(describing: error))
}

// MARK: 24. the app's own menu bar: TypeLeast / Edit / Window, with the standard shortcuts
do {
    let menus = MainMenu()
    var opened = 0
    menus.openSettings = { opened += 1 }
    let bar = menus.build()
    checkEq("three menus in the menu bar", bar.menu.items.count, 3)
    checkEq("the window menu is handed back", bar.menu.items[2].submenu === bar.windows, true)
    func find(_ key: String, _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        bar.menu.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mask }
    }
    checkEq("⌘C copies via the first responder", find("c")?.action, #selector(NSText.copy(_:)))
    checkEq("⌘V pastes", find("v")?.action, #selector(NSText.paste(_:)))
    checkEq("⌘X cuts", find("x")?.action, #selector(NSText.cut(_:)))
    checkEq("⌘A selects all", find("a")?.action, #selector(NSText.selectAll(_:)))
    checkEq("⌘Z undoes", find("z")?.action, Selector(("undo:")))
    checkEq("⇧⌘Z redoes", find("z", [.command, .shift])?.action, Selector(("redo:")))
    checkEq("edit actions have no fixed target", find("v")?.target == nil, true)
    checkEq("⌘W closes the window", find("w")?.action, #selector(NSWindow.performClose(_:)))
    checkEq("⌘M minimises", find("m")?.action, #selector(NSWindow.performMiniaturize(_:)))
    checkEq("⌘H hides the app", find("h")?.action, #selector(NSApplication.hide(_:)))
    checkEq("⌥⌘H hides the others", find("h", [.command, .option])?.action, #selector(NSApplication.hideOtherApplications(_:)))
    checkEq("⌘Q and ⌘, are there", find("q") != nil && find(",") != nil, true)
    if let settings = find(","), let action = settings.action { _ = (settings.target as? NSObject)?.perform(action) }
    checkEq("⌘, opens settings", opened, 1)
}

// MARK: 25. 翻译 and 语言变体: headers, decoding, settings
do {
    state.mode = "health"
    _ = try? client.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.TextEdit", strength: "prompt",
                                translateTo: "en", variants: "zh=tw,en=gb")
    checkEq("the target language is sent", state.lastRequest?.header("x-voice-translate"), "en")
    checkEq("the variants are sent", state.lastRequest?.header("x-voice-variants"), "zh=tw,en=gb")
    _ = try? client.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.TextEdit", strength: "prompt")
    checkEq("ordinary dictation sends no target", state.lastRequest?.header("x-voice-translate"), "")
    let r = try JSONDecoder().decode(DictateResponse.self, from: Data(#"{"text":"Hello","raw":"你好","fallback":false,"translated":"en"}"#.utf8))
    checkEq("the translated language is read", r.translated, "en")
    let old = try JSONDecoder().decode(LocalHistoryEntry.self, from: Data(#"{"id":"a","ts":0,"language":"zh","strength":"prompt","raw":"r","text":"t","fallback":false,"inserted":true}"#.utf8))
    checkEq("older history entries still decode", old.translated, nil)
    let s = Settings.shared
    let saved = (s.zhVariant, s.translateTarget)
    s.zhVariant = "hans"
    checkEq("default variants send nothing", s.variantsHeader, nil)
    s.zhVariant = "tw"
    checkEq("a chosen variant makes the header", s.variantsHeader, "zh=tw")
    s.zhVariant = "nonsense"
    checkEq("an unknown variant reads as Simplified", s.zhVariant, "hans")
    s.translateTarget = "xx"
    checkEq("an unknown target reads as English", s.translateTarget, "en")
    checkEq("the translate shortcut defaults to ⇧⌥Space", HotKeyBinding.translateDefault.modifiers, 512 | 2048)
    s.zhVariant = saved.0; s.translateTarget = saved.1
} catch {
    check("translate decoding", false, String(describing: error))
}

// MARK: 26. activity heatmap: counts per day, streaks, levels; never any text
do {
    let suite = "typeleast.tests.activity"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let log = ActivityLog(defaults: defaults, calendar: calendar)
    func day(_ d: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))! }
    checkEq("a new log is empty", log.activeDays, 0)
    log.seedIfNeeded(from: [(date: day(10), words: 30), (date: day(10), words: 5), (date: day(11), words: 8)])
    checkEq("seeding counts per day", log.day(day(10)), ActivityDay(dictations: 2, words: 35))
    log.seedIfNeeded(from: [(date: day(1), words: 1)])
    checkEq("seeding happens only once", log.day(day(1)).dictations, 0)
    log.record(words: 12, at: day(12))
    log.record(words: 3, at: day(14))
    log.record(words: 4, at: day(15))
    checkEq("active days", log.activeDays, 5)
    let today = log.streaks(today: day(15))
    checkEq("current streak ends today", today.current, 2)
    checkEq("longest streak", today.longest, 3)
    checkEq("a streak survives until the day is over", log.streaks(today: day(16)).current, 2)
    checkEq("and breaks after a missed day", log.streaks(today: day(17)).current, 0)
    checkEq("levels", [0, 1, 4, 10, 25].map(ActivityLog.level), [0, 1, 2, 3, 4])
    let reloaded = ActivityLog(defaults: defaults, calendar: calendar)
    checkEq("counts persist", reloaded.day(day(12)), ActivityDay(dictations: 1, words: 12))
    let stored = String(data: defaults.data(forKey: "voice.activity.v1") ?? Data(), encoding: .utf8) ?? ""
    checkEq("only dates and counts are stored", stored.contains("2026-10-12") && !stored.contains("text"), true)
    reloaded.clear()
    checkEq("clearing empties it", reloaded.activeDays, 0)
    defaults.removePersistentDomain(forName: suite)
}

// MARK: 27. security: sealed history, terminal paste, own signature, the one service
do {
    KeychainStore.stub = [:]
    HistorySeal.reset()
    let suite = "typeleast.tests.history"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let old = [LocalHistoryEntry(id: "a", ts: Date(), app: "x", language: "zh", strength: "prompt", raw: "明天三点开会",
                                 text: "明天三点开会。", fallback: false, fallbackReason: nil, model: nil, msTotal: nil,
                                 audioPath: nil, inserted: true, seconds: 2)]
    defaults.set(try! JSONEncoder().encode(old), forKey: "voice.history.v1")
    let store = HistoryStore(defaults: defaults)
    checkEq("plain history from older versions is read", store.entries.first?.text, "明天三点开会。")
    checkEq("and then removed", defaults.data(forKey: "voice.history.v1"), nil)
    let sealed = defaults.data(forKey: "voice.history.sealed.v1") ?? Data()
    checkEq("the sealed copy shows no words", String(decoding: sealed, as: UTF8.self).contains("开会"), false)
    checkEq("the key is in the Keychain, not the preferences", KeychainStore.stub?[HistorySeal.account] != nil, true)
    HistorySeal.reset()
    checkEq("a new start reads it back", HistoryStore(defaults: defaults).entries.count, 1)
    KeychainStore.stub = [:]
    HistorySeal.reset()
    checkEq("without the key nothing is readable", HistoryStore(defaults: defaults).entries.count, 0)
    defaults.removePersistentDomain(forName: suite)

    let wavPath = NSTemporaryDirectory() + "dsh-voice-test-" + UUID().uuidString + ".wav"
    FileManager.default.createFile(atPath: wavPath, contents: Data([1, 2, 3, 4]))
    let sealedPath = HistorySeal.sealFile(atPath: wavPath)
    checkEq("a kept recording is sealed", sealedPath, wavPath + ".sealed")
    checkEq("the plain recording is gone", FileManager.default.fileExists(atPath: wavPath), false)
    checkEq("it reads back in memory", try? HistorySeal.readAudio(URL(fileURLWithPath: sealedPath ?? "")), Data([1, 2, 3, 4]))
    checkEq("its file is owner-only", ((try? FileManager.default.attributesOfItem(atPath: sealedPath ?? ""))?[.posixPermissions] as? Int), 0o600)
    try? FileManager.default.removeItem(atPath: sealedPath ?? "")
    KeychainStore.stub = [:]
    HistorySeal.reset()
}
checkEq("ordinary apps get the text unchanged", TerminalGuard.safeText("第一行\n第二行", bundleId: "com.apple.Notes"), "第一行\n第二行")
checkEq("a terminal gets one line", TerminalGuard.safeText("ls\nrm -rf ~\n", bundleId: "com.apple.Terminal"), "ls rm -rf ~")
checkEq("escape sequences are dropped", TerminalGuard.safeText("echo hi\u{1b}[201~\r\nwhoami", bundleId: "com.googlecode.iterm2"), "echo hi[201~ whoami")
checkEq("Apple's own apps pass the signature check", SelfIntegrity.problem(bundleURL: URL(fileURLWithPath: "/System/Applications/TextEdit.app")), nil)
let unsignedDir = URL(fileURLWithPath: NSTemporaryDirectory() + "typeleast-unsigned-" + UUID().uuidString + ".app")
try? FileManager.default.createDirectory(at: unsignedDir, withIntermediateDirectories: true)
checkEq("an unsigned folder does not", SelfIntegrity.problem(bundleURL: unsignedDir) != nil, true)
try? FileManager.default.removeItem(at: unsignedDir)

// Upgrade retained recordings using fixture data only.
do {
    KeychainStore.stub = [:]; HistorySeal.reset()
    let suite = "typeleast.tests.audio-migration"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    let path = NSTemporaryDirectory() + "dsh-voice-upgrade-" + UUID().uuidString + ".wav"
    try! Data([7, 8, 9]).write(to: URL(fileURLWithPath: path))
    let entry = LocalHistoryEntry(id: "migration", ts: Date(), app: nil, language: "auto", strength: "prompt",
        raw: "fixture", text: "fixture", fallback: false, fallbackReason: nil, model: nil, msTotal: nil,
        audioPath: path, inserted: false)
    d.set(try! JSONEncoder().encode([entry]), forKey: "voice.history.v1")
    let store = HistoryStore(defaults: d)
    checkEq("legacy audio path migrates", store.last?.audioPath, path + ".sealed")
    checkEq("legacy audio plaintext is removed after history save", FileManager.default.fileExists(atPath: path), false)
    checkEq("migrated audio can be retried", try? HistorySeal.readAudio(URL(fileURLWithPath: path + ".sealed")), Data([7, 8, 9]))
    checkEq("migrated audio path survives reload", HistoryStore(defaults: d).last?.audioPath, path + ".sealed")
    try? FileManager.default.removeItem(atPath: path + ".sealed")
    d.removePersistentDomain(forName: suite)
    // An unavailable encryption key must not remove either legacy file.
    try! Data([7, 8, 9]).write(to: URL(fileURLWithPath: path))
    let original = try! JSONEncoder().encode([entry])
    d.set(original, forKey: "voice.history.v1")
    KeychainStore.stub = [HistorySeal.account: "invalid fixture key"]; HistorySeal.reset()
    let failedMigration = HistoryStore(defaults: d)
    check("failed audio migration reports a problem", failedMigration.persistenceProblem != nil)
    checkEq("failed audio migration preserves the legacy history", d.data(forKey: "voice.history.v1"), original)
    checkEq("failed audio migration preserves the original audio", try? Data(contentsOf: URL(fileURLWithPath: path)), Data([7, 8, 9]))
    try? FileManager.default.removeItem(atPath: path)
    d.removePersistentDomain(forName: suite)
    KeychainStore.stub = [:]; HistorySeal.reset()
    // A damaged legacy store must remain available for recovery.
    let invalid = Data("not JSON".utf8)
    d.set(invalid, forKey: "voice.history.v1")
    let broken = HistoryStore(defaults: d)
    broken.save()
    checkEq("invalid legacy history is preserved", d.data(forKey: "voice.history.v1"), invalid)
    check("invalid legacy history reports failure", broken.persistenceProblem != nil)
    d.removePersistentDomain(forName: suite)
    KeychainStore.stub = [:]; HistorySeal.reset()
}

// Verify a signed resource bundle, without starting an app or reading any user data.
do {
    let root = URL(fileURLWithPath: NSTemporaryDirectory() + "typeleast-integrity-" + UUID().uuidString + ".app")
    let contents = root.appendingPathComponent("Contents")
    let executable = contents.appendingPathComponent("MacOS/Fixture")
    let resource = contents.appendingPathComponent("Resources/fixture.txt")
    try! FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    let plist: [String: Any] = ["CFBundleIdentifier": "test.typeleast.integrity", "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL"]
    try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try! Data("original fixture".utf8).write(to: resource)
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", "--timestamp=none", "--options", "runtime", root.path]
    signer.standardError = FileHandle.nullDevice
    try! signer.run(); signer.waitUntilExit()
    checkEq("fixture signs with Hardened Runtime", signer.terminationStatus, 0)
    checkEq("intact signed resources pass", SelfIntegrity.problem(bundleURL: root), nil)
    try! Data("changed fixture".utf8).write(to: resource)
    check("modified signed resources are rejected", SelfIntegrity.problem(bundleURL: root) != nil)
    try? FileManager.default.removeItem(at: root)
}

// Failure paths must not overwrite a locked encrypted store or write new plaintext.
do {
    let suite = "typeleast.tests.history-failures"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    KeychainStore.stub = [:]; HistorySeal.reset()
    let store = HistoryStore(defaults: d)
    store.save()
    let saved = d.data(forKey: "voice.history.sealed.v1")
    KeychainStore.stub = [:]; HistorySeal.reset()
    let locked = HistoryStore(defaults: d)
    locked.save()
    checkEq("locked history preserves ciphertext", d.data(forKey: "voice.history.sealed.v1"), saved)
    checkEq("locked history never writes plaintext", d.data(forKey: "voice.history.v1"), nil)
    check("locked history exposes a storage problem", locked.persistenceProblem != nil)
    KeychainStore.stub = [HistorySeal.account: "invalid fixture key"]; HistorySeal.reset()
    checkEq("invalid stored key is never replaced", HistorySeal.key(create: true) == nil, true)
    checkEq("existing key remains intact", KeychainStore.stub?[HistorySeal.account], "invalid fixture key")
    locked.clear()
    checkEq("explicit clear removes locked ciphertext", d.data(forKey: "voice.history.sealed.v1"), nil)
    let empty = HistoryStore(defaults: d)
    empty.save()
    checkEq("failed encryption never writes plaintext", d.data(forKey: "voice.history.v1"), nil)
    check("failed encryption is reported", empty.persistenceProblem != nil)
    d.removePersistentDomain(forName: suite)
    KeychainStore.stub = [:]; HistorySeal.reset()
    let dir = NSTemporaryDirectory() + "typeleast-instance-" + UUID().uuidString
    var first: InstanceLock? = InstanceLock(directory: dir)
    let second = InstanceLock(directory: dir)
    checkEq("first instance owns the lock", first?.acquire(), true)
    checkEq("simultaneous second instance is rejected", second.acquire(), false)
    first = nil
    checkEq("lock releases when owner exits", second.acquire(), true)
    try? FileManager.default.removeItem(atPath: dir)
}

// Multi-round waiting never leaks the latest answer into the insertion path.
do {
    let waiting = try JSONDecoder().decode(DictateResponse.self, from: Data(#"{"text":"","raw":"latest answer","fallback":false,"beta":{"sessionId":"s","questions":[],"confirmed":["confirmed"],"round":3,"ready":true,"notice":"beta-validation"}}"#.utf8))
    check("ready clarification still waits for the user's Generate", waiting.betaWaiting)
    checkEq("ready clarification inserts nothing", waiting.insertableText, "")
    checkEq("round metadata decodes", waiting.beta?.round, 3)
    checkEq("confirmed metadata decodes", waiting.beta?.confirmed, ["confirmed"])
    checkEq("notice metadata decodes", waiting.beta?.notice, "beta-validation")
} catch { check("new Beta/config decoding", false) }

// MARK: 28. the service proves it is ours before anything is sent to it
checkEq("HMAC proof matches the service's (RFC 4231 case 2 key)",
        ServiceClient.proof(key: "4a656665", challenge: "what do ya want for nothing?"),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
checkEq("a non-hex key gives no proof", ServiceClient.proof(key: "zz", challenge: "x"), nil)
do {
    let impostor = ServiceClient()
    impostor.baseURL = server.baseURL
    impostor.tokenPath = tokenPath
    impostor.proofKey = String(repeating: "ab", count: 32)
    state.mode = "health"
    do {
        _ = try impostor.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.TextEdit", strength: "prompt",
                                     llm: LLMRoute(baseURL: "https://api.example.com/v1", model: "m", apiKey: "sk-test-0000"))
        check("a listener without the proof is refused", false)
    } catch let e as ServiceError {
        checkEq("a listener without the proof is refused", e, .untrusted)
    }
    checkEq("and the key never reached it", state.lastRequest?.header("x-voice-llm"), "")
}
// The service exited: whatever answers on its old port next proves itself again.
do {
    let key = String(repeating: "cd", count: 32)
    let owned = ServiceClient()
    owned.baseURL = server.baseURL
    owned.tokenPath = tokenPath
    owned.proofKey = key
    state.mode = "health"
    state.proofKey = key
    check("our own service proves itself", (try? owned.healthSync()) != nil)
    owned.invalidatePort()
    checkEq("a stopped service leaves no port to talk to", owned.baseURL.port, 1)
    state.proofKey = nil
    owned.usePort(Int(server.port))
    do {
        _ = try owned.dictateSync(wav: wav, language: "zh", appBundleId: "com.apple.TextEdit", strength: "prompt",
                                  llm: LLMRoute(baseURL: "https://api.example.com/v1", model: "m", apiKey: "sk-test-0000"))
        check("after the service exits, its old port is checked again", false)
    } catch let e as ServiceError {
        checkEq("after the service exits, its old port is checked again", e, .untrusted)
    }
    checkEq("and the key never reached the new listener", state.lastRequest?.header("x-voice-llm"), "")
}

// MARK: 29. Keychain: read once, never on a redraw, and handed over across an update
do {
    KeychainStore.stub = ["deepseek": "sk-test-0000", "history-encryption-key": "aGVsbG8="]
    checkEq("existence is known without reading", KeychainStore.exists(account: "deepseek"), true)
    checkEq("the accounts are listed", KeychainStore.accounts(), ["deepseek", "history-encryption-key"])

    // The new copy is recognised by code hash before any key goes to it.
    let me = Bundle.main.executableURL!
    let mine = KeychainHandoff.cdhash(of: me)
    check("a signed executable has a code hash", mine?.count == 40)
    checkEq("this process is the code with that hash", KeychainHandoff.process(getpid(), hasCDHash: mine ?? ""), true)
    checkEq("any other hash does not match", KeychainHandoff.process(getpid(), hasCDHash: String(repeating: "0", count: 40)), false)
    checkEq("a malformed hash never matches", KeychainHandoff.process(getpid(), hasCDHash: "cdhash"), false)

    // Versions up to 1.17.2 handed the items over in a file: it is restored once, then wiped.
    let file = URL(fileURLWithPath: NSTemporaryDirectory() + "typeleast-handoff-" + UUID().uuidString + ".json")
    let historyKey = Data(repeating: 7, count: 32).base64EncodedString()
    KeychainStore.stub = [:]
    try? JSONEncoder().encode(["deepseek": "sk-test-0000", "history-encryption-key": historyKey]).write(to: file)
    KeychainHandoff.restoreIfPresent(file: file)
    checkEq("the next copy recreates them", KeychainStore.stub?["deepseek"], "sk-test-0000")
    checkEq("including the history key", KeychainStore.stub?["history-encryption-key"], historyKey)
    checkEq("and the file is gone", FileManager.default.fileExists(atPath: file.path), false)
    KeychainStore.stub = ["deepseek": "kept"]
    try? JSONEncoder().encode(["deepseek": "stale"]).write(to: file)
    KeychainHandoff.restoreIfPresent(file: file)
    checkEq("an item still present is not overwritten", KeychainStore.stub?["deepseek"], "kept")

    // A key that cannot be recreated is not lost with the file, and no new history key replaces it.
    KeychainStore.stub = [:]
    KeychainStore.stubRefuses = ["history-encryption-key"]
    try? JSONEncoder().encode(["deepseek": "sk-test-0000", "history-encryption-key": historyKey]).write(to: file)
    KeychainHandoff.restoreIfPresent(file: file)
    checkEq("a key that could not be recreated keeps its file", FileManager.default.fileExists(atPath: file.path), true)
    KeychainHandoff.fileOverride = file
    HistorySeal.reset()
    check("no new history key is made meanwhile", HistorySeal.key(create: true) == nil)
    checkEq("so nothing replaces the old one", KeychainStore.stub?["history-encryption-key"], nil)
    KeychainStore.stubRefuses = []
    let recovered = HistorySeal.key(create: true)?.withUnsafeBytes { Data($0) }.base64EncodedString()
    checkEq("the next try takes the handed-over key", recovered, historyKey)
    checkEq("and only then is the file wiped", FileManager.default.fileExists(atPath: file.path), false)
    KeychainHandoff.fileOverride = nil
    HistorySeal.reset()
    KeychainStore.stub = [:]
}

// MARK: 30. "never keep history" keeps nothing on disk
do {
    KeychainStore.stub = [:]
    HistorySeal.reset()
    let suite = "typeleast.tests.never"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    let store = HistoryStore(defaults: defaults)
    store.keepsNothing = { true }
    store.add(LocalHistoryEntry(id: "n", ts: Date(), app: "x", language: "zh", strength: "prompt", raw: "r", text: "t",
                                fallback: false, fallbackReason: nil, model: nil, msTotal: nil, audioPath: nil, inserted: true, seconds: 1))
    checkEq("the last entry is kept in memory for paste-last", store.last?.text, "t")
    checkEq("nothing is written", defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("voice.history") }, [String]())
    defaults.removePersistentDomain(forName: suite)
    KeychainStore.stub = [:]
}
// Switching to "never" with exactly one stored entry clears the disk at once, its recording too.
do {
    KeychainStore.stub = [:]
    HistorySeal.reset()
    let suite = "typeleast.tests.never-switch"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    var never = false
    let store = HistoryStore(defaults: defaults)
    store.keepsNothing = { never }
    let audio = NSTemporaryDirectory() + "typeleast-test-" + UUID().uuidString + ".wav.sealed"
    FileManager.default.createFile(atPath: audio, contents: Data([1, 2, 3]))
    store.add(LocalHistoryEntry(id: "one", ts: Date(), app: "x", language: "zh", strength: "prompt", raw: "r", text: "t",
                                fallback: false, fallbackReason: nil, model: nil, msTotal: nil, audioPath: audio, inserted: true, seconds: 1))
    check("one entry is stored", defaults.data(forKey: "voice.history.sealed.v1") != nil)
    never = true
    store.applyRetention(.never)
    checkEq("switching to never clears the stored entry at once",
            defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("voice.history") }, [String]())
    checkEq("and its recording", FileManager.default.fileExists(atPath: audio), false)
    checkEq("the entry stays in memory for paste-last", store.last?.text, "t")
    defaults.removePersistentDomain(forName: suite)
    KeychainStore.stub = [:]
}

// Beta controller keeps the initial destination and route across follow-up rounds.
do {
    var shown = 0, hidden = 0, cancelled: [String] = []
    let controller = BetaController(host: .init(show: { _, _ in shown += 1 },
        hide: { hidden += 1 }, busy: { _ in }, cancel: { cancelled.append($0.sessionId) }))
    let info = try JSONDecoder().decode(BetaInfo.self, from: Data(#"{"sessionId":"round1","questions":[]}"#.utf8))
    controller.accept(info: info, sessionId: "round1", llm: nil, language: "zh", variants: nil,
                      appBundleId: "example.original", field: nil)
    controller.show(hotkey: "Fn")
    controller.accept(info: info, sessionId: "round2", llm: nil, language: "en", variants: "changed",
                      appBundleId: "example.followup", field: nil)
    checkEq("Beta retains original destination", controller.pending?.appBundleId, "example.original")
    checkEq("Beta retains original language", controller.pending?.language, "zh")
    checkEq("Beta preserves an originally absent variant", controller.pending?.variants, nil)
    checkEq("Beta advances session id", controller.pending?.sessionId, "round2")
    controller.cancel(); controller.cancel()
    checkEq("Beta cancels the current conversation once", cancelled, ["round2"])
    check("Beta clears before presenting a new conversation", controller.pending == nil)
    controller.show(hotkey: "Fn")
    checkEq("Beta cannot show a cancelled conversation", shown, 1)
    checkEq("Beta hides on cancellation", hidden, 1)
    controller.accept(info: info, sessionId: "new", llm: nil, language: "en", variants: nil,
                      appBundleId: "example.new", field: nil)
    checkEq("Beta new conversation has a new destination", controller.pending?.appBundleId, "example.new")
    controller.clear()
    checkEq("Beta completion does not send cancellation", cancelled.count, 1)
}

// Shared, versioned behavior for a future client written in another language.
do {
    struct ModeCase: Decodable { let stored: String?; let expected: String; let labelZh: String }
    struct RequestCase: Decodable {
        let id: String
        let language: String
        let strength: String
        let translateTo: String?
        let variants: String?
        let profile: String
    }
    struct ResponseCase: Decodable {
        let id: String
        let response: DictateResponse
        let insertable: String
        let betaWaiting: Bool
        let translated: String?
        let corrections: Int?
        let intention: String?
    }
    struct ClientContract: Decodable { let version: Int; let modeCases: [ModeCase]; let requestCases: [RequestCase]; let responseCases: [ResponseCase] }
    guard let path = ProcessInfo.processInfo.environment["TYPELEAST_CLIENT_CONTRACT"] else { fatalError("Missing client contract") }
    let contract = try JSONDecoder().decode(ClientContract.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    checkEq("client contract version", contract.version, 2)
    let oldLanguage = L10n.language
    L10n.language = "zh-Hans"
    for sample in contract.modeCases {
        let mode = VoiceStrength.stored(sample.stored)
        checkEq("shared stored mode: " + (sample.stored ?? "null"), mode.rawValue, sample.expected)
        checkEq("shared mode title: " + (sample.stored ?? "null"), mode.label, sample.labelZh)
    }
    L10n.language = oldLanguage
    state.mode = "health"
    for sample in contract.requestCases {
        _ = try client.dictateSync(wav: wav, language: sample.language, appBundleId: "example.editor",
                                   strength: sample.strength, translateTo: sample.translateTo,
                                   variants: sample.variants, profile: sample.profile)
        let sent = state.lastRequest
        checkEq("shared request path: " + sample.id, sent?.path, "/api/voice-polish/dictate")
        checkEq("shared request language: " + sample.id, sent?.header("x-voice-language"), sample.language)
        checkEq("shared request mode: " + sample.id, sent?.header("x-voice-strength"), sample.strength)
        checkEq("shared request translation: " + sample.id, sent?.header("x-voice-translate"), sample.translateTo ?? "")
        checkEq("shared request variants: " + sample.id, sent?.header("x-voice-variants"), sample.variants ?? "")
        let length = Int(sent?.header("x-voice-meta-bytes") ?? "") ?? -1
        let body = sent?.body ?? Data()
        check("shared meta length: " + sample.id, length >= 0 && length <= body.count)
        if length >= 0 && length <= body.count {
            let meta = length == 0 ? [:] : ((try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: String] ?? [:])
            checkEq("shared profile: " + sample.id, meta["profile"] ?? "", sample.profile)
            checkEq("shared WAV tail: " + sample.id, Data(body.suffix(from: length)), wav)
        }
    }
    for sample in contract.responseCases {
        checkEq("shared insertable response: " + sample.id, sample.response.insertableText, sample.insertable)
        checkEq("shared beta waiting: " + sample.id, sample.response.betaWaiting, sample.betaWaiting)
        checkEq("shared translation result: " + sample.id, sample.response.translated, sample.translated)
        checkEq("shared corrections: " + sample.id, sample.response.corrections?.count, sample.corrections)
        checkEq("shared intention: " + sample.id, sample.response.intention, sample.intention)
    }
}

do {
    struct NotesCase: Decodable { let id: String; let language: String; let markdown: String; let expected: String }
    let notes = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TYPELEAST_RELEASE_NOTES"]!)
    let cases = try JSONDecoder().decode([NotesCase].self, from: Data(contentsOf: notes))
    for sample in cases { checkEq("release summary: " + sample.id, ReleaseSummary.text(sample.markdown, language: sample.language), sample.expected) }
    checkEq("release summary line is bounded", ReleaseSummary.text("- " + String(repeating: "x", count: 1000)).count, 142)
    let data = Data(#"{"tag_name":"v1.18.0","body":"- Clearer modes","draft":false}"#.utf8)
    checkEq("release parser keeps version", Updater.release(from: data)?.version, "1.18.0")
    checkEq("release parser keeps bounded notes", Updater.release(from: data)?.summary, "• Clearer modes")
    check("draft is never offered", Updater.release(from: Data(#"{"tag_name":"v1.18.0","draft":true}"#.utf8)) == nil)
    checkEq("missing notes keep update usable", Updater.release(from: Data(#"{"tag_name":"v1.18.0"}"#.utf8))?.summary, "")
    let saved = UserDefaults.standard.string(forKey: "voice.strength")
    defer { if let saved { UserDefaults.standard.set(saved, forKey: "voice.strength") } else { UserDefaults.standard.removeObject(forKey: "voice.strength") } }
    let settings = Settings()
    settings.strength = "concise"
    checkEq("the concise tier persists", Settings().strength, "concise")
}

// MARK: the description of the user's work is learned from History and cleared with it
do {
    KeychainStore.stub = [:]
    HistorySeal.reset()
    let suite = "typeleast.tests.profile"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HistoryStore(defaults: defaults)
    store.keepsNothing = { false }
    var learned = LocalHistoryEntry(id: "a", ts: Date(), app: "x", language: "zh", strength: "prompt", raw: "修复哭达", text: "修复 CUDA",
                                    fallback: false, fallbackReason: nil, model: nil, msTotal: nil, audioPath: nil, inserted: true, seconds: 1)
    learned.corrections = [TermCorrection(from: "哭达", to: "CUDA", reason: "显存")]
    learned.intention = "修复显存溢出"
    store.add(LocalHistoryEntry(id: "b", ts: Date(), app: "x", language: "zh", strength: "prompt", raw: "r", text: "t",
                                fallback: false, fallbackReason: nil, model: nil, msTotal: nil, audioPath: nil, inserted: true, seconds: 1))
    store.add(learned)
    checkEq("only entries with something learned are sent", store.learningItems.count, 1)
    checkEq("…as corrections and intention, never the text", store.learningItems.first?.keys.sorted(), ["corrections", "intention"])
    checkEq("no description before the first launch writes one", store.profile, "")
    store.setProfile("做 CUDA 开发")
    checkEq("the description is kept, sealed", store.profile, "做 CUDA 开发")
    check("…not as plain text", !(defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("CUDA") == true }))
    store.setProfile(String(repeating: "字", count: 1200))
    checkEq("the description is capped at 1000 characters", store.profile.count, 1000)
    store.clear()
    checkEq("clearing History clears the description", store.profile, "")
}

// MARK: retry recordings are deleted after five minutes
do {
    KeychainStore.stub = [:]
    HistorySeal.reset()
    let suite = "typeleast.tests.audio-lifetime"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    checkEq("retry audio lives five minutes", HistoryStore.audioLifetime, 300)
    let store = HistoryStore(defaults: defaults)
    store.keepsNothing = { false }
    func entry(_ id: String, age: TimeInterval) -> (LocalHistoryEntry, String) {
        let path = NSTemporaryDirectory() + "dsh-voice-test-" + UUID().uuidString + ".wav.sealed"
        FileManager.default.createFile(atPath: path, contents: Data([1, 2, 3]))
        return (LocalHistoryEntry(id: id, ts: Date().addingTimeInterval(-age), app: "x", language: "zh", strength: "prompt",
                                  raw: "r", text: "t", fallback: false, fallbackReason: nil, model: nil, msTotal: nil,
                                  audioPath: path, inserted: true, seconds: 1), path)
    }
    let (old, oldPath) = entry("old", age: 6 * 60)
    let (fresh, freshPath) = entry("fresh", age: 60)
    store.add(old)
    store.add(fresh)
    store.pruneAudio()
    check("a six-minute-old recording is deleted", !FileManager.default.fileExists(atPath: oldPath))
    checkEq("…and its entry no longer offers a retry", store.entries.first { $0.id == "old" }?.audioPath, nil)
    check("a one-minute-old recording stays", FileManager.default.fileExists(atPath: freshPath))
    try? FileManager.default.removeItem(atPath: freshPath)
}

// MARK: new-user guide: every entry names a place; a failed model download offers a mirror
do {
    let entries = SettingsGuide.entries
    checkEq("the guide lists five places", entries.count, 5)
    check("every guide entry says where it is", entries.allSatisfy { !$0.place.isEmpty })
    checkEq("the API key lives under Settings › Models", entries.first { $0.title == L10n.text("API Key") }?.category, 1)
    checkEq("the speech model lives under Settings › Models", entries.first { $0.title == L10n.text("语音模型") }?.category, 1)
    let model = AppModel.shared
    let before = (model.page, model.settingsCategory)
    SettingsGuide.open(entries[1], in: model)
    check("opening an entry goes to its Settings tab", model.page == .settings && model.settingsCategory == 1)
    model.page = before.0; model.settingsCategory = before.1
    func speech(_ json: String) -> SpeechStatus { try! JSONDecoder().decode(SpeechStatus.self, from: Data(json.utf8)) }
    check("an unreachable host is a network failure", speech(#"{"phase":"error","error":"could not reach huggingface.co: fetch failed"}"#).networkFailure)
    check("a failed catalog download is a network failure", speech(#"{"phase":"ready","operation":{"modelId":"x","phase":"error","received":0,"total":0,"error":"download-failed"}}"#).networkFailure)
    check("a checksum failure is not", !speech(#"{"phase":"ready","operation":{"modelId":"x","phase":"error","received":0,"total":0,"error":"checksum-mismatch"}}"#).networkFailure)
    check("a load failure is not", !speech(#"{"phase":"error","error":"model load failed"}"#).networkFailure)
    checkEq("the suggested mirror", ModelMirror.suggested, "https://hf-mirror.com")
}

// The menu bar menu builds every item it later updates (a missing one stops the app at launch).
do {
    let menu = MenuController()
    var state = MenuState()
    menu.apply(state)
    state.hint = "fixture"; state.serviceUp = true; state.accessibilityTrusted = true; state.phase = .recording
    menu.apply(state)
    check("the menu applies every state without a missing item", menu.menu.items.count > 5)
    NSStatusBar.system.removeStatusItem(menu.statusItem)
}

// AI cleanup migration uses a dedicated preference domain.
do {
    let suite = "typeleast.tests.ai-cleanup." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("promptbeta", forKey: "voice.strength")
    let migrated = Settings(defaults: defaults)
    checkEq("existing users migrate to unified dictation once", migrated.strength, "prompt")
    migrated.strength = "prompt"
    checkEq("later startups preserve chosen mode", Settings(defaults: defaults).strength, "prompt")
}

do {
    state.mode = "ok"
    _ = try client.dictateSync(wav:Wav.wrap(pcm:Data(repeating:0,count:3200)),language:"zh",appBundleId:"fictional.editor",strength:"promptbeta")
    checkEq("assistant request has explicit task header",state.lastRequest?.header("x-voice-task"),"assistant")
    check("progress request id is bounded",(state.lastRequest?.header("x-request-id").count ?? 0) == 36)
    checkEq("ten-minute WAV is within the client ceiling",Wav.maxBytes,24*1024*1024)
    checkEq("generation timeout covers recognition and cleanup",client.dictateTimeout,600)
    let progress=try JSONDecoder().decode(TaskProgress.self,from:Data(#"{"stage":"generating","completed":2,"total":5}"#.utf8))
    checkEq("progress uses actual chunk counts",progress.label,L10n.text("正在整理 {0}/{1}",2,5))
    let response=try JSONDecoder().decode(DictateResponse.self,from:Data(#"{"task":"assistant","text":"result"}"#.utf8))
    checkEq("task survives response decoding",response.task,"assistant")
} catch { check("unified task contract",false,String(describing:error)) }

do {
    state.mode = "slow-generation"
    let began = Date()
    DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { client.cancelGeneration() }
    do {
        _ = try client.dictateSync(wav:Wav.wrap(pcm:Data(repeating:0,count:3200)),language:"zh",appBundleId:"fictional.editor",strength:"prompt")
        check("cancelled generation cannot return an insertable response",false)
    } catch { check("generation cancellation returns before the late provider",Date().timeIntervalSince(began)<0.9) }
    state.mode = "ok"
}

contextPreferencesTests()

server.stop()
print("")
print("TESTS: " + String(passed) + " passed, " + String(failed) + " failed")
exit(failed == 0 ? 0 : 1)

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
    let result = MeetingResult(segments: [
        MeetingSegment(start: 75.2, end: 80, speaker: "S01", text: "先看日志。"),
        MeetingSegment(start: 3700.5, end: nil, speaker: "S02", text: "已经回滚了。"),
    ], speakers: ["S01", "S02"], truncated: true)
    checkEq("meeting text keeps time and speaker on every line", MeetingFormat.text(result), "[01:15] S01: 先看日志。\n[1:01:40] S02: 已经回滚了。\n")
    checkEq("meeting subtitles keep the speaker; a missing end gets three seconds", MeetingFormat.srt(result),
            "1\n00:01:15,200 --> 00:01:20,000\nS01: 先看日志。\n\n2\n01:01:40,500 --> 01:01:43,500\nS02: 已经回滚了。\n")

    let status = try? JSONDecoder().decode(MeetingStatus.self, from: Data(#"{"id":"a","phase":"done","seconds":6,"elapsedMs":900,"result":{"segments":[{"start":0.1,"end":null,"speaker":"S01","text":"x"}],"speakers":["S01"],"text":"x","truncated":true}}"#.utf8))
    checkEq("a finished status carries labelled turns", status?.result?.segments.first?.speaker, "S01")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-tests-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    do {
        let m4a = folder.appendingPathComponent("stereo.m4a")
        try writeTone(to: m4a, seconds: 3, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2])
        let wav = try MeetingAudio.canonicalWav(from: m4a)
        check("an imported m4a becomes the canonical WAV", Wav.isCanonical(wav), Wav.describe(wav))
        check("the import keeps the length", abs((Wav.parse(wav)?.durationSeconds ?? 0) - 3) < 0.2)

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

    checkEq("every page has a title", HubPage.meetings.title, "会议")
    checkEq("the client's limit matches the service's", MeetingLimits.maxSeconds, 600)
    checkEq("a missing model is explained", MeetingController.explain(code: "model-not-installed"), "还没有下载 MOSS 模型。")
    checkEq("meeting copy is translated", L10n.render("录音太短。", arguments: [], language: "en"), "The recording is too short.")
}

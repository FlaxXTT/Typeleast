// Tools/meeting-check/main.swift - the meeting flow without clicks: the page's controller imports a
// file (or takes a WAV through the recorder path, fed in place of the microphone), the real service
// runs the real engine, and the transcript and a render of the page are written out.
// Usage: see Tools/meeting-check.sh. Never touches the installed app's data.
import AppKit
import SwiftUI

let arguments = CommandLine.arguments
guard arguments.count == 4, ["import", "record"].contains(arguments[1]) else {
    print("usage: meeting-check import|record <audio file> <output prefix>"); exit(2)
}
precondition(Bundle.main.bundleIdentifier != "com.dsh.voice")
guard let home = ProcessInfo.processInfo.environment["TYPELEAST_HOME"], !home.isEmpty else { print("TYPELEAST_HOME is required"); exit(2) }
KeychainStore.stub = [:]
L10n.language = "zh-Hans"
let (mode, source, prefix) = (arguments[1], arguments[2], arguments[3])
let client = ServiceClient.shared
guard client.discoverBaseURL() else { print("no service in TYPELEAST_HOME"); exit(1) }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let meeting = MeetingController(client: client)
meeting.pollInterval = 0.5
let began = Date()
if mode == "import" { meeting.importFile(URL(fileURLWithPath: source)) } else {
    let wav = try Data(contentsOf: URL(fileURLWithPath: source))
    meeting.recorder.demoPCM = wav.subdata(in: 44 ..< wav.count)
    meeting.startRecording(deviceUID: "")
}
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    switch meeting.stage {
    case .failed: print("FAILED:", meeting.message); exit(1)
    case .done:
        guard let result = meeting.result else { exit(1) }
        try? MeetingFormat.text(result).write(toFile: prefix + ".txt", atomically: true, encoding: .utf8)
        try? MeetingFormat.srt(result).write(toFile: prefix + ".srt", atomically: true, encoding: .utf8)
        let view = NSHostingView(rootView: MeetingsPage().environmentObject(AppModel.shared).environmentObject(meeting).background(Theme.window))
        view.frame = NSRect(x: 0, y: 0, width: 726, height: 640)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + ".png"))
        }
        print(String(format: "DONE %@ audio=%.1fs job=%.1fs wall=%.1fs speakers=%@ turns=%d truncated=%@", mode, meeting.seconds, meeting.elapsed, Date().timeIntervalSince(began), result.speakers.joined(separator: ","), result.segments.count, String(describing: result.truncated ?? false)))
        exit(0)
    default: break
    }
}
app.run()

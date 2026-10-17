// Tools/render/main.swift - render the UI offscreen to PNGs for design review.
// Uses sample data in its own defaults domain; never reads the app's real history.
// Build: see Tools/render.sh
import AppKit
import SwiftUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : (NSTemporaryDirectory() as NSString).appendingPathComponent("dsh-voice-render")
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// Sample data
let now = Date()
let samples: [(String, String, String, Bool, Double)] = [
    ("com.apple.Notes", "我想说三点：\n1. 要快\n2. 要准\n3. 要便宜", "嗯我想说三点啊第一呢就是要快第二要准然后第三个就是要便宜", false, 9),
    ("com.apple.mail", "我们周三把报告发出去。", "我们周二把报告发出去不对周三发出去", false, 4),
    ("com.microsoft.VSCode", "我们用 DeepSeek 的模型来做整理，然后接到 Harness 那边。", "我们用德普西克的模型来做整理然后接到哈尼斯那边", false, 6),
    ("com.tencent.xinWeChat", "昨天我想了一下迁移的事情，其实我觉得风险比我们想的要大，因为数据库每张表都要改。", "昨天我想了一下那个迁移的事情其实我觉得风险比我们想的要大因为数据库每张表都要改", true, 8),
]
var entries: [LocalHistoryEntry] = []
for (i, s) in samples.enumerated() {
    entries.append(LocalHistoryEntry(id: UUID().uuidString, ts: now.addingTimeInterval(Double(-i) * 3700), app: s.0,
                                     language: "auto", strength: "prompt", raw: s.2, text: s.1, fallback: s.3,
                                     fallbackReason: nil, model: "deepseek-flash", msTotal: 900, audioPath: nil,
                                     inserted: true, seconds: s.4))
}
UserDefaults.standard.set(try! JSONEncoder().encode(entries), forKey: "voice.history.v1")
Settings.shared.words = [
    LocalWord(id: "1", word: "DeepSeek", heardAs: "德普西克", source: .manual, addedAt: now),
    LocalWord(id: "2", word: "Harness", heardAs: nil, source: .auto, addedAt: now),
    LocalWord(id: "3", word: "SenseVoice", heardAs: nil, source: .manual, addedAt: now),
]
HistoryStore.shared.load()
let model = AppModel.shared
model.reloadHistory()
model.reloadWords()
model.serviceUp = true

func snapshot(_ view: NSView, size: NSSize, name: String, dark: Bool) {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    view.frame = NSRect(origin: .zero, size: size)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    let path = outDir + "/" + name + (dark ? "-dark" : "") + ".png"
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote " + path)
}

for dark in [false, true] {
    for page in HubPage.allCases {
        model.page = page
        let height: CGFloat = page == .settings ? 1900 : 680
        snapshot(NSHostingView(rootView: HubRootView().environmentObject(model)), size: NSSize(width: 960, height: height),
                 name: "hub-" + page.rawValue, dark: dark)
    }
}
snapshot(NSHostingView(rootView: OnboardingView(finish: {}).environmentObject(model)), size: NSSize(width: 600, height: 560),
         name: "onboarding-welcome", dark: false)

// The pill in each look, drawn on a grey backdrop.
for (name, configure) in [
    ("pill-recording", { (m: inout RecordingBarModel) in m.showRecording(destination: "x"); for i in 0..<40 { m.update(level: Float(abs(sin(Double(i) / 3))) * 0.5, elapsed: 7) } }),
    ("pill-countdown", { (m: inout RecordingBarModel) in m.showRecording(destination: "x"); for i in 0..<40 { m.update(level: Float(abs(sin(Double(i) / 2))) * 0.4, elapsed: 109) } }),
    ("pill-thinking", { (m: inout RecordingBarModel) in m.showRecording(destination: "x"); m.showThinking(detail: "") }),
    ("pill-result", { (m: inout RecordingBarModel) in m.showRecording(destination: "x"); m.showResult("我想说三点：1. 要快 2. 要准 3. 要便宜", warning: false) }),
] as [(String, (inout RecordingBarModel) -> Void)] {
    var m = RecordingBarModel()
    configure(&m)
    let width = PillView.width(for: m, limit: 120)
    let pill = PillView(frame: NSRect(x: 30, y: 20, width: width, height: PillView.height))
    pill.model = m
    for _ in 0..<30 { pill.advance() }
    let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: width + 60, height: 80))
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = NSColor(calibratedWhite: 0.86, alpha: 1).cgColor
    backdrop.addSubview(pill)
    snapshot(backdrop, size: backdrop.frame.size, name: name, dark: false)
}

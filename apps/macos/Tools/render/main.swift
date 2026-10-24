// Tools/render/main.swift - render the UI offscreen to PNGs for design review.
// Uses sample data in its own defaults domain; never reads the app's real history.
// Build: see Tools/render.sh
import AppKit
import SwiftUI

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
    : (NSTemporaryDirectory() as NSString).appendingPathComponent("dsh-voice-render")
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// This tool must never run as the installed application.
precondition(Bundle.main.bundleIdentifier != "com.dsh.voice")
// All service reads must stay inside this render's fixtures, even when Settings appears.
let isolatedState = (outDir as NSString).appendingPathComponent("isolated-state")
try FileManager.default.createDirectory(atPath: isolatedState, withIntermediateDirectories: true)
setenv("TYPELEAST_HOME", isolatedState, 1)

KeychainStore.stub = [:]
HistorySeal.reset()
// Discard only this command-line tool's generated fixtures from earlier renders.
UserDefaults.standard.removeObject(forKey: "voice.history.sealed.v1")
UserDefaults.standard.removeObject(forKey: "voice.activity.v1")
L10n.language = L10n.resolve(ProcessInfo.processInfo.environment["TYPELEAST_RENDER_LANGUAGE"] ?? "zh-Hans")
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// Sample data (made up; this tool never reads the app's real history, words or Keychain).
// Times are fixed sample times, not the moment of rendering.
let today = Calendar.current.startOfDay(for: Date())
let sampleTimes: [Date] = [
    today.addingTimeInterval(10 * 3600 + 24 * 60),
    today.addingTimeInterval(-24 * 3600 + 18 * 3600 + 40 * 60),
    today.addingTimeInterval(-24 * 3600 + 16 * 3600 + 5 * 60),
    today.addingTimeInterval(-24 * 3600 + 11 * 3600 + 32 * 60),
]
let now = sampleTimes[0]
let samples: [(String, String, String, Bool, Double)] = [
    ("com.apple.Notes", "我想说三点：\n1. 要快\n2. 要准\n3. 要便宜", "嗯我想说三点啊第一呢就是要快第二要准然后第三个就是要便宜", false, 9),
    ("com.apple.mail", "周五的会改到下周二上午十点。", "那个周五的会改到下周一不对是下周二上午十点", false, 5),
    ("com.microsoft.VSCode", "把这个函数改成异步的，并加上错误处理。", "帮我把这个函数改成异步的然后呢加上错误处理", false, 4),
    ("com.tencent.xinWeChat", "我晚点到，大概七点半，你们先点菜。", "我晚点到啊大概七点半吧你们先点菜", false, 4),
]
var entries: [LocalHistoryEntry] = []
for (i, s) in samples.enumerated() {
    entries.append(LocalHistoryEntry(id: UUID().uuidString, ts: sampleTimes[i], app: s.0,
                                     language: "auto", strength: "prompt", raw: s.2, text: s.1, fallback: s.3,
                                     fallbackReason: nil, model: "deepseek-chat", msTotal: 900, audioPath: nil,
                                     inserted: true, seconds: s.4))
}
UserDefaults.standard.set(try! JSONEncoder().encode(entries), forKey: "voice.history.v1")
Settings.shared.words = [
    LocalWord(id: "1", word: "DeepSeek", heardAs: "德普西克", source: .manual, addedAt: now),
    LocalWord(id: "2", word: "TypeLeast", heardAs: nil, source: .manual, addedAt: now),
    LocalWord(id: "3", word: "SenseVoice", heardAs: nil, source: .auto, addedAt: now),
    LocalWord(id: "4", word: "GitHub", heardAs: nil, source: .auto, addedAt: now),
]
KeychainStore.stub?["deepseek"] = "sk-0000000000000000000000000000"
Settings.shared.llmPresetID = "deepseek"
Settings.shared.llmModel = "deepseek-chat"
HistoryStore.shared.load()
precondition(HistoryStore.shared.entries.count == entries.count, "Sample history did not load")
ActivityLog.shared.seedIfNeeded(from: entries.map { ($0.ts, DictationStats.countWords($0.displayText).cjk + DictationStats.countWords($0.displayText).latin) })
let model = AppModel.shared
model.reloadHistory()
model.reloadWords()
model.serviceUp = true
model.serviceState = .running(port: 1)
model.nodeDescription = "v24.21.0 · App 内置"
model.health = try? JSONDecoder().decode(HealthResponse.self, from: Data(#"{"ok":true,"service":"typeleast","version":"0.2.0","provider":"custom:api.deepseek.com","model":"deepseek-chat","speech":{"providerId":"sensevoice-local","phase":"ready","ready":true}}"#.utf8))
model.speechCatalog = SpeechModelCatalog(activeModelId: "sensevoice-small", models: [
    SpeechModelOption(id: "sensevoice-small", name: "SenseVoice Small", modelBytes: 239549735,
        sourceUrl: "https://huggingface.co/FunAudioLLM/SenseVoice", licenseUrl: "https://github.com/FunAudioLLM/SenseVoice", canSetLanguage: true, installed: true),
    SpeechModelOption(id: "fireredasr2-ctc", name: "FireRedASR2 CTC", modelBytes: 775940592,
        sourceUrl: "https://huggingface.co/FireRedTeam/FireRedASR2-AED", licenseUrl: "https://huggingface.co/FireRedTeam/FireRedASR2-AED", canSetLanguage: false, installed: false),
    SpeechModelOption(id: "fun-asr-nano", name: "Fun-ASR-Nano", modelBytes: 1009605061,
        sourceUrl: "https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512", licenseUrl: "https://huggingface.co/FunAudioLLM/Fun-ASR-Nano-2512", canSetLanguage: true, installed: false),
    SpeechModelOption(id: "qwen3-asr-0.6b", name: "Qwen3-ASR-0.6B", modelBytes: 987015347,
        sourceUrl: "https://huggingface.co/Qwen/Qwen3-ASR-0.6B", licenseUrl: "https://huggingface.co/Qwen/Qwen3-ASR-0.6B", canSetLanguage: true, installed: false),
], operation: nil, notice: nil)
model.accessibilityTrusted = true
model.micStatus = .authorized

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

if ProcessInfo.processInfo.environment["TYPELEAST_RENDER_MODES_ONLY"] == "1" {
    for language in ["zh-Hans", "en"] {
        L10n.language = language
        for dark in [false, true] {
            for strength in ["prompt", "concise"] {
                model.settings.strength = strength
                model.page = .home
                snapshot(NSHostingView(rootView: HubRootView().environmentObject(model)),
                         size: NSSize(width: 820, height: 560), name: "modes-" + strength + "-" + language, dark: dark)
            }
            let progress = UpdateProgressModel()
            progress.version = "1.18.0"
            progress.stage = .downloading(received: 33 << 20, total: 52 << 20, source: "GitHub")
            progress.summary = "• " + L10n.text("标准整理") + " / " + L10n.text("精简整理") + "\n• " + L10n.text("更短，只留要点")
            let view = NSHostingView(rootView: UpdateProgressView(model: progress).environment(\.colorScheme, dark ? .dark : .light))
            snapshot(view, size: view.fittingSize, name: "summary-" + language, dark: dark)
        }
    }
    exit(0)
}

if ProcessInfo.processInfo.environment["TYPELEAST_RENDER_MODELS_ONLY"] == "1" {
    func modelPanel(dark: Bool = false) -> NSView {
        NSHostingView(rootView: SpeechModelOptions().environmentObject(model)
            .frame(width: 502, alignment: .topLeading).padding(24)
            .frame(width: 550, height: 960, alignment: .topLeading)
            .background(Color(NSColor.windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
    }
    for dark in [false, true] {
        snapshot(modelPanel(dark: dark),
                 size: NSSize(width: 550, height: 960), name: "speech-models", dark: dark)
    }
    model.speechCatalog?.operation = SpeechModelOperation(modelId: "fireredasr2-ctc", phase: "downloading", received: 320_000_000, total: 775_940_592, error: nil)
    snapshot(modelPanel(),
             size: NSSize(width: 550, height: 960), name: "speech-model-progress", dark: false)
    model.speechCatalog?.operation = SpeechModelOperation(modelId: "fireredasr2-ctc", phase: "error", received: 320_000_000, total: 775_940_592, error: "download-failed")
    snapshot(modelPanel(),
             size: NSSize(width: 550, height: 960), name: "speech-model-error", dark: false)
    exit(0)
}

if ProcessInfo.processInfo.environment["TYPELEAST_RENDER_FOCUS"] == "extensions" {
    // Made-up plugins, shown without a service.
    func summary(_ id: String, _ type: String, _ zh: String, _ en: String, _ dzh: String, _ den: String, terms: Int? = nil, source: String? = nil,
                 enabled: Bool? = nil, installed: String? = nil) -> PluginSummary {
        PluginSummary(id: id, version: "1.0.0", type: type, name: ["zh-Hans": zh, "en": en], description: ["zh-Hans": dzh, "en": den],
                      author: "TypeLeast", license: "CC0-1.0", homepage: nil, termCount: terms,
                      termsPreview: terms == nil ? nil : ["GitHub", "Kubernetes", "TypeScript", "Docker", "Node.js", "PostgreSQL", "Redis", "OAuth", "WebSocket", "Vite", "Figma", "Ollama"],
                      instructions: type == "style" ? "用正式、礼貌、简洁的书面语表达：\n- 把口语词换成书面说法。\n- 句子完整，主语清楚，不用感叹号和网络用语。\n- 不添加称呼、问候、落款。" : nil,
                      source: source, enabled: enabled, installedVersion: installed)
    }
    let pack = summary("typeleast.dev-terms", "dictionary", "开发常用术语", "Developer terms", "编程、云服务和开发工具里常被听错的英文名词。", "Developer terms that speech recognition often gets wrong.", terms: 82, source: "catalog", enabled: true)
    let style = summary("typeleast.formal-writing", "style", "正式书面语", "Formal writing", "把口语说法改成正式、礼貌的书面表达。", "Formal, polite written language.", source: "file", enabled: true)
    let legal = summary("example.legal-terms", "dictionary", "法律术语", "Legal terms", "合同与诉讼中的常用术语。", "Common contract and litigation terms.", terms: 640)
    model.plugins.preview(state: PluginState(plugins: [pack, style], style: style.id, problems: []),
                          catalog: PluginCatalog(ok: true, code: nil, source: "typeleast.promptking.workers.dev", fetchedAt: "2026-10-24T08:00:00Z",
                                                 plugins: [{ var p = pack; p.source = nil; p.enabled = nil; p.installedVersion = "1.0.0"; return p }(), legal]))
    for dark in [false, true] {
        model.page = .extensions
        snapshot(NSHostingView(rootView: HubRootView().environmentObject(model)), size: NSSize(width: 960, height: 680), name: "extensions-installed", dark: dark)
        snapshot(NSHostingView(rootView: MarketList(plugins: model.plugins, loadOnAppear: false).padding(24).frame(width: 700, alignment: .top)
            .background(Theme.window).environment(\.colorScheme, dark ? .dark : .light)), size: NSSize(width: 700, height: 330), name: "extensions-market", dark: dark)
        for (name, plugin, origin) in [("extensions-install-pack", legal, PendingPlugin.Origin.catalog), ("extensions-install-style", style, .file(Data()))] {
            let sheet = InstallSheet(pending: PendingPlugin(summary: plugin, origin: origin, installedVersion: nil), cancel: {}, confirm: { _ in })
                .background(Theme.window).environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: sheet)
            snapshot(host, size: host.fittingSize, name: name, dark: dark)
        }
        model.settings.strength = "prompt"
        model.page = .home
        snapshot(NSHostingView(rootView: HubRootView().environmentObject(model)), size: NSSize(width: 820, height: 560), name: "extensions-sidebar-style", dark: dark)
    }
    exit(0)
}

if ProcessInfo.processInfo.environment["TYPELEAST_RENDER_FOCUS"] == "settings" {
    for dark in [false, true] {
        for category in 0..<5 {
            model.settingsCategory = category
            model.page = .settings
            snapshot(NSHostingView(rootView: HubRootView().environmentObject(model)),
                     size: NSSize(width: 820, height: 560), name: "settings-" + String(category), dark: dark)
        }
        let info = BetaInfo(sessionId: "fixture", questions: [L10n.text("项目主要给谁使用？"), L10n.text("你提到的现有流程有什么问题？")],
                            confirmed: [L10n.text("项目需要支持团队日常使用。"), L10n.text("先把现有流程说清楚，再确定目标。")], round: 3, ready: false)
        snapshot(NSHostingView(rootView: BetaQuestionsView(info: info, hotkey: "fn", skip: {}, cancel: {})
            .background(Theme.card).environment(\.colorScheme, dark ? .dark : .light)),
            size: NSSize(width: 440, height: 540), name: "beta-round", dark: dark)
    }
    exit(0)
}

for dark in [false, true] {
    for page in HubPage.allCases {
        model.page = page
        let height: CGFloat = 680
        snapshot(NSHostingView(rootView: HubRootView().environmentObject(model)), size: NSSize(width: ProcessInfo.processInfo.environment["TYPELEAST_RENDER_MINIMUM"] == "1" ? 820 : 960, height: height),
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

// The update window in each step (light and dark).
for dark in [false, true] {
    for (name, stage) in [
        ("update-download-start", UpdateStage.downloading(received: 3 << 20, total: 52 << 20, source: "GitHub")),
        ("update-download-mirror", UpdateStage.downloading(received: 33 << 20, total: 52 << 20, source: "ghfast.top")),
        ("update-verifying", UpdateStage.verifying),
        ("update-signing", UpdateStage.signing),
        ("update-handover", UpdateStage.handingOver),
        ("update-installing", UpdateStage.installing),
    ] {
        let progress = UpdateProgressModel()
        progress.version = "1.18.0"
        progress.stage = stage
        let host = NSHostingView(rootView: UpdateProgressView(model: progress))
        snapshot(host, size: host.fittingSize, name: name, dark: dark)
    }
}

import SwiftUI
import AVFoundation
import Combine

// AppModel.swift - observable state shared by the main window, onboarding and menu.

enum AppPhase { case idle, recording, thinking }

enum HubPage: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L10n.text("首页")
        case .history: return L10n.text("历史")
        case .dictionary: return L10n.text("词典")
        case .settings: return L10n.text("设置")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .settings: return "gearshape"
        }
    }
}

/// What the windows may ask the app to do. Implemented by AppDelegate.
protocol AppActions: AnyObject {
    func toggleDictation()
    func pasteLast()
    func copyEntry(id: String, raw: Bool)
    func retryEntry(id: String)
    func deleteEntry(id: String)
    func clearHistory()
    func requestAccessibility()
    func requestMicrophone()
    func openKeyboardSettings()
    func openMicrophoneSettings()
    func restartService()
    func downloadModels()
    func chooseNode()
    func recheckHealth()
    func syncDictionary()
    func showOnboarding()
    func finishOnboarding()
    func applyGeneralSettings()
    func registerHotKeys()
    func checkForUpdates(interactive: Bool)
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    weak var actions: AppActions?

    @Published var page: HubPage = .home
    @Published private(set) var history: [LocalHistoryEntry] = []
    @Published private(set) var stats = DictationStats()
    @Published private(set) var words: [LocalWord] = []

    @Published var phase: AppPhase = .idle
    @Published var serviceUp = false
    @Published var serviceState: ServiceManager.State = .stopped
    @Published var nodeDescription = ""
    @Published var health: HealthResponse?
    @Published var serviceProblem = ""
    @Published var accessibilityTrusted = false
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    /// Whether the host accepted the last dictionary sync (nil = not tried yet).
    @Published var dictionarySynced: Bool?
    /// Short status line for the hub ("已粘贴", "听写失败：…").
    @Published var hint = ""

    /// Bumped whenever a Settings value changes so bindings re-read.
    @Published private var settingsRevision = 0

    let settings = Settings.shared
    private var observers: [NSObjectProtocol] = []

    init() {
        reloadHistory()
        reloadWords()
        refreshPermissions()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: HistoryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadHistory()
        })
        observers.append(center.addObserver(forName: Settings.wordsDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadWords()
        })
        observers.append(center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.settingsRevision += 1
        })
    }

    func reloadHistory() {
        history = HistoryStore.shared.entries
        stats = HistoryStore.shared.stats
    }

    func reloadWords() {
        words = settings.words
    }

    func refreshPermissions() {
        accessibilityTrusted = AXIsProcessTrusted()
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// A two-way binding onto a Settings property.
    func setting<T>(_ keyPath: ReferenceWritableKeyPath<Settings, T>, then: (() -> Void)? = nil) -> Binding<T> {
        Binding(
            get: { [settings] in settings[keyPath: keyPath] },
            set: { [weak self] value in
                guard let self = self else { return }
                self.settings[keyPath: keyPath] = value
                self.objectWillChange.send()
                then?()
            }
        )
    }

    var hotkeyLabel: String {
        let main = settings.hotkeyMain
        return main.isFn ? "fn" : HotKeyCentre.describe(keyCode: main.keyCode, modifiers: main.modifiers)
    }

    var modelSummary: String {
        let preset = LLMPreset.find(settings.llmPresetID)
        guard settings.activeLLMRoute != nil else { return L10n.text("整理模型未配置（只去口水词，不改写）") }
        return preset.name + " · " + settings.llmModel + (preset.id == "ollama" ? L10n.text("（本机）") : L10n.text("（自己的 Key）"))
    }

    /// Whether cleanup is configured: a model and (except for local servers) a key.
    var llmConfigured: Bool { settings.activeLLMRoute != nil }

    var speech: SpeechStatus? { health?.speech }
    var modelsMissing: Bool { speech?.modelsMissing ?? false }
    var modelsDownloading: Bool { speech?.downloading ?? false }

    var speechSummary: String {
        guard let speech = health?.speech else { return L10n.text("SenseVoice（本地）") }
        switch speech.phase ?? "" {
        case "ready": return L10n.text("SenseVoice（本地）· 就绪")
        case "missing-model": return L10n.text("SenseVoice（本地）· 模型未下载")
        case "downloading":
            let percent = speech.downloadFraction.map { String(Int($0 * 100)) + "%" } ?? ""
            return L10n.text("SenseVoice（本地）· 下载中 ") + percent
        case "loading": return L10n.text("SenseVoice（本地）· 加载中")
        case "error": return L10n.text("SenseVoice（本地）· 出错")
        default: return L10n.text("SenseVoice（本地）· ") + (speech.phase ?? L10n.text("准备中"))
        }
    }

    /// One line about the local service, for the window and settings.
    var serviceSummary: String {
        switch serviceState {
        case .running: return L10n.text("本地服务运行中")
        case .starting: return L10n.text("本地服务启动中…")
        case .stopped: return L10n.text("本地服务未启动")
        case .noNode(let found):
            return found.map { L10n.text("Node.js 版本过低：") + $0 + L10n.text("，需要 22 或更新") } ?? L10n.text("没有找到 Node.js（需要 22 或更新）")
        case .noService: return L10n.text("App 里缺少本地服务文件，请重新构建 App")
        case .failed(let why): return why
        }
    }
}

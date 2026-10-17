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
        case .home: return "首页"
        case .history: return "历史"
        case .dictionary: return "词典"
        case .settings: return "设置"
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
    func launchDSH()
    func recheckHealth()
    func syncDictionary()
    func showOnboarding()
    func finishOnboarding()
    func applyGeneralSettings()
    func registerHotKeys()
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
        if settings.llmMode == .custom {
            let preset = LLMPreset.find(settings.llmPresetID)
            guard settings.activeLLMRoute != nil else { return preset.name + "（未配置完整，暂用 DSH 账号）" }
            return preset.name + " · " + settings.llmModel + (preset.id == "ollama" ? "（本机）" : "（自己的 Key）")
        }
        guard let h = health else { return "DeepSeek 账号（云端）" }
        let model = h.model ?? "deepseek"
        return "DeepSeek 账号 · " + model + "（云端）"
    }

    var speechSummary: String {
        guard let speech = health?.speech else { return "SenseVoice（本地）" }
        let ready = speech.ready == true ? "就绪" : (speech.phase ?? "准备中")
        return "SenseVoice（本地）· " + ready
    }
}

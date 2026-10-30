import SwiftUI
import AVFoundation
import Combine

// AppModel.swift - observable state shared by the main window, onboarding and menu.

enum AppPhase { case idle, recording, thinking }

enum HubPage: String, CaseIterable, Identifiable {
    case home, history, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L10n.text("首页")
        case .history: return L10n.text("历史")
        case .settings: return L10n.text("设置")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

/// What the windows may ask the app to do. Implemented by AppDelegate.
protocol AppActions: AnyObject {
    func setCleanupMode(_ code: String)
    func startAssistant()
    /// The onboarding's 拆解一段示例提示词: opens 提示词模式 on a sample prompt.
    func breakdownSample()
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
    func manageSpeechModel(id: String, download: Bool, cancel: Bool)
    func downloadModels()
    func chooseNode()
    func recheckHealth()
    func openSetupSettings()
    func showOnboarding()
    func finishOnboarding()
    func applyGeneralSettings()
    func registerHotKeys()
    func checkForUpdates(interactive: Bool)
}

extension AppActions { func startAssistant() { setCleanupMode("promptbeta") } }

final class AppModel: ObservableObject {
    static let shared = AppModel()

    weak var actions: AppActions?

    @Published var page: HubPage = .home
    @Published var settingsCategory = 0
    @Published private(set) var history: [LocalHistoryEntry] = []
    @Published private(set) var stats = DictationStats()
    /// Bumped when the per-day activity changes; the heatmap reads ActivityLog.shared.
    @Published private(set) var activityRevision = 0

    @Published var phase: AppPhase = .idle
    @Published var serviceUp = false
    @Published var serviceState: ServiceManager.State = .stopped
    @Published var nodeDescription = ""
    @Published var speechCatalog: SpeechModelCatalog?
    @Published var health: HealthResponse?
    @Published var serviceProblem = ""
    @Published var accessibilityTrusted = false
    @Published var micStatus: AVAuthorizationStatus = .notDetermined
    /// Short status line for the hub ("已粘贴", "听写失败：…").
    @Published var hint = ""
    /// Shortcut slot ("main", "alt", "pasteLast", "translate") -> why it is not working.
    @Published var hotkeyProblems: [String: String] = [:]

    /// Bumped whenever a Settings value changes so bindings re-read.
    @Published private var settingsRevision = 0

    let settings = Settings.shared
    private var observers: [NSObjectProtocol] = []

    init() {
        reloadHistory()
        refreshPermissions()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: HistoryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadHistory()
        })
        observers.append(center.addObserver(forName: ActivityLog.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.activityRevision += 1
        })
        observers.append(center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.settingsRevision += 1
        })
    }

    func reloadHistory() {
        history = HistoryStore.shared.entries
        stats = HistoryStore.shared.stats
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

    func dismissGuide() {
        settings.guideDismissed = true
        objectWillChange.send()
    }

    /// Download again after a failure: the model whose download failed, else the default one.
    func retryModelDownload() {
        if let operation = speech?.operation ?? speechCatalog?.operation, operation.phase == "error" {
            actions?.manageSpeechModel(id: operation.modelId, download: true, cancel: false)
        } else {
            actions?.downloadModels()
        }
    }

    var hotkeyLabel: String {
        let main = settings.hotkeyMain
        return main.isFn ? "fn" : HotKeyCentre.describe(keyCode: main.keyCode, modifiers: main.modifiers)
    }

    /// 提示词模式's key, or "" when it has none.
    var assistantLabel: String {
        let key = settings.hotkeyAssistant
        return key.enabled ? HotKeyCentre.describe(keyCode: key.keyCode, modifiers: key.modifiers) : ""
    }

    var modelSummary: String {
        let preset = LLMPreset.find(settings.llmPresetID)
        guard settings.llmRouteReady else { return L10n.text("没有整理模型（只去口头禅）") }
        return preset.name + " · " + settings.llmModel + (preset.id == "ollama" ? L10n.text("（本机）") : L10n.text("（你的 Key）"))
    }

    /// Whether cleanup is configured: a model and (except for local servers) a key.
    var llmConfigured: Bool { settings.llmRouteReady }

    var speech: SpeechStatus? { health?.speech }
    var modelsMissing: Bool { speech?.modelsMissing ?? false }
    var modelsDownloading: Bool { speech?.downloading ?? false }

    var speechSummary: String {
        let name = speech?.displayName ?? L10n.text("未选择语音模型")
        return name + " · " + (speech?.ready == true ? L10n.text("就绪") : L10n.text("准备中"))
    }

    /// One line about the local service, for the window and settings.
    var serviceSummary: String {
        switch serviceState {
        case .running: return L10n.text("本地服务运行中")
        case .starting: return L10n.text("本地服务启动中…")
        case .stopped: return L10n.text("本地服务已停止")
        case .noNode(let found):
            return found.map { L10n.text("Node.js 版本太旧：") + $0 + L10n.text("，需要 22 或更新") } ?? L10n.text("找不到 Node.js（需要 22 或更新）")
        case .noService: return L10n.text("缺少本地服务文件，请重新构建")
        case .failed(let why): return why
        }
    }
}

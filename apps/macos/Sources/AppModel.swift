import SwiftUI
import AVFoundation
import Combine

// AppModel.swift - observable state shared by the main window, onboarding and menu.

enum AppPhase { case idle, starting, recording, thinking }

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, dictation, translation, prompts, models, tools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L10n.text("通用")
        case .dictation: return L10n.text("听写")
        case .translation: return L10n.text("翻译设置")
        case .prompts: return L10n.text("个性化")
        case .models: return L10n.text("模型")
        case .tools: return L10n.harnessTitle
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .translation: return "translate"
        case .prompts: return "doc.text"
        case .models: return "cpu"
        case .tools: return "text.bubble"
        }
    }
}

enum HubPage: String, CaseIterable, Identifiable {
    case home, history, vocabulary, meetings, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .history: return "History"
        case .vocabulary: return "Vocabulary"
        case .meetings: return "Conference"
        case .settings: return L10n.settingTitle
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .history: return "clock.arrow.circlepath"
        case .vocabulary: return "text.book.closed"
        case .meetings: return "person.2"
        case .settings: return "gearshape"
        }
    }
}

/// What the windows may ask the app to do. Implemented by AppDelegate.
protocol AppActions: AnyObject {
    /// The onboarding's 拆解一段示例提示词: opens 提示词模式 on a sample prompt.
    func breakdownSample()
    func toggleDictation()
    func pasteLast()
    func copyEntry(id: String, raw: Bool)
    func reviewEntry(id: String)
    func retryEntry(id: String)
    func deleteEntry(id: String)
    func clearHistory()
    func unlockCredentials()
    func openRecommendedApp(_ bundle: String)
    func requestAccessibility()
    func requestMicrophone()
    func openKeyboardSettings()
    func openMicrophoneSettings()
    func restartService()
    func clearSpeechModelStorage(id: String, partialOnly: Bool)
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

final class AppModel: ObservableObject {
    static let shared = AppModel()

    weak var actions: AppActions?

    @Published var page: HubPage = .home
    @Published var sidebarBrandPalette = SidebarBrandPalette.random()
    var cadenceIdleWords = CadenceIdleWords()
    @Published var settingsCategory: SettingsCategory = .general
    @Published var settingsPresented = false
    @Published var selectedHistoryID: String?
    @Published var retryingHistoryID: String?
    /// Starts a Home entrance when it becomes visible in the foreground.
    @Published var homePresentationID = 0
    @Published var homeStartupMaskVisible = false
    @Published var homePresentationSuspended = false
    @Published private(set) var history: [LocalHistoryEntry] = []
    @Published private(set) var historyUnavailable = false
    @Published var credentialsLocked = KeychainStore.requiresUnlock
    @Published var credentialsUnlocking = false
    @Published var credentialUnlockError: String?
    @Published private(set) var historyRevision = 0
    @Published private(set) var stats: DictationStats?
    @Published private(set) var activityReady = false
    private(set) var userCacheReady = false
    private var dashboardRequested = false
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
    @Published private var savedKeyPresence: [String: Bool] = [:]
    private var pendingKeyPresence: Set<String> = []
    private var permissionsLoading = false

    let settings = Settings.shared
    let meeting = MeetingController()
    private var observers: [NSObjectProtocol] = []

    init(loadCacheImmediately: Bool = true) {
        if loadCacheImmediately {
            finishUserCacheLoad()
            stats = ActivityLog.shared.stats
            activityReady = true
            dashboardRequested = true
        }
        refreshPermissions()
        refreshLLMKeyPresence()
        refreshOnlineASRKeyPresence()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: HistoryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadHistory()
        })
        observers.append(center.addObserver(forName: ActivityLog.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.stats != nil { self.stats = ActivityLog.shared.stats }
            if self.activityReady { self.activityRevision += 1 }
        })
        observers.append(center.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.settingsRevision += 1
            self?.refreshLLMKeyPresence()
            self?.refreshOnlineASRKeyPresence()
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            KeychainStore.invalidatePresence()
            self?.settingsRevision += 1
            self?.refreshLLMKeyPresence()
            self?.refreshOnlineASRKeyPresence()
        })
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.activityRevision += 1
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func navigate(to page: HubPage) {
        if page == .settings { settingsPresented = true }
        else if self.page != page { self.page = page }
    }

    func reloadHistory() {
        let store = HistoryStore.shared
        history = store.entries
        historyUnavailable = store.persistenceProblem != nil
        if stats != nil { stats = ActivityLog.shared.stats }
        historyRevision &+= 1
    }

    func finishUserCacheLoad() {
        reloadHistory()
        userCacheReady = true
    }

    func loadDashboard() {
        guard userCacheReady, !dashboardRequested else { return }
        dashboardRequested = true
        DispatchQueue.main.async { [weak self] in self?.stats = ActivityLog.shared.stats }
        DispatchQueue.main.async { [weak self] in self?.activityReady = true }
    }

    func refreshPermissions() {
        guard !permissionsLoading else { return }
        permissionsLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let trusted = AXIsProcessTrusted()
            let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
            DispatchQueue.main.async {
                guard let self else { return }
                self.permissionsLoading = false
                if self.accessibilityTrusted != trusted { self.accessibilityTrusted = trusted }
                if self.micStatus != microphone { self.micStatus = microphone }
            }
        }
    }

    /// Display metadata is read off the main thread; views never contact Keychain services.
    var llmKeyPresence: Bool? { credentialsLocked ? nil : savedKeyPresence[settings.llmPresetID] }

    func refreshLLMKeyPresence() {
        let account = settings.llmPresetID
        if LLMPreset.find(account).needsKey { refreshKeyPresence(account) }
    }

    var onlineASRKeyPresence: Bool? {
        asrKeyPresence(for: settings.onlineASRProvider)
    }

    func asrKeyPresence(for provider: OnlineASRProvider) -> Bool? {
        credentialsLocked ? nil : savedKeyPresence[provider.keychainAccount]
    }

    func refreshOnlineASRKeyPresence() {
        for provider in Set([settings.onlineASRProvider, settings.meetingASRProvider]) where provider != .local {
            refreshKeyPresence(provider.keychainAccount)
        }
    }

    private func refreshKeyPresence(_ account: String) {
        guard !credentialsLocked, pendingKeyPresence.insert(account).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let present = KeychainStore.exists(account: account)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingKeyPresence.remove(account)
                if self.savedKeyPresence[account] != present { self.savedKeyPresence[account] = present }
            }
        }
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

    var modelSummary: String {
        let cleanup = cleanupEngineSummary
        return cleanup.detail.map { cleanup.name + " · " + $0 } ?? cleanup.name
    }

    var cleanupEngineSummary: (name: String, detail: String?) {
        let preset = LLMPreset.find(settings.llmPresetID)
        if credentialsLocked && preset.needsKey {
            return (preset.name, L10n.text("钥匙串已锁定"))
        }
        guard llmConfigured else { return (L10n.text("没有整理模型（只去口头禅）"), nil) }
        let modelName = settings.llmModel
        return (preset.name, preset.id == "ollama" ? modelName + L10n.text("（本机）") : modelName)
    }

    /// Whether cleanup is configured: a model and (except for local servers) a key.
    var llmConfigured: Bool {
        !settings.llmModel.isEmpty && LLMPreset.isAllowedBaseURL(settings.llmBaseURL)
            && (!LLMPreset.find(settings.llmPresetID).needsKey || llmKeyPresence == true)
    }

    var speech: SpeechStatus? { health?.speech }
    var modelsMissing: Bool { speech?.modelsMissing ?? false }
    var modelsDownloading: Bool { speech?.downloading ?? false }

    var recognitionConfigured: Bool {
        settings.onlineASRProvider == .local ? speech?.ready == true : onlineASRKeyPresence == true
    }

    var speechEngineSummary: (name: String, detail: String) {
        let provider = settings.onlineASRProvider
        if provider != .local {
            let status: String
            if credentialsLocked { status = L10n.text("钥匙串已锁定") }
            else if let present = onlineASRKeyPresence { status = L10n.text(present ? "已配置" : "待配置 API Key") }
            else { status = L10n.text("正在检查 API Key…") }
            return (provider.label, status)
        }
        let name = speech?.displayName ?? L10n.text("未选择语音模型")
        let status = speech?.ready == true ? L10n.text("就绪") : L10n.text("准备中")
        // The MLX catalog includes its runtime and precision in a trailing qualifier.
        if name.hasSuffix(")"), let qualifier = name.range(of: " (MLX ", options: .backwards) {
            let variant = name[qualifier.lowerBound...].dropFirst(2).dropLast()
            return (String(name[..<qualifier.lowerBound]), "\(variant) · \(status)")
        }
        return (name, status)
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

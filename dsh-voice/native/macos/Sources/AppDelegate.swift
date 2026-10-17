import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

// AppDelegate.swift - lifecycle, hotkeys, windows and the actions the UI calls.
// Dictation itself (record -> host -> insert) lives in AppDelegate+Dictation.swift.
// The app never activates itself during dictation; only opening its own windows does.

final class AppDelegate: NSObject, NSApplicationDelegate, MenuActionTarget, AppActions {
    let menuController = MenuController()
    let recorder = Recorder()
    /// Floating capsule shown while listening and thinking.
    let recordingBar = RecordingBar()
    /// Resting bar at the bottom of the screen (Reference "show voice bar").
    let idleBar = IdleBar()
    let settings = Settings.shared
    let client = DshClient.shared
    let model = AppModel.shared
    let editWatcher = EditWatcher()
    lazy var hub = HubWindowController(model: model)
    lazy var onboarding = OnboardingWindowController(model: model)
    var previewPanel: PreviewPanel?

    var phase: AppPhase = .idle {
        didSet { model.phase = phase }
    }
    var recordingStartedAt: Date?
    var pendingAppBundleId = ""
    /// The text field captured when the current recording started.
    var pendingField: FocusedField?
    var tickTimer: Timer?
    /// Last whole second pushed into the menu, so the 20 Hz waveform timer does
    /// not rebuild the menu on every frame.
    var lastTickedSecond: Int = -1
    var escRegistered = false
    var serviceUp = false {
        didSet { model.serviceUp = serviceUp }
    }
    var hint: String?
    var hintWarning = false
    var launchedAsLoginItem = false
    /// Re-checks DSH every few seconds while it looks down. A single failed check at
    /// launch (e.g. DSH restarting, or starting after this app) used to leave the
    /// window saying "连不上 DSH" for good, although every dictation found DSH on its
    /// new port.
    var healthRetryTimer: Timer?
    private var dictionaryNeedsSync = true

    // MARK: lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.actions = self
        menuController.target = self
        NSApp.applicationIconImage = AppMark.image(size: 512)
        applyGeneralSettings()
        registerHotKeys()

        FnKeyMonitor.shared.onTap = { [weak self] source in self?.fnTapped(sourceAtPress: source) }
        recordingBar.onCancel = { [weak self] in self?.cancelDictation() }
        recordingBar.onStop = { [weak self] in self?.stopRecording() }
        idleBar.onClick = { [weak self] in self?.toggleDictation() }
        editWatcher.onLearn = { [weak self] word in self?.learned(word) }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(onSettingsChanged), name: Settings.didChange, object: nil)
        center.addObserver(self, selector: #selector(onWordsChanged), name: Settings.wordsDidChange, object: nil)
        center.addObserver(self, selector: #selector(onHistoryChanged), name: HistoryStore.didChange, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(onWake), name: NSWorkspace.didWakeNotification, object: nil)
        // Granting Accessibility happens in System Settings; the app learns about it
        // when the user switches apps again.
        workspace.addObserver(self, selector: #selector(onAppActivated),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)

        HistoryStore.shared.pruneAudio()
        HistoryStore.shared.applyRetention(settings.historyRetention)
        applyState()
        refreshHealth()

        if settings.warmUpPill {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.recordingBar.warmUp() }
        }

        if ProcessInfo.processInfo.environment["DSH_VOICE_SELFCHECK"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.runSelfCheck() }
            return
        }
        if !settings.onboardingDone {
            showOnboarding()
        } else if !launchedAsLoginItem {
            hub.show(page: .home)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { hub.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.cancel()
        OutputMuter.shared.restore()
        recordingBar.hide()
        idleBar.hide()
        FnKeyMonitor.shared.stop()
        HotKeyCentre.shared.unregisterAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Non-invasive launch diagnostics (used by build/acceptance checks). Never runs normally.
    func runSelfCheck() {
        // Own-API-key diagnostics, run inside the real bundle (where App Transport
        // Security and the app's Keychain identity apply). The key comes from the
        // environment and is never printed.
        if let base = ProcessInfo.processInfo.environment["DSH_VOICE_LLMCHECK_URL"] {
            let env = ProcessInfo.processInfo.environment
            // "@keychain" uses the key saved for the current preset without printing it.
            let keyArg = env["DSH_VOICE_LLMCHECK_KEY"] ?? ""
            let key = keyArg == "@keychain" ? settings.llmAPIKey : keyArg
            print("LLMCHECK key=" + (key.isEmpty ? "missing" : "present(" + String(key.count) + " chars)"))
            let route = LLMRoute(baseURL: base, model: env["DSH_VOICE_LLMCHECK_MODEL"] ?? "test", apiKey: key)
            do {
                let ids = try client.listModelsSync(route: route)
                print("LLMCHECK listModels=ok count=" + String(ids.count))
            } catch {
                print("LLMCHECK listModels=error " + ((error as? DshError)?.description ?? String(describing: error)))
            }
            do {
                let result = try client.testLLMSync(route: route)
                print("LLMCHECK test=" + (result.ok ? "ok" : "fail") + " code=" + (result.code ?? "-") + " ms=" + String(Int(result.ms ?? 0)))
            } catch {
                print("LLMCHECK test=error " + ((error as? DshError)?.description ?? String(describing: error)))
            }
            // Optional: one real dictation of a WAV file through this route.
            if let wavPath = env["DSH_VOICE_LLMCHECK_WAV"], let wav = FileManager.default.contents(atPath: wavPath) {
                let started = Date()
                do {
                    let r = try client.dictateSync(wav: wav, language: "auto", appBundleId: "com.apple.Notes",
                                                   strength: "prompt", llm: route)
                    print("LLMCHECK dictate provider=" + (r.provider ?? "?") + " model=" + (r.model ?? "?")
                          + " fallback=" + String(r.fallback) + (r.fallbackReason.map { " reason=" + $0 } ?? "")
                          + " ms=" + String(Int(Date().timeIntervalSince(started) * 1000)))
                    print("LLMCHECK dictate raw=" + r.raw)
                    print("LLMCHECK dictate text=" + r.text.replacingOccurrences(of: "\n", with: " / "))
                } catch {
                    print("LLMCHECK dictate=error " + ((error as? DshError)?.description ?? String(describing: error)))
                }
            }
            let probe = "selfcheck-probe"
            let wrote = KeychainStore.write("probe-value", account: probe)
            let readBack = KeychainStore.read(account: probe) == "probe-value"
            KeychainStore.write("", account: probe)
            print("LLMCHECK keychain.write=" + String(wrote) + " read=" + String(readBack)
                  + " status=" + String(KeychainStore.lastStatus))
        }
        let button = menuController.statusItem.button
        print("SELFCHECK activationPolicy=" + String(NSApp.activationPolicy().rawValue) + " (0=regular 1=accessory 2=prohibited)")
        print("SELFCHECK bundleID=" + (Bundle.main.bundleIdentifier ?? "?"))
        print("SELFCHECK statusItemButtonExists=" + String(button != nil))
        print("SELFCHECK hotkey.main=" + (HotKeyCentre.shared.status["main"] ?? "?"))
        print("SELFCHECK hotkey.alt=" + (HotKeyCentre.shared.status["alt"] ?? "?"))
        print("SELFCHECK hotkey.pasteLast=" + (HotKeyCentre.shared.status["pasteLast"] ?? "?"))
        print("SELFCHECK fnMonitor=" + String(FnKeyMonitor.shared.isRunning))
        print("SELFCHECK accessibilityTrusted=" + String(AXIsProcessTrusted()))
        // Port discovery is the one thing that silently breaks the whole app, so the
        // self-check reports the published port, the process-table candidates, and
        // whether a working server was adopted.
        let published = client.publishedPort()
        print("SELFCHECK port.published=" + (published.map(String.init) ?? "nil"))
        print("SELFCHECK port.processTable=" + String(describing: client.processTablePorts()))
        print("SELFCHECK port.adopted=" + String(client.adoptWorkingPort()))
        print("SELFCHECK port.inUse=" + client.baseURL.absoluteString)
        if let health = try? client.healthSync() {
            print("SELFCHECK health.ok=" + String(health.ok) + " version=" + (health.version ?? "?"))
        } else {
            print("SELFCHECK health.ok=false (unreachable)")
        }
        print("SELFCHECK serviceUp=" + String(serviceUp))
        print("SELFCHECK rssKB=" + String(AppDelegate.residentMemoryKB()))
        fflush(stdout)
        NSApp.terminate(nil)
    }

    static func residentMemoryKB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.resident_size / 1024) : -1
    }

    // MARK: hotkeys

    func registerHotKeys() {
        let centre = HotKeyCentre.shared
        var fnWanted = false
        for (slot, binding) in [("main", settings.hotkeyMain), ("alt", settings.hotkeyAlt)] {
            if binding.isFn {
                centre.unregister(slot: slot)
                fnWanted = fnWanted || binding.enabled
            } else {
                centre.register(slot: slot, binding: binding) { [weak self] in self?.hotkeyPressed() }
            }
        }
        if fnWanted { FnKeyMonitor.shared.start() } else { FnKeyMonitor.shared.stop() }
        centre.register(slot: "pasteLast", binding: settings.hotkeyPasteLast) { [weak self] in self?.pasteLast() }
    }

    /// Fn or a shortcut: toggle, exactly like Reference (press to start, press to stop).
    func hotkeyPressed() {
        toggleDictation()
    }

    /// A clean Fn tap. Stopping is immediate; starting waits a moment, and if the
    /// keyboard input source changed across the tap, the 🌐 key was switching 中/英
    /// for the system and the microphone stays closed.
    func fnTapped(sourceAtPress: String?) {
        guard phase == .idle else { hotkeyPressed(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + FnTapGate.settleSeconds) { [weak self] in
            guard let self = self, self.phase == .idle else { return }
            if FnTapGate.shouldStart(sourceAtPress: sourceAtPress, sourceAfter: InputSourceProbe.currentID()) {
                self.hotkeyPressed()
            } else {
                self.setHint("按 🌐 切换了输入法，没有开始听写（可在系统设置里把「按下 🌐 键时」改为「无操作」）")
                self.applyState()
            }
        }
    }

    func registerEscape() {
        guard !escRegistered else { return }
        escRegistered = HotKeyCentre.shared.register(slot: "esc",
            binding: HotKeyBinding(keyCode: 53, modifiers: 0, enabled: true, name: "Esc")) { [weak self] in
                self?.cancelDictation()
        }
    }

    func unregisterEscape() {
        guard escRegistered else { return }
        HotKeyCentre.shared.unregister(slot: "esc")
        escRegistered = false
    }

    // MARK: settings that change the app itself

    func applyGeneralSettings() {
        switch settings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { NSApp.applicationIconImage = AppMark.image(size: 512) }
        }
        updateIdleBar()
    }

    func updateIdleBar() {
        idleBar.hint = "按 " + model.hotkeyLabel + " 开始听写"
        if settings.showIdleBar && phase == .idle && !recordingBar.isVisible {
            idleBar.show()
        } else {
            idleBar.hide()
        }
    }

    // MARK: notifications

    @objc func onSettingsChanged() {
        applyState()
    }

    @objc func onWordsChanged() {
        model.reloadWords()
    }

    @objc func onHistoryChanged() { applyState() }

    @objc func onWake() { refreshHealth() }

    @objc func onAppActivated() {
        let trusted = AXIsProcessTrusted()
        if trusted != model.accessibilityTrusted {
            model.accessibilityTrusted = trusted
            if trusted, let h = hint, h.contains("辅助功能") { setHint("辅助功能已授权，可以自动粘贴了") }
            applyState()
        }
    }

    // MARK: state

    func applyState() {
        var s = MenuState()
        s.phase = phase
        s.elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        s.hint = hint
        s.hintWarning = hintWarning
        s.serviceUp = serviceUp
        s.accessibilityTrusted = AXIsProcessTrusted()
        s.hotkeySummary = model.hotkeyLabel
        let paste = settings.hotkeyPasteLast
        s.pasteLastSummary = paste.enabled ? HotKeyCentre.describe(keyCode: paste.keyCode, modifiers: paste.modifiers) : ""
        s.hasLast = HistoryStore.shared.last != nil
        menuController.apply(s)
        model.accessibilityTrusted = s.accessibilityTrusted
    }

    func setHint(_ text: String?, warning: Bool = false) {
        hint = text
        hintWarning = warning
        model.hint = text ?? ""
    }

    // MARK: health (single check; no polling)

    func refreshHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            // DSH publishes its live port on every launch; read it before asking.
            self.client.discoverBaseURL()
            do {
                let h = try self.client.healthSync()
                DispatchQueue.main.async {
                    self.serviceUp = h.ok
                    self.model.health = h
                    self.model.serviceProblem = h.ok ? "" : "语音识别模型还在准备"
                    if !h.ok { self.setHint("整理服务未就绪", warning: true) }
                    if self.dictionaryNeedsSync { self.syncDictionary() }
                    self.applyState()
                }
            } catch {
                let desc = (error as? DshError)?.description ?? error.localizedDescription
                DiagnosticsLog.write("health.fail", ["error": desc, "url": self.client.baseURL.absoluteString])
                DispatchQueue.main.async {
                    self.serviceUp = false
                    self.model.health = nil
                    self.model.serviceProblem = "连不上 DSH（会自动重试）：" + desc
                    self.applyState()
                    self.scheduleHealthRetry()
                }
            }
        }
    }

    /// While DSH looks down, check again every 15 s; stop as soon as it answers.
    func scheduleHealthRetry() {
        guard healthRetryTimer == nil else { return }
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.serviceUp {
                self.healthRetryTimer?.invalidate()
                self.healthRetryTimer = nil
            } else {
                self.refreshHealth()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthRetryTimer = timer
    }

    func menuOpened() { refreshHealth() }

    // MARK: dictionary

    /// Push the whole word list to the host (it is the source of truth for the model).
    func syncDictionary() {
        let entries = settings.hostDictionary
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let ok = (try? self.client.putDictionarySync(entries: entries)) != nil
            DispatchQueue.main.async {
                self.model.dictionarySynced = ok
                self.dictionaryNeedsSync = !ok
            }
        }
    }

    func learned(_ word: String) {
        guard settings.autoLearn, settings.addWord(word, source: .auto) else { return }
        setHint("已把「" + word + "」加入词典")
        syncDictionary()
        applyState()
    }

    // MARK: AppActions (called from the windows)

    func copyEntry(id: String, raw: Bool) {
        guard let e = HistoryStore.shared.entries.first(where: { $0.id == id }) else { return }
        let text = raw ? (e.raw.isEmpty ? e.text : e.raw) : e.displayText
        Inserter.shared.setString(text)
    }

    func retryEntry(id: String) {
        guard let e = HistoryStore.shared.entries.first(where: { $0.id == id }),
              let path = e.audioPath, FileManager.default.fileExists(atPath: path) else {
            setHint("原始录音已不存在（24 小时后自动清理）", warning: true)
            applyState()
            return
        }
        guard phase == .idle else { return }
        // A retry from the window copies the result rather than pasting into the window.
        sendToServer(audioURL: URL(fileURLWithPath: path), appBundleId: e.app ?? "", language: e.language,
                     strength: e.strength, keepAudioPath: path, seconds: e.seconds, field: nil, insert: false)
    }

    func deleteEntry(id: String) {
        HistoryStore.shared.remove(id: id)
    }

    func clearHistory() {
        HistoryStore.shared.clear()
    }

    /// Reset a sticky denial, ask macOS to prompt, and open the settings pane.
    func requestAccessibility() {
        let reset = Inserter.resetAccessibilityDecision()
        let trusted = Inserter.requestAccessibilityPrompt()
        model.accessibilityTrusted = trusted
        if trusted {
            setHint("辅助功能已授权，可以自动粘贴了")
            FnKeyMonitor.shared.stop()
            registerHotKeys()
        } else {
            setHint(reset ? "请在「辅助功能」里打开 TypeLeast 的开关" : "请手动在「辅助功能」里打开 TypeLeast", warning: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Inserter.openAccessibilitySettings() }
        }
        applyState()
    }

    func requestMicrophone() {
        Recorder.requestMicrophoneAccess { [weak self] _ in
            self?.model.refreshPermissions()
        }
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophoneSettings() { Inserter.openMicrophoneSettings() }

    func launchDSH() {
        let url = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { [weak self] _, err in
            DispatchQueue.main.async {
                if let err = err {
                    self?.setHint("无法启动 DSH：" + err.localizedDescription, warning: true)
                } else {
                    self?.setHint("正在启动 DSH…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refreshHealth() }
                }
                self?.applyState()
            }
        }
    }

    func recheckHealth() { refreshHealth() }

    func showOnboarding() {
        onboarding.onFinish = { [weak self] in self?.finishOnboarding() }
        onboarding.show()
    }

    func finishOnboarding() {
        settings.onboardingDone = true
        model.refreshPermissions()
        registerHotKeys()
        hub.show(page: .home)
    }

    // MARK: MenuActionTarget

    func menuToggleDictation() { toggleDictation() }
    func menuCancelDictation() { cancelDictation() }
    func menuPasteLast() { pasteLast() }
    func menuOpenHub(_ page: HubPage) { hub.show(page: page) }
    func menuRequestAccessibility() { requestAccessibility() }
    func menuLaunchDSH() { launchDSH() }

    func menuQuit() {
        recorder.cancel()
        NSApp.terminate(nil)
    }
}

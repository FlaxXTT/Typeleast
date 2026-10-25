import AppKit
import AVFoundation
import Carbon.HIToolbox
import ServiceManagement

// AppDelegate.swift - lifecycle, hotkeys, windows and the actions the UI calls.
// DictationController owns recording, service requests and insertion.
// The local service is started and watched by ServiceManager.swift.
// The app never activates itself during dictation; only opening its own windows does.

final class AppDelegate: NSObject, NSApplicationDelegate, MenuActionTarget, AppActions {
    let menuController = MenuController()
    let mainMenu = MainMenu()
    let recorder = Recorder()
    /// Floating capsule shown while listening and thinking.
    let recordingBar = RecordingBar()
    /// Resting bar at the bottom of the screen ("show voice bar").
    let idleBar = IdleBar()
    let settings = Settings.shared
    let client = ServiceClient.shared
    let model = AppModel.shared
    lazy var dictionary = DictionaryController(settings: settings,
                                               setHint: { [weak self] in self?.setHint($0) },
                                               changed: { [weak self] in self?.applyState() })
    lazy var updates = UpdateController(host: .init(
        busyReason: { [weak self] in
            guard let self else { return nil }
            if self.phase != .idle { return (L10n.text("正在听写"), L10n.text("听写结束后再更新。")) }
            // Restarting would drop the questions and the answers given so far.
            if self.betaPending != nil { return (L10n.text("提示词 Beta 未结束"), L10n.text("更新前，请先生成或取消提示词 Beta。")) }
            return nil
        },
        setHint: { [weak self] in self?.setHint($0) },
        showAvailable: { [weak self] in self?.menuController.setUpdateAvailable($0) },
        willQuit: { [weak self] in self?.recorder.cancel() }))
    lazy var hub = HubWindowController(model: model)
    lazy var onboarding = OnboardingWindowController(model: model)
    lazy var dictation = DictationController(host: .init(
        settings: settings, client: client, model: model, dictionary: dictionary, beta: beta,
        recorder: recorder, recordingBar: recordingBar, idleBar: idleBar,
        applyState: { [weak self] in self?.applyState() },
        updateIdleBar: { [weak self] in self?.updateIdleBar() },
        setHint: { [weak self] in self?.setHint($0, warning: $1) },
        hint: { [weak self] in self?.hint },
        registerEscape: { [weak self] in self?.registerEscape() },
        unregisterEscape: { [weak self] in self?.unregisterEscape() },
        showSettings: { [weak self] in self?.hub.show(page: .settings) },
        scheduleHealthRetry: { [weak self] in self?.scheduleHealthRetry() }))
    var phase: AppPhase { dictation.phase }
    var betaPending: BetaPending? { beta.pending }
    /// A test run beside the real app leaves the global hotkeys and Fn to it.
    var skipGlobalHotkeys = false
    private let instanceLock = InstanceLock()
    private let betaPanel = BetaPanel()
    lazy var beta: BetaController = {
        betaPanel.onSkip = { [weak self] in self?.finishBetaWithoutAnswers() }
        betaPanel.onCancel = { [weak self] in self?.dropBeta(notify: true) }
        return BetaController(host: .init(
            show: { [weak self] info, key in self?.betaPanel.show(info: info, hotkey: key) },
            hide: { [weak self] in self?.betaPanel.hide() },
            busy: { [weak self] in self?.betaPanel.setBusy($0) },
            cancel: { [client] pending in
                DispatchQueue.global(qos: .utility).async {
                    _ = try? client.betaSync(sessionId: pending.sessionId, skip: false,
                                            appBundleId: pending.appBundleId, llm: pending.llm)
                }
            }))
    }()
    var escRegistered = false
    var serviceUp: Bool { get { model.serviceUp } set { model.serviceUp = newValue } }
    var hint: String?
    var hintWarning = false
    var launchedAsLoginItem = false
    /// Re-checks the local service every few seconds while it looks down, so one
    /// failed check at launch (the service still starting) is never final.
    var healthRetryTimer: Timer?
    /// Polls quickly while the speech model loads or downloads, for the progress bar.
    var progressPollScheduled = false

    // MARK: lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            launchedAsLoginItem = true
        }
    }

    static let showHubNotification = Notification.Name("com.dsh.voice.showHub")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One TypeLeast at a time: two would fight over the hotkeys, the microphone and
        // the service. A second launch shows the first one's window and quits. A test run
        // with its own TYPELEAST_HOME may run beside it, without the global hotkeys.
        let isolatedTestRun = !(ProcessInfo.processInfo.environment["TYPELEAST_HOME"] ?? "").isEmpty
        if !isolatedTestRun, !instanceLock.acquire() {
            DistributedNotificationCenter.default().postNotificationName(AppDelegate.showHubNotification, object: nil,
                                                                         userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        skipGlobalHotkeys = isolatedTestRun
        if !isolatedTestRun { DistributedNotificationCenter.default().addObserver(forName: AppDelegate.showHubNotification, object: nil, queue: .main) { [weak self] _ in
            self?.hub.show()
        } }
        model.actions = self
        menuController.target = self
        mainMenu.openSettings = { [weak self] in self?.menuOpenHub(.settings) }
        mainMenu.checkForUpdates = { [weak self] in self?.menuCheckForUpdates() }
        mainMenu.quit = { [weak self] in self?.menuQuit() }
        let bar = mainMenu.build()
        NSApp.mainMenu = bar.menu
        NSApp.windowsMenu = bar.windows
        NSApp.applicationIconImage = AppMark.image(size: 512)
        // The heatmap starts from whatever history is still kept, once.
        ActivityLog.shared.seedIfNeeded(from: HistoryStore.shared.entries.filter { !$0.displayText.isEmpty }.map {
            let counts = DictationStats.countWords($0.displayText)
            return (date: $0.ts, words: counts.cjk + counts.latin)
        })
        applyGeneralSettings()
        registerHotKeys()
        updates.scheduleChecks()

        FnKeyMonitor.shared.onTap = { [weak self] source in self?.fnTapped(sourceAtPress: source) }
        recordingBar.onCancel = { [weak self] in self?.cancelDictation() }
        recordingBar.onStop = { [weak self] in self?.stopRecording() }
        idleBar.onClick = { [weak self] in self?.toggleDictation() }

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
        // Retry recordings live five minutes: look once a minute, so none outlasts six.
        let audioTimer = Timer(timeInterval: 60, repeats: true) { _ in HistoryStore.shared.pruneAudio() }
        RunLoop.main.add(audioTimer, forMode: .common)
        HistoryStore.shared.applyRetention(settings.historyRetention)
        applyState()
        startService()

        if settings.warmUpPill {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.recordingBar.warmUp() }
        }

        #if TYPELEAST_DEV
        // Development builds only: these hooks let the environment drive the app (paste a
        // WAV into the front app, read the Keychain for a model check), so a release has none.
        // Demo mode for screen recordings: a synthetic-voice WAV replaces the
        // microphone and one dictation starts by itself after a short delay, into
        // whatever app is in front. No window of TypeLeast is shown.
        if let demoPath = ProcessInfo.processInfo.environment["TYPELEAST_DEMO_WAV"],
           let wav = FileManager.default.contents(atPath: demoPath), Wav.isCanonical(wav) {
            recorder.demoPCM = wav.subdata(in: 44 ..< wav.count)
            let delay = Double(ProcessInfo.processInfo.environment["TYPELEAST_DEMO_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.toggleDictation() }
            return
        }

        if ProcessInfo.processInfo.environment["TYPELEAST_SELFCHECK"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.runSelfCheck() }
            return
        }
        #endif
        if !settings.onboardingDone {
            showOnboarding()
        } else if !launchedAsLoginItem {
            hub.show(page: .home)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A demo recording shows only the voice bar over another app.
        if recorder.demoPCM != nil { return false }
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
        ServiceManager.shared.stop()
        // Retry recordings do not outlive the app.
        HistoryStore.shared.pruneAudio(olderThan: 0)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    #if TYPELEAST_DEV
    /// Non-invasive launch diagnostics (used by build/acceptance checks). Development builds only.
    func runSelfCheck() {
        // Own-API-key diagnostics, run inside the real bundle (where App Transport
        // Security and the app's Keychain identity apply). The key comes from the
        // environment and is never printed.
        if let base = ProcessInfo.processInfo.environment["TYPELEAST_LLMCHECK_URL"] {
            let env = ProcessInfo.processInfo.environment
            // "@keychain" uses the key saved for the current preset without printing it, and only
            // toward the address that preset already sends it to: never to an address from the environment.
            let keyArg = env["TYPELEAST_LLMCHECK_KEY"] ?? ""
            let sameAddress = base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == settings.llmBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let key = keyArg == "@keychain" ? (sameAddress ? settings.llmAPIKey : "") : keyArg
            if keyArg == "@keychain", !sameAddress { print("LLMCHECK key=refused (address differs from the saved preset)") }
            print("LLMCHECK key=" + (key.isEmpty ? "missing" : "present(" + String(key.count) + " chars)"))
            let route = LLMRoute(baseURL: base, model: env["TYPELEAST_LLMCHECK_MODEL"] ?? "test", apiKey: key)
            do {
                let ids = try client.listModelsSync(route: route)
                print("LLMCHECK listModels=ok count=" + String(ids.count))
            } catch {
                print("LLMCHECK listModels=error " + ((error as? ServiceError)?.description ?? String(describing: error)))
            }
            do {
                let result = try client.testLLMSync(route: route)
                print("LLMCHECK test=" + (result.ok ? "ok" : "fail") + " code=" + (result.code ?? "-") + " ms=" + String(Int(result.ms ?? 0)))
            } catch {
                print("LLMCHECK test=error " + ((error as? ServiceError)?.description ?? String(describing: error)))
            }
            // Optional: one real dictation of a WAV file through this route.
            if let wavPath = env["TYPELEAST_LLMCHECK_WAV"], let wav = FileManager.default.contents(atPath: wavPath) {
                let started = Date()
                do {
                    let r = try client.dictateSync(wav: wav, language: "auto", appBundleId: "com.apple.Notes",
                                                   strength: env["TYPELEAST_LLMCHECK_STRENGTH"] ?? "prompt", llm: route,
                                                   translateTo: env["TYPELEAST_LLMCHECK_TRANSLATE"],
                                                   variants: env["TYPELEAST_LLMCHECK_VARIANTS"])
                    print("LLMCHECK dictate provider=" + (r.provider ?? "?") + " model=" + (r.model ?? "?")
                          + " translated=" + (r.translated ?? "-")
                          + " fallback=" + String(r.fallback) + (r.fallbackReason.map { " reason=" + $0 } ?? "")
                          + " ms=" + String(Int(Date().timeIntervalSince(started) * 1000)))
                    print("LLMCHECK dictate raw=" + r.raw)
                    print("LLMCHECK dictate text=" + r.text.replacingOccurrences(of: "\n", with: " / "))
                    // Prompt Beta: answer the questions with a second WAV, or skip them.
                    if let session = r.beta?.sessionId, !r.betaQuestions.isEmpty {
                        print("LLMCHECK beta questions=" + r.betaQuestions.joined(separator: " | "))
                        let next: DictateResponse
                        if let answerPath = env["TYPELEAST_LLMCHECK_ANSWER_WAV"],
                           let answer = FileManager.default.contents(atPath: answerPath) {
                            next = try client.dictateSync(wav: answer, language: "auto", appBundleId: "com.apple.Notes",
                                                          strength: "promptbeta", llm: route, betaSession: session)
                            print("LLMCHECK beta answer raw=" + next.raw)
                        } else {
                            next = try client.betaSync(sessionId: session, skip: true, appBundleId: "com.apple.Notes", llm: route)
                            print("LLMCHECK beta skipped")
                        }
                        print("LLMCHECK beta fallback=" + String(next.fallback) + (next.fallbackReason.map { " reason=" + $0 } ?? "")
                              + " issues=" + String(next.beta?.issues ?? -1) + " patched=" + String(next.beta?.patched ?? false)
                              + " ms=" + String(Int(Date().timeIntervalSince(started) * 1000)))
                        print("LLMCHECK beta text=" + next.text.replacingOccurrences(of: "\n", with: " / "))
                    }
                } catch {
                    print("LLMCHECK dictate=error " + ((error as? ServiceError)?.description ?? String(describing: error)))
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
        // The local service is the one thing that silently breaks the whole app, so
        // the self-check reports what was found and whether it answers.
        let manager = ServiceManager.shared
        print("SELFCHECK node=" + (manager.node.map { $0.version } ?? "none"))
        print("SELFCHECK serviceBundled=" + String(manager.serviceDirectory != nil))
        print("SELFCHECK service.state=" + String(describing: manager.state))
        print("SELFCHECK port.published=" + (client.publishedPort().map(String.init) ?? "nil"))
        print("SELFCHECK port.inUse=" + client.baseURL.absoluteString)
        if let health = try? client.healthSync() {
            print("SELFCHECK health.ok=" + String(health.ok) + " service=" + (health.service ?? "?")
                  + " version=" + (health.version ?? "?") + " speech=" + (health.speech?.phase ?? "?"))
        } else {
            print("SELFCHECK health.ok=false (unreachable)")
        }
        print("SELFCHECK serviceUp=" + String(serviceUp))
        print("SELFCHECK rssKB=" + String(AppDelegate.residentMemoryKB()))
        fflush(stdout)
        NSApp.terminate(nil)
    }
    #endif

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
        guard !skipGlobalHotkeys else { return }
        let centre = HotKeyCentre.shared
        var fnWanted = false
        var problems: [String: String] = [:]
        var taken = Set<String>()
        // A combination already used by an earlier slot, or refused by macOS (another app has it),
        // is shown beside that shortcut instead of failing silently.
        func register(_ slot: String, _ binding: HotKeyBinding, _ action: @escaping () -> Void) {
            let combo = String(binding.keyCode) + "-" + String(binding.modifiers)
            if binding.enabled && taken.contains(combo) {
                centre.unregister(slot: slot)
                problems[slot] = L10n.text("和其他快捷键重复")
                return
            }
            if centre.register(slot: slot, binding: binding, action: action) { taken.insert(combo) }
            else if binding.enabled { problems[slot] = L10n.text("被占用，请换一个") }
        }
        for (slot, binding) in [("main", settings.hotkeyMain), ("alt", settings.hotkeyAlt)] {
            if binding.isFn {
                centre.unregister(slot: slot)
                fnWanted = fnWanted || binding.enabled
            } else {
                register(slot, binding) { [weak self] in self?.hotkeyPressed() }
            }
        }
        if fnWanted { FnKeyMonitor.shared.start() } else { FnKeyMonitor.shared.stop() }
        register("pasteLast", settings.hotkeyPasteLast) { [weak self] in self?.pasteLast() }
        // Fn is reserved for dictation; a translate binding of Fn is ignored.
        let translate = settings.hotkeyTranslate
        if translate.isFn { centre.unregister(slot: "translate") } else {
            register("translate", translate) { [weak self] in self?.translateHotkeyPressed() }
        }
        model.hotkeyProblems = problems
    }

    /// Fn or a shortcut: toggle (press to start, press to stop).
    func hotkeyPressed() {
        toggleDictation()
    }

    /// 翻译模式: starts a recording whose text is inserted in the target language;
    /// while recording, either key finishes it.
    func translateHotkeyPressed() {
        toggleDictation(translateTo: settings.translateTarget)
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
                self.setHint(L10n.text("🌐 切换了输入法，未听写。请把「按下 🌐 键时」设为「无操作」"))
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
        idleBar.hint = L10n.text("按 ") + model.hotkeyLabel + L10n.text(" 开始听写")
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

    @objc func onWake() {
        refreshHealth()
        // Asleep, the five-minute check did not run: drop what expired meanwhile.
        HistoryStore.shared.pruneAudio()
    }

    @objc func onAppActivated(_ note: Notification) {
        // Leaving the app a dictation went into: the user is usually done fixing it.
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        dictionary.appActivated(app?.bundleIdentifier)
        let trusted = AXIsProcessTrusted()
        if trusted != model.accessibilityTrusted {
            model.accessibilityTrusted = trusted
            if trusted, let h = hint, h.contains(L10n.text("辅助功能")) { setHint(L10n.text("辅助功能已允许，可以自动粘贴")) }
            applyState()
        }
    }

    // MARK: state

    func applyState() {
        var s = MenuState()
        s.phase = phase
        s.strength = settings.strength
        s.elapsed = dictation.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
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
        let text = text ?? (HistoryStore.shared.persistenceProblem == nil ? nil : L10n.text("历史无法读写，文件已保留。请检查文件权限。"))
        hint = text
        hintWarning = warning
        model.hint = text ?? ""
    }

    // MARK: health (single check; no polling)

    func refreshHealth() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            do {
                let h = try self.client.healthSync()
                let catalog = try? self.client.speechModelsSync()
                DispatchQueue.main.async {
                    self.serviceUp = h.ok
                    self.model.health = h
                    self.model.speechCatalog = catalog
                    self.model.serviceProblem = AppDelegate.speechProblem(h.speech)
                    if h.ok, let hint = self.hint, hint.contains(L10n.text("语音模型")) { self.setHint(nil) }
                    self.applyState()
                    // While the model loads or downloads, follow its progress.
                    let phase = h.speech?.phase ?? ""
                    if (phase == "loading" || phase == "downloading" || h.speech?.operation?.running == true) && !self.progressPollScheduled {
                        self.progressPollScheduled = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.progressPollScheduled = false
                            self.refreshHealth()
                        }
                    }
                }
            } catch {
                let desc = (error as? ServiceError)?.description ?? error.localizedDescription
                DiagnosticsLog.write("health.fail", ["error": desc, "url": self.client.baseURL.absoluteString])
                DispatchQueue.main.async {
                    self.serviceUp = false
                    self.model.health = nil
                    self.model.serviceProblem = self.model.serviceSummary
                    self.applyState()
                    self.scheduleHealthRetry()
                }
            }
        }
    }

    /// What to tell the user about the recogniser, or "" when it is ready.
    static func speechProblem(_ speech: SpeechStatus?) -> String {
        switch speech?.phase ?? "" {
        case "ready": return ""
        case "missing-model": return L10n.text("请选择并安装语音模型。")
        case "downloading":
            return L10n.text("正在下载语音模型") + (speech?.downloadFraction.map { "：" + String(Int($0 * 100)) + "%" } ?? "…")
        case "loading": return L10n.text("正在加载语音模型…")
        case "error": return L10n.text("语音模型出错：") + (speech?.error ?? L10n.text("原因未知"))
        default: return L10n.text("语音识别未就绪")
        }
    }

    // MARK: local service

    func startService() {
        let manager = ServiceManager.shared
        manager.nodePathOverride = settings.nodePath
        manager.modelMirror = settings.modelMirror
        manager.onChange = { [weak self] state in
            guard let self = self else { return }
            self.model.serviceState = state
            self.model.nodeDescription = manager.node.map { $0.version + " · " + $0.path } ?? ""
            if case .running = state { self.refreshHealth() } else { self.model.serviceProblem = self.model.serviceSummary }
            self.applyState()
        }
        manager.start()
    }

    func restartService() {
        let manager = ServiceManager.shared
        manager.nodePathOverride = settings.nodePath
        manager.modelMirror = settings.modelMirror
        serviceUp = false
        setHint(L10n.text("正在重启本地服务…"))
        manager.restart()
        applyState()
    }

    func downloadModels() {
        model.settingsCategory = 4
        hub.show(page: .settings)
    }

    /// Let the user point at a Node.js binary (for unusual installs).
    func chooseNode() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("选择 Node.js（node 程序）")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.nodePath = url.path
            restartService()
        }
    }

    /// While the service looks down, check again every 15 s; stop as soon as it answers.
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

    // MARK: AppActions (called from the windows)

    func addWordFromHistory(_ word: String) { dictionary.addFromHistory(word) }

    func checkForUpdates(interactive: Bool) { updates.check(interactive: interactive) }

    func copyEntry(id: String, raw: Bool) {
        guard let e = HistoryStore.shared.entries.first(where: { $0.id == id }) else { return }
        let text = raw ? (e.raw.isEmpty ? e.text : e.raw) : e.displayText
        Inserter.shared.setString(text)
    }

    func retryEntry(id: String) {
        guard let e = HistoryStore.shared.entries.first(where: { $0.id == id }), e.strength != "promptbeta",
              let path = e.audioPath, FileManager.default.fileExists(atPath: path) else {
            setHint(L10n.text("录音已删除（保留 5 分钟）"), warning: true)
            applyState()
            return
        }
        guard phase == .idle else { return }
        // A retry from the window copies the result rather than pasting into the window.
        dictation.sendToServer(audioURL: URL(fileURLWithPath: path), appBundleId: e.app ?? "", language: e.language,
                     strength: e.strength, keepAudioPath: path, seconds: e.seconds, field: nil, insert: false,
                     translateTo: e.translated)
    }

    func deleteEntry(id: String) {
        HistoryStore.shared.remove(id: id)
    }

    func clearHistory() {
        HistoryStore.shared.clear()
        ActivityLog.shared.clear()
    }

    /// Reset a sticky denial, ask macOS to prompt, and open the settings pane.
    func requestAccessibility() {
        let reset = Inserter.resetAccessibilityDecision()
        let trusted = Inserter.requestAccessibilityPrompt()
        model.accessibilityTrusted = trusted
        if trusted {
            setHint(L10n.text("辅助功能已允许，可以自动粘贴"))
            FnKeyMonitor.shared.stop()
            registerHotKeys()
        } else {
            setHint(reset ? L10n.text("请在「辅助功能」里打开 TypeLeast") : L10n.text("请手动在「辅助功能」里打开 TypeLeast"), warning: true)
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

    func setCleanupMode(_ code: String) {
        guard phase == .idle, VoiceStrength(rawValue: code) != nil, code != settings.strength else { return }
        if betaPending != nil && code != "promptbeta" {
            let alert = NSAlert()
            alert.messageText = L10n.text("结束这次提示词 Beta？")
            alert.informativeText = L10n.text("切换会结束这次 Beta，未生成的文字不会插入。")
            alert.addButton(withTitle: L10n.text("取消"))
            alert.addButton(withTitle: L10n.text("切换模式"))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            dropBeta(notify: false)
        }
        settings.strength = code
        model.objectWillChange.send()
        applyState()
    }
    func menuSetStrength(_ code: String) { setCleanupMode(code) }

    func menuToggleDictation() { toggleDictation() }
    func menuCancelDictation() { cancelDictation() }
    func menuPasteLast() { pasteLast() }
    func menuOpenHub(_ page: HubPage) { hub.show(page: page) }
    func menuRequestAccessibility() { requestAccessibility() }
    func menuRestartService() { restartService() }
    func menuCheckForUpdates() { checkForUpdates(interactive: true) }

    func menuQuit() {
        recorder.cancel()
        NSApp.terminate(nil)
    }
}

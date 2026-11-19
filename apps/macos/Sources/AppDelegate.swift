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
    let recorder = Recorder(metersVoice: true)
    /// Floating capsule shown while listening and thinking.
    let recordingBar = RecordingBar()
    private lazy var recordingHints = RecordingHints(settings: settings) { [weak self] in self?.phase == .idle }
    private var wasDictationIdle = true
    let selectionTranslator = SelectionTranslator()
    private var readingShortcutSelection = false
    /// Resting bar at the bottom of the screen ("show voice bar").
    let idleBar = IdleBar()
    let settings = Settings.shared
    let client = ServiceClient.shared
    let model = AppModel(loadCacheImmediately: false)
    lazy var updates = UpdateController(host: .init(
        busyReason: { [weak self] in
            guard let self else { return nil }
            return UpdateController.blockingReason(practiceBusy: self.onboarding.practice.busy,
                phase: self.phase, promptPending: self.betaPending != nil, meetingBusy: self.model.meeting.busy)
        },
        dialogWindow: { [weak self] in
            self?.hub.updateDialogWindow ?? NSApp.keyWindow ?? NSApp.mainWindow
        },
        showAvailable: { [weak self] in self?.menuController.setUpdateAvailable($0) },
        willQuit: { [weak self] in
            self?.recorder.cancel()
            self?.hub.prepareForUpdate()
        }))
    lazy var hub = HubWindowController(model: model)
    lazy var onboarding = OnboardingWindowController(model: model)
    lazy var dictation = DictationController(host: .init(
        settings: settings, client: client, model: model, beta: beta,
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
        betaPanel.onContinue = { [weak self] in self?.startAssistant() }
        betaPanel.onSkip = { [weak self] in self?.finishBetaWithoutAnswers(answer: $0) }
        betaPanel.onAnswer = { [weak self] in self?.dictation.answerBeta($0) }
        betaPanel.onCancel = { [weak self] in self?.dropBeta(notify: true) }
        return BetaController(host: .init(
            show: { [weak self] info, key, anchor in self?.betaPanel.show(info: info, hotkey: key, anchor: anchor) },
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
    private var progressPoll: DispatchWorkItem?
    private var unlockingCredentials = false
    private var pendingShortcut: (slot: String, work: DispatchWorkItem)?
    private var heldShortcutSlot: String?
    private let healthRefresh = CoalescingRefresh<(HealthResponse, SpeechModelCatalog?)>()

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
            self?.openHomeFromOutside()
        } }
        #if TYPELEAST_DEV
        let environment = ProcessInfo.processInfo.environment
        let opensHome = environment["TYPELEAST_DEMO_WAV"] == nil && environment["TYPELEAST_SELFCHECK"] != "1"
        #else
        let opensHome = true
        #endif
        NSApp.appearance = configuredAppearance
        if opensHome, settings.onboardingDone, !launchedAsLoginItem { hub.openMainWindow() }
        model.credentialsLocked = TouchIDVault.shared.isConfigured && !TouchIDVault.shared.isUnlocked
        if model.credentialsLocked, opensHome, !launchedAsLoginItem {
            authenticateCredentials { [weak self] _ in self?.beginUserCacheLoad(opensHome: opensHome) }
        } else {
            beginUserCacheLoad(opensHome: opensHome)
        }
    }

    private func beginUserCacheLoad(opensHome: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Resolve the legacy handoff before the history cache accesses its key.
            KeychainHandoff.restoreIfPresent()
            let history = HistoryStore.shared
            let activity = ActivityLog.shared
            if !activity.isStarted, history.persistenceProblem == nil {
                activity.seedIfNeeded(from: history.entries.filter { !$0.displayText.isEmpty }.map {
                    let counts = DictationStats.countWords($0.displayText)
                    return (date: $0.ts, words: counts.cjk + counts.latin)
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.model.finishUserCacheLoad()
                self.hub.userCacheDidLoad()
                self.finishLaunch(opensHome: opensHome)
            }
        }
    }

    private func authenticateCredentials(completion: @escaping (Bool) -> Void) {
        guard !unlockingCredentials else { return }
        unlockingCredentials = true
        Task { @MainActor [weak self] in
            do { try await TouchIDVault.shared.unlock() }
            catch { DiagnosticsLog.write("keychain.touch-id.fail", ["status": String(TouchIDVault.status(error))]) }
            guard let self else { return }
            self.unlockingCredentials = false
            let unlocked = TouchIDVault.shared.isUnlocked
            self.model.credentialsLocked = !unlocked
            if unlocked {
                self.model.refreshLLMKeyPresence()
                self.model.refreshOnlineASRKeyPresence()
            }
            completion(unlocked)
        }
    }

    func unlockCredentials() {
        guard model.credentialsLocked, model.userCacheReady, phase == .idle else { return }
        authenticateCredentials { [weak self] unlocked in
            guard let self, unlocked else { return }
            HistoryStore.shared.retryAfterUnlock()
            self.model.reloadHistory()
            self.applyState()
        }
    }

    private func openHomeFromOutside() {
        hub.openMainWindow()
        if launchedAsLoginItem { unlockCredentials() }
    }

    private func finishLaunch(opensHome: Bool) {
        model.actions = self
        menuController.target = self
        mainMenu.openSettings = { [weak self] in self?.menuOpenHub(.settings) }
        mainMenu.checkForUpdates = { [weak self] in self?.menuCheckForUpdates() }
        mainMenu.quit = { [weak self] in self?.menuQuit() }
        let bar = mainMenu.build()
        NSApp.mainMenu = bar.menu
        NSApp.windowsMenu = bar.windows
        NSApp.applicationIconImage = AppMark.image(size: 512)
        applyGeneralSettings()
        registerHotKeys()
        updates.scheduleChecks()

        FnKeyMonitor.shared.onTap = { [weak self] source in self?.fnTapped(sourceAtPress: source) }
        FnKeyMonitor.shared.onHold = { [weak self] in self?.beginHeldDictation() == true }
        FnKeyMonitor.shared.onHoldEnd = { [weak self] in self?.dictation.endHeldShortcut() }
        recordingBar.onCancel = { [weak self] in self?.cancelDictation() }
        recordingBar.onDismiss = { [weak self] in self?.updateIdleBar() }
        recordingBar.onStop = { [weak self] in self?.stopRecording() }
        startSelectionTranslator()
        idleBar.onClick = { [weak self] in self?.toggleDictation() }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(onSettingsChanged), name: Settings.didChange, object: nil)
        center.addObserver(self, selector: #selector(onHistoryChanged), name: HistoryStore.didChange, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(onWake), name: NSWorkspace.didWakeNotification, object: nil)
        // Granting Accessibility happens in System Settings; the app learns about it
        // when the user switches apps again.
        workspace.addObserver(self, selector: #selector(onAppActivated),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if !skipGlobalHotkeys { recordingHints.start() }

        HistoryStore.shared.pruneAudio()
        // Retry recordings live five minutes: look once a minute, so none outlasts six.
        let audioTimer = Timer(timeInterval: 60, repeats: true) { _ in HistoryStore.shared.pruneAudio() }
        RunLoop.main.add(audioTimer, forMode: .common)
        HistoryStore.shared.applyRetention(settings.historyRetention)
        applyState()
        startService()

        if settings.warmUpPill && !settings.needsPractice {
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
        } else if !launchedAsLoginItem, !opensHome {
            hub.openMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A demo recording shows only the voice bar over another app.
        if recorder.demoPCM != nil { return false }
        openHomeFromOutside()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        recordingHints.stop()
        HubFeedback.shared.dismissAll()
        recorder.cancel()
        dictation.dropCancelledRecording()
        onboarding.practice.cancel()
        OutputMuter.shared.restore()
        recordingBar.hide()
        idleBar.hide()
        FnKeyMonitor.shared.stop()
        HotKeyCentre.shared.unregisterAll()
        ServiceManager.shared.stop()
        // Retry recordings do not outlive the app.
        if model.userCacheReady { HistoryStore.shared.pruneAudio(olderThan: 0) }
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
        pendingShortcut?.work.cancel()
        pendingShortcut = nil
        if heldShortcutSlot != nil { heldShortcutSlot = nil; dictation.endHeldShortcut() }
        let centre = HotKeyCentre.shared
        var fnWanted = false
        var chords: [FnChord: () -> Void] = [:]
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
            if binding.isFn || binding.fnChord != nil {
                centre.unregister(slot: slot)
                guard binding.enabled else { return }
                if let chord = binding.fnChord {
                    chords[chord] = action
                } else if slot == "main" || slot == "alt" {
                    fnWanted = true
                } else {
                    problems[slot] = L10n.text("Fn 单键用于听写")
                    return
                }
                taken.insert(combo)
                return
            }
            if binding.modifiers & FnChord.modifier != 0 {
                centre.unregister(slot: slot)
                if binding.enabled { problems[slot] = L10n.text("Fn 组合键仅支持左 Shift 或空格") }
                return
            }
            let dictationShortcut = slot == "main" || slot == "alt"
            let release: (() -> Void)? = dictationShortcut ? { [weak self] in self?.dictationShortcutReleased(slot) } : nil
            if centre.register(slot: slot, binding: binding, onRelease: release, action: { [weak self] in
                if dictationShortcut { self?.dictationShortcutPressed(slot) } else { action() }
            }) { taken.insert(combo) }
            else if binding.enabled { problems[slot] = L10n.text("被占用，请换一个") }
        }
        for (slot, binding) in [("main", settings.hotkeyMain), ("alt", settings.hotkeyAlt)] {
            register(slot, binding) { [weak self] in self?.hotkeyPressed() }
        }
        register("pasteLast", settings.hotkeyPasteLast) { [weak self] in self?.pasteLast() }
        register("assistant", settings.hotkeyAssistant) { [weak self] in self?.startAssistant() }
        register("translate", settings.hotkeyTranslate) { [weak self] in self?.translateHotkeyPressed() }
        FnKeyMonitor.shared.configure(bareFn: fnWanted, chords: chords)
        model.hotkeyProblems = problems
    }

    /// Fn or a shortcut: toggle (press to start, press to stop).
    func hotkeyPressed() {
        toggleDictation()
    }

    private func beginHeldDictation() -> Bool {
        guard !settings.needsPractice, !onboarding.practice.busy, !onboarding.practice.acceptsShortcut else { return false }
        return dictation.startHeldShortcut()
    }

    private func dictationShortcutPressed(_ slot: String) {
        guard pendingShortcut == nil, heldShortcutSlot == nil else { return }
        guard phase == .idle, !settings.needsPractice, !onboarding.practice.acceptsShortcut, !onboarding.practice.busy else {
            hotkeyPressed()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingShortcut?.slot == slot else { return }
            self.pendingShortcut = nil
            if self.beginHeldDictation() { self.heldShortcutSlot = slot }
        }
        pendingShortcut = (slot, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func dictationShortcutReleased(_ slot: String) {
        if heldShortcutSlot == slot {
            heldShortcutSlot = nil
            dictation.endHeldShortcut()
        } else if pendingShortcut?.slot == slot {
            pendingShortcut?.work.cancel()
            pendingShortcut = nil
            hotkeyPressed()
        }
    }

    /// The translation shortcut takes the selection first, or toggles spoken translation.
    func translateHotkeyPressed() {
        if onboarding.practice.acceptsShortcut && onboarding.practice.translateTo != nil { onboarding.practice.toggle(); return }
        guard phase == .idle, !onboarding.practice.acceptsShortcut, !onboarding.practice.busy, !settings.needsPractice else {
            toggleDictation(translateTo: settings.translateTarget)
            return
        }
        guard !readingShortcutSelection else { return }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier, !FieldContextReader.isBlocked(bundleId: bundle) else {
            performTranslationShortcut(selection: nil)
            return
        }
        if let field = FieldContextReader.capture(bundleId: bundle, requiringSelection: true) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            performTranslationShortcut(selection: field)
            return
        }
        guard Inserter.readsSelectionByCopy(bundle) else {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            performTranslationShortcut(selection: nil)
            return
        }

        let pid = app.processIdentifier
        readingShortcutSelection = true
        Inserter.shared.copySelection(whileFrontmost: pid) { [weak self] text in
            guard let self else { return }
            self.readingShortcutSelection = false
            guard self.phase == .idle, !self.onboarding.practice.acceptsShortcut, !self.onboarding.practice.busy,
                  !self.settings.needsPractice, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            let field = text.flatMap { FieldContextReader.frontmostApp(bundleId: bundle, selection: $0) }
            self.performTranslationShortcut(selection: field)
        }
    }

    private func performTranslationShortcut(selection: FocusedField?) {
        switch TranslationShortcutAction.resolve(selection: selection?.selection, speechTarget: settings.translateTarget,
                                                 selectionTarget: settings.preferredSelectionTranslateTarget) {
        case .speech(let target):
            toggleDictation(translateTo: target)
        case .selectedText(let target):
            if let selection { dictation.translateSelection(selection, to: target) }
        }
    }

    /// Quick Translate: the button and bubble next to a mouse selection.
    func startSelectionTranslator() {
        selectionTranslator.enabled = { [weak self] in
            guard let self else { return false }
            return self.settings.selectionTranslate && self.phase == .idle && !self.settings.needsPractice
        }
        selectionTranslator.preferredTarget = { [weak self] in self?.settings.preferredSelectionTranslateTarget ?? "en" }
        selectionTranslator.translate = { [weak self] text, target, cancellation, done in
            guard let self, let route = self.settings.activeLLMRoute else {
                return done(.failure(ServiceError.translationFailed(reason: "no-api-key")))
            }
            let language = self.settings.language, variants = self.settings.variantsHeader, ownPrompt = self.settings.customTranslatePrompt
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try self.client.polishSync(text: text, language: language, strength: "prompt", llm: route,
                                                                 translateTo: target, variants: variants, translatePrompt: ownPrompt,
                                                                 cancellation: cancellation) }
                DispatchQueue.main.async {
                    switch result {
                    // A failed translation comes back as the original text: say so instead of showing it.
                    case .success(let response) where !response.fallback && !response.insertableText.isEmpty:
                        done(.success(response.insertableText))
                    case .success(let response):
                        DiagnosticsLog.write("translation.fail", ["reason": response.fallbackReason ?? "empty-output"])
                        if let partial = response.translationProgress {
                            done(.failure(ServiceError.translationIncomplete(partial)))
                        } else {
                            done(.failure(ServiceError.translationFailed(reason: response.fallbackReason)))
                        }
                    case .failure(let error): done(.failure(error))
                    }
                }
            }
        }
        selectionTranslator.start()
    }

    /// A clean Fn tap. Stopping is immediate; starting waits a moment, and if the
    /// keyboard input source changed across the tap, the 🌐 key was switching 中/英
    /// for the system and the microphone stays closed.
    func fnTapped(sourceAtPress: String?) {
        guard phase == .idle else { hotkeyPressed(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + FnTapGate.currentDelay) { [weak self] in
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

    private var configuredAppearance: NSAppearance? {
        switch settings.appearance {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    func applyGeneralSettings() {
        HubThemeReveal.apply(configuredAppearance, in: hub.themeTransitionWindow,
                             additionalWindows: [hub.settingsThemeTransitionWindow].compactMap { $0 },
                             showsHome: model.page == .home || model.page == .settings)
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            if policy == .regular { NSApp.applicationIconImage = AppMark.image(size: 512) }
        }
        updateIdleBar()
    }

    func updateIdleBar() {
        idleBar.hint = L10n.text("按 ") + model.hotkeyLabel + L10n.text(" 开始听写")
        if !settings.needsPractice && settings.showIdleBar && phase == .idle && !recordingBar.isVisible {
            idleBar.show()
        } else {
            idleBar.hide()
        }
    }

    // MARK: notifications

    @objc func onSettingsChanged() {
        ServiceManager.shared.setLocalASREnabled(settings.onlineASRProvider == .local)
        applyState()
    }

    @objc func onHistoryChanged() {
        applyState()
        if serviceUp { refreshProfileOnce() }
    }

    @objc func onWake() {
        refreshHealth()
        // Asleep, the five-minute check did not run: drop what expired meanwhile.
        HistoryStore.shared.pruneAudio()
    }

    @objc func onAppActivated(_ note: Notification) {
        let trusted = AXIsProcessTrusted()
        if !skipGlobalHotkeys {
            FnKeyMonitor.shared.refreshEventSource()
            recordingHints.foregroundChanged()
        }
        if trusted != model.accessibilityTrusted {
            model.accessibilityTrusted = trusted
            if trusted, let h = hint, h.contains(L10n.text("辅助功能")) { setHint(L10n.text("辅助功能已允许，可以自动粘贴")) }
            applyState()
        }
    }

    // MARK: state

    func applyState() {
        let idle = phase == .idle
        if wasDictationIdle && !idle, !skipGlobalHotkeys { recordingHints.recordingStarted() }
        wasDictationIdle = idle
        var s = MenuState()
        s.phase = phase
        s.strength = settings.strength
        s.elapsed = dictation.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        s.hint = hint
        s.hintWarning = hintWarning
        s.serviceUp = serviceUp
        // Permission refresh happens at activation, window entry and explicit
        // permission actions, not on the recording timer's menu redraws.
        s.accessibilityTrusted = model.accessibilityTrusted
        s.hotkeySummary = model.hotkeyLabel
        let paste = settings.hotkeyPasteLast
        s.pasteLastSummary = paste.enabled ? HotKeyCentre.describe(keyCode: paste.keyCode, modifiers: paste.modifiers) : ""
        s.hasLast = HistoryStore.shared.last != nil
        menuController.apply(s)
    }

    func setHint(_ text: String?, warning: Bool = false) {
        let text = text ?? (HistoryStore.shared.persistenceProblem == nil ? nil : L10n.text("历史无法读写，文件已保留。请检查文件权限。"))
        hint = text
        hintWarning = warning
        model.hint = text ?? ""
    }

    // MARK: health (single check; no polling)

    /// The description of the user's work is rewritten once per launch, from History, in the background.
    private var profileRefreshed = false
    func refreshProfileOnce() {
        guard !profileRefreshed else { return }
        let items = HistoryStore.shared.learningItems
        guard !items.isEmpty, let route = settings.silentLLMRoute else { return }
        let generation = HistoryStore.shared.profileGeneration
        profileRefreshed = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let profile = try self.client.profileSync(items: items, llm: route)
                DispatchQueue.main.async { if !profile.isEmpty { HistoryStore.shared.setProfile(profile, generation: generation) } }
            } catch {
                DiagnosticsLog.write("profile.fail", ["error": (error as? ServiceError)?.description ?? error.localizedDescription])
            }
        }
    }

    func refreshHealth() {
        healthRefresh.request(work: { [client] in
            let health = try client.healthSync()
            return (health, try? client.speechModelsSync())
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let (h, catalog)):
                if self.serviceUp != h.ok { self.serviceUp = h.ok }
                if h.ok { self.refreshProfileOnce() }
                if self.model.health != h { self.model.health = h }
                if self.model.speechCatalog != catalog { self.model.speechCatalog = catalog }
                let problem = AppDelegate.speechProblem(h.speech)
                if self.model.serviceProblem != problem { self.model.serviceProblem = problem }
                if h.ok, let hint = self.hint, hint.contains(L10n.text("语音模型")) { self.setHint(nil) }
                self.applyState()
                // While the model loads or downloads, follow its progress.
                let phase = h.speech?.phase ?? ""
                if phase == "loading" || phase == "downloading" || h.speech?.operation?.running == true {
                    if self.progressPoll == nil {
                        let poll = DispatchWorkItem { [weak self] in
                            self?.progressPoll = nil
                            self?.refreshHealth()
                        }
                        self.progressPoll = poll
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: poll)
                    }
                } else {
                    self.progressPoll?.cancel()
                    self.progressPoll = nil
                }
            case .failure(let error):
                let desc = (error as? ServiceError)?.description ?? error.localizedDescription
                DiagnosticsLog.write("health.fail", ["error": desc, "url": self.client.baseURL.absoluteString])
                self.serviceUp = false
                self.model.health = nil
                self.model.speechCatalog = nil
                self.model.serviceProblem = self.model.serviceSummary
                self.progressPoll?.cancel()
                self.progressPoll = nil
                self.applyState()
                self.scheduleHealthRetry()
            }
        }
    }

    private func invalidateHealthRefresh() {
        healthRefresh.invalidate()
        progressPoll?.cancel()
        progressPoll = nil
        if serviceUp { serviceUp = false }
        if model.health != nil { model.health = nil }
        if model.speechCatalog != nil { model.speechCatalog = nil }
    }

    /// What to tell the user about the recogniser, or "" when it is ready.
    static func speechProblem(_ speech: SpeechStatus?) -> String {
        switch speech?.phase ?? "" {
        case "ready", "disabled": return ""
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
        manager.setLocalASREnabled(settings.onlineASRProvider == .local)
        manager.onChange = { [weak self] state in
            guard let self = self else { return }
            if !state.isRunning { self.invalidateHealthRefresh() }
            self.model.serviceState = state
            self.model.nodeDescription = manager.node.map { $0.version + " · " + $0.path } ?? ""
            if case .running = state { self.refreshHealth() } else { self.model.serviceProblem = self.model.serviceSummary }
            self.applyState()
        }
        manager.start()
    }

    func restartService() {
        invalidateHealthRefresh()
        let manager = ServiceManager.shared
        manager.nodePathOverride = settings.nodePath
        manager.modelMirror = settings.modelMirror
        setHint(L10n.text("正在重启本地服务…"))
        manager.restart()
        applyState()
    }

    func downloadModels() {
        model.settingsCategory = .models
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

    func breakdownSample() {
        dictation.startBreakdown(L10n.text("你是一名资深产品经理。请为一款面向大学生的记账 App 写一份需求文档，包含目标用户、核心功能、首版范围和成功指标。语气专业但易读，控制在 1500 字以内。"), appBundleId: "tutorial")
    }

    func checkForUpdates(interactive: Bool) { updates.check(interactive: interactive) }

    func copyEntry(id: String, raw: Bool) {
        guard let e = HistoryStore.shared.entries.first(where: { $0.id == id }) else { return }
        let text = raw ? (e.raw.isEmpty ? e.text : e.raw) : e.displayText
        Inserter.shared.setString(text)
    }

    func reviewEntry(id: String) { dictation.reviewHistoryEntry(id: id) }

    func retryEntry(id: String) {
        guard let e = HistoryStore.shared.entries.first(where: { $0.id == id }), e.strength != "promptbeta",
              let path = e.audioPath, FileManager.default.fileExists(atPath: path) else {
            setHint(L10n.text("录音已删除（保留 5 分钟）"), warning: true)
            applyState()
            return
        }
        guard phase == .idle else { return }
        // A retry from the window copies the result rather than pasting into the window.
        model.retryingHistoryID = id
        dictation.sendToServer(audioURL: URL(fileURLWithPath: path), appBundleId: e.app ?? "", language: e.language,
                     strength: e.strength, keepAudioPath: path, seconds: e.seconds, field: nil, insert: false,
                     translateTo: e.translated)
    }

    func deleteEntry(id: String) {
        let history = HistoryStore.shared
        guard history.removeWithUndo(id: id) else { return }
        if model.selectedHistoryID == id { model.selectedHistoryID = nil }
        HubFeedback.shared.show(L10n.text("记录已删除"),
                                undo: { history.undoRemoval(id: id) },
                                expired: { history.finishRemoval(id: id) })
    }

    func clearHistory() {
        HubFeedback.shared.dismissAll()
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

    func openSetupSettings() { hub.show(page: .settings) }

    func showOnboarding() {
        onboarding.onFinish = { [weak self] in self?.finishOnboarding() }
        onboarding.show()
    }

    func finishOnboarding() {
        settings.onboardingDone = true
        model.refreshPermissions()
        registerHotKeys()
        hub.openMainWindow()
        recordingBar.resetAfterOnboarding()
        if !skipGlobalHotkeys { recordingHints.permissionsChanged() }
    }

    func openRecommendedApp(_ bundle: String) { recordingHints.openRecommendation(bundle) }

    // MARK: MenuActionTarget

    func startAssistant() {
        guard !onboarding.practice.acceptsShortcut && !onboarding.practice.busy else { return }
        guard !settings.needsPractice else { showOnboarding(); return }
        dictation.toggleAssistant()
    }
    func setCleanupMode(_ code: String) {
        if code == "promptbeta" { startAssistant() }
    }
    func menuSetStrength(_ code: String) { setCleanupMode(code) }

    func menuToggleDictation() { toggleDictation() }
    func menuCancelDictation() { cancelDictation() }
    func menuPasteLast() { pasteLast() }
    func menuOpenHub(_ page: HubPage) {
        if page == .home { openHomeFromOutside() }
        else { hub.show(page: page) }
    }
    func menuRequestAccessibility() { requestAccessibility() }
    func menuRestartService() { restartService() }
    func menuCheckForUpdates() { checkForUpdates(interactive: true) }

    func menuQuit() {
        if hub.dismissSettingsIfVisible() { return }
        recorder.cancel()
        NSApp.terminate(nil)
    }
}

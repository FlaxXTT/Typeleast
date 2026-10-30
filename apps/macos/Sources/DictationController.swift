import AppKit
import AVFoundation

/// Recording, service requests, and insertion. Lifecycle and windows call the narrow entry points.
final class DictationController {
    struct Host {
        let settings: Settings
        let client: ServiceClient
        let model: AppModel
        let beta: BetaController
        let recorder: Recorder
        let recordingBar: RecordingBar
        let idleBar: IdleBar
        let applyState: () -> Void
        let updateIdleBar: () -> Void
        let setHint: (String?, Bool) -> Void
        let hint: () -> String?
        let registerEscape: () -> Void
        let unregisterEscape: () -> Void
        let showSettings: () -> Void
        let scheduleHealthRetry: () -> Void
    }
    private let host: Host
    init(host: Host) { self.host = host }
    private var settings: Settings { host.settings }
    private var client: ServiceClient { host.client }
    private var model: AppModel { host.model }
    private var beta: BetaController { host.beta }
    private var betaPending: BetaPending? { beta.pending }
    private var recorder: Recorder { host.recorder }
    private var recordingBar: RecordingBar { host.recordingBar }
    private var idleBar: IdleBar { host.idleBar }
    private var serviceUp: Bool { get { model.serviceUp } set { model.serviceUp = newValue } }
    private func applyState() { host.applyState() }
    private func updateIdleBar() { host.updateIdleBar() }
    private func setHint(_ text: String?, warning: Bool = false) { host.setHint(text, warning) }
    private var hint: String? { host.hint() }
    private func registerEscape() { host.registerEscape() }
    private func unregisterEscape() { host.unregisterEscape() }
    private func scheduleHealthRetry() { host.scheduleHealthRetry() }

    private(set) var phase: AppPhase = .idle { didSet { model.phase = phase } }
    private(set) var recordingStartedAt: Date?
    private var pendingAppBundleId = ""
    private var pendingField: FocusedField?
    private var progressID = UUID()
    private var pendingAssistant = false
    /// The open 提示词模式 session began from a selected prompt: its result is copied, not pasted over the selection.
    private var copyFinalPrompt = false
    /// A recording cancelled a moment ago, kept until 撤销 sends it on or the toast goes away.
    private var heldRecording: (url: URL, seconds: Double, app: String, field: FocusedField?, language: String, keep: Bool, translateTo: String?)?
    private let cancelToast = LearnedToast()
    private var pendingTranslate: String?

    private var tickTimer: Timer?
    private var lastTickedSecond = -1

    func toggleDictation() { toggleDictation(translateTo: nil) }

    func toggleAssistant() { toggleDictation(translateTo:nil,assistant:true) }

    /// `translateTo` only matters when this starts a recording (翻译模式's own hotkey).
    func toggleDictation(translateTo: String?, assistant: Bool = false) {
        switch phase {
        case .idle:
            pendingAssistant = assistant
            pendingTranslate = translateTo
            startRecording()
        case .recording:
            // A second press right after the first (a double tap) turns this recording into 提示词模式.
            if !pendingAssistant, pendingTranslate == nil, translateTo == nil,
               let started = recordingStartedAt, Date().timeIntervalSince(started) < DictationController.doubleTapWindow {
                pendingAssistant = true
                recordingBar.showRecording(destination: pendingAppBundleId, badge: L10n.text("提示词模式"))
                if betaPending != nil { beta.setBusy(L10n.text("正在听。说完按 {0}。", model.hotkeyLabel)) }
                return
            }
            stopRecording()
        case .thinking: NSSound.beep()
        }
    }

    /// Two presses within this many seconds are a double tap.
    static let doubleTapWindow: TimeInterval = 0.4

    func startRecording() {
        guard phase == .idle else { return }
        if recorder.demoPCM != nil {
            beginCapture()   // demo input: no microphone involved
            return
        }
        switch Recorder.authorizationStatus() {
        case .notDetermined:
            Recorder.requestMicrophoneAccess { [weak self] granted in
                guard let self = self else { return }
                self.model.refreshPermissions()
                if granted {
                    self.beginCapture()
                } else {
                    self.setHint(L10n.text("录音需要麦克风权限"), warning: true)
                    self.applyState()
                }
            }
        case .denied, .restricted:
            setHint(L10n.text("麦克风权限被拒绝，请在设置里打开"), warning: true)
            applyState()
            host.showSettings()
        default:
            beginCapture()
        }
    }

    func beginCapture() {
        progressID = UUID()
        cancelToast.finish()
        // Contract: frontmost bundle id is captured BEFORE recording starts.
        pendingAppBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        pendingField = nil
        let deviceID = AudioDevices.deviceID(forUID: settings.inputDeviceUID)
        recorder.prepareEngine = { engine in AudioInputSelector.apply(deviceID: deviceID, to: engine) }
        recorder.maxSeconds = max(5, min(600, settings.maxSeconds))
        recorder.onAutoStop = { [weak self] in self?.stopRecording(auto: true) }
        do {
            try recorder.start()
        } catch {
            let msg = (error as? RecorderError)?.description ?? error.localizedDescription
            setHint(msg, warning: true)
            applyState()
            return
        }
        phase = .recording
        // An answer to Prompt Beta: the questions stay visible so the user can answer them one by one.
        if pendingAssistant && betaPending != nil { beta.setBusy(L10n.text("正在听。说完按 {0}。", settings.hotkeyAssistant.enabled ? settings.hotkeyAssistant.name : model.hotkeyLabel)) }
        recordingStartedAt = Date()
        idleBar.hide()
        recordingBar.limitSeconds = Double(recorder.maxSeconds)
        recordingBar.showRecording(destination: pendingAppBundleId,
                                   badge: pendingTranslate.map { L10n.text("翻译") + " →" + $0.uppercased() }
                                       ?? (pendingAssistant ? L10n.text("提示词模式") : ""))
        setHint(serviceUp ? nil : (model.serviceProblem.isEmpty ? L10n.text("本地服务未就绪") : model.serviceProblem), warning: !serviceUp)
        playSound(start: true)
        if settings.muteWhileDictating {
            // The chime plays on the same output device: mute only after it (0.24 s) has played.
            let started = recordingStartedAt
            DispatchQueue.main.asyncAfter(deadline: .now() + (settings.soundEnabled ? 0.3 : 0)) { [weak self] in
                guard let self, self.phase == .recording, self.recordingStartedAt == started else { return }
                OutputMuter.shared.muteIfNeeded()
            }
        }
        registerEscape()
        startTick()
        applyState()

        // Read the target field off the main thread while the user is already speaking: to see,
        // on this computer, what precedes the cursor, and as context for the model (only with
        // 参考输入框里的内容 on).
        do {
            let bundle = pendingAppBundleId
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let field = FieldContextReader.capture(bundleId: bundle)
                DispatchQueue.main.async {
                    guard let self = self, self.phase == .recording, self.pendingAppBundleId == bundle else { return }
                    self.pendingField = field
                }
            }
        }
    }

    func stopRecording(auto: Bool = false) {
        guard phase == .recording else { return }
        unregisterEscape()
        stopTick()
        OutputMuter.shared.restore()
        let app = pendingAppBundleId
        let field = pendingField
        let language = settings.language
        let strength = pendingAssistant ? "promptbeta" : "prompt"
        pendingAssistant = false
        // With "never keep history" nothing stays on disk, the recording included.
        let keep = settings.keepAudio24h && settings.historyRetention.seconds != 0
        let translateTo = pendingTranslate
        pendingTranslate = nil
        // A recording made while Prompt Beta's questions are open is the answer to them;
        // a translation is not, and leaves the questions waiting.
        let betaSession = translateTo == nil && strength == VoiceStrength.promptbeta.rawValue ? betaPending?.sessionId : nil
        if betaSession != nil { beta.setBusy(L10n.text("正在更新…")) }
        do {
            let r = try recorder.finish()
            playSound(start: false)
            phase = .thinking
            recordingBar.showThinking(detail: "")
            setHint(auto ? L10n.text("已到 {0} 秒上限，正在整理", recorder.maxSeconds) : nil)
            applyState()
            sendToServer(audioURL: r.url, appBundleId: app, language: language, strength: strength,
                         keepAudioPath: keep ? r.url.path : nil, seconds: r.seconds, field: field,
                         insert: true, deleteWhenDone: !keep, betaSession: betaSession, translateTo: translateTo)
        } catch {
            playSound(start: false)
            phase = .idle
            recordingStartedAt = nil
            recordingBar.hide()
            let msg = (error as? RecorderError)?.description ?? error.localizedDescription
            if betaPending != nil { showBetaQuestions() }
            setHint(msg, warning: true)
            applyState()
            updateIdleBar()
        }
    }

    func cancelDictation() {
        switch phase {
        case .recording:
            unregisterEscape()
            stopTick()
            // A dictation can be taken back for a few seconds; an assistant answer cannot.
            if !pendingAssistant, let r = try? recorder.finish() {
                heldRecording = (r.url, r.seconds, pendingAppBundleId, pendingField, settings.language,
                                 settings.keepAudio24h && settings.historyRetention.seconds != 0, pendingTranslate)
                cancelToast.show(message: L10n.text("转录已取消"),
                                 undo: { [weak self] in self?.resumeHeldRecording() },
                                 expired: { [weak self] in self?.discardHeldRecording() })
                setHint(nil)
            } else {
                recorder.cancel()
                setHint(L10n.text("已取消，录音已删除"))
            }
            pendingAssistant = false
            OutputMuter.shared.restore()
            phase = .idle
            recordingStartedAt = nil
            pendingField = nil
            recordingBar.hide()
            pendingTranslate = nil
            if betaPending != nil { showBetaQuestions() }
            applyState()
            updateIdleBar()
        case .thinking:
            progressID = UUID()
            client.cancelGeneration()
            unregisterEscape(); stopTick(); recordingBar.hide()
            phase = .idle
            if betaPending != nil { showBetaQuestions() }
            setHint(L10n.text("已取消"));applyState();updateIdleBar()
        case .idle:
            break
        }
    }

    /// 撤销 on 「转录已取消」: the kept recording is transcribed as if it had been finished.
    private func resumeHeldRecording() {
        guard let held = heldRecording else { return }
        heldRecording = nil
        guard phase == .idle else { try? FileManager.default.removeItem(at: held.url); return }
        sendToServer(audioURL: held.url, appBundleId: held.app, language: held.language, strength: "prompt",
                     keepAudioPath: held.keep ? held.url.path : nil, seconds: held.seconds, field: held.field,
                     insert: true, deleteWhenDone: !held.keep, translateTo: held.translateTo)
    }

    /// Quitting: a recording waiting on 撤销 is deleted now.
    func dropCancelledRecording() { cancelToast.finish() }

    private func discardHeldRecording() {
        guard let held = heldRecording else { return }
        heldRecording = nil
        try? FileManager.default.removeItem(at: held.url)
    }

    // MARK: server

    func sendToServer(audioURL: URL, appBundleId: String, language: String, strength: String,
                      keepAudioPath: String?, seconds: Double?, field: FocusedField?,
                      insert: Bool, deleteWhenDone: Bool = false, betaSession: String? = nil,
                      translateTo: String? = nil) {
        phase = .thinking
        registerEscape()
        if !recordingBar.isVisible { recordingBar.showThinking(detail: "") }
        idleBar.hide()
        applyState()
        // The field's text goes to the model's provider only when the user turned that on.
        let context = settings.readFieldContext ? field?.context.encoded() : nil
        // Read on the main thread, where Settings lives; the key comes from the Keychain.
        let previousBeta = betaSession == nil ? nil : betaPending
        let llm = previousBeta?.llm ?? settings.activeLLMRoute
        let effectiveLanguage = previousBeta?.language ?? language
        let variants = previousBeta == nil ? settings.variantsHeader : previousBeta?.variants
        let profile = HistoryStore.shared.profile
        let progressID = UUID(); self.progressID = progressID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var outcome: Result<DictateResponse, Error>
            do {
                let data = try HistorySeal.readAudio(audioURL)
                if data.count > Wav.maxBytes {
                    throw ServiceError.transport(L10n.text("录音超过 24 MiB"))
                }
                outcome = .success(try self.client.dictateSync(wav: data, language: effectiveLanguage,
                                                              appBundleId: appBundleId, strength: strength,
                                                              fieldContext: context, llm: llm,
                                                              betaSession: betaSession,
                                                              translateTo: translateTo, variants: variants,
                                                              profile: profile,
                                                              onProgress: { [weak self] progress in DispatchQueue.main.async {
                                                                  guard let self, self.phase == .thinking, self.progressID == progressID else { return }
                                                                  self.recordingBar.showThinking(detail:progress.label)
                                                              } }))
            } catch {
                outcome = .failure(error)
            }
            if deleteWhenDone { try? FileManager.default.removeItem(at: audioURL) }
            DispatchQueue.main.async {
                guard self.progressID == progressID else { return }
                self.finishRequest(outcome, appBundleId: appBundleId, language: effectiveLanguage, strength: strength,
                                   audioPath: keepAudioPath, seconds: seconds, field: field, insert: insert, llm: llm, variants: variants)
            }
        }
    }

    func finishRequest(_ outcome: Result<DictateResponse, Error>, appBundleId: String, language: String,
                       strength: String, audioPath: String?, seconds: Double?, field: FocusedField?, insert: Bool,
                       llm: LLMRoute? = nil, variants: String? = nil) {
        unregisterEscape()
        // A failed request or Beta question does not retain an untracked raw recording.
        defer {
            if let path = audioPath, !path.hasSuffix(".sealed") {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        phase = .idle
        recordingStartedAt = nil
        pendingField = nil
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in self?.updateIdleBar() }
        }
        switch outcome {
        case .success(let resp):
            serviceUp = true
            model.serviceProblem = ""
            if let sessionId = resp.beta?.sessionId, let info = resp.beta {
                beta.accept(info: info, sessionId: sessionId, llm: llm, language: language,
                            variants: variants, appBundleId: appBundleId, field: field)
                recordingBar.hide()
                showBetaQuestions()
                setHint(L10n.text("提示词模式：继续补充或生成"))
                applyState()
                return
            }
            // The answer to Prompt Beta's questions: the prompt goes where the request was made.
            var appBundleId = appBundleId, field = field
            if let pending = betaPending, strength == VoiceStrength.promptbeta.rawValue, resp.translated == nil {
                appBundleId = pending.appBundleId
                field = pending.field
                beta.clear()
            }
            let text = resp.insertableText
            // A kept recording is sealed before its path goes into the history.
            let audioPath = audioPath.flatMap { path -> String? in
                guard HistoryStore.shared.persistenceProblem == nil, let sealed = HistorySeal.sealFile(atPath: path) else {
                    // This is the recording created by this request; do not retain plaintext on failure.
                    try? FileManager.default.removeItem(atPath: path)
                    return nil
                }
                return sealed
            }
            var entry = LocalHistoryEntry(id: HistoryStore.newID(), ts: Date(), app: appBundleId,
                                          language: language, strength: strength,
                                          raw: resp.raw, text: text, fallback: resp.fallback,
                                          fallbackReason: resp.fallbackReason, model: resp.model,
                                          msTotal: resp.ms?.total, audioPath: audioPath, inserted: false,
                                          seconds: seconds)
            entry.model = resp.model ?? resp.provider
            entry.translated = resp.translated
            entry.corrections = resp.corrections
            entry.intention = resp.intention
            entry.variants = variants
            entry.task = resp.task
            HistoryStore.shared.add(entry)
            if text.isEmpty {
                recordingBar.showResult(L10n.text("没有识别到内容"), warning: true)
                setHint(L10n.text("没有识别到内容"), warning: true)
                applyState()
                return
            }
            let failedHint = resp.translated != nil ? L10n.text("翻译失败，已插入原文。") : L10n.text("已用原文（整理失败）")
            setHint(resp.fallback ? failedHint : nil, warning: resp.fallback)
            if insert {
                let counts = DictationStats.countWords(text)
                ActivityLog.shared.record(words: counts.cjk + counts.latin)
                insertText(text, fallback: resp.fallback, entryId: entry.id, appBundleId: appBundleId, field: field)
            } else {
                Inserter.shared.setString(text)
                recordingBar.showResult(text, warning: resp.fallback)
                setHint(L10n.text("重试完成，结果已复制"))
                applyState()
            }
        case .failure(let error):
            let d = error as? ServiceError
            if case .http(410, _, _)? = d, betaPending != nil {
                dropBeta(notify: false)
                recordingBar.showResult(L10n.text("问题已过期，请重新说需求"), warning: true)
                setHint(L10n.text("问题已过期，请重新说需求"), warning: true)
                applyState()
                return
            }
            DiagnosticsLog.write("dictate.fail", ["error": d?.description ?? error.localizedDescription,
                                                  "ownKey": settings.activeLLMRoute == nil ? "no" : "yes"])
            if d?.serviceUnavailable == true {
                serviceUp = false
                scheduleHealthRetry()
            }
            recordingBar.showResult(serviceUp ? L10n.text("听写失败") : L10n.text("本地服务未就绪"), warning: true)
            if betaPending != nil { showBetaQuestions() }
            setHint(L10n.text("听写失败：") + (d?.description ?? error.localizedDescription), warning: true)
            applyState()
        }
    }

    // MARK: insertion

    func insertText(_ text: String, fallback: Bool, entryId: String?, appBundleId: String, field: FocusedField?) {
        // A terminal gets one line without control characters: this reduces accidental command execution.
        // Elsewhere a list never starts right after the text the cursor follows.
        let text = TerminalGuard.isTerminal(appBundleId) ? TerminalGuard.safeText(text, bundleId: appBundleId)
            : Inserter.separatingList(text, before: field?.bundleId == appBundleId ? field?.context.before : nil)
        // The user may have moved on while the text was being cleaned up. Pasting
        // into whatever is in front now could type into a terminal or the wrong
        // chat, so nothing is pasted and the clipboard is left alone; the text is
        // in History and one "paste last" away.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        func notPasted(_ short: String, _ long: String) {
            if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = false } }
            let paste = settings.hotkeyPasteLast
            let key = paste.enabled ? HotKeyCentre.describe(keyCode: paste.keyCode, modifiers: paste.modifiers) : ""
            recordingBar.showResult(short + (key.isEmpty ? L10n.text("，未粘贴 · 见历史") : L10n.text("，未粘贴 · 按 ") + key + L10n.text(" 贴到这里")),
                                    warning: true)
            setHint(long + (key.isEmpty ? L10n.text("文字在历史里。") : L10n.text("按 ") + key + L10n.text(" 贴到这里。历史里也有。")),
                    warning: true)
            applyState()
        }
        guard PasteTarget.matches(expected: appBundleId, frontmost: frontmost) else {
            notPasted(L10n.text("已切换应用"), L10n.text("整理时切换了应用，未粘贴。"))
            return
        }
        // The cursor the user placed first is where the text goes, even if it moved meanwhile.
        // When that field is gone (closed, another tab), pasting into whatever has focus now
        // would put the text in the wrong place.
        if let field, field.bundleId == appBundleId, FieldContextReader.restoreCaret(field) == .lost {
            notPasted(L10n.text("输入框已切换"), L10n.text("整理时原来的输入框已关闭或切换，未粘贴。"))
            return
        }
        let rich = Inserter.richListApps.contains(appBundleId)
            ? Inserter.listHTML(for: text) : nil
        Inserter.shared.insert(text, richHTML: rich) { [weak self] result, _ in
            guard let self = self else { return }
            self.setHint(result == .pasted ? (fallback ? self.hint : nil) : result.message, warning: !result.ok)
            self.recordingBar.showResult(text, warning: !result.ok || fallback)
            if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = result.ok } }
            self.applyState()
        }
    }

    /// "Paste last transcript": re-insert the newest entry at the cursor.
    func pasteLast() {
        guard phase == .idle, let last = HistoryStore.shared.last, !last.displayText.isEmpty else {
            NSSound.beep()
            return
        }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        insertText(last.displayText, fallback: last.fallback, entryId: nil, appBundleId: app, field: FieldContextReader.capture(bundleId: app))
    }

    // MARK: helpers

    /// One timer for both the menu and the waveform.
    func startTick() {
        stopTick()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, self.phase == .recording else { return }
            self.recordingBar.update(level: self.recorder.level(), elapsed: self.recorder.elapsed)
            let second = Int(self.recorder.elapsed)
            if second != self.lastTickedSecond {
                self.lastTickedSecond = second
                self.applyState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stopTick() {
        tickTimer?.invalidate()
        tickTimer = nil
        lastTickedSecond = -1
    }

    func playSound(start: Bool) {
        guard settings.soundEnabled else { return }
        if start {
            StartChime.sound?.stop()
            StartChime.sound?.play()
        } else {
            StartChime.stopSound?.stop()
            StartChime.stopSound?.play()
        }
    }

    // MARK: Prompt Beta

    /// 拆解提示词: a prompt the user selected starts 提示词模式 as its first input. Nothing is
    /// pasted over the selection; the finished prompt is copied.
    func startBreakdown(_ text: String, appBundleId: String) {
        guard phase == .idle else { NSSound.beep(); return }
        guard let route = settings.activeLLMRoute else { setHint(L10n.text("请先配置可用的整理模型。"), warning: true); applyState(); return }
        if betaPending != nil { beta.cancel() }
        copyFinalPrompt = true
        sendBetaText(text, session: nil, source: "selection", appBundleId: appBundleId, route: route, language: settings.language, variants: settings.variantsHeader)
    }

    /// A typed or chosen answer to the open questions (the quick choices in the panel).
    func answerBeta(_ text: String) {
        guard phase == .idle, let pending = betaPending else { return }
        beta.setBusy(L10n.text("正在更新…"))
        sendBetaText(text, session: pending.sessionId, source: nil, appBundleId: pending.appBundleId, route: pending.llm, language: pending.language, variants: pending.variants)
    }

    private func sendBetaText(_ text: String, session: String?, source: String?, appBundleId: String, route: LLMRoute?, language: String, variants: String?) {
        phase = .thinking
        registerEscape()
        recordingBar.showThinking(detail: "")
        applyState()
        let strength = VoiceStrength.promptbeta.rawValue
        let generation = UUID(); progressID = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result { try self.client.polishSync(text: text, language: language, strength: strength, llm: route, translateTo: nil, variants: variants,
                                                              betaSession: session, source: source) }
            DispatchQueue.main.async {
                guard self.progressID == generation else { return }
                self.finishRequest(outcome, appBundleId: appBundleId, language: language, strength: strength, audioPath: nil, seconds: nil,
                                   field: nil, insert: false, llm: route, variants: variants)
            }
        }
    }

    func showBetaQuestions() {
        beta.show(hotkey: settings.hotkeyAssistant.enabled ? settings.hotkeyAssistant.name : L10n.text("继续补充按钮"))
    }

    /// Explicitly finish clarification; unanswered points stay unconfirmed.
    func finishBetaWithoutAnswers() {
        guard phase == .idle, let pending = betaPending else { return }
        beta.hide()
        phase = .thinking
        registerEscape()
        recordingBar.showThinking(detail: "")
        applyState()
        let llm = pending.llm
        let language = pending.language
        let variants = pending.variants
        let generation = UUID(); progressID = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result { try self.client.betaSync(sessionId: pending.sessionId, skip: true,
                                                            appBundleId: pending.appBundleId, llm: llm,
                                                            variants: variants) }
            DispatchQueue.main.async {
                guard self.progressID == generation else { return }
                self.finishRequest(outcome, appBundleId: pending.appBundleId, language: language,
                                   strength: VoiceStrength.promptbeta.rawValue, audioPath: nil, seconds: nil,
                                   field: pending.field, insert: !self.copyFinalPrompt, llm: llm, variants: variants)
                self.copyFinalPrompt = false
            }
        }
    }

    /// Close the questions; the service forgets the session too.
    func dropBeta(notify: Bool) {
        guard betaPending != nil else { return }
        beta.cancel()
        if notify {
            setHint(L10n.text("已取消"))
            applyState()
        }
    }
}

import AppKit
import AVFoundation

/// Recording, service requests, and insertion. Lifecycle and windows call the narrow entry points.
final class DictationController {
    struct Host {
        let settings: Settings
        let client: ServiceClient
        let model: AppModel
        let dictionary: DictionaryController
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
    private var dictionary: DictionaryController { host.dictionary }
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
    /// A recording cancelled a moment ago, kept until 撤销 sends it on or the toast goes away.
    private var heldRecording: (url: URL, seconds: Double, app: String, field: FocusedField?, language: String, keep: Bool, translateTo: String?)?
    private let cancelToast = LearnedToast()
    private var pendingTranslate: String?
    private let namePanel = NameConfirmationPanel()
    private var clarificationSource: String?
    private var clarificationDestination: (app: String, field: FocusedField?, language: String, strength: String, target: String?, variants: String?, evidence: String, disabled: Bool)?

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
        case .recording: stopRecording()
        case .thinking: NSSound.beep()
        }
    }

    func startRecording() {
        guard phase == .idle else { return }
        namePanel.dismiss()
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
        // The previous dictation's field is checked for corrections before a new one starts.
        dictionary.dictationStarting()
        // Contract: frontmost bundle id is captured BEFORE recording starts.
        pendingAppBundleId = clarificationDestination?.app ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
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

        // Read the target field off the main thread while the user is already speaking: as
        // context for the model (only with 参考输入框里的内容 on) and, locally, so the edit
        // learner can see what the user fixes afterwards.
        if clarificationSource == nil && (settings.readFieldContext || settings.autoLearn) {
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

    func dropNameConfirmation() {
        namePanel.dismiss()
        clarificationSource = nil
        clarificationDestination = nil
    }

    func cancelDictation() {
        dropNameConfirmation()
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
        let source = clarificationSource
        let destination = source == nil ? nil : clarificationDestination
        clarificationSource = nil
        clarificationDestination = nil
        let appBundleId = destination?.app ?? appBundleId
        let field = destination?.field ?? field
        let language = destination?.language ?? language
        let strength = destination?.strength ?? strength
        let translateTo = destination?.target ?? translateTo
        phase = .thinking
        registerEscape()
        if !recordingBar.isVisible { recordingBar.showThinking(detail: "") }
        idleBar.hide()
        applyState()
        // The field's text goes to the model's provider only when the user turned that on.
        let context = (destination?.disabled == true) ? nil : (settings.readFieldContext ? field?.context.encoded() : nil)
        // Read on the main thread, where Settings lives; the key comes from the Keychain.
        let previousBeta = betaSession == nil ? nil : betaPending
        let llm = previousBeta?.llm ?? settings.activeLLMRoute
        let effectiveLanguage = previousBeta?.language ?? language
        let variants = destination?.variants ?? (previousBeta == nil ? settings.variantsHeader : previousBeta?.variants)
        let dictionary = self.dictionary.serviceEntries
        let localOnly = self.dictionary.localEntries
        let policy = self.dictionary.policy(disabled: destination?.disabled ?? false)
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
                                                              dictionary: dictionary, localOnly: localOnly, clarificationSource: source, clarificationEvidence: destination?.evidence, personalization: policy,
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
            if resp.contextOnly {
                recordingBar.showResult(L10n.text("这次只有解释信息，没有正文，未插入。"), warning: false)
                setHint(L10n.text("这次只有解释信息，没有正文，未插入。"))
                applyState(); return
            }
            if let clarification = resp.clarification {
                recordingBar.hide()
                clarificationSource = resp.raw
                clarificationDestination = (appBundleId, field, language, strength, clarification.target, variants, clarification.evidence, clarification.personalizationDisabled ?? false)
                namePanel.show(question: clarification.kind == "quality" ? CleanupIssue.message(clarification.reason) : L10n.text("需要确认：{0}", clarification.evidence), raw: clarification.kind == "quality" ? (clarification.candidate ?? resp.raw) : resp.raw, kind: clarification.kind) { [weak self] choice in
                    guard let self else { return }
                    self.clarificationSource = nil
                    self.clarificationDestination = nil
                    switch choice {
                    case .cancel: self.setHint(L10n.text("已取消"))
                    case .supplement:
                        self.clarificationSource = resp.raw
                        self.clarificationDestination = (appBundleId, field, language, strength, clarification.target, variants, clarification.evidence, clarification.personalizationDisabled ?? false)
                        self.toggleDictation(translateTo: clarification.target)
                    case .original:
                        var confirmed = resp
                        confirmed.clarification = nil
                        confirmed.text = resp.raw
                        confirmed.suggestions = []
                        self.finishRequest(.success(confirmed), appBundleId: appBundleId, language: language, strength: strength,
                                           audioPath: nil, seconds: seconds, field: field, insert: insert, llm: llm, variants: variants)
                    case .edit(let text) where clarification.kind == "quality":
                        var confirmed = resp
                        confirmed.clarification = nil; confirmed.fallback = false; confirmed.fallbackReason = nil
                        confirmed.text = text; confirmed.suggestions = []
                        self.finishRequest(.success(confirmed), appBundleId: appBundleId, language: language, strength: strength,
                                           audioPath: nil, seconds: seconds, field: field, insert: insert, llm: llm, variants: variants)
                    case .retry, .edit:
                        let text: String
                        if case .edit(let edited) = choice { text = edited } else { text = resp.raw }
                        self.phase = .thinking
                        self.registerEscape()
                        self.recordingBar.showThinking(detail:L10n.text("正在整理…"))
                        let generation = UUID(); self.progressID = generation
                        self.applyState()
                        let entries = self.dictionary.serviceEntries
                        let local = self.dictionary.localEntries
                        let context = self.settings.readFieldContext ? field?.context.encoded() : nil
                        let policy = self.dictionary.policy(disabled: clarification.personalizationDisabled ?? false)
                        DispatchQueue.global(qos: .userInitiated).async {
                            let outcome = Result { try self.client.polishSync(text: text, language: language, strength: strength, llm: llm,
                                translateTo: clarification.target, variants: variants,
                                dictionary: entries, localOnly: local, fieldContext: context, personalization: policy) }
                            DispatchQueue.main.async {
                                guard self.progressID == generation else { return }
                                self.finishRequest(outcome, appBundleId: appBundleId, language: language, strength: strength,
                                                   audioPath: nil, seconds: seconds, field: field, insert: insert, llm: llm, variants: variants)
                            }
                        }
                    }
                }
                applyState()
                return
            }
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
            entry.personalization = resp.personalization
            entry.variants = variants
            entry.task = resp.task
            HistoryStore.shared.add(entry)
            if !resp.fallback, resp.translated == nil { dictionary.received(resp.suggestions) }
            if text.isEmpty {
                recordingBar.showResult(L10n.text("没有识别到内容"), warning: true)
                setHint(L10n.text("没有识别到内容"), warning: true)
                applyState()
                return
            }
            let failedHint = resp.uncertain == true ? L10n.text("已插入，可能有误，可在历史中修改") : ["entity-changed", "name-kept"].contains(resp.fallbackReason ?? "") ? L10n.text("名称改写缺少依据，已保留识别原文。") : resp.translated != nil ? L10n.text("翻译失败，已插入原文。") : L10n.text("已用原文（整理失败）")
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
        let text = TerminalGuard.safeText(text, bundleId: appBundleId)
        // The user may have moved on while the text was being cleaned up. Pasting
        // into whatever is in front now could type into a terminal or the wrong
        // chat, so nothing is pasted and the clipboard is left alone; the text is
        // in History and one "paste last" away.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard PasteTarget.matches(expected: appBundleId, frontmost: frontmost) else {
            if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = false } }
            let paste = settings.hotkeyPasteLast
            let key = paste.enabled ? HotKeyCentre.describe(keyCode: paste.keyCode, modifiers: paste.modifiers) : ""
            recordingBar.showResult(key.isEmpty ? L10n.text("已切换应用，未粘贴 · 见历史") : L10n.text("已切换应用，未粘贴 · 按 ") + key + L10n.text(" 贴到这里"),
                                    warning: true)
            setHint(L10n.text("整理时切换了应用，未粘贴。") + (key.isEmpty ? L10n.text("文字在历史里。") : L10n.text("按 ") + key + L10n.text(" 贴到这里。历史里也有。")),
                    warning: true)
            applyState()
            return
        }
        let rich = Inserter.richListApps.contains(appBundleId)
            ? Inserter.listHTML(for: text) : nil
        Inserter.shared.insert(text, richHTML: rich) { [weak self] result, _ in
            guard let self = self else { return }
            self.setHint(result == .pasted ? (fallback ? self.hint : nil) : result.message, warning: !result.ok)
            self.recordingBar.showResult(text, warning: !result.ok || fallback)
            if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = result.ok } }
            if result == .pasted, let field = field, field.bundleId == appBundleId {
                self.dictionary.pasted(text, into: field)
            }
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
        insertText(last.displayText, fallback: last.fallback, entryId: nil, appBundleId: app, field: nil)
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
                                   field: pending.field, insert: true, llm: llm, variants: variants)
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

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
    /// 提示词模式's draft copied from a browser, whose fields Accessibility cannot read.
    private var copiedSelection: String?
    /// A recording cancelled a moment ago, kept until 撤销 sends it on or the toast goes away.
    private var heldRecording: (url: URL, seconds: Double, app: String, field: FocusedField?, language: String, keep: Bool, translateTo: String?)?
    private let cancelToast = LearnedToast()
    private let noiseReview = NoiseReviewPanel()
    private let quantityReview = QuantityReviewPanel()
    private var pendingReviewedRequest: ReviewedRequest?
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
        // Fn is for dictation only; 提示词模式 has its own key (⌥Space by default).
        case .recording: stopRecording()
        case .thinking: NSSound.beep()
        }
    }

    /// The key that answers 提示词模式's questions, as shown to the user.
    private var assistantKeyLabel: String {
        model.assistantLabel.isEmpty ? L10n.text("继续补充按钮") : model.assistantLabel
    }

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
        copiedSelection = nil
        cancelToast.finish()
        // Text still waiting for the user to come back stays in History.
        Delivery.cancelWaiting()
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
        if pendingAssistant && betaPending != nil { beta.setBusy(L10n.text("正在听。说完按 {0}。", assistantKeyLabel)) }
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
                    // Text selected when 提示词模式 starts is the draft the user is about to revise.
                    guard self.pendingAssistant, self.betaPending == nil else { return }
                    if Self.hasText(field?.selection) {
                        self.recordingBar.showRecording(destination: bundle, badge: L10n.text("提示词模式 · 修改选中内容"))
                    } else if Inserter.readsSelectionByCopy(bundle) {
                        Inserter.shared.copySelection { [weak self] text in
                            guard let self, self.phase == .recording, self.pendingAssistant, self.pendingAppBundleId == bundle,
                                  Self.hasText(text) else { return }
                            self.copiedSelection = text.map { String($0.prefix(FieldContextReader.selectionLimit)) }
                            self.recordingBar.showRecording(destination: bundle, badge: L10n.text("提示词模式 · 修改选中内容"))
                        }
                    }
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
        let language = settings.recognitionLanguage(for: model.speech?.modelId)
        let strength = pendingAssistant ? "promptbeta" : "prompt"
        // A new 提示词模式 conversation starts from the selected text, revised by what was said.
        let baseline = !pendingAssistant || betaPending != nil ? nil : Self.hasText(field?.selection) ? field?.selection : copiedSelection
        copiedSelection = nil
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
                         insert: true, deleteWhenDone: !keep, betaSession: betaSession, translateTo: translateTo,
                         baseline: baseline)
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
                heldRecording = (r.url, r.seconds, pendingAppBundleId, pendingField, settings.recognitionLanguage(for: model.speech?.modelId),
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
            if let pending = pendingReviewedRequest {
                pendingReviewedRequest = nil
                presentReviewedCandidate(pending)
            }
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
                      translateTo: String? = nil, baseline: String? = nil) {
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
        let canFailOver = llm != nil && settings.hasConfiguredBackupProviders
        let effectiveLanguage = previousBeta?.language ?? language
        let variants = previousBeta == nil ? settings.variantsHeader : previousBeta?.variants
        let profile = HistoryStore.shared.profile
        let ownPrompt = settings.customTranslatePrompt
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
                                                              profile: profile, baseline: baseline, translatePrompt: ownPrompt, hasConfiguredBackups: canFailOver,
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
                self.withBackupIfNeeded(outcome, generation: progressID, language: effectiveLanguage, strength: strength,
                                        translateTo: translateTo, variants: variants, profile: profile, context: context,
                                        baseline: baseline, appBundleId: appBundleId, translatePrompt: ownPrompt,
                                        currentRoute: llm, betaSession: betaSession) { resolved, usedRoute in
                self.finishRequest(resolved, appBundleId: appBundleId, language: effectiveLanguage, strength: strength,
                                   audioPath: keepAudioPath, seconds: seconds, field: field, insert: insert, llm: usedRoute ?? llm, variants: variants,
                                   betaSession: betaSession, betaInfo: previousBeta?.info, translateTo: translateTo, baseline: baseline,
                                   reviewContext: context, reviewProfile: profile, reviewTranslatePrompt: ownPrompt)
                }
            }
        }
    }

    /// The first route was unavailable. Only now read the previously configured backup keys.
    private func withBackupIfNeeded(_ outcome: Result<DictateResponse, Error>, generation: UUID,
                                    language: String, strength: String, translateTo: String?, variants: String?,
                                    profile: String, context: Data?, baseline: String?, appBundleId: String,
                                    translatePrompt: String?, currentRoute: LLMRoute?, betaSession: String? = nil,
                                    source: String? = nil, originalText: String? = nil, betaSkip: Bool = false,
                                    completion: @escaping (Result<DictateResponse, Error>, LLMRoute?) -> Void) {
        guard case .success(let response) = outcome, response.offerFailover else { completion(outcome, nil); return }
        let isAssistant = strength == VoiceStrength.promptbeta.rawValue
        let retrySession = isAssistant ? (response.beta?.sessionId ?? betaSession) : nil
        let text = originalText ?? response.raw
        guard isAssistant ? retrySession != nil : !text.isEmpty else { completion(outcome, nil); return }
        let routes = settings.backupLLMRoutes(excluding: currentRoute)
        guard progressID == generation else { return }
        guard let first = routes.first else { completion(outcome, nil); return }
        recordingBar.showThinking(detail: L10n.text("正在切换备用模型…"))
        let ticket = client.generationTicket()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let retried = Result {
                var answer = try self.client.polishSync(text: text, language: language, strength: strength, llm: first,
                    translateTo: translateTo, variants: variants, profile: profile, fieldContext: context,
                    betaSession: retrySession, source: source, translatePrompt: translatePrompt, baseline: baseline, appHint: appBundleId,
                    generationTicket: ticket, llmBackups: Array(routes.dropFirst()), retryInitial: isAssistant && betaSession == nil, betaSkip: betaSkip)
                if !answer.fallback && answer.beta?.notice == nil { answer.switchedProvider = true }
                return answer
            }
            DispatchQueue.main.async {
                guard self.progressID == generation else { return }
                let selected: LLMRoute?
                if case .success(let answer) = retried, answer.switchedProvider {
                    selected = routes.first { route in
                        guard route.model == answer.model, let url = URL(string: route.baseURL), let host = url.host else { return false }
                        let authority = host + (url.port.map { ":\($0)" } ?? "")
                        return answer.provider == "custom:" + authority
                    } ?? first
                } else { selected = nil }
                completion(retried, selected)
            }
        }
    }

    enum ReviewContinuation: Equatable { case ready, busy, sessionChanged }

    private struct ReviewedRequest {
        let text: String
        let repeated: Bool
        let appBundleId: String
        let language: String
        let strength: String
        let field: FocusedField?
        let insert: Bool
        let llm: LLMRoute?
        let variants: String?
        let betaSession: String?
        let betaInfo: BetaInfo?
        let translateTo: String?
        let baseline: String?
        let context: Data?
        let profile: String
        let translatePrompt: String?
    }

    /// A non-modal panel can outlive a recording or an assistant round. Never let
    /// its action interrupt a newer task or submit an old answer to a later round.
    static func reviewContinuation(phase: AppPhase, strength: String, translateTo: String?,
                                   originalSession: String?, originalInfo: BetaInfo?,
                                   currentSession: String?, currentInfo: BetaInfo?) -> ReviewContinuation {
        guard phase == .idle else { return .busy }
        if strength == VoiceStrength.promptbeta.rawValue && translateTo == nil {
            guard originalSession == currentSession, originalInfo == currentInfo else { return .sessionChanged }
        }
        return .ready
    }

    /// Each history row owns its own recording. A retry's sealed recording is
    /// copied without decryption; a storage failure must not delete the source.
    static func retainAudioForHistory(_ path: String, canPersist: Bool) -> String? {
        let sealed = path.hasSuffix(".sealed")
        guard canPersist else {
            if !sealed { try? FileManager.default.removeItem(atPath: path) }
            return nil
        }
        if !sealed {
            guard let result = HistorySeal.sealFile(atPath: path) else {
                try? FileManager.default.removeItem(atPath: path)
                return nil
            }
            return result
        }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        let target = folder.appendingPathComponent("dsh-voice-retry-\(UUID().uuidString).wav.sealed")
        var copied = false
        do {
            try FileManager.default.copyItem(atPath: path, toPath: target.path)
            copied = true
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return target.path
        } catch {
            if copied { try? FileManager.default.removeItem(at: target) }
            return nil
        }
    }

    private func presentReviewedCandidate(_ request: ReviewedRequest) {
        noiseReview.show(candidate: request.text, repeated: request.repeated) { [weak self] _ in
            guard let self else { return false }
            switch Self.reviewContinuation(phase: self.phase, strength: request.strength, translateTo: request.translateTo,
                                           originalSession: request.betaSession, originalInfo: request.betaInfo,
                                           currentSession: self.beta.pending?.sessionId, currentInfo: self.beta.pending?.info) {
            case .busy:
                self.setHint(L10n.text("请先完成或取消当前操作。"), warning: true)
                self.applyState()
                return false
            case .sessionChanged:
                self.setHint(L10n.text("原提示词会话已结束，识别原文仍在此窗口。"), warning: true)
                self.applyState()
                return false
            case .ready:
                self.continueReviewedText(request)
                return true
            }
        }
    }

    /// A confirmed ASR candidate is processed as the original task, never
    /// inserted before cleanup or substituted for a pending assistant answer.
    private func continueReviewedText(_ request: ReviewedRequest) {
        phase = .thinking
        registerEscape()
        recordingBar.showThinking(detail: "")
        idleBar.hide()
        if request.betaSession != nil { beta.setBusy(L10n.text("正在更新…")) }
        setHint(nil)
        applyState()
        pendingReviewedRequest = request
        let generation = UUID(); progressID = generation
        let requestTicket = client.generationTicket()
        let canFailOver = request.llm != nil && settings.hasConfiguredBackupProviders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result {
                try self.client.polishSync(text: request.text, language: request.language, strength: request.strength, llm: request.llm,
                                           translateTo: request.translateTo, variants: request.variants, profile: request.profile,
                                           fieldContext: request.context, betaSession: request.betaSession, translatePrompt: request.translatePrompt,
                                           baseline: request.baseline, appHint: request.appBundleId, generationTicket: requestTicket, hasConfiguredBackups: canFailOver)
            }
            DispatchQueue.main.async {
                guard self.progressID == generation else { return }
                self.withBackupIfNeeded(outcome, generation: generation, language: request.language, strength: request.strength,
                    translateTo: request.translateTo, variants: request.variants, profile: request.profile, context: request.context,
                    baseline: request.baseline, appBundleId: request.appBundleId, translatePrompt: request.translatePrompt,
                    currentRoute: request.llm, betaSession: request.betaSession, originalText: request.text) { resolved, usedRoute in
                self.pendingReviewedRequest = nil
                if Self.reviewNeedsRetry(resolved) {
                    self.unregisterEscape()
                    self.phase = .idle
                    if request.betaSession != nil, self.beta.pending?.sessionId == request.betaSession { self.beta.setBusy(nil) }
                    self.recordingBar.showResult(L10n.text("处理未完成，请重试或忽略。"), warning: true)
                    self.setHint(L10n.text("处理未完成，请重试或忽略。"), warning: true)
                    self.presentReviewedCandidate(request)
                    self.applyState()
                    self.updateIdleBar()
                    return
                }
                self.finishRequest(resolved, appBundleId: request.appBundleId, language: request.language, strength: request.strength,
                                   audioPath: nil, seconds: nil, field: request.field, insert: request.insert,
                                   llm: usedRoute ?? request.llm, variants: request.variants, betaSession: request.betaSession, translateTo: request.translateTo)
                }
            }
        }
    }

    static func reviewNeedsRetry(_ outcome: Result<DictateResponse, Error>) -> Bool {
        switch outcome {
        case .failure: return true
        case .success(let response):
            if response.qualityReview != nil { return false }
            return response.fallback || (!response.betaWaiting && response.insertableText.isEmpty)
        }
    }

    private lazy var advisor = ModelAdvisor(client: client)

    func finishRequest(_ outcome: Result<DictateResponse, Error>, appBundleId: String, language: String,
                       strength: String, audioPath: String?, seconds: Double?, field: FocusedField?, insert: Bool,
                       llm: LLMRoute? = nil, variants: String? = nil, copyResult: Bool = false,
                       betaSession: String? = nil, betaInfo: BetaInfo? = nil, translateTo: String? = nil, baseline: String? = nil,
                       reviewContext: Data? = nil, reviewProfile: String = "", reviewTranslatePrompt: String? = nil) {
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
            if let review = resp.qualityReview {
                // The pending history row has no text: neither the transcript nor
                // the model draft can be pasted through “paste last” before review.
                let keptAudio = audioPath.flatMap { Self.retainAudioForHistory($0, canPersist: HistoryStore.shared.persistenceProblem == nil) }
                var entry = LocalHistoryEntry(id: HistoryStore.newID(), ts: Date(), app: appBundleId,
                                              language: language, strength: strength, raw: "", text: "",
                                              fallback: true, fallbackReason: resp.fallbackReason ?? "fact-review", model: resp.model,
                                              msTotal: resp.ms?.total, audioPath: keptAudio, inserted: false, seconds: seconds)
                entry.task = resp.task
                entry.variants = variants
                entry.qualityReview = review
                HistoryStore.shared.add(entry)
                recordingBar.showResult(L10n.text("整理结果需要核对"), warning: true)
                setHint(L10n.text("请比较识别原文和整理结果，再选择要使用的内容。"), warning: true)
                quantityReview.show(review: review) { [weak self] choice in
                    guard let self else { return false }
                    guard self.phase == .idle else {
                        self.setHint(L10n.text("请先完成或取消当前操作。"), warning: true)
                        self.applyState()
                        return false
                    }
                    let original: Bool
                    let selected: String
                    switch choice {
                    case .original: original = true; selected = review.original
                    case .candidate(let edited): original = false; selected = edited
                    }
                    HistoryStore.shared.update(id: entry.id) {
                        $0.raw = review.original; $0.text = selected
                        $0.fallback = original; $0.fallbackReason = original ? (resp.fallbackReason ?? "fact-review") : nil
                        $0.qualityReview = nil
                    }
                    if insert {
                        let counts = DictationStats.countWords(selected)
                        ActivityLog.shared.record(words: counts.cjk + counts.latin)
                        self.insertText(selected, fallback: original, entryId: entry.id, appBundleId: appBundleId, field: field)
                    } else {
                        Inserter.shared.setString(selected)
                        self.recordingBar.showResult(selected, warning: original)
                        self.setHint(L10n.text("重试完成，结果已复制"))
                        self.applyState()
                    }
                    return true
                }
                applyState()
                return
            }
            if resp.noiseSuspected {
                let candidate = resp.noiseCandidate ?? ""
                let repeated = resp.fallbackReason == "recognition-repetition"
                if betaSession != nil, beta.pending?.sessionId == betaSession { beta.setBusy(nil) }
                // Respect the same encrypted history and recording-retention settings
                // as ordinary dictation. The result is explicitly marked uninserted.
                let retainedAudio = audioPath.flatMap { Self.retainAudioForHistory($0, canPersist: HistoryStore.shared.persistenceProblem == nil) }
                var entry = LocalHistoryEntry(id: HistoryStore.newID(), ts: Date(), app: appBundleId,
                                              language: language, strength: strength, raw: candidate, text: candidate,
                                              fallback: true, fallbackReason: resp.fallbackReason, model: resp.model,
                                              msTotal: resp.ms?.total, audioPath: retainedAudio, inserted: false,
                                              seconds: seconds)
                entry.task = resp.task
                entry.variants = variants
                entry.translated = translateTo
                HistoryStore.shared.add(entry)
                recordingBar.showResult(L10n.text("识别结果待查看，未自动输入"), warning: true)
                setHint(L10n.text("请查看识别原文，或忽略后重新说。"), warning: true)
                presentReviewedCandidate(ReviewedRequest(text: candidate, repeated: repeated, appBundleId: appBundleId,
                    language: language, strength: strength, field: field, insert: insert, llm: llm, variants: variants,
                    betaSession: betaSession, betaInfo: betaInfo, translateTo: translateTo, baseline: baseline,
                    context: reviewContext, profile: reviewProfile, translatePrompt: reviewTranslatePrompt))
                applyState()
                return
            }
            if let sessionId = resp.beta?.sessionId, let info = resp.beta {
                beta.accept(info: info, sessionId: sessionId, llm: llm, language: language,
                            variants: variants, appBundleId: appBundleId, field: field, copyResult: copyResult)
                recordingBar.hide()
                showBetaQuestions()
                setHint(L10n.text("提示词模式：继续补充或生成"))
                applyState()
                return
            }
            // The answer to Prompt Beta's questions: the prompt goes where the request was made.
            var appBundleId = appBundleId, field = field, insert = insert, copied = false
            if let pending = betaPending, strength == VoiceStrength.promptbeta.rawValue, resp.translated == nil {
                appBundleId = pending.appBundleId
                field = pending.field
                if pending.copyResult { insert = false; copied = true }
                beta.clear()
            }
            let text = resp.insertableText
            // A kept recording is sealed before its path goes into the history.
            let audioPath = audioPath.flatMap { Self.retainAudioForHistory($0, canPersist: HistoryStore.shared.persistenceProblem == nil) }
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
            // The end of 提示词模式: which of this app's models suits the finished prompt.
            if strength == VoiceStrength.promptbeta.rawValue, !text.isEmpty, !resp.fallback, resp.translated == nil,
               settings.recommendModel, let route = llm ?? settings.activeLLMRoute {
                advisor.recommend(task: text, appBundleId: appBundleId, field: field, route: route)
            }
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
                setHint(copied ? L10n.text("提示词已复制") : L10n.text("重试完成，结果已复制"))
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
        let text = Delivery.prepare(text, appBundleId: appBundleId, field: field)
        Delivery.deliver(text, appBundleId: appBundleId, field: field, onWaiting: { [weak self] _ in
            guard let self else { return }
            self.recordingBar.showResult(L10n.text("回到原来的位置后自动放入"), warning: false)
            self.setHint(L10n.text("文字已整理好，回到开始听写的位置后会自动放入。"))
            self.applyState()
        }) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .pasted(let result):
                self.setHint(result == .pasted ? (fallback ? self.hint : nil) : result.message, warning: !result.ok)
                self.recordingBar.showResult(text, warning: !result.ok || fallback)
                if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = result.ok } }
                self.applyState()
            case .appChanged:
                self.notPasted(entryId, L10n.text("没有回到原应用"), L10n.text("等了一会儿没有回到原来的应用，未粘贴。"))
            case .fieldLost:
                self.notPasted(entryId, L10n.text("没有回到原输入框"), L10n.text("等了一会儿没有回到原来的输入框，未粘贴。"))
            case .superseded:
                if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = false } }
            }
        }
    }

    /// Nothing was pasted: say why, and how to paste it from History.
    private func notPasted(_ entryId: String?, _ short: String, _ long: String) {
        if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = false } }
        let paste = settings.hotkeyPasteLast
        let key = paste.enabled ? HotKeyCentre.describe(keyCode: paste.keyCode, modifiers: paste.modifiers) : ""
        recordingBar.showResult(short + (key.isEmpty ? L10n.text("，未粘贴 · 见历史") : L10n.text("，未粘贴 · 按 ") + key + L10n.text(" 贴到这里")),
                                warning: true)
        setHint(long + (key.isEmpty ? L10n.text("文字在历史里。") : L10n.text("按 ") + key + L10n.text(" 贴到这里。历史里也有。")),
                warning: true)
        applyState()
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

    static func hasText(_ text: String?) -> Bool {
        !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The onboarding's sample: a prompt starts 提示词模式 as its draft, with nothing said yet.
    /// There is no field to paste into, so the finished prompt is copied.
    func startBreakdown(_ text: String, appBundleId: String) {
        guard phase == .idle else { NSSound.beep(); return }
        guard let route = settings.activeLLMRoute else { setHint(L10n.text("请先配置可用的整理模型。"), warning: true); applyState(); return }
        if betaPending != nil { beta.cancel() }
        sendBetaText(text, session: nil, source: "selection", appBundleId: appBundleId, route: route, language: settings.language,
                     variants: settings.variantsHeader, copyResult: true)
    }

    /// A typed or chosen answer to the open questions (the quick choices in the panel).
    func answerBeta(_ text: String) {
        guard phase == .idle, let pending = betaPending else { return }
        beta.setBusy(L10n.text("正在更新…"))
        sendBetaText(text, session: pending.sessionId, source: nil, appBundleId: pending.appBundleId, route: pending.llm, language: pending.language, variants: pending.variants)
    }

    private func sendBetaText(_ text: String, session: String?, source: String?, appBundleId: String, route: LLMRoute?, language: String,
                              variants: String?, copyResult: Bool = false) {
        phase = .thinking
        registerEscape()
        recordingBar.showThinking(detail: "")
        applyState()
        let strength = VoiceStrength.promptbeta.rawValue
        let generation = UUID(); progressID = generation
        let canFailOver = route != nil && settings.hasConfiguredBackupProviders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result { try self.client.polishSync(text: text, language: language, strength: strength, llm: route, translateTo: nil, variants: variants,
                                                              betaSession: session, source: source, hasConfiguredBackups: canFailOver) }
            DispatchQueue.main.async {
                guard self.progressID == generation else { return }
                self.withBackupIfNeeded(outcome, generation: generation, language: language, strength: strength,
                    translateTo: nil, variants: variants, profile: "", context: nil, baseline: nil,
                    appBundleId: appBundleId, translatePrompt: nil, currentRoute: route, betaSession: session,
                    source: source, originalText: text) { resolved, usedRoute in
                    self.finishRequest(resolved, appBundleId: appBundleId, language: language, strength: strength, audioPath: nil, seconds: nil,
                                       field: nil, insert: false, llm: usedRoute ?? route, variants: variants, copyResult: copyResult)
                }
            }
        }
    }

    func showBetaQuestions() {
        beta.show(hotkey: assistantKeyLabel)
    }

    /// 生成: write the prompt now, with the chosen answers not sent yet; unanswered points stay unconfirmed.
    func finishBetaWithoutAnswers(answer: String? = nil) {
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
        let canFailOver = llm != nil && settings.hasConfiguredBackupProviders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result { try self.client.betaSync(sessionId: pending.sessionId, skip: true,
                                                            appBundleId: pending.appBundleId, llm: llm,
                                                            variants: variants, answer: answer, hasConfiguredBackups: canFailOver) }
            DispatchQueue.main.async {
                guard self.progressID == generation else { return }
                self.withBackupIfNeeded(outcome, generation: generation, language: language, strength: VoiceStrength.promptbeta.rawValue,
                    translateTo: nil, variants: variants, profile: "", context: nil, baseline: nil,
                    appBundleId: pending.appBundleId, translatePrompt: nil, currentRoute: llm, betaSession: pending.sessionId,
                    originalText: answer ?? "", betaSkip: true) { resolved, usedRoute in
                self.finishRequest(resolved, appBundleId: pending.appBundleId, language: language,
                                   strength: VoiceStrength.promptbeta.rawValue, audioPath: nil, seconds: nil,
                                   field: pending.field, insert: true, llm: usedRoute ?? llm, variants: variants)
                }
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

    // MARK: 翻译 of selected text

    /// 翻译's key with text selected: the selection is translated and replaces itself; nothing is recorded.
    func translateSelection(_ field: FocusedField, to target: String) {
        guard phase == .idle else { NSSound.beep(); return }
        guard let route = settings.activeLLMRoute else { setHint(L10n.text("请先配置可用的整理模型。"), warning: true); applyState(); return }
        cancelToast.finish()
        phase = .thinking
        registerEscape()
        idleBar.hide()
        recordingBar.showThinking(detail: L10n.text("正在翻译…") + "  " + SelectionTranslator.sourceCountLabel(field.selection))
        applyState()
        let text = field.selection, language = settings.language, variants = settings.variantsHeader
        let profile = HistoryStore.shared.profile
        let generation = UUID(); progressID = generation
        let ownPrompt = settings.customTranslatePrompt
        let canFailOver = settings.hasConfiguredBackupProviders
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result { try self.client.polishSync(text: text, language: language, strength: "prompt", llm: route,
                                                              translateTo: target, variants: variants, profile: profile, translatePrompt: ownPrompt, hasConfiguredBackups: canFailOver) }
            DispatchQueue.main.async {
                guard self.progressID == generation else { return }
                self.withBackupIfNeeded(outcome, generation: generation, language: language, strength: "prompt",
                    translateTo: target, variants: variants, profile: profile, context: nil, baseline: nil,
                    appBundleId: field.bundleId, translatePrompt: ownPrompt, currentRoute: route, originalText: text) { resolved, usedRoute in
                    self.finishRequest(resolved, appBundleId: field.bundleId, language: language, strength: "prompt", audioPath: nil,
                                       seconds: nil, field: field, insert: true, llm: usedRoute ?? route, variants: variants)
                }
            }
        }
    }
}

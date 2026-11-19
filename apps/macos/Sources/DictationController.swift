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

    private(set) var phase: AppPhase = .idle {
        didSet {
            model.phase = phase
            if phase == .idle, model.retryingHistoryID != nil { model.retryingHistoryID = nil }
        }
    }
    private(set) var recordingStartedAt: Date?
    private var pendingAppBundleId = ""
    private var pendingField: FocusedField?
    private var progressID = UUID()
    private var captureTake: RecordingBar.Take?
    private var captureRequest: UUID?
    private var heldShortcut = false
    private var onlineASRTask: Task<Void, Never>?
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
    private let translationPanel = SelectionPanel(allowsTextFocus: true)

    struct TranslationPreview {
        let target: String
        let anchor: NSRect

        static func selected(_ field: FocusedField, to target: String) -> Self {
            let anchor = FieldContextReader.caretRect(field) ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
            return Self(target: target, anchor: anchor)
        }

        static func result(_ outcome: Result<DictateResponse, Error>) -> SelectionBubble {
            switch outcome {
            case .success(let response):
                if !response.fallback, DictationController.hasText(response.insertableText) {
                    return .done(response.insertableText)
                }
                let message = response.fallback
                    ? ServiceError.translationFailed(reason: response.fallbackReason).description
                    : L10n.text("没有识别到内容")
                return .failed(message, partial: response.translationProgress?.text)
            case .failure(let error):
                let serviceError = error as? ServiceError
                if case .translationIncomplete(let partial)? = serviceError {
                    return .failed(serviceError?.description ?? L10n.text("翻译失败"), partial: partial.text)
                }
                return .failed(serviceError?.description ?? L10n.text("翻译失败"), partial: nil)
            }
        }
    }

    private func showTranslation(_ state: SelectionBubble, preview: TranslationPreview, whileRunning generation: UUID? = nil) {
        translationPanel.showBubble(state, target: preview.target, at: preview.anchor, title: SelectionTranslator.featureName, retry: nil) {
            [weak self] in
            guard let self else { return }
            self.translationPanel.hide()
            if self.progressID == generation, self.phase == .thinking { self.cancelDictation() }
        }
    }

    private var tickTimer: Timer?
    private var lastTickedSecond = -1
    private var lastMicrophoneActivityAt: Date?
    private var lastMicrophoneName = ""
    private static let microphoneReminderInterval: TimeInterval = 5 * 60

    func toggleDictation() { toggleDictation(translateTo: nil) }

    func toggleAssistant() { toggleDictation(translateTo:nil,assistant:true) }

    /// `translateTo` only matters when this starts a recording (翻译模式's own hotkey).
    func toggleDictation(translateTo: String?, assistant: Bool = false) {
        switch phase {
        case .idle:
            pendingAssistant = assistant
            pendingTranslate = translateTo
            if translateTo != nil { translationPanel.hide() }
            startRecording()
        case .starting: cancelDictation()
        case .recording: stopRecording()
        case .thinking: NSSound.beep()
        }
    }

    /// The key that answers 提示词模式's questions, as shown to the user.
    private var assistantKeyLabel: String {
        model.assistantLabel.isEmpty ? L10n.text("继续补充按钮") : model.assistantLabel
    }

    @discardableResult
    func startHeldShortcut() -> Bool {
        guard phase == .idle, captureRequest == nil else { return false }
        pendingAssistant = false
        pendingTranslate = nil
        heldShortcut = true
        startRecording()
        return true
    }

    func endHeldShortcut() {
        guard heldShortcut else { return }
        heldShortcut = false
        captureRequest = nil
        if phase == .starting { cancelDictation() }
        else if phase == .recording { stopRecording() }
    }

    func startRecording() {
        guard phase == .idle else { return }
        if recorder.demoPCM != nil {
            beginCapture()   // demo input: no microphone involved
            return
        }
        switch Recorder.authorizationStatus() {
        case .notDetermined:
            guard captureRequest == nil else { return }
            let request = UUID()
            captureRequest = request
            Recorder.requestMicrophoneAccess { [weak self] granted in
                guard let self, self.captureRequest == request else { return }
                self.captureRequest = nil
                self.model.refreshPermissions()
                if granted {
                    self.beginCapture()
                } else {
                    self.heldShortcut = false
                    self.setHint(L10n.text("录音需要麦克风权限"), warning: true)
                    self.applyState()
                }
            }
        case .denied, .restricted:
            heldShortcut = false
            setHint(L10n.text("麦克风权限被拒绝，请在设置里打开"), warning: true)
            applyState()
            host.showSettings()
        default:
            beginCapture()
        }
    }

    func beginCapture() {
        guard phase == .idle else { return }
        progressID = UUID()
        copiedSelection = nil
        cancelToast.finish()
        // Text still waiting for the user to come back stays in History.
        Delivery.cancelWaiting()
        // Contract: frontmost bundle id is captured BEFORE recording starts.
        pendingAppBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        pendingField = nil
        let inputUID = settings.inputDeviceUID
        recorder.prepareEngine = { engine in
            AudioInputSelector.apply(deviceID: AudioDevices.deviceID(forUID: inputUID), to: engine)
        }
        recorder.maxSeconds = max(5, min(600, settings.maxSeconds))
        phase = .starting
        idleBar.hide()
        let take = recordingBar.begin(handsFree: !heldShortcut)
        captureTake = take
        recorder.onAutoStop = { [weak self, weak take] in
            guard let self, let take, self.captureTake === take else { return }
            self.stopRecording(auto: true)
        }
        registerEscape()
        applyState()
        let token = progressID
        let openingAt = ProcessInfo.processInfo.systemUptime
        recorder.startAsync { [weak self] result in
            guard let self, self.phase == .starting, self.progressID == token else { return }
            let elapsed = String(Int((ProcessInfo.processInfo.systemUptime - openingAt) * 1000))
            switch result {
            case .success:
                DiagnosticsLog.write("recording.device-ready", ["ms": elapsed])
                self.captureDidStart(take)
            case .failure(let error):
                DiagnosticsLog.write("recording.device-failed", ["ms": elapsed])
                self.phase = .idle
                self.pendingAssistant = false
                self.pendingTranslate = nil
                self.unregisterEscape()
                self.captureTake = nil
                self.heldShortcut = false
                take.cancel()
                self.setHint((error as? RecorderError)?.description ?? error.localizedDescription, warning: true)
                self.applyState()
                self.updateIdleBar()
            }
        }
    }

    private func captureDidStart(_ take: RecordingBar.Take) {
        phase = .recording
        // An answer to Prompt Beta: the questions stay visible so the user can answer them one by one.
        if pendingAssistant && betaPending != nil { beta.setBusy(L10n.text("正在听。说完按 {0}。", assistantKeyLabel)) }
        recordingStartedAt = recorder.startedAt ?? Date()
        idleBar.hide()
        recordingBar.limitSeconds = Double(recorder.maxSeconds)
        let now = Date()
        let microphone = recorder.microphoneName
        let remindMicrophone = lastMicrophoneActivityAt.map { now.timeIntervalSince($0) >= Self.microphoneReminderInterval } ?? true
        take.recording(destination: pendingAppBundleId,
                       badge: pendingTranslate.map { L10n.text("翻译") + " →" + $0.uppercased() }
                           ?? (pendingAssistant ? L10n.text("提示词模式") : ""))
        if !microphone.isEmpty, remindMicrophone || microphone != lastMicrophoneName {
            recordingBar.showMicrophoneHint(microphone)
        }
        lastMicrophoneName = microphone
        lastMicrophoneActivityAt = now
        let localServiceNeeded = settings.onlineASRProvider == .local && !serviceUp
        setHint(localServiceNeeded ? (model.serviceProblem.isEmpty ? L10n.text("本地服务未就绪") : model.serviceProblem) : nil,
                warning: localServiceNeeded)
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
                    guard let self, self.phase == .recording, self.captureTake === take else { return }
                    self.pendingField = field
                    // Text selected when 提示词模式 starts is the draft the user is about to revise.
                    guard self.pendingAssistant, self.betaPending == nil else { return }
                    if Self.hasText(field?.selection) {
                        take.badge(L10n.text("提示词模式 · 修改选中内容"))
                    } else if Inserter.readsSelectionByCopy(bundle) {
                        Inserter.shared.copySelection { [weak self] text in
                            guard let self, self.phase == .recording, self.pendingAssistant, self.captureTake === take,
                                  Self.hasText(text) else { return }
                            self.copiedSelection = text.map { String($0.prefix(FieldContextReader.selectionLimit)) }
                            take.badge(L10n.text("提示词模式 · 修改选中内容"))
                        }
                    }
                }
            }
        }
    }

    func stopRecording(auto: Bool = false) {
        guard phase == .recording else { return }
        let take = captureTake
        heldShortcut = false
        lastMicrophoneActivityAt = Date()
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
        let translateTo = pendingTranslate
        let keep = keepsRecording(forTranslationTo: translateTo)
        pendingTranslate = nil
        // A recording made while Prompt Beta's questions are open is the answer to them;
        // a translation is not, and leaves the questions waiting.
        let betaSession = translateTo == nil && strength == VoiceStrength.promptbeta.rawValue ? betaPending?.sessionId : nil
        if betaSession != nil { beta.setBusy(L10n.text("正在更新…")) }
        do {
            let r = try recorder.finish()
            playSound(start: false)
            phase = .thinking
            take?.processing()
            setHint(auto ? L10n.text("已到 {0} 秒上限 · thinking", recorder.maxSeconds) : nil)
            applyState()
            sendToServer(audioURL: r.url, appBundleId: app, language: language, strength: strength,
                         keepAudioPath: keep ? r.url.path : nil, seconds: r.seconds, field: field,
                         insert: true, deleteWhenDone: !keep, betaSession: betaSession, translateTo: translateTo,
                         baseline: baseline, take: take)
        } catch {
            playSound(start: false)
            phase = .idle
            recordingStartedAt = nil
            captureTake = nil
            take?.cancel()
            let msg = (error as? RecorderError)?.description ?? error.localizedDescription
            if betaPending != nil { showBetaQuestions() }
            setHint(msg, warning: true)
            applyState()
            updateIdleBar()
        }
    }

    func cancelDictation() {
        heldShortcut = false
        captureRequest = nil
        let take = captureTake
        captureTake = nil
        switch phase {
        case .starting:
            progressID = UUID()
            recorder.cancel()
            unregisterEscape()
            phase = .idle
            pendingAssistant = false
            pendingTranslate = nil
            pendingField = nil
            take?.cancel()
            setHint(nil)
            applyState()
            updateIdleBar()
        case .recording:
            lastMicrophoneActivityAt = Date()
            unregisterEscape()
            stopTick()
            // A dictation can be taken back for a few seconds; an assistant answer cannot.
            if !pendingAssistant, let r = try? recorder.finish() {
                heldRecording = (r.url, r.seconds, pendingAppBundleId, pendingField, settings.recognitionLanguage(for: model.speech?.modelId),
                                 keepsRecording(forTranslationTo: pendingTranslate), pendingTranslate)
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
            take?.cancel()
            pendingTranslate = nil
            if betaPending != nil { showBetaQuestions() }
            applyState()
            updateIdleBar()
        case .thinking:
            progressID = UUID()
            onlineASRTask?.cancel()
            onlineASRTask = nil
            client.cancelGeneration()
            translationPanel.hide()
            unregisterEscape(); stopTick()
            if let take { take.cancel() } else { recordingBar.hide() }
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

    private func keepsRecording(forTranslationTo target: String?) -> Bool {
        target == nil && settings.keepAudio24h && settings.historyRetention.seconds != 0
    }

    static func keepsHistory(translateTo target: String?, response: DictateResponse) -> Bool {
        target == nil && response.translated == nil && response.task != "translation"
    }

    func sendToServer(audioURL: URL, appBundleId: String, language: String, strength: String,
                      keepAudioPath: String?, seconds: Double?, field: FocusedField?,
                      insert: Bool, deleteWhenDone: Bool = false, betaSession: String? = nil,
                      translateTo: String? = nil, baseline: String? = nil, take: RecordingBar.Take? = nil) {
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
        let asrProvider = settings.onlineASRProvider
        let usesOnlineASR = asrProvider != .local
        let progressID = UUID(); self.progressID = progressID
        let complete: (Result<DictateResponse, Error>) -> Void = { [weak self] outcome in
            if deleteWhenDone { try? FileManager.default.removeItem(at: audioURL) }
            DispatchQueue.main.async {
                guard let self, self.progressID == progressID else {
                    if let path = keepAudioPath, !path.hasSuffix(".sealed") {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                    return
                }
                self.onlineASRTask = nil
                self.withBackupIfNeeded(outcome, generation: progressID, language: effectiveLanguage, strength: strength,
                                        translateTo: translateTo, variants: variants, profile: profile, context: context,
                                        baseline: baseline, appBundleId: appBundleId, translatePrompt: ownPrompt,
                                        currentRoute: llm, betaSession: betaSession) { resolved, usedRoute in
                self.finishRequest(resolved, appBundleId: appBundleId, language: effectiveLanguage, strength: strength,
                                   audioPath: keepAudioPath, seconds: seconds, field: field, insert: insert, llm: usedRoute ?? llm, variants: variants,
                                   betaSession: betaSession, betaInfo: previousBeta?.info, translateTo: translateTo, baseline: baseline,
                                   reviewContext: context, reviewProfile: profile, reviewTranslatePrompt: ownPrompt,
                                   usesOnlineASR: usesOnlineASR, take: take)
                }
            }
        }
        let readAudio = {
            let data = try HistorySeal.readAudio(audioURL)
            guard data.count <= Wav.maxBytes else { throw ServiceError.transport(L10n.text("录音超过 24 MiB")) }
            return data
        }
        let client = self.client
        if usesOnlineASR {
            let workspaceID = settings.funASRWorkspaceID
            let ticket = client.generationTicket()
            recordingBar.showThinking(detail: L10n.text("正在识别…"))
            onlineASRTask = Task.detached(priority: .userInitiated) {
                do {
                    let apiKey = KeychainStore.read(account: asrProvider.keychainAccount) ?? ""
                    try Task.checkCancellation()
                    let configuration = OnlineASRConfiguration(provider: asrProvider, apiKey: apiKey, workspaceID: workspaceID)
                    let spoken = try await OnlineASR.transcribe(wav: readAudio(), language: effectiveLanguage, configuration: configuration)
                    try Task.checkCancellation()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let outcome = Result {
                            do {
                                var response = try client.polishSync(text: spoken, language: effectiveLanguage, strength: strength,
                                    llm: llm, translateTo: translateTo, variants: variants, profile: profile,
                                    fieldContext: context, betaSession: betaSession, translatePrompt: ownPrompt, baseline: baseline,
                                    appHint: appBundleId, generationTicket: ticket, hasConfiguredBackups: canFailOver)
                                if response.model == nil { response.model = asrProvider.label }
                                return response
                            } catch let error as ServiceError
                                      where error.serviceUnavailable && translateTo == nil && strength != VoiceStrength.promptbeta.rawValue {
                                var response = DictateResponse(text: spoken, raw: spoken, fallback: true)
                                response.task = "dictation"
                                response.model = asrProvider.label
                                response.fallbackReason = "local-service-unavailable"
                                return response
                            }
                        }
                        complete(outcome)
                    }
                } catch {
                    complete(.failure(error))
                }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                complete(Result {
                    try client.dictateSync(wav: readAudio(), language: effectiveLanguage, appBundleId: appBundleId,
                        strength: strength, fieldContext: context, llm: llm, betaSession: betaSession,
                        translateTo: translateTo, variants: variants, profile: profile, baseline: baseline,
                        translatePrompt: ownPrompt, hasConfiguredBackups: canFailOver, onProgress: { progress in
                            DispatchQueue.main.async {
                                guard let self, self.phase == .thinking, self.progressID == progressID else { return }
                                self.recordingBar.showThinking(detail: progress.label)
                            }
                        })
                })
            }
        }
    }

    /// The first route was unavailable. Only now read the previously configured backup keys.
    private func withBackupIfNeeded(_ outcome: Result<DictateResponse, Error>, generation: UUID,
                                    language: String, strength: String, translateTo: String?, variants: String?,
                                    profile: String, context: Data?, baseline: String?, appBundleId: String,
                                    translatePrompt: String?, currentRoute: LLMRoute?, betaSession: String? = nil,
                                    source: String? = nil, originalText: String? = nil, betaSkip: Bool = false,
                                    showsCapsule: Bool = true,
                                    completion: @escaping (Result<DictateResponse, Error>, LLMRoute?) -> Void) {
        guard case .success(let response) = outcome, response.offerFailover else { completion(outcome, nil); return }
        let isAssistant = strength == VoiceStrength.promptbeta.rawValue
        let retrySession = isAssistant ? (response.beta?.sessionId ?? betaSession) : nil
        let text = originalText ?? response.raw
        guard isAssistant ? retrySession != nil : !text.isEmpty else { completion(outcome, nil); return }
        let routes = settings.backupLLMRoutes(excluding: currentRoute)
        guard progressID == generation else { return }
        guard let first = routes.first else { completion(outcome, nil); return }
        if showsCapsule { recordingBar.showThinking(detail: L10n.text("正在切换备用模型…")) }
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
        let preview: TranslationPreview?
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
                                   llm: usedRoute ?? request.llm, variants: request.variants, betaSession: request.betaSession,
                                   translateTo: request.translateTo, preview: request.preview)
                }
            }
        }
    }

    func reviewHistoryEntry(id: String) {
        guard let entry = HistoryStore.shared.entries.first(where: { $0.id == id }), let review = entry.qualityReview else { return }
        presentQualityReview(entry, review: review, historyID: entry.id, insert: false, field: nil, showsCapsule: false)
    }

    private func presentQualityReview(_ entry: LocalHistoryEntry, review: QualityReview, historyID: String?, insert: Bool,
                                      field: FocusedField?, showsCapsule: Bool, preview: TranslationPreview? = nil) {
        quantityReview.show(id: entry.id, review: review, copiesResult: !insert, isTranslation: entry.task == "translation",
                            showsPreview: preview != nil) { [weak self] choice in
            guard let self else { return false }
            guard self.phase == .idle else {
                self.setHint(L10n.text("请先完成或取消当前操作。"), warning: true)
                self.applyState()
                return false
            }
            let isOriginal: Bool
            let selected: String
            switch choice {
            case .original: isOriginal = true; selected = review.original
            case .candidate(let edited): isOriginal = false; selected = edited
            }
            if let historyID {
                HistoryStore.shared.update(id: historyID) {
                    $0.raw = review.original; $0.text = selected
                    $0.fallback = isOriginal; $0.fallbackReason = isOriginal ? entry.fallbackReason : nil
                    $0.qualityReview = nil
                }
            }
            if let preview {
                let state: SelectionBubble = isOriginal ? .failed(L10n.text("原始识别"), partial: selected) : .done(selected)
                self.showTranslation(state, preview: preview)
                self.setHint(nil)
                self.applyState()
            } else if insert {
                let counts = DictationStats.countWords(selected)
                ActivityLog.shared.record(words: counts.cjk + counts.latin, seconds: entry.seconds,
                                          typingSeconds: Double(counts.cjk) + Double(counts.latin) * 1.5)
                self.insertText(selected, fallback: isOriginal, entryId: historyID,
                                appBundleId: entry.app ?? "", field: field, showsCapsule: showsCapsule,
                                offersHistoryRecovery: historyID != nil)
            } else {
                Inserter.shared.setString(selected)
                self.setHint(L10n.text("结果已复制"))
                self.applyState()
            }
            return true
        }
    }

    static func reviewNeedsRetry(_ outcome: Result<DictateResponse, Error>) -> Bool {
        switch outcome {
        case .failure: return true
        case .success(let response):
            if response.qualityReview != nil { return false }
            if response.fallbackReason == "fact-check-unavailable", !response.insertableText.isEmpty { return false }
            return response.fallback || (!response.betaWaiting && response.insertableText.isEmpty)
        }
    }

    private lazy var advisor = ModelAdvisor(client: client)

    func finishRequest(_ outcome: Result<DictateResponse, Error>, appBundleId: String, language: String,
                       strength: String, audioPath: String?, seconds: Double?, field: FocusedField?, insert: Bool,
                       llm: LLMRoute? = nil, variants: String? = nil, copyResult: Bool = false,
                       betaSession: String? = nil, betaInfo: BetaInfo? = nil, translateTo: String? = nil, baseline: String? = nil,
                       reviewContext: Data? = nil, reviewProfile: String = "", reviewTranslatePrompt: String? = nil,
                       usesOnlineASR: Bool = false, take: RecordingBar.Take? = nil, preview: TranslationPreview? = nil) {
        let insert = insert && preview == nil
        unregisterEscape()
        captureTake = nil
        let generation = progressID
        let showRequestResult: (String, Bool) -> Void = { [weak self] text, warning in
            guard let self, preview == nil, take == nil, self.progressID == generation, self.phase == .idle else { return }
            self.recordingBar.showResult(text, warning: warning)
        }
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
            let keepsHistory = Self.keepsHistory(translateTo: translateTo ?? preview?.target, response: resp)
            func saveToHistory(_ entry: LocalHistoryEntry) -> String? {
                guard keepsHistory else { return nil }
                var entry = entry
                let history = HistoryStore.shared
                entry.audioPath = audioPath.flatMap { Self.retainAudioForHistory($0, canPersist: history.persistenceProblem == nil) }
                history.add(entry)
                return entry.id
            }
            if resp.insertableText.isEmpty && resp.beta == nil && resp.qualityReview == nil && !resp.noiseSuspected {
                take?.cancel()
            } else if resp.qualityReview == nil {
                take?.done()
            }
            if !usesOnlineASR {
                serviceUp = true
                model.serviceProblem = ""
            }
            if let review = resp.qualityReview {
                if preview != nil { translationPanel.hide() }
                // The pending history row has no text: neither the transcript nor
                // the model draft can be pasted through “paste last” before review.
                var entry = LocalHistoryEntry(id: HistoryStore.newID(), ts: Date(), app: appBundleId,
                                              language: language, strength: strength, raw: "", text: "",
                                              fallback: true, fallbackReason: resp.fallbackReason ?? "fact-review", model: resp.model,
                                              msTotal: resp.ms?.total, audioPath: nil, inserted: false, seconds: seconds)
                entry.task = keepsHistory ? resp.task : "translation"
                entry.variants = variants
                entry.qualityReview = review
                let historyID = saveToHistory(entry)
                let notice = L10n.text("整理结果需要核对")
                if let take { take.needsReview(notice) }
                else if preview == nil { recordingBar.showResult(notice, warning: true, requiresReview: true) }
                setHint(notice, warning: true)
                presentQualityReview(entry, review: review, historyID: historyID, insert: insert, field: field,
                                     showsCapsule: take == nil, preview: preview)
                applyState()
                return
            }
            if resp.noiseSuspected {
                if preview != nil { translationPanel.hide() }
                let candidate = resp.noiseCandidate ?? ""
                let repeated = resp.fallbackReason == "recognition-repetition"
                if betaSession != nil, beta.pending?.sessionId == betaSession { beta.setBusy(nil) }
                // A saved recognition candidate is explicitly marked uninserted.
                var entry = LocalHistoryEntry(id: HistoryStore.newID(), ts: Date(), app: appBundleId,
                                              language: language, strength: strength, raw: candidate, text: candidate,
                                              fallback: true, fallbackReason: resp.fallbackReason, model: resp.model,
                                              msTotal: resp.ms?.total, audioPath: nil, inserted: false,
                                              seconds: seconds)
                entry.task = resp.task
                entry.variants = variants
                entry.translated = translateTo
                _ = saveToHistory(entry)
                showRequestResult(L10n.text("识别结果待查看，未自动输入"), true)
                setHint(L10n.text("请查看识别原文，或忽略后重新说。"), warning: true)
                presentReviewedCandidate(ReviewedRequest(text: candidate, repeated: repeated, appBundleId: appBundleId,
                    language: language, strength: strength, field: field, insert: insert, llm: llm, variants: variants,
                    betaSession: betaSession, betaInfo: betaInfo, translateTo: translateTo, baseline: baseline,
                    context: reviewContext, profile: reviewProfile, translatePrompt: reviewTranslatePrompt, preview: preview))
                applyState()
                return
            }
            if let sessionId = resp.beta?.sessionId, let info = resp.beta {
                beta.accept(info: info, sessionId: sessionId, llm: llm, language: language,
                            variants: variants, appBundleId: appBundleId, field: field, copyResult: copyResult)
                if take == nil { recordingBar.hide() }
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
            var entry = LocalHistoryEntry(id: HistoryStore.newID(), ts: Date(), app: appBundleId,
                                          language: language, strength: strength,
                                          raw: resp.raw, text: text, fallback: resp.fallback,
                                          fallbackReason: resp.fallbackReason, model: resp.model,
                                          msTotal: resp.ms?.total, audioPath: nil, inserted: false,
                                          seconds: seconds)
            entry.model = resp.model ?? resp.provider
            entry.translated = resp.translated
            entry.corrections = resp.corrections
            entry.intention = resp.intention
            entry.variants = variants
            entry.task = resp.task
            let historyID = saveToHistory(entry)
            if let preview {
                let state = TranslationPreview.result(outcome)
                if case .failed(let message, _) = state {
                    setHint(message, warning: true)
                } else {
                    setHint(nil)
                }
                showTranslation(state, preview: preview)
                applyState()
                return
            }
            // The end of 提示词模式: which of this app's models suits the finished prompt.
            if strength == VoiceStrength.promptbeta.rawValue, !text.isEmpty, !resp.fallback, resp.translated == nil,
               settings.recommendModel, let route = llm ?? settings.activeLLMRoute {
                advisor.recommend(task: text, appBundleId: appBundleId, field: field, route: route)
            }
            if text.isEmpty {
                showRequestResult(L10n.text("没有识别到内容"), true)
                setHint(L10n.text("没有识别到内容"), warning: true)
                applyState()
                return
            }
            let failedHint: String
            if resp.fallbackReason == "fact-check-unavailable" {
                failedHint = L10n.text("未能核对整理结果，已使用原文。")
            } else {
                failedHint = resp.translated != nil ? L10n.text("翻译失败，已插入原文。") : L10n.text("已用原文（整理失败）")
            }
            setHint(resp.fallback ? failedHint : nil, warning: resp.fallback)
            if insert {
                let counts = DictationStats.countWords(text)
                ActivityLog.shared.record(words: counts.cjk + counts.latin, seconds: seconds,
                                          typingSeconds: Double(counts.cjk) + Double(counts.latin) * 1.5)
                insertText(text, fallback: resp.fallback, entryId: historyID, appBundleId: appBundleId, field: field,
                           showsCapsule: take == nil, offersHistoryRecovery: keepsHistory)
            } else {
                Inserter.shared.setString(text)
                showRequestResult(text, resp.fallback)
                setHint(copied ? L10n.text("提示词已复制") : L10n.text("重试完成，结果已复制"))
                applyState()
            }
        case .failure(let error):
            take?.cancel()
            if let preview { showTranslation(TranslationPreview.result(outcome), preview: preview) }
            let d = error as? ServiceError
            if case .http(410, _, _)? = d, betaPending != nil {
                dropBeta(notify: false)
                showRequestResult(L10n.text("问题已过期，请重新说需求"), true)
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
            showRequestResult(usesOnlineASR || serviceUp ? L10n.text("听写失败") : L10n.text("本地服务未就绪"), true)
            if betaPending != nil { showBetaQuestions() }
            setHint(L10n.text("听写失败：") + (d?.description ?? error.localizedDescription), warning: true)
            applyState()
        }
    }

    // MARK: insertion

    func insertText(_ text: String, fallback: Bool, entryId: String?, appBundleId: String, field: FocusedField?,
                    showsCapsule: Bool = true, offersHistoryRecovery: Bool = true) {
        let generation = progressID
        let text = Delivery.prepare(text, appBundleId: appBundleId, field: field)
        Delivery.deliver(text, appBundleId: appBundleId, field: field, onWaiting: { [weak self] _ in
            guard let self, self.progressID == generation, self.phase == .idle else { return }
            if showsCapsule { self.recordingBar.showResult(L10n.text("回到原来的位置后自动放入"), warning: false) }
            self.setHint(L10n.text("文字已整理好，回到开始听写的位置后会自动放入。"))
            self.applyState()
        }) { [weak self] outcome in
            guard let self = self else { return }
            if case .pasted(let result) = outcome, let id = entryId {
                HistoryStore.shared.update(id: id) { $0.inserted = result.ok }
            }
            guard self.progressID == generation, self.phase == .idle else { return }
            switch outcome {
            case .pasted(let result):
                self.setHint(result == .pasted ? (fallback ? self.hint : nil) : result.message, warning: !result.ok)
                if showsCapsule { self.recordingBar.showResult(text, warning: !result.ok || fallback) }
                self.applyState()
            case .appChanged:
                self.notPasted(entryId, L10n.text("没有回到原应用"), L10n.text("等了一会儿没有回到原来的应用，未粘贴。"),
                               showsCapsule: showsCapsule, offersHistoryRecovery: offersHistoryRecovery)
            case .fieldLost:
                self.notPasted(entryId, L10n.text("没有回到原输入框"), L10n.text("等了一会儿没有回到原来的输入框，未粘贴。"),
                               showsCapsule: showsCapsule, offersHistoryRecovery: offersHistoryRecovery)
            case .superseded:
                if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = false } }
            }
        }
    }

    /// Nothing was pasted: say why, and how to paste it from History.
    private func notPasted(_ entryId: String?, _ short: String, _ long: String, showsCapsule: Bool, offersHistoryRecovery: Bool) {
        if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = false } }
        guard offersHistoryRecovery else {
            if showsCapsule { recordingBar.showResult(short, warning: true) }
            setHint(long, warning: true)
            applyState()
            return
        }
        let paste = settings.hotkeyPasteLast
        let key = paste.enabled ? HotKeyCentre.describe(keyCode: paste.keyCode, modifiers: paste.modifiers) : ""
        if showsCapsule {
            recordingBar.showResult(short + (key.isEmpty ? L10n.text("，未粘贴 · 见历史") : L10n.text("，未粘贴 · 按 ") + key + L10n.text(" 贴到这里")),
                                    warning: true)
        }
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
        let take = captureTake
        let timer = Timer(timeInterval: VoiceCaptureMeter.interval, repeats: true) { [weak self] _ in
            guard let self, self.phase == .recording, self.captureTake === take else { return }
            take?.level(self.recorder.voiceLevel(), elapsed: self.recorder.elapsed)
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

    /// The shortcut translates only the selection and shows the result beside it.
    func translateSelection(_ field: FocusedField, to target: String) {
        guard phase == .idle else { NSSound.beep(); return }
        let preview = TranslationPreview.selected(field, to: target)
        translationPanel.hide()
        let text = field.selection
        idleBar.hide()
        recordingBar.flashSelectionCount(for: text)
        guard let route = settings.activeLLMRoute else {
            showTranslation(.failed(L10n.text("请先配置可用的整理模型。"), partial: nil), preview: preview)
            return
        }
        cancelToast.finish()
        phase = .thinking
        registerEscape()
        let language = settings.language, variants = settings.variantsHeader
        let profile = HistoryStore.shared.profile
        let generation = UUID(); progressID = generation
        showTranslation(.loading, preview: preview, whileRunning: generation)
        applyState()
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
                    appBundleId: field.bundleId, translatePrompt: ownPrompt, currentRoute: route, originalText: text, showsCapsule: false) { resolved, usedRoute in
                    self.finishRequest(resolved, appBundleId: field.bundleId, language: language, strength: "prompt", audioPath: nil,
                                       seconds: nil, field: nil, insert: false, llm: usedRoute ?? route, variants: variants,
                                       translateTo: target, preview: preview)
                }
            }
        }
    }
}

import AppKit
import AVFoundation

// AppDelegate+Dictation.swift - recording / request / insertion state machine.

extension AppDelegate {

    func toggleDictation() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .thinking: NSSound.beep()
        }
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
                    self.setHint(L10n.text("需要麦克风权限才能录音"), warning: true)
                    self.applyState()
                }
            }
        case .denied, .restricted:
            setHint(L10n.text("麦克风权限被拒绝 · 在设置里打开"), warning: true)
            applyState()
            hub.show(page: .settings)
        default:
            beginCapture()
        }
    }

    func beginCapture() {
        // The previous dictation's field is checked for corrections before a new one starts.
        editWatcher.check()
        // Contract: frontmost bundle id is captured BEFORE recording starts.
        pendingAppBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        pendingField = nil
        let deviceID = AudioDevices.deviceID(forUID: settings.inputDeviceUID)
        recorder.prepareEngine = { engine in AudioInputSelector.apply(deviceID: deviceID, to: engine) }
        recorder.maxSeconds = max(5, min(120, settings.maxSeconds))
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
        recordingStartedAt = Date()
        idleBar.hide()
        recordingBar.limitSeconds = Double(recorder.maxSeconds)
        recordingBar.showRecording(destination: pendingAppBundleId)
        if settings.muteWhileDictating { OutputMuter.shared.muteIfNeeded() }
        setHint(serviceUp ? nil : (model.serviceProblem.isEmpty ? L10n.text("本地服务未就绪") : model.serviceProblem), warning: !serviceUp)
        playSound(start: true)
        registerEscape()
        startTick()
        applyState()

        // Read the target field off the main thread while the user is already speaking.
        if settings.readFieldContext {
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
        let strength = settings.strength
        let keep = settings.keepAudio24h
        // A recording made while Prompt Beta's questions are open is the answer to them.
        if strength != VoiceStrength.promptbeta.rawValue, betaPending != nil { dropBeta(notify: false) }
        let betaSession = strength == VoiceStrength.promptbeta.rawValue ? betaPending?.sessionId : nil
        do {
            let r = try recorder.finish()
            playSound(start: false)
            phase = .thinking
            recordingBar.showThinking(detail: "")
            setHint(auto ? L10n.text("已到 {0} 秒上限，正在整理", recorder.maxSeconds) : nil)
            applyState()
            sendToServer(audioURL: r.url, appBundleId: app, language: language, strength: strength,
                         keepAudioPath: keep ? r.url.path : nil, seconds: r.seconds, field: field,
                         insert: true, deleteWhenDone: !keep, betaSession: betaSession)
        } catch {
            playSound(start: false)
            phase = .idle
            recordingStartedAt = nil
            recordingBar.hide()
            let msg = (error as? RecorderError)?.description ?? error.localizedDescription
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
            recorder.cancel()
            OutputMuter.shared.restore()
            phase = .idle
            recordingStartedAt = nil
            pendingField = nil
            recordingBar.hide()
            setHint(L10n.text("已取消，录音已丢弃"))
            applyState()
            updateIdleBar()
        case .thinking:
            setHint(L10n.text("正在整理，无法取消"))
            applyState()
        case .idle:
            break
        }
    }

    // MARK: server

    func sendToServer(audioURL: URL, appBundleId: String, language: String, strength: String,
                      keepAudioPath: String?, seconds: Double?, field: FocusedField?,
                      insert: Bool, deleteWhenDone: Bool = false, betaSession: String? = nil) {
        phase = .thinking
        if !recordingBar.isVisible { recordingBar.showThinking(detail: "") }
        idleBar.hide()
        applyState()
        let context = field?.context.encoded()
        // Read on the main thread, where Settings lives; the key comes from the Keychain.
        let llm = settings.activeLLMRoute
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var outcome: Result<DictateResponse, Error>
            do {
                let data = try Data(contentsOf: audioURL)
                if data.count > Wav.maxBytes {
                    throw ServiceError.transport(L10n.text("录音超过 4 MiB 上限"))
                }
                outcome = .success(try self.client.dictateSync(wav: data, language: language,
                                                              appBundleId: appBundleId, strength: strength,
                                                              fieldContext: context, llm: llm,
                                                              betaSession: betaSession))
            } catch {
                outcome = .failure(error)
            }
            if deleteWhenDone { try? FileManager.default.removeItem(at: audioURL) }
            DispatchQueue.main.async {
                self.finishRequest(outcome, appBundleId: appBundleId, language: language, strength: strength,
                                   audioPath: keepAudioPath, seconds: seconds, field: field, insert: insert)
            }
        }
    }

    func finishRequest(_ outcome: Result<DictateResponse, Error>, appBundleId: String, language: String,
                       strength: String, audioPath: String?, seconds: Double?, field: FocusedField?, insert: Bool) {
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
            if let sessionId = resp.beta?.sessionId, !resp.betaQuestions.isEmpty {
                betaPending = BetaPending(sessionId: sessionId, questions: resp.betaQuestions,
                                          appBundleId: appBundleId, field: field)
                recordingBar.hide()
                showBetaQuestions()
                setHint(L10n.text("提示词 Beta：先回答面板里的问题"))
                applyState()
                return
            }
            // The answer to Prompt Beta's questions: the prompt goes where the request was made.
            var appBundleId = appBundleId, field = field
            if let pending = betaPending, strength == VoiceStrength.promptbeta.rawValue {
                appBundleId = pending.appBundleId
                field = pending.field ?? field
                betaPending = nil
                betaPanel.hide()
            }
            let text = resp.insertableText
            var entry = LocalHistoryEntry(id: HistoryStore.newID(), ts: Date(), app: appBundleId,
                                          language: language, strength: strength,
                                          raw: resp.raw, text: text, fallback: resp.fallback,
                                          fallbackReason: resp.fallbackReason, model: resp.model,
                                          msTotal: resp.ms?.total, audioPath: audioPath, inserted: false,
                                          seconds: seconds)
            entry.model = resp.model ?? resp.provider
            HistoryStore.shared.add(entry)
            if text.isEmpty {
                recordingBar.showResult(L10n.text("没有识别到内容"), warning: true)
                setHint(L10n.text("没有识别到内容"), warning: true)
                applyState()
                return
            }
            setHint(resp.fallback ? L10n.text("这次用了原文（整理没有成功）") : nil, warning: resp.fallback)
            if insert {
                insertText(text, fallback: resp.fallback, entryId: entry.id, appBundleId: appBundleId, field: field)
            } else {
                Inserter.shared.setString(text)
                recordingBar.showResult(text, warning: resp.fallback)
                setHint(L10n.text("重试完成，结果已复制到剪贴板"))
                applyState()
            }
        case .failure(let error):
            let d = error as? ServiceError
            if case .http(410, _, _)? = d, betaPending != nil {
                dropBeta(notify: false)
                recordingBar.showResult(L10n.text("问题已过期，请重新说一遍需求"), warning: true)
                setHint(L10n.text("问题已过期，请重新说一遍需求"), warning: true)
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
            setHint(L10n.text("听写失败：") + (d?.description ?? error.localizedDescription), warning: true)
            applyState()
        }
    }

    // MARK: insertion

    func insertText(_ text: String, fallback: Bool, entryId: String?, appBundleId: String, field: FocusedField?) {
        let mode = InsertionMode(rawValue: settings.insertionMode) ?? .autoPaste
        switch mode {
        case .autoPaste:
            // The user may have moved on while the text was being cleaned up. Pasting
            // into whatever is in front now could type into a terminal or the wrong
            // chat, so nothing is pasted and the clipboard is left alone; the text is
            // in History and one "paste last" away.
            let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard PasteTarget.matches(expected: appBundleId, frontmost: frontmost) else {
                if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = false } }
                let paste = settings.hotkeyPasteLast
                let key = paste.enabled ? HotKeyCentre.describe(keyCode: paste.keyCode, modifiers: paste.modifiers) : ""
                recordingBar.showResult(key.isEmpty ? L10n.text("已切换应用，没有粘贴 · 在历史里") : L10n.text("已切换应用，没有粘贴 · 按 ") + key + L10n.text(" 贴到这里"),
                                        warning: true)
                setHint(L10n.text("你在整理时切换了应用，这次没有粘贴。") + (key.isEmpty ? L10n.text("文字在历史里。") : L10n.text("按 ") + key + L10n.text(" 可以贴到当前位置，历史里也有。")),
                        warning: true)
                applyState()
                return
            }
            let rich = settings.richTextLists && Inserter.richListApps.contains(appBundleId)
                ? Inserter.listHTML(for: text) : nil
            Inserter.shared.insert(text, mode: .autoPaste, restoreClipboard: settings.restoreClipboard,
                                   richHTML: rich) { [weak self] result, _ in
                guard let self = self else { return }
                self.setHint(result == .pasted ? (fallback ? self.hint : nil) : result.message, warning: !result.ok)
                self.recordingBar.showResult(text, warning: !result.ok || fallback)
                if let id = entryId { HistoryStore.shared.update(id: id) { $0.inserted = result.ok } }
                if result == .pasted, self.settings.autoLearn, let field = field, field.bundleId == appBundleId {
                    self.editWatcher.watch(field: field, inserted: text)
                }
                self.applyState()
            }
        case .clipboardOnly:
            Inserter.shared.setString(text)
            recordingBar.showResult(text, warning: fallback)
            setHint(L10n.text("已复制到剪贴板"))
            applyState()
        case .preview:
            Inserter.shared.setString(text)
            if previewPanel == nil { previewPanel = PreviewPanel() }
            previewPanel?.show(text: text)
            recordingBar.showResult(text, warning: fallback)
            setHint(L10n.text("预览 · 已复制到剪贴板"))
            applyState()
        }
    }

    /// Reference "Paste last transcript": re-insert the newest entry at the cursor.
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
            NSSound(named: NSSound.Name("Pop"))?.play()
        }
    }

    // MARK: Prompt Beta

    func showBetaQuestions() {
        guard let pending = betaPending else { return }
        betaPanel.onSkip = { [weak self] in self?.finishBetaWithoutAnswers() }
        betaPanel.onCancel = { [weak self] in self?.dropBeta(notify: true) }
        betaPanel.show(questions: pending.questions, hotkey: model.hotkeyLabel)
    }

    /// "跳过，直接生成": write the prompt now; unanswered points go to 「待确认」.
    func finishBetaWithoutAnswers() {
        guard phase == .idle, let pending = betaPending else { return }
        betaPanel.hide()
        phase = .thinking
        recordingBar.showThinking(detail: "")
        applyState()
        let llm = settings.activeLLMRoute
        let language = settings.language
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = Result { try self.client.betaSync(sessionId: pending.sessionId, skip: true,
                                                            appBundleId: pending.appBundleId, llm: llm) }
            DispatchQueue.main.async {
                self.finishRequest(outcome, appBundleId: pending.appBundleId, language: language,
                                   strength: VoiceStrength.promptbeta.rawValue, audioPath: nil, seconds: nil,
                                   field: pending.field, insert: true)
            }
        }
    }

    /// Close the questions; the service forgets the session too.
    func dropBeta(notify: Bool) {
        guard let pending = betaPending else { return }
        betaPending = nil
        betaPanel.hide()
        let llm = settings.activeLLMRoute
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = try? self?.client.betaSync(sessionId: pending.sessionId, skip: false, appBundleId: pending.appBundleId, llm: llm)
        }
        if notify {
            setHint(L10n.text("已取消"))
            applyState()
        }
    }
}


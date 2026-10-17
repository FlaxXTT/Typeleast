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
        switch Recorder.authorizationStatus() {
        case .notDetermined:
            Recorder.requestMicrophoneAccess { [weak self] granted in
                guard let self = self else { return }
                self.model.refreshPermissions()
                if granted {
                    self.beginCapture()
                } else {
                    self.setHint("需要麦克风权限才能录音", warning: true)
                    self.applyState()
                }
            }
        case .denied, .restricted:
            setHint("麦克风权限被拒绝 · 在设置里打开", warning: true)
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
        setHint(serviceUp ? nil : "整理服务未运行，转写需要 DSH", warning: !serviceUp)
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
        do {
            let r = try recorder.finish()
            playSound(start: false)
            phase = .thinking
            recordingBar.showThinking(detail: "")
            setHint(auto ? "已到 \(recorder.maxSeconds) 秒上限，正在整理" : nil)
            applyState()
            sendToServer(audioURL: r.url, appBundleId: app, language: language, strength: strength,
                         keepAudioPath: keep ? r.url.path : nil, seconds: r.seconds, field: field,
                         insert: true, deleteWhenDone: !keep)
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
            setHint("已取消，录音已丢弃")
            applyState()
            updateIdleBar()
        case .thinking:
            setHint("正在整理，无法取消")
            applyState()
        case .idle:
            break
        }
    }

    // MARK: server

    func sendToServer(audioURL: URL, appBundleId: String, language: String, strength: String,
                      keepAudioPath: String?, seconds: Double?, field: FocusedField?,
                      insert: Bool, deleteWhenDone: Bool = false) {
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
                    throw DshError.transport("录音超过 4 MiB 上限")
                }
                outcome = .success(try self.client.dictateSync(wav: data, language: language,
                                                              appBundleId: appBundleId, strength: strength,
                                                              fieldContext: context, llm: llm))
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
                recordingBar.showResult("没有识别到内容", warning: true)
                setHint("没有识别到内容", warning: true)
                applyState()
                return
            }
            setHint(resp.fallback ? "这次用了原文（整理没有成功）" : nil, warning: resp.fallback)
            if insert {
                insertText(text, fallback: resp.fallback, entryId: entry.id, appBundleId: appBundleId, field: field)
            } else {
                Inserter.shared.setString(text)
                recordingBar.showResult(text, warning: resp.fallback)
                setHint("重试完成，结果已复制到剪贴板")
                applyState()
            }
        case .failure(let error):
            let d = error as? DshError
            DiagnosticsLog.write("dictate.fail", ["error": d?.description ?? error.localizedDescription,
                                                  "ownKey": settings.activeLLMRoute == nil ? "no" : "yes"])
            if d?.serviceUnavailable == true {
                serviceUp = false
                scheduleHealthRetry()
            }
            recordingBar.showResult(serviceUp ? "听写失败" : "整理服务未运行", warning: true)
            setHint("听写失败：" + (d?.description ?? error.localizedDescription), warning: true)
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
                recordingBar.showResult(key.isEmpty ? "已切换应用，没有粘贴 · 在历史里" : "已切换应用，没有粘贴 · 按 " + key + " 贴到这里",
                                        warning: true)
                setHint("你在整理时切换了应用，这次没有粘贴。" + (key.isEmpty ? "文字在历史里。" : "按 " + key + " 可以贴到当前位置，历史里也有。"),
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
            setHint("已复制到剪贴板")
            applyState()
        case .preview:
            Inserter.shared.setString(text)
            if previewPanel == nil { previewPanel = PreviewPanel() }
            previewPanel?.show(text: text)
            recordingBar.showResult(text, warning: fallback)
            setHint("预览 · 已复制到剪贴板")
            applyState()
        }
    }

    /// Typeless "Paste last transcript": re-insert the newest entry at the cursor.
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
        NSSound(named: NSSound.Name(start ? "Tink" : "Pop"))?.play()
    }
}

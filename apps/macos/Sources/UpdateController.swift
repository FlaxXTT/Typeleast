import AppKit

/// Background discovery and a single, user-initiated update dialog.
final class UpdateController {
    static func blockingReason(practiceBusy: Bool, phase: AppPhase, promptPending: Bool,
                               meetingBusy: Bool) -> (title: String, text: String)? {
        if practiceBusy { return (L10n.text("正在练习"), L10n.text("练习结束后再更新。")) }
        if phase != .idle { return (L10n.text("正在听写"), L10n.text("听写结束后再更新。")) }
        if promptPending { return (L10n.text("提示词模式 未结束"), L10n.text("更新前，请先生成或取消提示词模式。")) }
        if meetingBusy { return (L10n.text("会议"), L10n.text("会议结束后再更新。")) }
        return nil
    }

    struct Host {
        /// Why an update cannot start now (dictating, Prompt Beta open), or nil.
        let busyReason: () -> (title: String, text: String)?
        let dialogWindow: () -> NSWindow?
        /// Show (or clear, with nil) "有新版本" in the menu.
        let showAvailable: (String?) -> Void
        /// Last thing before the app quits for the installer.
        let willQuit: () -> Void
    }

    private let host: Host
    private let progress = UpdateProgressWindow()
    private var checking = false
    private var available: Updater.Release?
    private var downloadState: UpdateDialogState?
    private var prepared: (version: String, app: URL, work: URL)?
    private var restarting = false

    init(host: Host) {
        self.host = host
    }

    func check(interactive: Bool) {
        if !interactive && progress.isVisible { return }
        if interactive {
            if restarting { return }
            if progress.raiseIfVisible() { return }
            if let prepared {
                present(.ready(prepared.version))
                return
            }
            if let downloadState {
                present(downloadState)
                return
            }
            if Updater.intelDiscontinued() {
                present(.message(L10n.text("Intel Mac 不再更新"),
                                 L10n.text("Intel Mac 不再更新。1.17.1 是最终版，可继续使用。")))
                return
            }
            present(.checking)
        }
        guard !checking, downloadState == nil, prepared == nil, !restarting, !Updater.intelDiscontinued() else { return }
        checking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Updater.latestRelease() }
            DispatchQueue.main.async { self?.finishedCheck(result) }
        }
    }

    private func finishedCheck(_ result: Result<Updater.Release, Error>) {
        checking = false
        let state: UpdateDialogState
        switch result {
        case .success(let release) where Updater.isNewer(release.version, than: Updater.currentVersion):
            available = release
            host.showAvailable(release.version)
            state = .available(release)
        case .success:
            available = nil
            host.showAvailable(nil)
            state = .latest
        case .failure(let error):
            state = .message(L10n.text("检查更新失败"), error.localizedDescription)
        }
        if progress.isVisible { progress.update(state) }
    }

    /// Check quietly after launch, then every six hours.
    func scheduleChecks() {
        guard ProcessInfo.processInfo.environment["TYPELEAST_HOME"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(interactive: false) }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(interactive: false) }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func present(_ state: UpdateDialogState) {
        progress.present(in: host.dialogWindow(), state: state,
                         download: { [weak self] in self?.download() },
                         restart: { [weak self] in self?.restart() })
    }

    private func download() {
        guard let release = available, downloadState == nil, prepared == nil, !restarting else { return }
        let version = release.version
        showProgress(.preparing, version: version)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try Updater.prepare(version: version) { stage in
                    DispatchQueue.main.async {
                        guard let self, self.downloadState != nil else { return }
                        self.showProgress(stage, version: version)
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.downloadState = nil
                switch result {
                case .success(let ready):
                    self.prepared = (version, ready.app, ready.work)
                    self.progress.update(.ready(version))
                case .failure(let error):
                    self.progress.update(.message(L10n.text("更新失败"), error.localizedDescription))
                }
            }
        }
    }

    private func showProgress(_ stage: UpdateStage, version: String) {
        let state = UpdateDialogState.progress(version, stage)
        downloadState = state
        progress.update(state)
    }

    private func restart() {
        guard let prepared, !restarting else { return }
        if let reason = host.busyReason() {
            progress.update(.ready(prepared.version, note: reason.text))
            return
        }
        do {
            try Updater.replaceAfterExit(pid: ProcessInfo.processInfo.processIdentifier,
                                         newApp: prepared.app, installed: Bundle.main.bundleURL, work: prepared.work) { [weak self] status in
                guard let self, self.restarting else { return }
                self.restarting = false
                let state = UpdateDialogState.ready(prepared.version, note: L10n.text("未能退出 TypeLeast，请重试。"))
                DiagnosticsLog.write("update.handoff.failed", ["status": String(status)])
                if NSApp.isActive { self.present(state) }
            }
            restarting = true
            progress.close()
            host.willQuit()
            DispatchQueue.main.async { NSApp.terminate(nil) }
        } catch {
            progress.update(.ready(prepared.version, note: error.localizedDescription))
        }
    }
}

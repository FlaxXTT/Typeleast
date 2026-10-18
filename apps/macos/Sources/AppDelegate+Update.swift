import AppKit

// AppDelegate+Update.swift - "检查更新…" in the menu and in Settings, plus one quiet
// check a little after launch. The work itself is in Updater.swift.

extension AppDelegate {

    /// `interactive`: the user asked, so say "already up to date" and show errors.
    /// The quiet launch check only changes the menu item when there is a newer version.
    func checkForUpdates(interactive: Bool) {
        if interactive { setHint("正在检查更新…") }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Updater.latestVersion() }
            DispatchQueue.main.async {
                guard let self else { return }
                if interactive { self.setHint(nil) }
                switch result {
                case .success(let latest) where Updater.isNewer(latest, than: Updater.currentVersion):
                    self.menuController.setUpdateAvailable(latest)
                    if interactive { self.offerUpdate(to: latest) }
                case .success:
                    self.menuController.setUpdateAvailable(nil)
                    if interactive { self.updateAlert("已经是最新版本", "当前版本 " + Updater.currentVersion + "。") }
                case .failure(let error):
                    if interactive { self.updateAlert("检查更新失败", error.localizedDescription) }
                }
            }
        }
    }

    func offerUpdate(to version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "有新版本 " + version
        alert.informativeText = "当前版本 " + Updater.currentVersion + "。更新会下载新版本、核对校验值、用本机证书签名，然后自动重启 TypeLeast。权限不需要重新授予。"
        alert.addButton(withTitle: "立即更新")
        alert.addButton(withTitle: "以后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installUpdate(version)
    }

    func installUpdate(_ version: String) {
        guard phase == .idle else {
            updateAlert("正在听写", "听写结束后再更新。")
            return
        }
        setHint("正在下载更新 " + version + "…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Updater.prepare(version: version) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let ready):
                    do {
                        try Updater.replaceAfterExit(pid: ProcessInfo.processInfo.processIdentifier,
                                                     newApp: ready.app, installed: Bundle.main.bundleURL, work: ready.work)
                        self.setHint("正在安装更新，TypeLeast 会自动重新打开…")
                        self.recorder.cancel()
                        NSApp.terminate(nil)
                    } catch {
                        self.setHint(nil)
                        self.updateAlert("更新失败", error.localizedDescription)
                    }
                case .failure(let error):
                    self.setHint(nil)
                    self.updateAlert("更新失败", error.localizedDescription)
                }
            }
        }
    }

    /// One quiet look a little after launch, so the menu can show "有新版本".
    func scheduleLaunchUpdateCheck() {
        // Test and demo runs (a temporary TYPELEAST_HOME) never reach out to GitHub.
        guard ProcessInfo.processInfo.environment["TYPELEAST_HOME"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdates(interactive: false) }
    }

    private func updateAlert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

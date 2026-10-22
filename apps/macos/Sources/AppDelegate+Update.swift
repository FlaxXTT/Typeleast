import AppKit

// AppDelegate+Update.swift - "检查更新…" in the menu and in Settings, plus one quiet
// check a little after launch. The work itself is in Updater.swift.

extension AppDelegate {

    /// `interactive`: the user asked, so say "already up to date" and show errors.
    /// The quiet launch check only changes the menu item when there is a newer version.
    func checkForUpdates(interactive: Bool) {
        guard !Updater.intelDiscontinued() else {
            if interactive {
                updateAlert(L10n.text("Intel Mac 已停止更新"),
                            L10n.text("TypeLeast 不再为 Intel 芯片的 Mac 提供新版本，最终版是 1.17.1。当前版本可以继续使用。"))
            }
            return
        }
        if interactive { setHint(L10n.text("正在检查更新…")) }
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
                    if interactive { self.updateAlert(L10n.text("已经是最新版本"), L10n.text("当前版本 ") + Updater.currentVersion + "。") }
                case .failure(let error):
                    if interactive { self.updateAlert(L10n.text("检查更新失败"), error.localizedDescription) }
                }
            }
        }
    }

    func offerUpdate(to version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.text("有新版本 ") + version
        var detail = L10n.text("当前版本 ") + Updater.currentVersion + L10n.text("。更新会下载新版本、核对校验值、用本机证书签名，然后自动重启 TypeLeast。权限和钥匙串里的 Key 都会保留，不需要输入密码。")
        if !Updater.hasSigningIdentity() {
            detail += "\n\n" + L10n.text("这是第一次在这台 Mac 上更新：会先生成一个只给这台 Mac 用的签名证书。macOS 会请你输入一次登录密码，好让签名工具使用它，请选「始终允许」；也可能需要在「隐私与安全性」里重新允许一次麦克风和辅助功能。以后的更新都不会再问。")
        }
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.text("立即更新"))
        alert.addButton(withTitle: L10n.text("以后"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installUpdate(version)
    }

    func installUpdate(_ version: String) {
        guard phase == .idle else {
            updateAlert(L10n.text("正在听写"), L10n.text("听写结束后再更新。"))
            return
        }
        // Restarting would drop the questions and the answers given so far.
        guard betaPending == nil else {
            updateAlert(L10n.text("提示词 Beta 还没结束"), L10n.text("生成或取消这次提示词 Beta 后再更新。"))
            return
        }
        setHint(L10n.text("正在下载更新 ") + version + "…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Updater.prepare(version: version) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let ready):
                    // Hand the Keychain items to the next copy, so updating asks for no password.
                    KeychainHandoff.prepare()
                    do {
                        try Updater.replaceAfterExit(pid: ProcessInfo.processInfo.processIdentifier,
                                                     newApp: ready.app, installed: Bundle.main.bundleURL, work: ready.work)
                        self.setHint(L10n.text("正在安装更新，TypeLeast 会自动重新打开…"))
                        self.recorder.cancel()
                        NSApp.terminate(nil)
                    } catch {
                        KeychainHandoff.restoreIfPresent()
                        self.setHint(nil)
                        self.updateAlert(L10n.text("更新失败"), error.localizedDescription)
                    }
                case .failure(let error):
                    self.setHint(nil)
                    self.updateAlert(L10n.text("更新失败"), error.localizedDescription)
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

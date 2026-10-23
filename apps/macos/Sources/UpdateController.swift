import AppKit

// UpdateController.swift - in-app updates as one piece: the quiet checks (20 s after launch,
// then every six hours), the offer, the progress window and the install. The work itself is in
// Updater.swift; the app is reached only through the small Host it is given, so this file does
// not depend on the rest of AppDelegate.

final class UpdateController {
    struct Host {
        /// Why an update cannot start now (dictating, Prompt Beta open), or nil.
        let busyReason: () -> (title: String, text: String)?
        let setHint: (String?) -> Void
        /// Show (or clear, with nil) "有新版本" in the menu.
        let showAvailable: (String?) -> Void
        /// Last thing before the app quits for the installer.
        let willQuit: () -> Void
    }

    private let host: Host
    private let progress = UpdateProgressWindow()
    private let offeredKey = "voice.updateOffered"
    private var summary = ""

    init(host: Host) {
        self.host = host
    }

    /// `interactive`: the user asked, so say "already up to date" and show errors.
    func check(interactive: Bool) {
        guard !Updater.intelDiscontinued() else {
            if interactive {
                alert(L10n.text("Intel Mac 已停止更新"),
                      L10n.text("TypeLeast 不再为 Intel 芯片的 Mac 提供新版本，最终版是 1.17.1。当前版本可以继续使用。"))
            }
            return
        }
        if interactive { host.setHint(L10n.text("正在检查更新…")) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Updater.latestRelease() }
            DispatchQueue.main.async {
                guard let self else { return }
                if interactive { self.host.setHint(nil) }
                switch result {
                case .success(let release) where Updater.isNewer(release.version, than: Updater.currentVersion):
                    let latest = release.version
                    self.summary = release.summary
                    self.host.showAvailable(latest)
                    let offered = UserDefaults.standard.string(forKey: self.offeredKey)
                    if Updater.shouldOffer(latest: latest, offered: offered, interactive: interactive,
                                                    busy: self.host.busyReason() != nil) {
                        UserDefaults.standard.set(latest, forKey: self.offeredKey)
                        self.offer(latest)
                    }
                case .success:
                    self.host.showAvailable(nil)
                    if interactive { self.alert(L10n.text("已经是最新版本"), L10n.text("当前版本 ") + Updater.currentVersion + "。") }
                case .failure(let error):
                    if interactive { self.alert(L10n.text("检查更新失败"), error.localizedDescription) }
                }
            }
        }
    }

    /// A look a little after launch, and every six hours for a Mac that stays on.
    func scheduleChecks() {
        // Test and demo runs (a temporary TYPELEAST_HOME) never reach out to GitHub.
        guard ProcessInfo.processInfo.environment["TYPELEAST_HOME"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(interactive: false) }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check(interactive: false) }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func offer(_ version: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.text("有新版本 ") + version
        var detail = L10n.text("当前版本 ") + Updater.currentVersion + L10n.text("。更新会下载新版本、核对校验值、用本机证书签名，然后自动重启 TypeLeast。权限和钥匙串里的 Key 都会保留，不需要输入密码。")
        if !summary.isEmpty { detail = L10n.text("本次更新") + "\n" + summary + "\n\n" + detail }
        if !Updater.hasSigningIdentity() {
            detail += "\n\n" + L10n.text("这是第一次在这台 Mac 上更新：会先生成一个只给这台 Mac 用的签名证书。macOS 会请你输入一次登录密码，好让签名工具使用它，请选「始终允许」；也可能需要在「隐私与安全性」里重新允许一次麦克风和辅助功能。以后的更新都不会再问。")
        }
        alert.informativeText = detail
        alert.addButton(withTitle: L10n.text("立即更新"))
        alert.addButton(withTitle: L10n.text("以后"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        install(version)
    }

    private func install(_ version: String) {
        // Restarting in the middle of a dictation or a Prompt Beta would lose it.
        if let reason = host.busyReason() {
            alert(reason.title, reason.text)
            return
        }
        host.setHint(L10n.text("正在下载更新 ") + version + "…")
        progress.show(version: version, summary: summary)
        let report: (UpdateStage) -> Void = { [weak self] stage in
            DispatchQueue.main.async { self?.progress.update(stage) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Updater.prepare(version: version, stage: report) }
            // Hand the Keychain items straight to the new copy, so updating asks for no password.
            // Without a code hash to check it against, nothing is handed over and the new copy asks once.
            if case .success(let ready) = result, let cdhash = ready.cdhash {
                report(.handingOver)
                KeychainHandoff.transfer(toExecutable: ready.app.appendingPathComponent("Contents/MacOS/TypeLeast"), cdhash: cdhash)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let ready):
                    do {
                        try Updater.replaceAfterExit(pid: ProcessInfo.processInfo.processIdentifier,
                                                     newApp: ready.app, installed: Bundle.main.bundleURL, work: ready.work)
                        self.host.setHint(L10n.text("正在安装更新，TypeLeast 会自动重新打开…"))
                        self.progress.update(.installing)
                        self.host.willQuit()
                        NSApp.terminate(nil)
                    } catch {
                        self.fail(error)
                    }
                case .failure(let error):
                    self.fail(error)
                }
            }
        }
    }

    private func fail(_ error: Error) {
        host.setHint(nil)
        progress.close()
        alert(L10n.text("更新失败"), error.localizedDescription)
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

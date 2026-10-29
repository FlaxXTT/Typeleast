import AppKit

// MenuController.swift - the menu bar icon and its short menu:
// status, start/stop, paste last, open the app, settings, quit. Everything else lives
// in the main window.

struct MenuState {
    var phase: AppPhase = .idle
    var elapsed: Double = 0
    var hint: String?
    var hintWarning: Bool = false
    var serviceUp: Bool = false
    var accessibilityTrusted: Bool = false
    var hotkeySummary: String = ""
    var pasteLastSummary: String = ""
    var hasLast: Bool = false
    var strength = "prompt"
}

protocol MenuActionTarget: AnyObject {
    func menuSetStrength(_ code: String)
    func menuToggleDictation()
    func menuCancelDictation()
    func menuPasteLast()
    func menuOpenHub(_ page: HubPage)
    func menuRequestAccessibility()
    func menuRestartService()
    func menuCheckForUpdates()
    func menuQuit()
    /// The menu is about to show: a cheap moment to refresh the service status line.
    func menuOpened()
}

final class MenuController: NSObject, NSMenuDelegate {
    weak var target: MenuActionTarget?

    func menuWillOpen(_ menu: NSMenu) { target?.menuOpened() }

    let statusItem: NSStatusItem
    let menu = NSMenu()
    private var statusLine: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var cancelItem: NSMenuItem!
    private var pasteItem: NSMenuItem!
    private var hintItem: NSMenuItem!
    private var axItem: NSMenuItem!
    private var launchItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var modeItems: [NSMenuItem] = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        statusItem.menu = menu
        menu.delegate = self
        setIcon("waveform")
    }

    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        statusLine = item("TypeLeast", nil)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleItem = item(L10n.text("开始听写"), #selector(onToggle))
        menu.addItem(toggleItem)
        cancelItem = item(L10n.text("取消听写"), #selector(onCancel))
        menu.addItem(cancelItem)
        pasteItem = item(L10n.text("粘贴上一条"), #selector(onPasteLast))
        menu.addItem(pasteItem)
        let assistant = item(L10n.text("提示词模式"), #selector(onMode(_:)))
        assistant.representedObject = "promptbeta"
        menu.addItem(assistant)
        hintItem = item("", nil)
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        axItem = item(L10n.text("自动粘贴需要辅助功能权限，点此允许"), #selector(onAccessibility))
        menu.addItem(axItem)
        launchItem = item(L10n.text("重启本地服务"), #selector(onLaunch))
        menu.addItem(launchItem)
        menu.addItem(.separator())
        menu.addItem(item(L10n.text("打开 TypeLeast"), #selector(onOpenHome)))
        menu.addItem(item(L10n.text("历史…"), #selector(onOpenHistory)))
        menu.addItem(item(L10n.text("词典"), #selector(onOpenDictionary)))
        let settings = item(L10n.text("设置…"), #selector(onOpenSettings))
        settings.keyEquivalent = ","
        menu.addItem(settings)
        updateItem = item(L10n.text("检查更新…"), #selector(onCheckForUpdates))
        menu.addItem(updateItem)
        menu.addItem(.separator())
        let quit = item(L10n.text("退出 TypeLeast"), #selector(onQuit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    func apply(_ s: MenuState) {
        switch s.phase {
        case .idle:
            statusLine.title = s.serviceUp ? L10n.text("就绪 · 按 ") + s.hotkeySummary + L10n.text(" 听写") : L10n.text("本地服务未就绪")
            toggleItem.title = L10n.text("开始听写")
            setIcon("waveform")
        case .recording:
            statusLine.title = L10n.text("正在听 ") + format(s.elapsed)
            toggleItem.title = L10n.text("结束听写")
            setIcon("waveform.circle.fill")
        case .thinking:
            statusLine.title = L10n.text("正在整理…")
            toggleItem.title = L10n.text("正在整理…")
            setIcon("ellipsis.circle")
        }
        for item in modeItems {
            item.state = item.representedObject as? String == s.strength ? .on : .off
            item.isEnabled = s.phase == .idle
        }
        toggleItem.keyEquivalent = ""
        toggleItem.isEnabled = s.phase != .thinking
        cancelItem.isHidden = s.phase != .recording
        pasteItem.title = L10n.text("粘贴上一条") + (s.pasteLastSummary.isEmpty ? "" : "  " + s.pasteLastSummary)
        pasteItem.isEnabled = s.hasLast && s.phase == .idle
        if let hint = s.hint, !hint.isEmpty {
            hintItem.title = (s.hintWarning ? "⚠︎ " : "") + shorten(hint, 52)
            hintItem.isHidden = false
        } else {
            hintItem.isHidden = true
        }
        axItem.isHidden = s.accessibilityTrusted
        launchItem.isHidden = s.serviceUp
        statusItem.button?.toolTip = "TypeLeast · " + statusLine.title
    }

    /// A newer version was found: say so on the menu item (nil: back to "检查更新…").
    func setUpdateAvailable(_ version: String?) {
        updateItem.title = version.map { L10n.text("新版本 ") + $0 + L10n.text(" · 点击更新") } ?? L10n.text("检查更新…")
    }

    private func setIcon(_ symbol: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TypeLeast")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func format(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(s / 60) + ":" + String(format: "%02d", s % 60)
    }

    private func shorten(_ s: String, _ n: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= n ? flat : String(flat.prefix(n)) + "…"
    }

    @objc private func onMode(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { target?.menuSetStrength(code) }
    }
    @objc private func onToggle() { target?.menuToggleDictation() }
    @objc private func onCheckForUpdates() { target?.menuCheckForUpdates() }
    @objc private func onCancel() { target?.menuCancelDictation() }
    @objc private func onPasteLast() { target?.menuPasteLast() }
    @objc private func onAccessibility() { target?.menuRequestAccessibility() }
    @objc private func onLaunch() { target?.menuRestartService() }
    @objc private func onOpenHome() { target?.menuOpenHub(.home) }
    @objc private func onOpenHistory() { target?.menuOpenHub(.history) }
    @objc private func onOpenDictionary() { target?.menuOpenHub(.dictionary) }
    @objc private func onOpenSettings() { target?.menuOpenHub(.settings) }
    @objc private func onQuit() { target?.menuQuit() }
}

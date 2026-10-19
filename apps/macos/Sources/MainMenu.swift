import AppKit

// MainMenu.swift - the app's own menu bar (TypeLeast / Edit / Window). Without it,
// switching to the main window left the previous app's menus in the menu bar, and
// text fields had no ⌘C / ⌘V / ⌘Z, which AppKit routes through the main menu.

final class MainMenu: NSObject {
    var openSettings: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var quit: () -> Void = {}

    /// Builds the menu bar; NSApp.mainMenu and NSApp.windowsMenu are set by the caller.
    func build() -> (menu: NSMenu, windows: NSMenu) {
        let bar = NSMenu()

        // The first menu's title is ignored: macOS shows the bundle name there.
        let app = NSMenu(title: "TypeLeast")
        app.addItem(withTitle: L10n.text("关于 TypeLeast"),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(own(L10n.text("设置…"), #selector(onSettings), ","))
        app.addItem(own(L10n.text("检查更新…"), #selector(onCheckForUpdates), ""))
        app.addItem(.separator())
        app.addItem(withTitle: L10n.text("隐藏 TypeLeast"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: L10n.text("隐藏其他"),
                                 action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L10n.text("全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(own(L10n.text("退出 TypeLeast"), #selector(onQuit), "q"))
        add(app, to: bar)

        // Standard edit actions go to the first responder (target nil).
        let edit = NSMenu(title: L10n.text("编辑"))
        edit.addItem(withTitle: L10n.text("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L10n.text("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.text("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.text("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.text("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.text("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: bar)

        let window = NSMenu(title: L10n.text("窗口"))
        window.addItem(withTitle: L10n.text("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L10n.text("缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(withTitle: L10n.text("关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(withTitle: L10n.text("前置全部窗口"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, to: bar)

        return (bar, window)
    }

    private func own(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func add(_ menu: NSMenu, to bar: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        bar.addItem(holder)
    }

    @objc private func onSettings() { openSettings() }
    @objc private func onCheckForUpdates() { checkForUpdates() }
    @objc private func onQuit() { quit() }
}

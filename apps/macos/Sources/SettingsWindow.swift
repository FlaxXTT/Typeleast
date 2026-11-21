import AppKit
import SwiftUI

/// Settings stays fixed above its main window.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("typeleast.settings")
    static let size = NSSize(width: 900, height: 624)
    private let model: AppModel
    private var window: SettingsDialogWindow?

    init(model: AppModel) { self.model = model; super.init() }

    var visibleWindow: NSWindow? { window?.isVisible == true ? window : nil }

    func show(relativeTo parent: NSWindow?) {
        if window == nil {
            let size = Self.size
            let panel = SettingsDialogWindow(contentRect: NSRect(origin: .zero, size: size),
                                             styleMask: [.borderless, .closable], backing: .buffered, defer: false)
            panel.identifier = Self.identifier
            panel.title = L10n.settingTitle
            panel.isMovable = false
            panel.isMovableByWindowBackground = false
            installSettingsPage(in: panel)
            AppWindowStyle.fixSize(panel, to: size)
            panel.collectionBehavior.insert(.fullScreenNone)
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            if let parent, parent.isVisible {
                panel.setFrameOrigin(NSPoint(x: parent.frame.midX - size.width / 2,
                                              y: parent.frame.midY - size.height / 2))
            } else { panel.center() }
            window = panel
            AppWindowStyle.round(panel, radius: Theme.settingsRadius)
        }
        guard let window else { return }
        if window.isClosing { installSettingsPage(in: window) }
        NSApp.activate(ignoringOtherApps: true)
        window.present()
        if let parent, parent.isVisible, !parent.isMiniaturized, window.parent !== parent {
            parent.addChildWindow(window, ordered: .above)
        }
    }

    private func installSettingsPage(in window: NSWindow) {
        let host = NSHostingController(rootView:
            SettingsPage(onClose: { [weak self] in self?.close() }).environmentObject(model))
        host.sizingOptions = []
        window.contentViewController = host
    }

    func close() { window?.close() }
    func closeIfVisible() -> Bool {
        guard let window = visibleWindow else { return false }
        window.close()
        return true
    }
    func closeImmediately() { window?.finishClose() }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window { AppWindowStyle.round(window, radius: Theme.settingsRadius) }
        model.refreshPermissions()
    }

    func windowWillClose(_ notification: Notification) {
        if let window {
            window.parent?.removeChildWindow(window)
            window.contentViewController = nil
        }
        window = nil
        if model.settingsPresented { model.settingsPresented = false }
    }
}

private final class SettingsDialogWindow: NSWindow {
    private var fadeGeneration = 0
    private(set) var isClosing = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performClose(_ sender: Any?) {
        close()
    }

    func present() {
        fadeGeneration &+= 1
        isClosing = false
        ignoresMouseEvents = false
        let appearing = !isVisible
        if appearing { alphaValue = 0 }
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.225
            animator().alphaValue = 1
        }
    }

    override func close() {
        guard !isClosing else { return }
        if !isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { super.close(); return }
        isClosing = true
        ignoresMouseEvents = true
        fadeGeneration &+= 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.195
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.isClosing, self.fadeGeneration == generation else { return }
            self.finishClose()
        }
    }

    func finishClose() {
        isClosing = false
        super.close()
    }
}

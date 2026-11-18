import AppKit
import SwiftUI

/// Settings is a movable window, not an attached sheet.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("typeleast.settings")
    private let model: AppModel
    private var window: SettingsDialogWindow?

    init(model: AppModel) { self.model = model; super.init() }

    var visibleWindow: NSWindow? { window?.isVisible == true ? window : nil }

    func show(relativeTo parent: NSWindow?) {
        if window == nil {
            let size = NSSize(width: 940, height: 652)
            let panel = SettingsDialogWindow(contentRect: NSRect(origin: .zero, size: size),
                                             styleMask: [.borderless, .closable], backing: .buffered, defer: false)
            panel.identifier = Self.identifier
            panel.title = L10n.text("设置")
            panel.contentViewController = NSHostingController(rootView:
                SettingsPage(onClose: { [weak self] in self?.close() }).environmentObject(model))
            panel.setContentSize(size)
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
        NSApp.activate(ignoringOtherApps: true)
        window?.present()
    }

    func close() { window?.close() }
    func closeForUpdate() { window?.finishClose() }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window { AppWindowStyle.round(window, radius: Theme.settingsRadius) }
        model.refreshPermissions()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
        if model.settingsPresented { model.settingsPresented = false }
    }
}

private final class SettingsDialogWindow: NSWindow {
    private var fadeGeneration = 0
    private var closing = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present() {
        fadeGeneration &+= 1
        closing = false
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
        guard !closing else { return }
        if !isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { super.close(); return }
        closing = true
        ignoresMouseEvents = true
        fadeGeneration &+= 1
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.195
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.closing, self.fadeGeneration == generation else { return }
            self.finishClose()
        }
    }

    func finishClose() {
        closing = false
        super.close()
    }
}

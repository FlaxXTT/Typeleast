import AppKit
import SwiftUI
import ServiceManagement

/// Exercise the real settings view with a counted system-status provider. No login
/// item is registered, no microphone is opened, and all history uses a temporary home.
func settingsScrollTests(output: String) throws {
    let app = NSApplication.shared
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

    func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        view.layoutSubtreeIfNeeded()
    }
    func settle(_ view: NSView, until ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        repeat { settle(view) } while !ready() && Date() < deadline
    }
    func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
    func save(_ view: NSView, _ name: String) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            check("settings screenshot is available", false)
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
    }

    for dark in [false, true] {
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Content widths at the Hub's minimum and default window sizes.
        for width in [606, 726] {
            var queries = 0
            var systemStatus: SMAppService.Status = .enabled
            let status = LoginItemStatus {
                queries += 1
                return systemStatus
            }
            checkEq("constructing settings status performs no system query", queries, 0)
            let model = AppModel()
            model.settingsCategory = 2
            let view = NSHostingView(rootView: SettingsPage(loginItemStatus: status)
                .environmentObject(model).background(Theme.window)
                .environment(\.colorScheme, dark ? .dark : .light))
            let frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = frame
            settle(view, until: { status.status == .enabled && !status.isLoading })
            checkEq("entering General reads login status once", queries, 1)
            check("General receives the actual enabled state", status.status == .enabled)
            let baseline = queries
            let name = "general-\(width)-\(dark ? "dark" : "light")"
            try save(view, name + "-top")
            guard let scroll = scrollView(in: view), let document = scroll.documentView else {
                check("General has a native scroll view", false)
                window.orderOut(nil)
                continue
            }
            let distance = max(0, document.bounds.height - scroll.contentView.bounds.height)
            check("General fixture has scrollable content", distance > 100)
            for step in 0..<60 {
                let fraction = CGFloat(step % 20) / 19
                let y = distance * (step / 20 % 2 == 0 ? fraction : 1 - fraction)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                // Service/recording updates must not turn layout into system IPC.
                model.hint = "fixture update \(step)"
                settle(view)
                view.displayIfNeeded()
            }
            checkEq("scrolling and 60 model updates make no login-system queries", queries, baseline)
            try save(view, name + "-bottom")

            systemStatus = .requiresApproval
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
            settle(view, until: { status.status == .requiresApproval && !status.isLoading })
            checkEq("returning from System Settings refreshes once", queries, baseline + 1)
            check("external login-item changes are reflected", status.status == .requiresApproval)
            model.settingsCategory = 0
            settle(view)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
            settle(view)
            checkEq("other settings tabs do not query login items", queries, baseline + 1)
            systemStatus = .notRegistered
            model.settingsCategory = 2
            settle(view, until: { status.status == .notRegistered && !status.isLoading })
            checkEq("returning to General refreshes once", queries, baseline + 2)
            check("returning to General receives the latest disabled state", status.status == .notRegistered)
            if dark, width == 726 {
                var presenceQueries = 0
                KeychainStore.invalidatePresence()
                KeychainStore.presenceQueryOverride = { _ in presenceQueries += 1; return false }
                defer {
                    KeychainStore.presenceQueryOverride = nil
                    KeychainStore.invalidatePresence()
                }
                model.settingsCategory = 1
                settle(view)
                checkEq("model form reads key metadata once", presenceQueries, 1)
                if let modelScroll = scrollView(in: view), let document = modelScroll.documentView {
                    for step in 0..<30 {
                        let distance = max(0, document.bounds.height - modelScroll.contentView.bounds.height)
                        modelScroll.contentView.scroll(to: NSPoint(x: 0, y: distance * CGFloat(step % 10) / 9))
                        modelScroll.reflectScrolledClipView(modelScroll.contentView)
                        model.hint = "model fixture \(step)"
                        settle(view)
                    }
                    checkEq("scrolling model settings makes no repeated Keychain queries", presenceQueries, 1)
                } else { check("model settings have a native scroll view", false) }
            }
            window.orderOut(nil)
        }
    }
}

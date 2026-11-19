import AppKit
import QuartzCore

/// Keep the old appearance in place until every participating window has repainted.
enum HubThemeReveal {
    private static var activeOverlays: [ThemeRevealOverlay] = []
    private static var pendingTransition: (() -> Void)?

    static func apply(_ appearance: NSAppearance?, in preferredWindow: NSWindow? = nil,
                      additionalWindows: [NSWindow] = [], showsHome: Bool = true) {
        let changesAppearance = NSApp.appearance?.name != appearance?.name
        if !activeOverlays.isEmpty {
            // Complete the visible transition, then apply only the latest selection.
            pendingTransition = changesAppearance ? { [weak preferredWindow] in
                apply(appearance, in: preferredWindow, additionalWindows: additionalWindows, showsHome: showsHome)
            } : nil
            return
        }
        guard changesAppearance else { return }

        var windows: [NSWindow] = []
        if let main = preferredWindow, main.isVisible {
            windows.append(main)
            if let sheet = main.attachedSheet, sheet.isVisible { windows.append(sheet) }
        } else if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
            windows.append(window)
        }
        for window in additionalWindows where window.isVisible && !windows.contains(where: { $0 === window }) {
            windows.append(window)
        }

        var prepared: [(content: NSView, overlay: ThemeRevealOverlay, oldTheme: NSAppearance.Name?)] = []
        let center = NotificationCenter.default
        for window in windows {
            guard let content = window.contentView, let container = content.superview,
                  let oldImage = snapshot(content) else { continue }
            let overlay = ThemeRevealOverlay(frame: container.convert(content.bounds, from: content), oldImage: oldImage,
                                             cornerRadius: window.identifier == SettingsWindowController.identifier || window.sheetParent != nil
                                                ? Theme.settingsRadius : Theme.panelRadius)
            overlay.autoresizingMask = [.width, .height]
            // NSHostingView can rebuild its managed subviews during a theme change.
            // Its native frame keeps the old snapshot and animation above that work.
            container.addSubview(overlay, positioned: .above, relativeTo: content)
            let minimizeObserver = center.addObserver(forName: NSWindow.willMiniaturizeNotification,
                                                     object: window, queue: .main) { [weak overlay] _ in
                overlay?.finish()
            }
            let hideObserver = center.addObserver(forName: NSApplication.willHideNotification,
                                                 object: NSApp, queue: .main) { [weak overlay] _ in
                overlay?.finish()
            }
            overlay.onFinish = { [weak overlay] in
                center.removeObserver(minimizeObserver)
                center.removeObserver(hideObserver)
                activeOverlays.removeAll { $0 === overlay }
                if activeOverlays.isEmpty {
                    let next = pendingTransition
                    pendingTransition = nil
                    next?()
                }
            }
            activeOverlays.append(overlay)
            overlay.observeClose(of: window)
            prepared.append((content, overlay,
                             content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])))
        }
        NSApp.appearance = appearance

        guard let clock = prepared.first?.overlay else { return }
        let windowsToReveal = prepared
        var started = false
        let start = {
            guard !started else { return }
            started = true
            let rendered = windowsToReveal.compactMap { item -> (ThemeRevealOverlay, ThemeRevealLayout, NSAppearance.Name)? in
                guard activeOverlays.contains(where: { $0 === item.overlay }) else { return nil }
                item.content.layoutSubtreeIfNeeded()
                let current = item.content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                guard let window = item.content.window, window.isVisible, let current, current != item.oldTheme else {
                    item.overlay.finish()
                    return nil
                }
                window.displayIfNeeded()
                let layout: ThemeRevealLayout
                if window.identifier == SettingsWindowController.identifier {
                    layout = .settings
                } else if window === preferredWindow {
                    layout = showsHome ? .home : .sidebar
                } else {
                    layout = .single
                }
                return (item.overlay, layout, current)
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                rendered.forEach { $0.0.crossfade() }
            } else {
                let startTime = CACurrentMediaTime() + 0.02
                for (overlay, layout, theme) in rendered {
                    overlay.reveal(layout: layout, toDark: theme == .darkAqua, startTime: startTime)
                }
            }
        }
        // A minimized or occluded display can throttle its display link.
        clock.afterAppearanceRender(start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: start)
    }

    private static func snapshot(_ content: NSView) -> NSImage? {
        guard content.bounds.width > 0, content.bounds.height > 0 else { return nil }
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

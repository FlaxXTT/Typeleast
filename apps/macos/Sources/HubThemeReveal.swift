import AppKit

/// Reveal the new appearance behind a mosaic of the previous appearance.
enum HubThemeReveal {
    private static var activeOverlays: [ThemeMosaicOverlay] = []

    static func apply(_ appearance: NSAppearance?, in preferredWindow: NSWindow? = nil,
                      additionalWindows: [NSWindow] = []) {
        guard NSApp.appearance?.name != appearance?.name else { return }
        let previous = activeOverlays
        activeOverlays.removeAll()
        previous.forEach { $0.finish() }

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

        var prepared: [(window: NSWindow, content: NSView, overlay: ThemeMosaicOverlay, oldTheme: NSAppearance.Name?)] = []
        for window in windows {
            guard let content = window.contentView, let container = content.superview,
                  let oldImage = snapshot(content) else { continue }
            let overlay = ThemeMosaicOverlay(frame: container.convert(content.bounds, from: content), oldImage: oldImage,
                                             cornerRadius: window.identifier == SettingsWindowController.identifier || window.sheetParent != nil
                                                ? Theme.settingsRadius : Theme.panelRadius)
            overlay.autoresizingMask = [.width, .height]
            // NSHostingView can rebuild its managed subviews during a theme change.
            // Its native frame keeps the old snapshot and animation above that work.
            container.addSubview(overlay, positioned: .above, relativeTo: content)
            overlay.onFinish = { [weak overlay] in activeOverlays.removeAll { $0 === overlay } }
            activeOverlays.append(overlay)
            overlay.observeClose(of: window)
            prepared.append((window, content, overlay,
                             content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])))
        }
        NSApp.appearance = appearance
        for item in prepared { item.window.appearance = appearance }

        // Setting appearance is not a completed SwiftUI render. Both the main
        // window and separate Settings window wait for the new display frames.
        for item in prepared {
            let oldTheme = item.oldTheme
            item.overlay.afterAppearanceRender { [weak content = item.content, weak overlay = item.overlay] in
                guard let content, let overlay, activeOverlays.contains(where: { $0 === overlay }) else { return }
                content.layoutSubtreeIfNeeded()
                content.window?.displayIfNeeded()
                guard oldTheme != content.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) else {
                    overlay.finish()
                    return
                }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    overlay.crossfade()
                } else {
                    overlay.scatter()
                }
            }
        }
    }

    private static func snapshot(_ content: NSView) -> NSImage? {
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.effectiveAppearance.performAsCurrentDrawingAppearance {
            content.cacheDisplay(in: content.bounds, to: bitmap)
        }
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

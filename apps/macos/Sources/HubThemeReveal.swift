import AppKit
import QuartzCore

/// Switch light/dark appearance with two shared snapshots and a native 3D mosaic.
enum HubThemeReveal {
    private static weak var activeOverlay: ThemeMosaicOverlay?

    static func apply(_ appearance: NSAppearance?) {
        guard NSApp.appearance?.name != appearance?.name else { return }
        activeOverlay?.finish()
        let oldTheme = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        guard let window = NSApp.keyWindow, window.isVisible,
              let content = window.contentView,
              let oldImage = snapshot(content) else {
            NSApp.appearance = appearance
            return
        }
        let overlay = ThemeMosaicOverlay(frame: content.bounds, oldImage: oldImage)
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay)
        activeOverlay = overlay
        overlay.lockContent(in: window)
        NSApp.appearance = appearance

        // A preference can change without changing the effective light/dark theme.
        guard oldTheme != NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) else {
            overlay.finish()
            return
        }

        // Let the native appearance and SwiftUI layout update under the old image.
        DispatchQueue.main.async { [weak content, weak overlay] in
            guard let content, let overlay, activeOverlay === overlay, overlay.window != nil else { return }
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                overlay.crossfade()
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            overlay.isHidden = true
            let newImage = snapshot(content)
            overlay.isHidden = false
            CATransaction.commit()
            if let newImage { overlay.flip(to: newImage) }
            else { overlay.crossfade() }
        }
    }

    private static func snapshot(_ content: NSView) -> NSImage? {
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

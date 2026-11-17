import AppKit
import QuartzCore

/// Reveal the new native appearance through a growing circle, using one temporary
/// image of the old window rather than a second live SwiftUI page hierarchy.
enum HubThemeReveal {
    private static weak var activeOverlay: NSView?

    static func apply(_ appearance: NSAppearance?) {
        guard NSApp.appearance?.name != appearance?.name else { return }
        activeOverlay?.removeFromSuperview()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let window = NSApp.keyWindow, window.isVisible,
              let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            NSApp.appearance = appearance
            return
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(bitmap)
        let overlay = ThemeRevealImage(frame: content.bounds)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.setAccessibilityElement(false)
        content.addSubview(overlay)
        activeOverlay = overlay
        NSApp.appearance = appearance

        let point = overlay.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let origin = overlay.bounds.contains(point) ? point : NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        let radius = hypot(overlay.bounds.width, overlay.bounds.height)
        func maskPath(radius: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.addRect(overlay.bounds)
            path.addEllipse(in: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2))
            return path
        }
        let mask = CAShapeLayer()
        mask.frame = overlay.bounds
        mask.fillRule = .evenOdd
        mask.path = maskPath(radius: radius)
        overlay.layer?.mask = mask
        let reveal = CABasicAnimation(keyPath: "path")
        reveal.fromValue = maskPath(radius: 0.5)
        reveal.toValue = mask.path
        reveal.duration = 0.32
        reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak overlay] in overlay?.removeFromSuperview() }
        mask.add(reveal, forKey: "appearance-reveal")
        CATransaction.commit()
    }
}

private final class ThemeRevealImage: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

import AppKit
import SwiftUI

/// Rounded native surfaces use the panel radius; the voice capsule has its own geometry.
enum AppWindowStyle {
    static func fixSize(_ window: NSWindow, to size: NSSize) {
        window.styleMask.remove(.resizable)
        window.minSize = size
        window.maxSize = size
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    static func round(_ window: NSWindow, radius: CGFloat = Theme.panelRadius) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.hasShadow = true
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.cornerCurve = .circular
            content.layer?.cornerRadius = min(radius, min(content.bounds.width, content.bounds.height) / 2)
            content.layer?.masksToBounds = true
        }
        if window.sheetParent == nil, let content = window.contentView, let frame = content.superview {
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                if let button = window.standardWindowButton(type) {
                    let rect = NSRect(x: 14 + CGFloat(index) * 20,
                                      y: content.isFlipped ? 14 : content.bounds.maxY - 28,
                                      width: 14, height: 14)
                    if button.superview !== frame {
                        button.removeFromSuperview()
                        frame.addSubview(button, positioned: .above, relativeTo: content)
                    }
                    button.translatesAutoresizingMaskIntoConstraints = true
                    button.autoresizingMask = []
                    button.frame = frame.convert(rect, from: content)
                }
            }
        }
    }
}

struct RoundedWindowMarker: NSViewRepresentable {
    var radius: CGFloat = Theme.panelRadius
    func makeNSView(context: Context) -> WindowRoundingView {
        let view = WindowRoundingView()
        view.radius = radius
        return view
    }
    func updateNSView(_ view: WindowRoundingView, context: Context) { view.radius = radius; view.apply() }
}

final class WindowRoundingView: NSView {
    private weak var configured: NSWindow?
    private var size = NSSize.zero
    var radius: CGFloat = Theme.panelRadius
    private var appliedRadius: CGFloat = -1
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    override func layout() { super.layout(); apply() }
    func apply() {
        guard let window, let content = window.contentView else { return }
        guard configured !== window || size != content.bounds.size || appliedRadius != radius else { return }
        configured = window
        size = content.bounds.size
        appliedRadius = radius
        AppWindowStyle.round(window, radius: radius)
        DispatchQueue.main.async { [weak window, radius] in
            if let window { AppWindowStyle.round(window, radius: radius) }
        }
    }
}

final class CapsuleEditorScrollView: NSScrollView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NativeScrollAppearance.apply(to: self)
    }

    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerCurve = .circular
        layer?.cornerRadius = min(Theme.radius, min(bounds.width, bounds.height) / 2)
        layer?.masksToBounds = true
    }
}

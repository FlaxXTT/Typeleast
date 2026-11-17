import AppKit
import SwiftUI

/// Match border-radius: 99px with circular arcs, including owned window surfaces.
enum AppWindowStyle {
    static func fixSize(_ window: NSWindow, to size: NSSize) {
        window.styleMask.remove(.resizable)
        window.minSize = size
        window.maxSize = size
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.standardWindowButton(.zoomButton)?.isEnabled = false
    }

    static func round(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.hasShadow = true
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.cornerCurve = .circular
            content.layer?.cornerRadius = min(99, min(content.bounds.width, content.bounds.height) / 2)
            content.layer?.masksToBounds = true
        }
        // Use the native frame as parent; the original traffic-light cluster can be
        // too narrow to show buttons moved inward for a 99-point corner.
        if let content = window.contentView, let frame = content.superview {
            for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                if let button = window.standardWindowButton(type) {
                    let rect = NSRect(x: 60 + CGFloat(index) * 20,
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
    func makeNSView(context: Context) -> WindowRoundingView { WindowRoundingView() }
    func updateNSView(_ view: WindowRoundingView, context: Context) { view.apply() }
}

final class WindowRoundingView: NSView {
    private weak var configured: NSWindow?
    private var size = NSSize.zero
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
    override func layout() { super.layout(); apply() }
    func apply() {
        guard let window, let content = window.contentView else { return }
        guard configured !== window || size != content.bounds.size else { return }
        configured = window
        size = content.bounds.size
        AppWindowStyle.round(window)
        DispatchQueue.main.async { [weak window] in
            if let window { AppWindowStyle.round(window) }
        }
    }
}

final class CapsuleEditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        wantsLayer = true
        layer?.cornerCurve = .circular
        layer?.cornerRadius = min(99, min(bounds.width, bounds.height) / 2)
        layer?.masksToBounds = true
    }
}

import AppKit
import SwiftUI

/// Rounded native surfaces use the panel radius; the voice capsule has its own geometry.
enum AppWindowStyle {
    private static let disabledZoomID = NSUserInterfaceItemIdentifier("typeleast.disabledZoom")

    static func fixSize(_ window: NSWindow, to size: NSSize) {
        window.styleMask.remove(.resizable)
        window.minSize = size
        window.maxSize = size
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
    }

    private static func fixedZoomButton(for window: NSWindow, in frame: NSView) -> NSButton? {
        let placeholder = frame.subviews.first(where: { $0.identifier == disabledZoomID }) as? NSButton
        let button: NSButton
        if let native = window.standardWindowButton(.zoomButton) {
            if let placeholder, placeholder !== native { placeholder.removeFromSuperview() }
            button = native
        } else if let placeholder {
            button = placeholder
        } else {
            guard window.styleMask.contains(.titled),
                  let native = NSWindow.standardWindowButton(.zoomButton, for: window.styleMask.union(.resizable))
            else { return nil }
            button = native
            button.identifier = disabledZoomID
        }
        button.isHidden = false
        button.isTransparent = false
        button.isEnabled = false
        return button
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
                let button = type == .zoomButton && window.minSize == window.maxSize
                    ? fixedZoomButton(for: window, in: frame)
                    : window.standardWindowButton(type)
                if let button {
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

/// Explicit native drag targets work even when SwiftUI consumes background clicks.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ view: WindowDragView, context: Context) {
        view.toolTip = L10n.text("拖动窗口")
    }
}

final class WindowDragView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// The locked corner keeps the familiar diagonal shape without offering a resize action.
struct FixedWindowCornerRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> FixedWindowCornerView { FixedWindowCornerView() }
    func updateNSView(_ view: FixedWindowCornerView, context: Context) {}
}

final class FixedWindowCornerView: NSView {
    private static let cursor: NSCursor = {
        let source: NSImage
        let hotspot: NSPoint
        if #available(macOS 15.0, *) {
            let native = NSCursor.frameResize(position: .bottomRight, directions: .all)
            source = native.image
            hotspot = native.hotSpot
        } else {
            source = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))!
            hotspot = NSPoint(x: source.size.width / 2, y: source.size.height / 2)
        }
        let image = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            NSColor(calibratedWhite: 0.55, alpha: 1).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        return NSCursor(image: image, hotSpot: hotspot)
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("Created in code") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.cursor)
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

import AppKit
import SwiftUI
import QuartzCore

/// Keep native wheel/trackpad scrolling. Scroll observations draw only the small HUD;
/// they never publish offsets through the SwiftUI page tree.
struct HubScrollView<Content: View>: View {
    let key: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content.background(HubScrollAnchor(key: key))
        }
    }
}

private enum HubScrollMemory {
    static var offsets: [String: CGFloat] = [:]
}

private struct HubScrollAnchor: NSViewRepresentable {
    let key: String
    func makeNSView(context: Context) -> HubScrollMarker { HubScrollMarker(key: key) }
    func updateNSView(_ view: HubScrollMarker, context: Context) { view.use(key: key) }
    static func dismantleNSView(_ view: HubScrollMarker, coordinator: ()) { view.detach() }
}

private final class HubScrollMarker: NSView {
    private var key: String
    private weak var scroll: NSScrollView?
    private var observer: NSObjectProtocol?
    private let chrome = HubScrollChrome()

    init(key: String) { self.key = key; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Created in code") }
    deinit { detach() }

    func use(key: String) {
        if self.key != key {
            detach()
            self.key = key
        }
        if scroll == nil { scheduleAttach() }
        chrome.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() } else { scheduleAttach() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { scheduleAttach() }
    }

    private func scheduleAttach() {
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard window != nil, scroll == nil, let scroll = enclosingScrollView else { return }
        self.scroll = scroll
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        chrome.scroll = scroll
        chrome.frame = scroll.bounds
        chrome.autoresizingMask = [.width, .height]
        scroll.addSubview(chrome, positioned: .above, relativeTo: clip)
        // SwiftUI finishes the document layout before its native offset is restored.
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll, self.scroll === scroll else { return }
            let height = scroll.documentView?.frame.height ?? 0
            let y = min(max(0, height - scroll.contentView.bounds.height), HubScrollMemory.offsets[self.key] ?? 0)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            self.observe(scroll)
            self.chrome.update()
        }
    }

    private func observe(_ scroll: NSScrollView) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                         object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let self, let scroll = self.scroll else { return }
            HubScrollMemory.offsets[self.key] = scroll.contentView.bounds.minY
            self.chrome.update()
        }
    }

    func detach() {
        if let scroll { HubScrollMemory.offsets[key] = scroll.contentView.bounds.minY }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        chrome.removeFromSuperview()
        chrome.scroll = nil
        scroll = nil
    }
}

private final class HubScrollChrome: NSView {
    weak var scroll: NSScrollView?
    private var progress: CGFloat = 0
    private var showsFade = false
    private let topButton = NSButton()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        topButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: L10n.text("回到顶部"))
        topButton.bezelStyle = .regularSquare
        topButton.isBordered = false
        topButton.toolTip = L10n.text("回到顶部")
        topButton.setAccessibilityLabel(L10n.text("回到顶部"))
        topButton.target = self
        topButton.action = #selector(backToTop)
        topButton.wantsLayer = true
        topButton.layer?.cornerRadius = 16 // min(99, 32 / 2)
        topButton.isHidden = true
        addSubview(topButton)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Created in code") }

    override func layout() {
        super.layout()
        topButton.frame = NSRect(x: bounds.maxX - 52, y: bounds.maxY - 52, width: 32, height: 32)
        update()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    func update() {
        guard let scroll else { return }
        let offset = max(0, scroll.contentView.bounds.minY)
        let extent = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        progress = extent > 0 ? min(1, offset / extent) : 0
        showsFade = extent - offset > 2
        topButton.isHidden = offset < 360
        topButton.contentTintColor = NSColor(Theme.accent)
        topButton.layer?.backgroundColor = NSColor(Theme.card).cgColor
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !topButton.isHidden, topButton.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    @objc private func backToTop() {
        guard let scroll else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.20
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            scroll.contentView.animator().setBoundsOrigin(.zero)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if progress > 0 {
            NSColor(Theme.accent).withAlphaComponent(0.6).setFill()
            NSRect(x: 0, y: 0, width: bounds.width * progress, height: 2).fill()
        }
        if showsFade {
            let colour = NSColor(Theme.window)
            NSGradient(starting: colour.withAlphaComponent(0), ending: colour)?
                .draw(in: NSRect(x: 0, y: bounds.maxY - 24, width: bounds.width, height: 24), angle: 90)
        }
    }
}

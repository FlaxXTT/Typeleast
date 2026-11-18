import AppKit
import SwiftUI
import QuartzCore

/// All app scroll surfaces keep the system's wheel, inertia, keyboard and scroller
/// behaviour. Only the optional progress/fade chrome observes their positions.
struct HubScrollView<Content: View>: View {
    var key: String? = nil
    var showsChrome = true
    var showsProgress = true
    var showsBottomFade = true
    var followsBottom = false
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content.overlay(alignment: .topLeading) {
                HubScrollAnchor(key: key, showsChrome: showsChrome, showsProgress: showsProgress,
                                showsBottomFade: showsBottomFade, followsBottom: followsBottom)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Also used by the native text editors. No wheel-event interception or custom inertia.
enum NativeScrollAppearance {
    static func apply(to scroll: NSScrollView) {
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if !scroll.hasVerticalScroller { scroll.hasVerticalScroller = true }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        if let current = scroll.verticalScroller, !(current is HoverScroller) {
            let replacement = HoverScroller(frame: current.frame)
            replacement.scrollerStyle = .overlay
            replacement.knobStyle = current.knobStyle
            replacement.target = current.target
            replacement.action = current.action
            replacement.isEnabled = current.isEnabled
            replacement.doubleValue = current.doubleValue
            replacement.knobProportion = current.knobProportion
            scroll.verticalScroller = replacement
        }
        if scroll.verticalScroller?.controlSize != .small { scroll.verticalScroller?.controlSize = .small }
    }
}

/// Customize only native scroller drawing, retaining AppKit tracking and momentum.
private final class HoverScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    private var hoverTracking: NSTrackingArea?
    private var hovering = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        hovering = true
        setNeedsDisplay(rect(for: .knob))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovering = false
        setNeedsDisplay(rect(for: .knob))
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        let highlighted = hovering || hitPart == .knob
        let width: CGFloat = highlighted ? 6 : 4
        let thumb = NSRect(x: knob.midX - width / 2, y: knob.minY, width: width, height: knob.height)
        NSColor.labelColor.withAlphaComponent(highlighted ? 0.46 : 0.22).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: width / 2, yRadius: width / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}

private enum HubScrollMemory {
    static var offsets: [String: CGFloat] = [:]
}

private struct HubScrollAnchor: NSViewRepresentable {
    let key: String?
    let showsChrome: Bool
    let showsProgress: Bool
    let showsBottomFade: Bool
    let followsBottom: Bool

    func makeNSView(context: Context) -> HubScrollMarker {
        HubScrollMarker(key: key, showsChrome: showsChrome, showsProgress: showsProgress,
                        showsBottomFade: showsBottomFade, followsBottom: followsBottom)
    }
    func updateNSView(_ view: HubScrollMarker, context: Context) {
        view.use(key: key, showsChrome: showsChrome, showsProgress: showsProgress,
                 showsBottomFade: showsBottomFade, followsBottom: followsBottom)
    }
    static func dismantleNSView(_ view: HubScrollMarker, coordinator: ()) { view.detach() }
}

private final class ScrollFrameTarget: NSObject {
    weak var owner: HubScrollMarker?
    init(owner: HubScrollMarker) { self.owner = owner }
    @objc func displayFrame(_ link: CADisplayLink) { owner?.displayFrame() }
}

private final class HubScrollMarker: NSView {
    private var key: String?
    private var showsChrome: Bool
    private var followsBottom: Bool
    private weak var scroll: NSScrollView?
    private var observers: [NSObjectProtocol] = []
    private let chrome = HubScrollChrome()
    private lazy var frameTarget = ScrollFrameTarget(owner: self)
    private var frameLink: CADisplayLink?
    private var geometryDirty = true
    private var viewportSize = NSSize.zero
    private var extent: CGFloat = 0
    private var lastOffset: CGFloat = 0
    private var nearBottom = true
    private var liveScrolling = false

    init(key: String?, showsChrome: Bool, showsProgress: Bool, showsBottomFade: Bool, followsBottom: Bool) {
        self.key = key
        self.showsChrome = showsChrome
        self.followsBottom = followsBottom
        super.init(frame: .zero)
        chrome.showsProgress = showsProgress
        chrome.showsBottomFade = showsBottomFade
    }
    required init?(coder: NSCoder) { fatalError("Created in code") }
    deinit { detach() }

    func use(key: String?, showsChrome: Bool, showsProgress: Bool, showsBottomFade: Bool, followsBottom: Bool) {
        if chrome.showsProgress != showsProgress {
            chrome.showsProgress = showsProgress
        }
        if chrome.showsBottomFade != showsBottomFade {
            chrome.showsBottomFade = showsBottomFade
            requestFrame()
        }
        if self.key != key || self.showsChrome != showsChrome || self.followsBottom != followsBottom {
            detach()
            self.key = key
            self.showsChrome = showsChrome
            self.followsBottom = followsBottom
        }
        if scroll == nil { scheduleAttach() }
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
        NativeScrollAppearance.apply(to: scroll)
        // A page that only remembers its position needs no live scroll observer.
        if showsChrome || followsBottom { observeVisibleScroll(scroll) }

        guard key != nil || followsBottom || showsChrome else { return }
        DispatchQueue.main.async { [weak self, weak scroll] in
            guard let self, let scroll, self.scroll === scroll else { return }
            self.readGeometry(scroll)
            if self.followsBottom {
                self.move(scroll, to: self.extent)
            } else if let key = self.key {
                self.move(scroll, to: min(self.extent, max(0, HubScrollMemory.offsets[key] ?? 0)))
            }
            self.lastOffset = scroll.contentView.bounds.minY
            self.nearBottom = self.extent - self.lastOffset <= 40
            self.requestFrame()
        }
    }

    private func observeVisibleScroll(_ scroll: NSScrollView) {
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        if showsChrome {
            chrome.frame = scroll.bounds
            chrome.autoresizingMask = [.width, .height]
            chrome.scroll = scroll
            scroll.addSubview(chrome, positioned: .above, relativeTo: clip)
        }
        let link = scroll.displayLink(target: frameTarget, selector: #selector(ScrollFrameTarget.displayFrame(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        frameLink = link

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                             object: clip, queue: nil) { [weak self] _ in
            // A passive observation: read no document sizes and rebuild no SwiftUI view.
            self?.requestFrame()
        })
        if let document = scroll.documentView {
            document.postsFrameChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.frameDidChangeNotification,
                                                 object: document, queue: nil) { [weak self] _ in
                self?.geometryDirty = true
                self?.requestFrame()
            })
        }
        if followsBottom {
            observers.append(center.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                                 object: scroll, queue: nil) { [weak self] _ in
                self?.liveScrolling = true
            })
            observers.append(center.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                                                 object: scroll, queue: nil) { [weak self] _ in
                self?.liveScrolling = false
                self?.requestFrame()
            })
        }
    }

    private func requestFrame() {
        guard let frameLink, frameLink.isPaused else { return }
        frameLink.isPaused = false
    }

    private func readGeometry(_ scroll: NSScrollView) {
        viewportSize = scroll.contentView.bounds.size
        extent = max(0, (scroll.documentView?.frame.height ?? 0) - viewportSize.height)
        geometryDirty = false
    }

    private func move(_ scroll: NSScrollView, to offset: CGFloat) {
        guard abs(scroll.contentView.bounds.minY - offset) > 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func displayFrame() {
        frameLink?.isPaused = true
        guard let scroll else { return }
        let offset = max(0, scroll.contentView.bounds.minY)
        if abs(offset - lastOffset) > 0.5 {
            nearBottom = extent - offset <= 40
        }
        if geometryDirty || viewportSize != scroll.contentView.bounds.size {
            let follow = followsBottom && nearBottom && !liveScrolling
            readGeometry(scroll)
            if follow { move(scroll, to: extent) }
        }
        lastOffset = max(0, scroll.contentView.bounds.minY)
        nearBottom = extent - lastOffset <= 40
        if showsChrome { chrome.update(offset: lastOffset, extent: extent) }
    }

    func detach() {
        if let scroll, let key { HubScrollMemory.offsets[key] = scroll.contentView.bounds.minY }
        frameLink?.invalidate()
        frameLink = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        chrome.removeFromSuperview()
        chrome.scroll = nil
        scroll = nil
        geometryDirty = true
        viewportSize = .zero
        extent = 0
        lastOffset = 0
        nearBottom = true
        liveScrolling = false
    }
}

private final class HubScrollChrome: NSView {
    var showsProgress = true { didSet { progressLayer.isHidden = !showsProgress } }
    var showsBottomFade = true
    weak var scroll: NSScrollView?
    private var progressWidth: CGFloat = 0
    private var showsFade = false
    private let topButton = NSButton()
    private let progressLayer = CALayer()
    private let fadeLayer = CAGradientLayer()
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(progressLayer)
        layer?.addSublayer(fadeLayer)
        fadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        fadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
        fadeLayer.isHidden = true
        topButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: L10n.text("回到顶部"))
        topButton.bezelStyle = .regularSquare
        topButton.isBordered = false
        topButton.toolTip = L10n.text("回到顶部")
        topButton.setAccessibilityLabel(L10n.text("回到顶部"))
        topButton.target = self
        topButton.action = #selector(backToTop)
        topButton.wantsLayer = true
        topButton.layer?.cornerRadius = Theme.smallControlRadius
        topButton.isHidden = true
        addSubview(topButton)
        updateColours()
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Created in code") }

    override func layout() {
        super.layout()
        topButton.frame = NSRect(x: bounds.maxX - 52, y: bounds.maxY - 52, width: 32, height: 32)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.frame = NSRect(x: 0, y: 0, width: progressWidth, height: 2)
        fadeLayer.frame = NSRect(x: 0, y: bounds.maxY - 24, width: bounds.width, height: 24)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColours()
    }
    private func updateColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            topButton.contentTintColor = NSColor(Theme.accent)
            topButton.layer?.backgroundColor = NSColor(Theme.card).cgColor
            progressLayer.backgroundColor = NSColor(Theme.accent).withAlphaComponent(0.6).cgColor
            let background = NSColor(Theme.window)
            fadeLayer.colors = [background.withAlphaComponent(0).cgColor, background.cgColor]
            CATransaction.commit()
        }
    }

    func update(offset: CGFloat, extent: CGFloat) {
        let scale = window?.backingScaleFactor ?? 2
        let width = ((extent > 0 ? min(1, offset / extent) : 0) * bounds.width * scale).rounded() / scale
        let fade = showsBottomFade && extent - offset > 2
        let hideButton = offset < 360
        if topButton.isHidden != hideButton { topButton.isHidden = hideButton }
        if progressWidth != width || showsFade != fade {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progressWidth = width
            showsFade = fade
            progressLayer.frame.size.width = width
            fadeLayer.isHidden = !fade
            CATransaction.commit()
        }
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

}

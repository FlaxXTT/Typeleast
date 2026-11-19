import AppKit
import QuartzCore

enum ThemeRevealLayout {
    case home, sidebar, settings, single

    static let fadeDuration: TimeInterval = 0.324
    private static let lastSectionDelay: TimeInterval = 0.166

    func boundaries(in width: CGFloat) -> [CGFloat] {
        let dividers: [CGFloat]
        switch self {
        case .home:
            let columnWidth = max(0, width - Theme.sidebarWidth - 2 * HomePage.horizontalInset - HomePage.columnGap)
            let columnDivider = Theme.sidebarWidth + HomePage.horizontalInset
                + columnWidth * HomePage.insightsFraction + HomePage.columnGap / 2
            dividers = [Theme.sidebarWidth, columnDivider]
        case .sidebar:
            dividers = [Theme.sidebarWidth]
        case .settings:
            dividers = [SettingsPage.sidebarWidth]
        case .single:
            dividers = []
        }
        return [0] + dividers.filter { $0 < width } + [width]
    }

    static func delay(for index: Int, count: Int, toDark: Bool) -> TimeInterval {
        guard count > 1 else { return 0 }
        let order = toDark ? count - 1 - index : index
        return lastSectionDelay * Double(order) / Double(count - 1)
    }
}

final class ThemeRevealOverlay: NSView {
    var onFinish: (() -> Void)?
    private let cover: NSImageView
    private var appearanceLink: CADisplayLink?
    private var appearanceFrames = 0
    private var renderReady: (() -> Void)?
    private var windowCloseObserver: NSObjectProtocol?

    init(frame: NSRect, oldImage: NSImage, cornerRadius: CGFloat) {
        cover = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .circular
        layer?.cornerRadius = min(cornerRadius, min(frame.width, frame.height) / 2)
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        cover.image = oldImage
        cover.imageScaling = .scaleAxesIndependently
        cover.autoresizingMask = [.width, .height]
        addSubview(cover)
    }

    required init?(coder: NSCoder) { fatalError("Created in code") }

    func observeClose(of window: NSWindow) {
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                      object: window, queue: .main) { [weak self] _ in
            self?.finish()
        }
    }

    func afterAppearanceRender(_ ready: @escaping () -> Void) {
        renderReady = ready
        appearanceFrames = 0
        let link = displayLink(target: self, selector: #selector(appearanceFrame(_:)))
        appearanceLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func appearanceFrame(_ link: CADisplayLink) {
        appearanceFrames += 1
        guard appearanceFrames >= 2 else { return }
        let ready = renderReady
        stopWaitingForRender()
        ready?()
    }

    private func stopWaitingForRender() {
        appearanceLink?.invalidate()
        appearanceLink = nil
        renderReady = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func finish() {
        let completion = onFinish
        onFinish = nil
        stopWaitingForRender()
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        removeFromSuperview()
        completion?()
    }

    func crossfade() {
        stopWaitingForRender()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.finish() }
    }

    func reveal(layout: ThemeRevealLayout, toDark: Bool, startTime: CFTimeInterval) {
        stopWaitingForRender()
        guard let layer, bounds.width > 0,
              let image = cover.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            crossfade()
            return
        }
        let pixelWidth = CGFloat(image.width)
        let scale = pixelWidth / bounds.width
        // Use adjacent pixel-aligned slices of one snapshot so no content shifts at a divider.
        let edges = layout.boundaries(in: bounds.width).map { ($0 * scale).rounded() }
        let sections = zip(edges, edges.dropFirst()).filter { $0.0 < $0.1 }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        for (index, section) in sections.enumerated() {
            let (left, right) = section
            let slice = CALayer()
            slice.frame = CGRect(x: bounds.minX + left / scale, y: bounds.minY,
                                 width: (right - left) / scale, height: bounds.height)
            slice.contents = image
            slice.contentsScale = scale
            slice.contentsRect = CGRect(x: left / pixelWidth, y: 0, width: (right - left) / pixelWidth, height: 1)
            slice.opacity = 0
            layer.addSublayer(slice)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = ThemeRevealLayout.fadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.fillMode = .backwards
            fade.beginTime = slice.convertTime(startTime, from: nil)
                + ThemeRevealLayout.delay(for: index, count: sections.count, toDark: toDark)
            slice.add(fade, forKey: "theme-reveal")
        }
        cover.isHidden = true
        CATransaction.commit()
    }
}

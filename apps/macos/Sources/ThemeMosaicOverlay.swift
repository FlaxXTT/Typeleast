import AppKit
import QuartzCore

private struct ThemeMosaicGrid {
    let columns: Int
    let rows: Int

    init(size: NSSize) {
        let preferred = max(96, min(144, Double(size.width * size.height) / (90 * 90)))
        var best = (columns: 12, rows: 8)
        var bestScore = Double.infinity
        for columns in 4...24 {
            for rows in 4...24 {
                let count = columns * rows
                guard (96...144).contains(count) else { continue }
                let tileAspect = Double(size.width / CGFloat(columns)) / Double(size.height / CGFloat(rows))
                let score = abs(log(tileAspect)) + abs(Double(count) - preferred) / preferred * 0.25
                if score < bestScore {
                    best = (columns, rows)
                    bestScore = score
                }
            }
        }
        columns = best.columns
        rows = best.rows
    }
}

final class ThemeMosaicOverlay: NSView {
    var onFinish: (() -> Void)?
    private static let flightDuration: TimeInterval = 0.59
    private static let waveDuration: TimeInterval = 0.28
    private static let gap: CGFloat = 0.75
    private let oldImage: NSImage
    private let cover: NSImageView
    private var appearanceLink: CADisplayLink?
    private var appearanceFrames = 0
    private var renderReady: (() -> Void)?
    private var windowCloseObserver: NSObjectProtocol?

    init(frame: NSRect, oldImage: NSImage, cornerRadius: CGFloat = Theme.panelRadius) {
        self.oldImage = oldImage
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
        guard appearanceFrames == 2 else { return }
        link.invalidate()
        appearanceLink = nil
        let ready = renderReady
        renderReady = nil
        ready?()
    }

    // Theme transitions are visual. The underlying buttons retain focus and hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func finish() {
        let completion = onFinish
        onFinish = nil
        appearanceLink?.invalidate()
        appearanceLink = nil
        renderReady = nil
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        removeFromSuperview()
        completion?()
    }

    func crossfade() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.finish() }
    }

    func scatter() {
        guard let root = layer,
              let image = oldImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            crossfade()
            return
        }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { finish(); return }
        let originalGrid = ThemeMosaicGrid(size: size)
        // Splitting each axis by sqrt(8) gives approximately one eighth the cell area.
        let columns = Int((Double(originalGrid.columns) * sqrt(8)).rounded())
        let rows = Int((Double(originalGrid.rows) * sqrt(8)).rounded())
        let scale = window?.backingScaleFactor ?? 2
        let start = CACurrentMediaTime()
        let scene = CALayer()
        scene.frame = bounds
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 850
        scene.sublayerTransform = perspective

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        root.addSublayer(scene)

        for row in 0..<rows {
            for column in 0..<columns {
                let left = size.width * CGFloat(column) / CGFloat(columns)
                let right = size.width * CGFloat(column + 1) / CGFloat(columns)
                let bottom = size.height * CGFloat(rows - row - 1) / CGFloat(rows)
                let top = size.height * CGFloat(rows - row) / CGFloat(rows)
                let rect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
                    .insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
                let tile = CALayer()
                tile.bounds = CGRect(origin: .zero, size: rect.size)
                tile.position = CGPoint(x: rect.midX, y: rect.midY)
                tile.contents = image
                tile.contentsRect = CGRect(x: rect.minX / size.width, y: (size.height - rect.maxY) / size.height,
                                           width: rect.width / size.width, height: rect.height / size.height)
                tile.contentsScale = scale
                scene.addSublayer(tile)

                let horizontal = (row + column).isMultiple(of: 2)
                let direction: CGFloat = (row * 3 + column * 5).isMultiple(of: 3) ? -1 : 1
                let dx = (rect.midX / size.width - 0.5) * 172 + direction * 22
                let dy = (rect.midY / size.height - 0.5) * 92 + 56
                let destination = CGPoint(x: rect.midX + dx, y: rect.midY + dy)
                let rotation = CATransform3DMakeRotation(direction * 1.15, horizontal ? 1 : 0, horizontal ? 0 : 1, 0)
                let departure = CATransform3DConcat(rotation, CATransform3DMakeScale(0.65, 0.65, 1))

                let drift = CABasicAnimation(keyPath: "position")
                drift.fromValue = tile.position
                drift.toValue = destination
                let spin = CABasicAnimation(keyPath: "transform")
                spin.fromValue = CATransform3DIdentity
                spin.toValue = departure
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [1, 0.9, 0]
                fade.keyTimes = [0, 0.22, 1]
                let animations: [CAAnimation] = [drift, spin, fade]
                for animation in animations { animation.duration = Self.flightDuration }

                let flight = CAAnimationGroup()
                flight.animations = animations
                flight.duration = Self.flightDuration
                flight.beginTime = start + Double(row + column) / Double(rows + columns - 2) * Self.waveDuration
                flight.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.45, 0.4, 1)
                flight.fillMode = .backwards

                tile.position = destination
                tile.transform = departure
                tile.opacity = 0
                tile.add(flight, forKey: "theme-scatter")
            }
        }

        cover.isHidden = true
        CATransaction.commit()
    }
}

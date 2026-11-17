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
    private static let flipDuration: TimeInterval = 0.42
    private static let waveDuration: TimeInterval = 0.32
    private static let settleDuration: TimeInterval = 0.04
    private static let fadeDuration: TimeInterval = 0.12
    private static let gap: CGFloat = 2
    private let oldImage: NSImage
    private let cover: NSImageView
    private weak var previousResponder: NSResponder?
    private var appearanceLink: CADisplayLink?
    private var appearanceFrames = 0
    private var renderReady: (() -> Void)?
    private var windowCloseObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }

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

    func lockContent(in window: NSWindow) {
        previousResponder = window.firstResponder
        window.makeFirstResponder(self)
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

    // Consume content input while its two snapshots are on screen.
    override func hitTest(_ point: NSPoint) -> NSView? { self }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}

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
        if let window, window.firstResponder === self {
            window.makeFirstResponder(previousResponder)
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

    func flip(to newImage: NSImage) {
        guard let root = layer,
              let old = oldImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let new = newImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            crossfade()
            return
        }
        let size = bounds.size
        let grid = ThemeMosaicGrid(size: size)
        let scale = window?.backingScaleFactor ?? 2
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        let start = CACurrentMediaTime()
        let scene = CALayer()
        scene.frame = bounds
        scene.backgroundColor = NSColor(Theme.detail).cgColor
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 900
        scene.sublayerTransform = perspective

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        root.addSublayer(scene)

        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                // Rows count from the top; native layer coordinates grow from the bottom.
                let left = (size.width * CGFloat(column) / CGFloat(grid.columns) * scale).rounded() / scale
                let right = (size.width * CGFloat(column + 1) / CGFloat(grid.columns) * scale).rounded() / scale
                let bottom = (size.height * CGFloat(grid.rows - row - 1) / CGFloat(grid.rows) * scale).rounded() / scale
                let top = (size.height * CGFloat(grid.rows - row) / CGFloat(grid.rows) * scale).rounded() / scale
                let rect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
                    .insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
                // Image crops start at the top, while these layer positions start
                // at the bottom. Keep each old/new image fragment in its own row.
                let crop = CGRect(x: rect.minX / size.width, y: (size.height - rect.maxY) / size.height,
                                  width: rect.width / size.width, height: rect.height / size.height)
                let horizontal = (row + column).isMultiple(of: 2)
                let x: CGFloat = horizontal ? 1 : 0
                let y: CGFloat = horizontal ? 0 : 1
                let rotation = CATransform3DMakeRotation(.pi, x, y, 0)
                let tile = CATransformLayer()
                tile.bounds = CGRect(origin: .zero, size: rect.size)
                tile.position = CGPoint(x: rect.midX, y: rect.midY)
                tile.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                scene.addSublayer(tile)

                let front = face(old, crop: crop, size: rect.size, scale: scale)
                let back = face(new, crop: crop, size: rect.size, scale: scale)
                back.transform = rotation
                back.zPosition = -0.1
                let shade = CALayer()
                shade.frame = back.bounds
                shade.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
                back.addSublayer(shade)
                let highlight = CALayer()
                highlight.frame = CGRect(x: 0, y: rect.height - 1 / scale, width: rect.width, height: 1 / scale)
                highlight.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
                back.addSublayer(highlight)
                tile.addSublayer(front)
                tile.addSublayer(back)

                // Equal row+column diagonals start together, strictly top-left to bottom-right.
                let delay = Double(row + column) / Double(grid.rows + grid.columns - 2) * Self.waveDuration
                tile.transform = rotation
                let flip = CABasicAnimation(keyPath: horizontal ? "transform.rotation.x" : "transform.rotation.y")
                flip.fromValue = 0
                flip.toValue = Double.pi
                flip.beginTime = start + delay
                flip.duration = Self.flipDuration
                flip.timingFunction = timing
                flip.fillMode = .backwards
                tile.add(flip, forKey: "theme-flip")

                let lift = CAKeyframeAnimation(keyPath: "transform.translation.z")
                lift.values = [0, 10, 0]
                lift.keyTimes = [0, 0.45, 1]
                lift.timingFunctions = [timing, timing]
                lift.beginTime = start + delay
                lift.duration = Self.flipDuration
                lift.fillMode = .backwards
                tile.add(lift, forKey: "theme-lift")
            }
        }

        cover.isHidden = true
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = start + Self.waveDuration + Self.flipDuration + Self.settleDuration
        fade.duration = Self.fadeDuration
        fade.fillMode = .backwards
        fade.timingFunction = timing
        scene.opacity = 0
        scene.add(fade, forKey: "theme-finish")
        CATransaction.commit()
    }

    private func face(_ image: CGImage, crop: CGRect, size: CGSize, scale: CGFloat) -> CALayer {
        let face = CALayer()
        face.frame = CGRect(origin: .zero, size: size)
        let pixels = CGRect(x: (crop.minX * CGFloat(image.width)).rounded(),
                            y: (crop.minY * CGFloat(image.height)).rounded(),
                            width: (crop.width * CGFloat(image.width)).rounded(),
                            height: (crop.height * CGFloat(image.height)).rounded())
        face.contents = image.cropping(to: pixels)
        face.contentsGravity = .resize
        face.contentsScale = scale
        face.isDoubleSided = false
        face.borderWidth = 1 / scale
        face.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        face.shadowColor = NSColor.black.cgColor
        face.shadowOpacity = 0.16
        face.shadowRadius = 5
        face.shadowOffset = CGSize(width: 0, height: -2)
        face.shadowPath = CGPath(rect: face.bounds, transform: nil)
        return face
    }
}

import AppKit
import QuartzCore

/// The transparent 750×500 carrier. Only the capsule is interactive.
final class RecordingOverlayHost: NSView {
    let pill: PillView
    private let modeLabel = NSTextField(labelWithString: "")
    private let nearShadow = CALayer()
    private let farShadow = CALayer()
    override var isOpaque: Bool { false }

    init(pill: PillView) {
        self.pill = pill
        super.init(frame: NSRect(origin: .zero, size: VoiceBarGeometry.overlay))
        wantsLayer = true
        for (shadow, opacity, blur, drop) in [(farShadow, Float(0.25), CGFloat(15), CGFloat(-25)),
                                             (nearShadow, Float(0.15), CGFloat(10), CGFloat(0))] {
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = opacity
            shadow.shadowRadius = blur
            shadow.shadowOffset = CGSize(width: 0, height: drop)
            layer?.addSublayer(shadow)
        }
        addSubview(pill)
        modeLabel.font = InterfaceTypography.localizedAppKit(12, weight: .semibold)
        modeLabel.textColor = .white
        modeLabel.alignment = .center
        modeLabel.lineBreakMode = .byTruncatingTail
        modeLabel.maximumNumberOfLines = 1
        modeLabel.wantsLayer = true
        modeLabel.layer?.backgroundColor = VoiceBarPalette.card.cgColor
        modeLabel.layer?.cornerRadius = min(Theme.radius, 14)
        modeLabel.layer?.borderColor = VoiceBarPalette.edge.cgColor
        modeLabel.layer?.borderWidth = 1
        modeLabel.isHidden = true
        addSubview(modeLabel)
    }
    required init?(coder: NSCoder) { fatalError("Created in code") }

    func apply(_ model: RecordingBarModel) {
        var text = model.isStartingMicrophone ? "" : model.warning ? model.resultText : model.badge
        let remaining = pill.limitSeconds - model.elapsed
        if model.phase == .recording, remaining <= PillView.countdownSeconds {
            let countdown = RecordingBarFormat.elapsed(remaining)
            text = text.isEmpty ? countdown : text + " · " + countdown
        }
        if modeLabel.stringValue != text {
            modeLabel.stringValue = text
            modeLabel.isHidden = text.isEmpty
            needsLayout = true
        }
        let tip = model.warning ? model.resultText : (model.badge.isEmpty ? model.detail : model.badge)
        if pill.toolTip != tip { pill.toolTip = tip }
    }

    var hintTop: CGFloat { max(pill.frame.maxY, modeLabel.isHidden ? 0 : modeLabel.frame.maxY) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = min(99, min(pill.frame.width, pill.frame.height) / 2)
        for shadow in [nearShadow, farShadow] {
            shadow.frame = pill.frame
            shadow.shadowPath = CGPath(roundedRect: shadow.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        CATransaction.commit()
        let width = min(bounds.width - 32, modeLabel.fittingSize.width + 28)
        modeLabel.frame = NSRect(x: (bounds.width - width) / 2, y: pill.frame.maxY + 10, width: width, height: 28)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return VoiceBarGeometry.contains(local, in: pill.frame) ? super.hitTest(point) : nil
    }
}

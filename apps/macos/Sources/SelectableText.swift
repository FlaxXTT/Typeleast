import AppKit
import SwiftUI

// SelectableText.swift - history text the user can select and copy. A plain click (no selection
// made) still reaches the row, which expands it.

struct SelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    /// 0 for no limit.
    let maxLines: Int
    var lineHeight: CGFloat? = nil
    var acceptsInactiveClick = false
    let onPlainClick: () -> Void

    func makeNSView(context: Context) -> HistoryTextView {
        let view = HistoryTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        // SwiftUI proposes the text width before assigning the native frame. Letting
        // AppKit replace that width during layout can leave a stale, shorter height.
        view.textContainer?.widthTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: HistoryTextView, context: Context) {
        var layoutChanged = false
        if view.string != text { view.string = text; layoutChanged = true }
        if view.font != font { view.font = font; layoutChanged = true }
        if view.textColor != color { view.textColor = color }
        if view.lineHeight != lineHeight { view.lineHeight = lineHeight; layoutChanged = true }
        if let container = view.textContainer {
            let mode: NSLineBreakMode = maxLines == 0 ? .byWordWrapping : .byTruncatingTail
            if container.maximumNumberOfLines != maxLines {
                container.maximumNumberOfLines = maxLines; layoutChanged = true
            }
            if container.lineBreakMode != mode { container.lineBreakMode = mode; layoutChanged = true }
        }
        view.onPlainClick = onPlainClick
        view.acceptsInactiveClick = acceptsInactiveClick
        if layoutChanged {
            let paragraph = NSMutableParagraphStyle()
            if let lineHeight { paragraph.minimumLineHeight = lineHeight; paragraph.maximumLineHeight = lineHeight }
            view.defaultParagraphStyle = paragraph
            view.textStorage?.addAttribute(.paragraphStyle, value: paragraph,
                                            range: NSRange(location: 0, length: view.string.utf16.count))
            view.invalidateMeasurement()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: HistoryTextView, context: Context) -> CGSize? {
        view.measuredSize(width: proposal.width ?? (view.bounds.width > 0 ? view.bounds.width : 400))
    }
}

final class HistoryTextView: NSTextView {
    var lineHeight: CGFloat?
    var onPlainClick: (() -> Void)?
    var acceptsInactiveClick = false
    private var cachedMeasurement: CGSize?

    override var string: String {
        didSet { if string != oldValue { cachedMeasurement = nil } }
    }

    override var font: NSFont? {
        didSet { if font != oldValue { cachedMeasurement = nil } }
    }

    func invalidateMeasurement() {
        cachedMeasurement = nil
        invalidateIntrinsicContentSize()
    }

    func measuredSize(width: CGFloat) -> CGSize {
        let width = max(1, width)
        if let cachedMeasurement, cachedMeasurement.width == width { return cachedMeasurement }
        guard let container = textContainer, let layout = layoutManager else { return CGSize(width: width, height: 20) }
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let size = CGSize(width: width, height: max(1, ceil(layout.usedRect(for: container).height)))
        cachedMeasurement = size
        return size
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changedWidth = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changedWidth {
            _ = measuredSize(width: newSize.width)
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        guard bounds.width > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 20) }
        return NSSize(width: NSView.noIntrinsicMetric, height: measuredSize(width: bounds.width).height)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        acceptsInactiveClick || super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // super tracks the drag; with nothing selected it was a click on the row.
        if selectedRange().length == 0 { onPlainClick?() }
    }
}

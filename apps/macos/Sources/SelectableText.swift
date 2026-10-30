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
        if view.string != text { view.string = text }
        view.font = font
        view.textColor = color
        view.textContainer?.maximumNumberOfLines = maxLines
        view.textContainer?.lineBreakMode = maxLines == 0 ? .byWordWrapping : .byTruncatingTail
        view.onPlainClick = onPlainClick
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: HistoryTextView, context: Context) -> CGSize? {
        view.measuredSize(width: proposal.width ?? (view.bounds.width > 0 ? view.bounds.width : 400))
    }
}

final class HistoryTextView: NSTextView {
    var onPlainClick: (() -> Void)?

    func measuredSize(width: CGFloat) -> CGSize {
        let width = max(1, width)
        guard let container = textContainer, let layout = layoutManager else { return CGSize(width: width, height: 20) }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: max(1, ceil(layout.usedRect(for: container).height)))
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

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // super tracks the drag; with nothing selected it was a click on the row.
        if selectedRange().length == 0 { onPlainClick?() }
    }
}

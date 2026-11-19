import AppKit
import SwiftUI

/// Nonactivating panels can own text focus while another app still owns the menu bar.
class TextShortcutPanel: NSPanel {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let text = firstResponder as? NSTextView {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if modifiers == .command {
                switch key {
                case "a": text.selectAll(nil); return
                case "c": text.copy(nil); return
                case "v" where text.isEditable: text.paste(nil); return
                case "x" where text.isEditable: text.cut(nil); return
                case "z" where text.isEditable: text.undoManager?.undo(); return
                default: break
                }
            } else if modifiers == [.shift, .command], key == "z", text.isEditable {
                text.undoManager?.redo()
                return
            }
        }
        super.sendEvent(event)
    }
}

// SelectableText.swift - history text the user can select and copy. A plain click (no selection
// made) still reaches the row, which expands it.

struct SelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    /// 0 for no limit.
    let maxLines: Int
    var lineHeight: CGFloat? = nil
    var paragraphStyle: NSParagraphStyle? = nil
    var maxViewportHeight: CGFloat? = nil
    var acceptsInactiveClick = false
    var onSelectionChange: ((String?) -> Void)? = nil
    let onPlainClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
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
        view.delegate = context.coordinator
        if maxViewportHeight != nil {
            let scroll = SelectableTextScrollView()
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            NativeScrollAppearance.apply(to: scroll)
            scroll.documentView = view
            return scroll
        }
        return view
    }

    func updateNSView(_ host: NSView, context: Context) {
        guard let view = textView(in: host) else { return }
        var layoutChanged = false
        if view.string != text { view.string = text; layoutChanged = true }
        if view.font != font { view.font = font; layoutChanged = true }
        if view.textColor != color { view.textColor = color }
        if view.lineHeight != lineHeight { view.lineHeight = lineHeight; layoutChanged = true }
        if let paragraphStyle, view.defaultParagraphStyle != paragraphStyle { layoutChanged = true }
        if let container = view.textContainer {
            let mode: NSLineBreakMode = maxLines == 0 ? .byWordWrapping : .byTruncatingTail
            if container.maximumNumberOfLines != maxLines {
                container.maximumNumberOfLines = maxLines; layoutChanged = true
            }
            if container.lineBreakMode != mode { container.lineBreakMode = mode; layoutChanged = true }
        }
        view.onPlainClick = onPlainClick
        view.acceptsInactiveClick = acceptsInactiveClick
        context.coordinator.onSelectionChange = onSelectionChange
        if layoutChanged {
            let paragraph = paragraphStyle ?? fixedLineStyle
            view.defaultParagraphStyle = paragraph
            if let storage = view.textStorage {
                storage.beginEditing()
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
                if paragraphStyle != nil { spaceBlankParagraphs(in: storage, using: paragraph) }
                storage.endEditing()
            }
            view.invalidateMeasurement()
            if host !== view { host.invalidateIntrinsicContentSize(); host.needsLayout = true }
        }
    }

    private var fixedLineStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        if let lineHeight {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        return style
    }

    /// Render existing blank lines as paragraph gaps without touching the text users copy.
    private func spaceBlankParagraphs(in storage: NSTextStorage, using paragraph: NSParagraphStyle) {
        guard paragraph.paragraphSpacing > 0,
              let adjoining = paragraph.mutableCopy() as? NSMutableParagraphStyle,
              let blank = paragraph.mutableCopy() as? NSMutableParagraphStyle else { return }
        adjoining.paragraphSpacing = 0
        blank.paragraphSpacing = 0
        blank.minimumLineHeight = paragraph.paragraphSpacing
        blank.maximumLineHeight = paragraph.paragraphSpacing

        let text = storage.string as NSString
        var location = 0
        var previousText: NSRange?
        while location < text.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            if text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                storage.addAttribute(.paragraphStyle, value: blank, range: range)
                if let previousText { storage.addAttribute(.paragraphStyle, value: adjoining, range: previousText) }
                previousText = nil
            } else {
                previousText = range
            }
            location = NSMaxRange(range)
        }
    }

    private func textView(in host: NSView) -> HistoryTextView? {
        (host as? HistoryTextView) ?? ((host as? NSScrollView)?.documentView as? HistoryTextView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView host: NSView, context: Context) -> CGSize? {
        guard let view = textView(in: host) else { return nil }
        let natural = view.measuredSize(width: proposal.width ?? (host.bounds.width > 0 ? host.bounds.width : 400))
        guard let maxViewportHeight else { return natural }
        return CGSize(width: natural.width, height: min(maxViewportHeight, natural.height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onSelectionChange: ((String?) -> Void)?

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, onSelectionChange != nil else { return }
            let range = view.selectedRange()
            let text = view.string as NSString
            let selection = range.length > 0 && NSMaxRange(range) <= text.length ? text.substring(with: range) : nil
            DispatchQueue.main.async { [weak self] in self?.onSelectionChange?(selection) }
        }
    }
}

private final class SelectableTextScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let text = documentView as? HistoryTextView, contentSize.width > 0 else { return }
        let size = text.measuredSize(width: contentSize.width)
        if text.frame.size != size { text.setFrameSize(size) }
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

    override var needsPanelToBecomeKey: Bool {
        acceptsInactiveClick || super.needsPanelToBecomeKey
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // super tracks the drag; with nothing selected it was a click on the row.
        if selectedRange().length == 0 { onPlainClick?() }
    }
}

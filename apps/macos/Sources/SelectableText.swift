import AppKit
import SwiftUI

// SelectableText.swift - history text the user can select, with 「加入词典」 at the top of the
// right-click menu for the selection. A plain click (no selection made) still reaches the row,
// which expands it.

struct SelectableText: NSViewRepresentable {
    let text: String
    let font: NSFont
    let color: NSColor
    /// 0 for no limit.
    let maxLines: Int
    let onAddWord: (String) -> Void
    let onPlainClick: () -> Void

    func makeNSView(context: Context) -> HistoryTextView {
        let view = HistoryTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: HistoryTextView, context: Context) {
        if view.string != text { view.string = text }
        view.font = font
        view.textColor = color
        view.textContainer?.maximumNumberOfLines = maxLines
        view.textContainer?.lineBreakMode = maxLines == 0 ? .byWordWrapping : .byTruncatingTail
        view.onAddWord = onAddWord
        view.onPlainClick = onPlainClick
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: HistoryTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }
}

final class HistoryTextView: NSTextView {
    var onAddWord: ((String) -> Void)?
    var onPlainClick: (() -> Void)?

    /// The selection, when it is short enough to be a word or name.
    var selectedWord: String? {
        let range = selectedRange()
        guard range.length > 0 else { return nil }
        let word = (string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...40).contains(word.count) && !word.contains("\n") ? word : nil
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // super tracks the drag; with nothing selected it was a click on the row.
        if selectedRange().length == 0 { onPlainClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let word = selectedWord {
            let item = NSMenuItem(title: L10n.text("把「{0}」加入词典", word), action: #selector(addWord), keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func addWord() {
        if let word = selectedWord { onAddWord?(word) }
    }
}

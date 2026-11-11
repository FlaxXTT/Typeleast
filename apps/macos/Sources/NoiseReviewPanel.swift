import AppKit
import SwiftUI

private final class NoiseReviewHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A non-modal review for an uncertain recognition. Each pending result gets
/// its own panel so a later dictation cannot silently replace it.
final class NoiseReviewPanel {
    private var panels: [UUID: NSPanel] = [:]

    func show(candidate: String, repeated: Bool, use: @escaping (String) -> Bool) {
        let id = UUID()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let dismiss: () -> Void = { [weak self] in
            if let panel = self?.panels.removeValue(forKey: id) { panel.orderOut(nil) }
        }
        panel.contentView = NoiseReviewHostingView(rootView: NoiseReviewView(
            candidate: candidate, repeated: repeated,
            use: { if use(candidate) { dismiss() } }, dismiss: dismiss))
        panels[id] = panel
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: max(frame.minX, frame.maxX - panel.frame.width - 24),
                                         y: max(frame.minY, frame.maxY - panel.frame.height - 24)))
        } else { panel.center() }
        panel.orderFrontRegardless()
    }
}

struct NoiseReviewView: View {
    let candidate: String
    let repeated: Bool
    let use: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(repeated ? L10n.text("识别结果出现异常重复") : L10n.text("可能主要是背景噪声"))
                .font(.headline).foregroundColor(Theme.ink)
            Text(L10n.text("没有自动输入。继续后按当前设置处理；如使用联网整理模型，文字会发送给该服务。"))
                .font(.subheadline).foregroundColor(Theme.secondary)
            ScrollView {
                Text(candidate.isEmpty ? L10n.text("没有识别到文字") : candidate)
                    .textSelection(.enabled)
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                Button(L10n.text("忽略"), action: dismiss).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(L10n.text("继续处理"), action: use)
                    .buttonStyle(PrimaryButtonStyle()).disabled(candidate.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 260)
        .background(Theme.window)
    }
}

/// The response stays out of the paste path until the user chooses a version.
final class QuantityReviewPanel {
    enum Choice { case original; case candidate(String) }
    private var panels: [UUID: NSPanel] = [:]

    func show(review: QualityReview, choose: @escaping (Choice) -> Bool) {
        let id = UUID()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 370),
                            styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let dismiss: () -> Void = { [weak self] in
            if let panel = self?.panels.removeValue(forKey: id) { panel.orderOut(nil) }
        }
        panel.contentView = NoiseReviewHostingView(rootView: QuantityReviewView(
            review: review,
            original: { if choose(.original) { dismiss() } },
            candidate: { text in if choose(.candidate(text)) { dismiss() } },
            dismiss: dismiss))
        panels[id] = panel
        let point = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: max(frame.minX, frame.maxX - panel.frame.width - 24),
                                         y: max(frame.minY, frame.maxY - panel.frame.height - 24)))
        } else { panel.center() }
        panel.orderFrontRegardless()
    }
}

struct QuantityReviewView: View {
    let review: QualityReview
    let original: () -> Void
    let candidate: (String) -> Void
    let dismiss: () -> Void
    @State private var editedCandidate: String

    init(review: QualityReview, original: @escaping () -> Void,
         candidate: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        self.review = review
        self.original = original
        self.candidate = candidate
        self.dismiss = dismiss
        _editedCandidate = State(initialValue: review.candidate)
    }

    private func highlighted(_ value: String, quotes: [String]) -> Text {
        var marked = AttributedString(value)
        for quote in Set(quotes.filter { !$0.isEmpty }) {
            var search = marked.startIndex..<marked.endIndex
            while let range = marked[search].range(of: quote) {
                marked[range].backgroundColor = Color.orange.opacity(0.30)
                marked[range].underlineStyle = .single
                guard range.upperBound < marked.endIndex else { break }
                search = range.upperBound..<marked.endIndex
            }
        }
        return Text(marked)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(review.kind == "quantity" ? L10n.text("数量或单位可能发生变化") : L10n.text("整理结果需要核对")).font(.headline).foregroundColor(Theme.ink)
            Text(L10n.text("请比较识别原文和整理结果，再选择要使用的内容。"))
                .font(.subheadline).foregroundColor(Theme.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("原始识别")).font(.caption).foregroundColor(Theme.secondary)
                    highlighted(review.original, quotes: (review.issues ?? []).map(\.source)).textSelection(.enabled).foregroundColor(Theme.ink)
                    Text(L10n.text("整理结果（可编辑）")).font(.caption).foregroundColor(Theme.secondary)
                    ReviewTextEditor(text: $editedCandidate, quotes: (review.issues ?? []).map(\.candidate))
                        .frame(minHeight: 110, maxHeight: 180)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                Button(L10n.text("暂不使用"), action: dismiss).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(L10n.text("使用识别原文"), action: original).buttonStyle(SecondaryButtonStyle())
                Button(L10n.text("使用整理结果")) { candidate(editedCandidate) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(editedCandidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 520, height: 370).background(Theme.window)
    }
}

/// Editable text with visual marks for review evidence. Edits remain plain text.
private struct ReviewTextEditor: NSViewRepresentable {
    @Binding var text: String
    let quotes: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let view = NSTextView()
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        context.coordinator.mark(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text, !view.hasMarkedText() else { return }
        view.string = text
        context.coordinator.mark(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReviewTextEditor
        init(_ parent: ReviewTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            if !view.hasMarkedText() { mark(view) }
        }
        func mark(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let entire = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: entire)
            storage.removeAttribute(.underlineStyle, range: entire)
            let content = storage.string as NSString
            for quote in Set(parent.quotes.filter { !$0.isEmpty }) {
                var cursor = 0
                while cursor < content.length {
                    let match = content.range(of: quote, options: [], range: NSRange(location: cursor, length: content.length - cursor))
                    guard match.location != NSNotFound else { break }
                    storage.addAttribute(.backgroundColor, value: NSColor.systemOrange.withAlphaComponent(0.30), range: match)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match)
                    cursor = NSMaxRange(match)
                }
            }
            storage.endEditing()
        }
    }
}

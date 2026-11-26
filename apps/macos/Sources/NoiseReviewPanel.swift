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
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 500),
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
        AppWindowStyle.fixSize(panel, to: NSSize(width: 350, height: 500))
        panel.orderFrontRegardless()
        AppWindowStyle.round(panel)
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
                .font(InterfaceTypography.localized(18, weight: .semibold)).foregroundColor(Theme.ink)
            Text(L10n.text("没有自动输入。继续后按当前设置处理；如使用联网整理模型，文字会发送给该服务。"))
                .font(Theme.rowFont).foregroundColor(Theme.secondary)
            HubScrollView(showsChrome: false) {
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
        .padding(16)
        .frame(width: 350, height: 500)
        .font(Theme.bodyFont)
        .background(Theme.window)
    }
}

/// The response stays out of the paste path until the user chooses a version.
final class QuantityReviewPanel {
    enum Choice { case original; case candidate(String) }

    static let size = NSSize(width: 470, height: 485)
    private var panels: [String: NSPanel] = [:]

    func show(id: String, review: QualityReview, copiesResult: Bool, isTranslation: Bool, showsPreview: Bool = false,
              choose: @escaping (Choice) -> Bool) {
        if let panel = panels[id] {
            panel.orderFrontRegardless()
            return
        }

        let panel = TextShortcutPanel(contentRect: NSRect(origin: .zero, size: Self.size),
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
            review: review, copiesResult: copiesResult, isTranslation: isTranslation, showsPreview: showsPreview,
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
        AppWindowStyle.fixSize(panel, to: Self.size)
        panel.orderFrontRegardless()
        AppWindowStyle.round(panel)
    }
}

/// Uses a UTF-16 range for NSTextView and avoids selecting the wrong occurrence when a quote repeats.
struct ReviewEditFocus {
    let id = UUID()
    let quote: String?

    static func uniqueRange(of quote: String, in text: String) -> NSRange? {
        guard !quote.isEmpty else { return nil }
        let content = text as NSString
        let match = content.range(of: quote, options: [.literal])
        guard match.location != NSNotFound else { return nil }
        let next = match.location + 1
        let remainder = NSRange(location: next, length: content.length - next)
        guard content.range(of: quote, options: [.literal], range: remainder).location == NSNotFound else { return nil }
        return match
    }
}

struct QuantityReviewView: View {
    let review: QualityReview
    let copiesResult: Bool
    let isTranslation: Bool
    let showsPreview: Bool
    let original: () -> Void
    let candidate: (String) -> Void
    let dismiss: () -> Void
    @State private var editedCandidate: String
    @State private var focus: ReviewEditFocus?
    @State private var showsOriginal: Bool

    init(review: QualityReview, copiesResult: Bool = false, isTranslation: Bool = false, showsPreview: Bool = false,
         original: @escaping () -> Void, candidate: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        self.review = review
        self.copiesResult = copiesResult
        self.isTranslation = isTranslation
        self.showsPreview = showsPreview
        self.original = original
        self.candidate = candidate
        self.dismiss = dismiss
        _editedCandidate = State(initialValue: review.candidate)
        _showsOriginal = State(initialValue: review.issues?.isEmpty != false)
    }

    private var issues: [QualityReviewIssue] { review.issues ?? [] }
    private var resultLabel: String { L10n.text(isTranslation ? "译文" : "整理结果") }
    private var confirmLabel: String {
        if showsPreview { return L10n.text("查看译文") }
        if editedCandidate != review.candidate {
            return L10n.text(copiesResult ? "复制修改后的结果" : "插入修改后的结果")
        }
        return L10n.text(copiesResult ? "复制结果" : "插入结果")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(isTranslation ? "确认译文" : "确认整理结果"))
                        .font(InterfaceTypography.localized(22, weight: .semibold))
                    Text(L10n.text(showsPreview ? "确认后在翻译面板中显示。" : copiesResult ? "确认后复制到剪贴板。" : "确认后尝试插入原输入位置。"))
                        .font(Theme.captionFont).foregroundColor(Theme.secondary)
                }
                Spacer()
                IconButton(symbol: "xmark", help: L10n.text("关闭"), size: 28, symbolSize: 12, feedback: .fixed, action: dismiss)
                    .accessibilityLabel(L10n.text("关闭"))
            }
            Divider().overlay(Theme.border)
            HubScrollView(showsChrome: false) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(issues.isEmpty ? L10n.text("请核对全文") : L10n.text("待核对 · {0} 项", issues.count))
                        .font(InterfaceTypography.localized(13, weight: .semibold))
                        .foregroundColor(Theme.warning)
                    if issues.isEmpty {
                        Text(L10n.text("自动核对未能确认结果，请对照原始识别。"))
                            .font(Theme.captionFont).foregroundColor(Theme.secondary)
                    }
                    ForEach(issues.indices, id: \.self) { index in
                        issueRow(issues[index])
                    }
                    DisclosureGroup(L10n.text("原始识别"), isExpanded: $showsOriginal) {
                        Text(review.original).textSelection(.enabled)
                            .font(Theme.rowFont).lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
                    }
                    .font(Theme.captionFont)
                }
                .padding(.trailing, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(resultLabel).font(InterfaceTypography.localized(13, weight: .semibold))
                    Spacer()
                    Button(L10n.text("编辑结果")) { focus = ReviewEditFocus(quote: nil) }
                        .buttonStyle(FlatActionButtonStyle()).font(Theme.captionFont).foregroundColor(Theme.accent)
                }
                ReviewTextEditor(text: $editedCandidate, quotes: issues.map(\.candidate), focus: focus)
                    .accessibilityLabel(resultLabel)
                    .frame(height: 116)
                    .background(Theme.detail, in: RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border).allowsHitTesting(false))
            }
            HStack {
                Button(L10n.text("暂不使用"), action: dismiss).buttonStyle(SecondaryButtonStyle())
                Spacer()
                Button(L10n.text("使用识别原文"), action: original)
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(review.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(confirmLabel) { candidate(editedCandidate) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(editedCandidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: QuantityReviewPanel.size.width, height: QuantityReviewPanel.size.height)
        .font(Theme.bodyFont).foregroundColor(Theme.ink)
        .background(Theme.window)
        .onExitCommand(perform: dismiss)
    }

    private func issueRow(_ issue: QualityReviewIssue) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(issueTitle(issue)).font(InterfaceTypography.localized(12, weight: .semibold))
                Spacer()
                if ReviewEditFocus.uniqueRange(of: issue.candidate, in: editedCandidate) != nil {
                    Button(L10n.text("定位修改")) { focus = ReviewEditFocus(quote: issue.candidate) }
                        .buttonStyle(FlatActionButtonStyle()).font(Theme.captionFont).foregroundColor(Theme.accent)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                excerpt(L10n.text("原始识别"), issue.source)
                excerpt(resultLabel, issue.candidate)
            }
        }
        .padding(9)
        .background(Theme.detail, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border).allowsHitTesting(false))
    }

    private func excerpt(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.captionFont).foregroundColor(Theme.secondary)
            Text(text.isEmpty ? L10n.text("无对应文字") : text)
                .font(Theme.rowFont).foregroundColor(text.isEmpty ? Theme.tertiary : Theme.ink)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func issueTitle(_ issue: QualityReviewIssue) -> String {
        if review.kind == "quantity" { return L10n.text("数量或单位可能发生变化") }
        switch issue.kind {
        case "addition": return L10n.text("可能新增")
        case "omission": return L10n.text("可能遗漏")
        default: return L10n.text("可能改动")
        }
    }
}

/// Editable text with visual marks for review evidence. Edits remain plain text.
private struct ReviewTextEditor: NSViewRepresentable {
    @Binding var text: String
    let quotes: [String]
    let focus: ReviewEditFocus?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CapsuleEditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let view = ReviewEditorView()
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = InterfaceTypography.localizedAppKit(14)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 7, height: 8)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.string = text
        scroll.documentView = view
        context.coordinator.mark(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            context.coordinator.mark(view)
        }
        context.coordinator.focus(view)
    }

    private final class ReviewEditorView: NSTextView {
        override var needsPanelToBecomeKey: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReviewTextEditor
        private var focusID: UUID?
        init(_ parent: ReviewTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            if !view.hasMarkedText() { mark(view) }
        }
        func focus(_ view: NSTextView) {
            guard let request = parent.focus, focusID != request.id else { return }
            focusID = request.id
            DispatchQueue.main.async { [weak self, weak view] in
                guard self?.focusID == request.id, let view, let window = view.window, window.isVisible else { return }
                window.makeKey()
                guard window.makeFirstResponder(view) else { return }
                if let quote = request.quote, let range = ReviewEditFocus.uniqueRange(of: quote, in: view.string) {
                    view.setSelectedRange(range)
                } else if request.quote != nil {
                    view.moveToEndOfDocument(nil)
                }
                view.scrollRangeToVisible(view.selectedRange())
            }
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

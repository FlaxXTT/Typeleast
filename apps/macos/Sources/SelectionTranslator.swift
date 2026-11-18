import AppKit
import ApplicationServices
import NaturalLanguage
import SwiftUI

// SelectionTranslator.swift - select text with the mouse in any app and a small 「翻译」 button
// appears next to it; a click shows the translation in a bubble. The selection is read on this
// Mac through Accessibility and is sent to the model only after the click. If the selection
// cannot be confirmed, no button appears. Nothing is inserted or recorded. TypeLeast's own
// windows and password fields are ignored.
//
// Both panels are non-activating and never become key, so the app the user is reading keeps
// its focus and its selection.

final class SelectionTranslator {
    /// How long the button waits for a click.
    static let buttonSeconds: TimeInterval = 6
    /// Longest selection translated at once, in characters.
    static let limit = 5000

    var enabled: () -> Bool = { true }
    /// Translate `text` into `target`; completes on the main queue.
    var translate: ((_ text: String, _ target: String, _ cancellation: ServiceRequestCancellation,
                     _ completion: @escaping (Result<String, Error>) -> Void) -> Void)?
    /// The language translations go to (翻译's target in Settings).
    var preferredTarget: () -> String = { "en" }

    private var monitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var dragged = false
    private var dragOrigin = NSPoint.zero
    private var lastKeyTime = -Double.infinity
    private let dot = SelectionPanel()
    private let bubble = SelectionPanel()
    private var hideTimer: Timer?
    private var offerToken = 0
    private var runToken = 0
    private var request: ServiceRequestCancellation?
    private struct Job {
        let text: String
        let target: String
        let anchor: NSPoint
    }
    private var offerActive = false
    private let selectionQueue = DispatchQueue(label: "typeleast.translation.selection", qos: .utility)
    private var readingSelection = false
    private struct SelectionRead {
        let pid: pid_t
        let token: Int
        let completion: (String?) -> Void
    }
    private var pendingRead: SelectionRead?

    func start() {
        guard monitors.isEmpty else { return }
        let events: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            // A click elsewhere or typing withdraws the dot; the translation stays until its × is clicked.
            (.leftMouseDown, { [weak self] _ in
                self?.dragged = false
                self?.dragOrigin = NSEvent.mouseLocation
                self?.hideOffer()
            }),
            (.leftMouseDragged, { [weak self] _ in
                guard let self, !self.dragged else { return }
                let point = NSEvent.mouseLocation
                self.dragged = hypot(point.x - self.dragOrigin.x, point.y - self.dragOrigin.y) >= 5
            }),
            (.leftMouseUp, { [weak self] event in self?.mouseUp(event) }),
            // Shortcuts can also clear or replace the selection.
            (.keyDown, { [weak self] event in
                self?.lastKeyTime = event.timestamp
                self?.hideOffer()
                if event.keyCode == 53 { self?.closeBubble() }
            }),
        ]
        for (mask, handler) in events {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(monitor) }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.hideOffer() }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        hide()
    }

    func hide() {
        hideOffer()
        closeBubble()
    }

    private func hideOffer() {
        // Typing cancels pending reads without touching AppKit/WindowServer when hidden.
        offerToken &+= 1
        pendingRead = nil
        guard offerActive else { return }
        offerActive = false
        hideTimer?.invalidate()
        hideTimer = nil
        dot.hide()
    }

    private func closeBubble() {
        runToken += 1
        request?.cancel()
        request = nil
        bubble.hide()
    }

    private func mouseUp(_ event: NSEvent) {
        // A drag or repeated click may select text; confirm the actual selection below.
        let selecting = dragged || event.clickCount >= 2
        dragged = false
        guard selecting, event.timestamp - lastKeyTime >= 0.25, enabled(),
              let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier, !FieldContextReader.isBlocked(bundleId: bundle) else { return }
        let point = NSEvent.mouseLocation
        let pid = app.processIdentifier
        offerActive = true
        let token = offerToken
        // Passive offers never force another app to build its full accessibility tree.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.offerActive, self.offerToken == token else { return }
            guard self.enabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                self.hideOffer(); return
            }
            self.readSelection(pid: pid, token: token) { [weak self] text in
                guard let self, self.offerActive, self.offerToken == token else { return }
                guard self.enabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let text else { self.hideOffer(); return }
                self.offer(at: point, text: text, pid: pid)
            }
        }
    }

    private func readSelection(pid: pid_t, token: Int, completion: @escaping (String?) -> Void) {
        pendingRead = SelectionRead(pid: pid, token: token, completion: completion)
        readNextSelection()
    }

    private func readNextSelection() {
        guard !readingSelection, let request = pendingRead else { return }
        pendingRead = nil
        readingSelection = true
        selectionQueue.async { [weak self] in
            let text = Self.selectedText(in: request.pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingSelection = false
                if self.offerToken == request.token { request.completion(text) }
                self.readNextSelection()
            }
        }
    }

    /// The focused element's selected text; nil when it cannot be read, and for password fields.
    static func selectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return selectedText(in: app.processIdentifier)
    }

    private static func selectedText(in pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.08)
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        guard let text = selected as? String, DictationController.hasText(text) else { return nil }
        return text
    }

    /// Translations go to the target set for 翻译, except that text already in that language
    /// goes the other way: Chinese ⇄ the target (English when the target is Chinese).
    static func target(for text: String, preferred: String) -> String {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return preferred }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1600)))
        let source = recognizer.dominantLanguage?.rawValue.split(separator: "-").first.map(String.init)
        return source == preferred ? (preferred == "zh" ? "en" : "zh") : preferred
    }

    private func offer(at point: NSPoint, text: String, pid: pid_t) {
        let token = offerToken
        dot.showDot(at: point, hoverChanged: { [weak self] hovering in
            guard let self, self.offerToken == token else { return }
            if hovering {
                self.hideTimer?.invalidate()
                self.hideTimer = nil
            } else {
                self.scheduleOfferDismissal(token: token)
            }
        }) { [weak self] in
            guard let self, self.offerToken == token else { return }
            self.hideOffer()
            // A non-activating button keeps the source focused. Recheck it so a
            // changed or cleared selection can never translate captured stale text.
            guard self.enabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.offerActive = true
            let validationToken = self.offerToken
            self.readSelection(pid: pid, token: validationToken) { [weak self] selected in
                guard let self, self.offerActive, self.offerToken == validationToken else { return }
                self.offerActive = false
                guard self.enabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      selected == text else { return }
                self.closeBubble()
                let job = Job(text: text, target: Self.target(for: text, preferred: self.preferredTarget()), anchor: point)
                guard text.unicodeScalars.count <= Self.limit else {
                    self.showBubble(.failed(L10n.text("选区超过 {0} 字符，请分段翻译。", Self.limit), partial: nil),
                                    job: job, canRetry: false)
                    return
                }
                self.run(job)
            }
        }
        scheduleOfferDismissal(token: token)
    }

    private func scheduleOfferDismissal(token: Int) {
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: SelectionTranslator.buttonSeconds, repeats: false) { [weak self] _ in
            guard let self, self.offerToken == token else { return }
            self.hideOffer()
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func showBubble(_ state: SelectionBubble, job: Job, canRetry: Bool = false) {
        let target = TranslateLanguage(rawValue: job.target)?.label ?? job.target
        let retry: (() -> Void)? = canRetry ? { [weak self] in self?.run(job) } : nil
        bubble.showBubble(state, target: target, at: job.anchor, retry: retry) { [weak self] in self?.closeBubble() }
    }

    /// Count the text actually sent for translation, without persisting it.
    static func sourceCountLabel(_ text: String) -> String {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { _, _, _, _ in words += 1 }
        return L10n.text("原文：{0} 字符 · {1} 词", text.count, words)
    }

    private func run(_ job: Job) {
        runToken &+= 1
        let token = runToken
        request?.cancel()
        guard let translate else {
            return showBubble(.failed(L10n.text("请先配置可用的整理模型。"), partial: nil), job: job)
        }
        let cancellation = ServiceRequestCancellation()
        request = cancellation
        showBubble(.loading, job: job)
        translate(job.text, job.target, cancellation) { [weak self] result in
            guard let self, self.runToken == token else { return }
            self.request = nil
            switch result {
            case .success(let translated): self.showBubble(.done(translated), job: job)
            case .failure(let error):
                let service = error as? ServiceError
                let partial: String?
                if case .translationIncomplete(let progress)? = service { partial = progress.text }
                else { partial = nil }
                self.showBubble(.failed(service?.description ?? L10n.text("翻译失败"), partial: partial), job: job, canRetry: true)
            }
        }
    }
}

// MARK: - panels

enum SelectionBubble: Equatable {
    case loading
    case done(String)
    case failed(String, partial: String?)
}

/// A borderless, non-activating panel holding the dot or the translation.
final class SelectionPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var existingPanel: Panel?
    private var panel: Panel {
        if let existingPanel { return existingPanel }
        let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        existingPanel = p
        return p
    }
    private var anchor = NSPoint.zero
    private var dragOffset: NSPoint?

    func showDot(at point: NSPoint, hoverChanged: @escaping (Bool) -> Void = { _ in }, action: @escaping () -> Void) {
        anchor = point
        show(SelectionDotView(action: action, hoverChanged: hoverChanged), castsShadow: false)
    }

    func showBubble(_ state: SelectionBubble, target: String, at point: NSPoint,
                    retry: (() -> Void)?, close: @escaping () -> Void) {
        anchor = point
        let screen = screenFrame(at: panel.isVisible ? NSPoint(x: panel.frame.midX, y: panel.frame.midY) : point)
        show(SelectionBubbleView(state: state, target: target, maxTextHeight: min(300, screen.height * 0.4),
                                 retry: retry, close: close,
                                 drag: { [weak self] in self?.drag() }, dragEnded: { [weak self] in self?.dragOffset = nil }))
    }

    /// Any other draggable card in this panel; the view is given the two drag callbacks.
    func showCard<V: View>(at point: NSPoint, _ view: (_ drag: @escaping () -> Void, _ dragEnded: @escaping () -> Void) -> V) {
        anchor = point
        show(view({ [weak self] in self?.drag() }, { [weak self] in self?.dragOffset = nil }))
    }

    func hide() {
        guard let panel = existingPanel else { return }
        if panel.isVisible { panel.orderOut(nil) }
        guard panel.contentView != nil else { return }
        panel.contentView = nil
    }

    /// Follows the mouse, in screen coordinates: the view moves with the panel, so its own are useless.
    private func drag() {
        let mouse = NSEvent.mouseLocation
        let offset = dragOffset ?? NSPoint(x: panel.frame.minX - mouse.x, y: panel.frame.minY - mouse.y)
        dragOffset = offset
        panel.setFrameOrigin(NSPoint(x: mouse.x + offset.x, y: mouse.y + offset.y))
    }

    private func show<V: View>(_ view: V, castsShadow: Bool = true) {
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        // A panel already open stays where it is (the user may have moved it), its top edge fixed.
        let top = panel.isVisible ? panel.frame.maxY : nil
        let left = panel.frame.minX
        panel.contentView = host
        panel.setContentSize(size)
        AppWindowStyle.fixSize(panel, to: size)
        AppWindowStyle.round(panel)
        panel.hasShadow = castsShadow
        let screen = screenFrame(at: top.map { NSPoint(x: left + size.width / 2, y: $0 - 1) } ?? anchor)
        var origin = top.map { NSPoint(x: left, y: $0 - size.height) }
            ?? NSPoint(x: anchor.x + 8, y: anchor.y - size.height - 12)
        if top == nil && origin.y < screen.minY { origin.y = anchor.y + 16 }
        origin.x = max(screen.minX + 8, min(origin.x, screen.maxX - size.width - 8))
        origin.y = max(screen.minY + 8, min(origin.y, screen.maxY - size.height - 8))
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    private func screenFrame(at point: NSPoint) -> NSRect {
        NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    }
}

/// The panel never becomes key, so its buttons must take the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The complete 24pt mark is clickable, including the solid circle and gaps.
struct SelectionDotView: View {
    let action: () -> Void
    var hoverChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Button(action: action) { TranslationSunset(hoverChanged: hoverChanged) }
            .buttonStyle(TranslationDotPressStyle())
            .frame(width: TranslationSunset.displaySize.width, height: TranslationSunset.displaySize.height)
            .contentShape(Rectangle())
            .accessibilityLabel(L10n.text("翻译"))
            .help(L10n.text("翻译"))
    }
}

private struct TranslationDotPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.translationSunPressed, configuration.isPressed)
    }
}

/// A compact translation card with a selectable, height-limited body.
struct SelectionBubbleView: View {
    let state: SelectionBubble
    let target: String
    let maxTextHeight: CGFloat
    let retry: (() -> Void)?
    let close: () -> Void
    let drag: () -> Void
    let dragEnded: () -> Void
    @State private var copyFeedback: UUID?

    private let contentWidth: CGFloat = 310
    private let lineHeight: CGFloat = 21

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack {
                    Text(target).font(Theme.captionFont).foregroundColor(Theme.secondary)
                    Spacer(minLength: 8)
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in drag() }.onEnded { _ in dragEnded() })
                if case .done(let text) = state {
                    Button(copyFeedback == nil ? L10n.text("复制") : L10n.text("已复制")) {
                        Inserter.shared.setString(text)
                        copyFeedback = UUID()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                IconButton(symbol: "xmark", help: L10n.text("关闭"), size: 28, symbolSize: 12, action: close)
                    .accessibilityLabel(L10n.text("关闭"))
            }
            switch state {
            case .loading:
                HStack(spacing: 8) {
                    LoadingCircularProgress(size: 16, color: Theme.ink)
                    Text(L10n.text("正在翻译…")).font(Theme.rowFont)
                }
            case .done(let text):
                translationText(text)
            case .failed(let message, let partial):
                HStack(alignment: .center, spacing: 8) {
                    Text(message).font(Theme.rowFont)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if let retry {
                        Button(L10n.text("重试"), action: retry).buttonStyle(SecondaryButtonStyle())
                    }
                }
                if let partial { translationText(partial) }
            }
        }
        .frame(width: contentWidth, alignment: .leading)
        .padding(16)
        .resetCopyFeedback($copyFeedback)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.tile))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border).allowsHitTesting(false))
    }

    private func translationText(_ text: String) -> some View {
        let font = InterfaceTypography.localizedAppKit(14)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let size = (text as NSString).boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        let height = max(lineHeight, ceil(size.height))
        return Group {
            if height > maxTextHeight {
                HubScrollView(showsChrome: false) { selectable(text, font: font) }
                    .frame(height: maxTextHeight)
            } else {
                selectable(text, font: font)
                    .frame(height: height)
            }
        }
    }

    private func selectable(_ text: String, font: NSFont) -> some View {
        SelectableText(text: text, font: font, color: NSColor(Theme.ink), maxLines: 0,
                       lineHeight: lineHeight, acceptsInactiveClick: true, onPlainClick: {})
    }
}

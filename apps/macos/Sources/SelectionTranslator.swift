import AppKit
import ApplicationServices
import SwiftUI

// SelectionTranslator.swift - select text with the mouse in any app and a small 「翻译」 button
// appears next to it; a click shows the translation in a bubble. The selection is read on this
// Mac (Accessibility, or a ⌘C for browsers that hide it) and is sent to the model only after the
// click. Nothing is inserted or recorded. TypeLeast's own windows and password fields are ignored.
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
    var translate: ((_ text: String, _ target: String, _ completion: @escaping (Result<String, Error>) -> Void) -> Void)?
    /// The language translations go to (翻译's target in Settings).
    var preferredTarget: () -> String = { "en" }

    private var monitors: [Any] = []
    private var dragged = false
    private let panel = SelectionPanel()
    private var hideTimer: Timer?
    private var generation = 0

    func start() {
        guard monitors.isEmpty else { return }
        let events: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            // Clicks in TypeLeast's own panels never reach a global monitor, so any click here is elsewhere.
            (.leftMouseDown, { [weak self] _ in self?.dragged = false; self?.hide() }),
            (.leftMouseDragged, { [weak self] _ in self?.dragged = true }),
            (.leftMouseUp, { [weak self] event in self?.mouseUp(event) }),
            // Typing closes it; a ⌘ shortcut does not (the ⌘C that reads a browser's selection is one).
            (.keyDown, { [weak self] event in if !event.modifierFlags.contains(.command) { self?.hide() } }),
        ]
        for (mask, handler) in events {
            if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(monitor) }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hide()
    }

    func hide() {
        generation += 1
        hideTimer?.invalidate()
        hideTimer = nil
        panel.hide()
    }

    private func mouseUp(_ event: NSEvent) {
        // A drag, or a double or triple click, selects text; a plain click does not.
        let selecting = dragged || event.clickCount >= 2
        dragged = false
        guard selecting, enabled(), AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier, !FieldContextReader.isBlocked(bundleId: bundle) else { return }
        let point = NSEvent.mouseLocation
        FieldContextReader.exposeContent(bundleId: bundle)
        // Give the app a moment to update its selection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { return }
            let text = SelectionTranslator.selectedText()
            if let text, DictationController.hasText(text) {
                self.offer(at: point) { $0(text) }
            } else if text == nil, Inserter.readsSelectionByCopy(bundle) {
                // A browser that hides the selection: copy it, but only once the user asks.
                self.offer(at: point) { done in Inserter.shared.copySelection { done($0) } }
            }
        }
    }

    /// The focused element's selected text; nil when it cannot be read, and for password fields.
    static func selectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           (subrole as? String) == (kAXSecureTextFieldSubrole as String) { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success else { return nil }
        return selected as? String
    }

    /// Translations go to the target set for 翻译, except that text already in that language
    /// goes the other way: Chinese ⇄ the target (English when the target is Chinese).
    static func target(for text: String, preferred: String) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let han = letters.filter { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }.count
        let mostlyChinese = !letters.isEmpty && han * 2 >= letters.count
        if preferred == "zh" { return mostlyChinese ? "en" : "zh" }
        let latin = letters.filter { $0.isASCII }.count
        let alreadyTarget = preferred == "en" ? (!letters.isEmpty && latin * 2 > letters.count) : false
        return alreadyTarget ? "zh" : preferred
    }

    private func offer(at point: NSPoint, read: @escaping (@escaping (String?) -> Void) -> Void) {
        let token = generation + 1
        generation = token
        panel.showButton(at: point) { [weak self] in
            guard let self, self.generation == token else { return }
            self.hideTimer?.invalidate()
            self.panel.showBubble(.loading)
            read { [weak self] text in
                guard let self, self.generation == token else { return }
                guard let text, DictationController.hasText(text) else { return self.hide() }
                self.run(String(text.prefix(SelectionTranslator.limit)), token: token)
            }
        }
        hideTimer?.invalidate()
        let timer = Timer(timeInterval: SelectionTranslator.buttonSeconds, repeats: false) { [weak self] _ in
            guard let self, self.generation == token, self.panel.showsButton else { return }
            self.hide()
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func run(_ text: String, token: Int) {
        guard let translate else { return panel.showBubble(.failed(L10n.text("请先配置可用的整理模型。"))) }
        translate(text, SelectionTranslator.target(for: text, preferred: preferredTarget())) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success(let translated): self.panel.showBubble(.done(translated))
            case .failure(let error):
                self.panel.showBubble(.failed((error as? ServiceError)?.description ?? L10n.text("翻译失败")))
            }
        }
    }
}

// MARK: - panels

enum SelectionBubble: Equatable {
    case loading
    case done(String)
    case failed(String)
}

/// One borderless, non-activating panel that shows either the button or the bubble.
final class SelectionPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private lazy var panel: Panel = {
        let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return p
    }()
    private var anchor = NSPoint.zero
    private(set) var showsButton = false

    func showButton(at point: NSPoint, action: @escaping () -> Void) {
        anchor = point
        showsButton = true
        show(SelectionButtonView(action: action))
    }

    func showBubble(_ state: SelectionBubble) {
        showsButton = false
        show(SelectionBubbleView(state: state, close: { [weak self] in self?.hide() }))
    }

    func hide() {
        showsButton = false
        panel.orderOut(nil)
    }

    private func show<V: View>(_ view: V) {
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(size)
        // Below and to the right of the mouse, kept on the screen it is on.
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(x: anchor.x + 8, y: anchor.y - size.height - 12)
        if origin.y < screen.minY { origin.y = anchor.y + 16 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }
}

/// The panel never becomes key, so its buttons must take the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The dark capsule offered next to a selection.
struct SelectionButtonView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "character.bubble").font(.system(size: 12, weight: .semibold))
                Text(L10n.text("翻译")).font(.system(size: 12.5, weight: .semibold)).fixedSize()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color(white: 0.09)))
            .overlay(Capsule().stroke(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .padding(4)
    }
}

/// The translation, with copy and close.
struct SelectionBubbleView: View {
    let state: SelectionBubble
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch state {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在翻译…")).font(.system(size: 13))
                }
            case .done(let text):
                ScrollView {
                    Text(text).font(.system(size: 13.5)).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 260)
                HStack {
                    Spacer()
                    Button(copied ? L10n.text("已复制") : L10n.text("复制")) {
                        Inserter.shared.setString(text)
                        copied = true
                    }
                    Button(L10n.text("关闭"), action: close)
                }
                .controlSize(.small)
            case .failed(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                    Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L10n.text("关闭"), action: close).controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .padding(4)
    }
}

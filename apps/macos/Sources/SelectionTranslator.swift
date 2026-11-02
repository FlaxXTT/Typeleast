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
    private let dot = SelectionPanel()
    private let bubble = SelectionPanel()
    private var hideTimer: Timer?
    private var offerToken = 0
    private var runToken = 0

    func start() {
        guard monitors.isEmpty else { return }
        let events: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            // A click elsewhere or typing withdraws the dot; the translation stays until its × is clicked.
            (.leftMouseDown, { [weak self] _ in self?.dragged = false; self?.hideOffer() }),
            (.leftMouseDragged, { [weak self] _ in self?.dragged = true }),
            (.leftMouseUp, { [weak self] event in self?.mouseUp(event) }),
            // A ⌘ shortcut does not withdraw it (the ⌘C that reads a browser's selection is one).
            (.keyDown, { [weak self] event in if !event.modifierFlags.contains(.command) { self?.hideOffer() } }),
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
        hideOffer()
        closeBubble()
    }

    private func hideOffer() {
        offerToken += 1
        hideTimer?.invalidate()
        hideTimer = nil
        dot.hide()
    }

    private func closeBubble() {
        runToken += 1
        bubble.hide()
    }

    private func mouseUp(_ event: NSEvent) {
        // A drag, or a double or triple click, selects text; a plain click does not.
        let selecting = dragged || event.clickCount >= 2
        dragged = false
        guard selecting, enabled(), AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier, !FieldContextReader.isBlocked(bundleId: bundle) else { return }
        let point = NSEvent.mouseLocation
        // The first time, a browser or Electron app (Claude, VS Code, Slack…) builds its
        // Accessibility tree only now: give it longer than the usual moment.
        let fresh = FieldContextReader.exposeContent(bundleId: bundle)
        let copies = SelectionTranslator.readsByCopy(bundleId: bundle, bundleURL: app.bundleURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + (fresh ? 0.6 : 0.15)) { [weak self] in
            guard let self, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else { return }
            let text = SelectionTranslator.selectedText()
            if let text, DictationController.hasText(text) {
                self.offer(at: point) { $0(text) }
            } else if copies, text?.isEmpty != false {
                // An app that hides its selection: copy it, but only once the user asks.
                self.offer(at: point) { done in Inserter.shared.copySelection { done($0) } }
            }
        }
    }

    /// AI tools that may hide their selection from Accessibility but are not recognisable as Electron.
    static let agentApps = ["com.openai.chat", "com.openai.codex", "com.anthropic.claudefordesktop", "com.todesktop.",
                            "com.exafunction.windsurf", "dev.zed.Zed", "com.trae.", "com.google.antigravity",
                            "ai.opencode.", "com.claude-prism.", "com.deepseek.dsh", "com.microsoft.VSCode"]

    /// Electron apps, recognised by what they ship: some rename the framework (ChatGPT's is
    /// "Codex Framework"), but the app.asar stays.
    static func isElectron(bundleURL url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
            || fm.fileExists(atPath: url.appendingPathComponent("Contents/Resources/app.asar").path)
    }

    /// Whether a drag in this app may be a selection that only a ⌘C can read: browsers, AI tools,
    /// Electron apps and terminals (where Claude Code and Codex run). ⌘C is sent only after a click on the button.
    static func readsByCopy(bundleId: String, bundleURL: URL?) -> Bool {
        Inserter.readsSelectionByCopy(bundleId) || TerminalGuard.isTerminal(bundleId)
            || agentApps.contains { bundleId == $0 || ($0.hasSuffix(".") && bundleId.hasPrefix($0)) }
            || (bundleURL.map(isElectron(bundleURL:)) ?? false)
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
        hideOffer()
        let token = offerToken
        dot.showDot(at: point) { [weak self] in
            guard let self, self.offerToken == token else { return }
            self.hideOffer()
            self.runToken += 1
            let run = self.runToken
            self.showBubble(.loading, at: point)
            read { [weak self] text in
                guard let self, self.runToken == run else { return }
                guard let text, DictationController.hasText(text) else { return self.closeBubble() }
                self.run(String(text.prefix(SelectionTranslator.limit)), token: run, at: point)
            }
        }
        let timer = Timer(timeInterval: SelectionTranslator.buttonSeconds, repeats: false) { [weak self] _ in
            guard let self, self.offerToken == token else { return }
            self.hideOffer()
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimer = timer
    }

    private func showBubble(_ state: SelectionBubble, at point: NSPoint) {
        bubble.showBubble(state, at: point) { [weak self] in self?.closeBubble() }
    }

    private func run(_ text: String, token: Int, at point: NSPoint) {
        guard let translate else { return showBubble(.failed(L10n.text("请先配置可用的整理模型。")), at: point) }
        translate(text, SelectionTranslator.target(for: text, preferred: preferredTarget())) { [weak self] result in
            guard let self, self.runToken == token else { return }
            switch result {
            case .success(let translated): self.showBubble(.done(translated), at: point)
            case .failure(let error):
                self.showBubble(.failed((error as? ServiceError)?.description ?? L10n.text("翻译失败")), at: point)
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

/// A borderless, non-activating panel holding the dot or the translation.
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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }()
    private var anchor = NSPoint.zero
    private var dragOffset: NSPoint?

    func showDot(at point: NSPoint, action: @escaping () -> Void) {
        anchor = point
        show(SelectionDotView(action: action))
    }

    func showBubble(_ state: SelectionBubble, at point: NSPoint, close: @escaping () -> Void) {
        anchor = point
        show(SelectionBubbleView(state: state, close: close,
                                 drag: { [weak self] in self?.drag() }, dragEnded: { [weak self] in self?.dragOffset = nil }))
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Follows the mouse, in screen coordinates: the view moves with the panel, so its own are useless.
    private func drag() {
        let mouse = NSEvent.mouseLocation
        let offset = dragOffset ?? NSPoint(x: panel.frame.minX - mouse.x, y: panel.frame.minY - mouse.y)
        dragOffset = offset
        panel.setFrameOrigin(NSPoint(x: mouse.x + offset.x, y: mouse.y + offset.y))
    }

    private func show<V: View>(_ view: V) {
        let host = FirstClickHostingView(rootView: view)
        let size = host.fittingSize
        // A panel already open stays where it is (the user may have moved it), its top edge fixed.
        let top = panel.isVisible ? panel.frame.maxY : nil
        let left = panel.frame.minX
        panel.contentView = host
        panel.setContentSize(size)
        if let top {
            panel.setFrameOrigin(NSPoint(x: left, y: top - size.height))
        } else {
            // Below and to the right of the mouse, kept on the screen it is on.
            let screen = NSScreen.screens.first { $0.frame.contains(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            var origin = NSPoint(x: anchor.x + 8, y: anchor.y - size.height - 12)
            if origin.y < screen.minY { origin.y = anchor.y + 16 }
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
    }
}

/// The panel never becomes key, so its buttons must take the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The small white dot offered next to a selection; the hit area is larger than the dot.
struct SelectionDotView: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(Color(red: 1, green: 250.0/255, blue: 252.0/255))
                .overlay(Circle().fill(Color(red: 252.0/255, green: 179.0/255, blue: 181.0/255))
                    .padding(2))
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.25), radius: 2)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("翻译"))
    }
}

/// The translation: drag it anywhere; it stays until its × is clicked.
struct SelectionBubbleView: View {
    let state: SelectionBubble
    let close: () -> Void
    let drag: () -> Void
    let dragEnded: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.text("关闭"))
            }
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
                }
                .controlSize(.small)
            case .failed(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                    Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14)
        .frame(width: 360, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { _ in drag() }.onEnded { _ in dragEnded() })
        .padding(4)
    }
}

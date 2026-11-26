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
// Both panels are non-activating. Only an interaction with the translated text can make
// the result panel key so AppKit can handle selection and keyboard shortcuts.

final class SelectionTranslator {
    static let featureName = "Quick Translate"
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
    private let bubble = SelectionPanel(allowsTextFocus: true)
    private var hideTimer: Timer?
    private var offerToken = 0
    private var runToken = 0
    private var request: ServiceRequestCancellation?
    private struct Job {
        let text: String
        let target: String
        let anchor: NSRect
    }
    private var offerActive = false
    private let selectionQueue = DispatchQueue(label: "typeleast.translation.selection", qos: .utility)
    private var readingSelection = false
    private struct SelectionSnapshot {
        let text: String
        let placement: TranslationOfferPlacement?
    }
    private struct OfferLocation {
        let pointer: NSPoint
        let screen: NSRect
        let primaryTop: CGFloat
    }
    private struct SelectionRead {
        let pid: pid_t
        let token: Int
        let location: OfferLocation?
        let completion: (SelectionSnapshot?) -> Void
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
            (.scrollWheel, { [weak self] _ in self?.hideOffer() }),
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
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let primary = NSScreen.screens.first else { return }
        let location = OfferLocation(pointer: point, screen: screen.visibleFrame, primaryTop: primary.frame.maxY)
        let pid = app.processIdentifier
        offerActive = true
        let token = offerToken
        // Passive offers never force another app to build its full accessibility tree.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.offerActive, self.offerToken == token else { return }
            guard self.enabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                self.hideOffer(); return
            }
            self.readSelection(pid: pid, token: token, location: location) { [weak self] selection in
                guard let self, self.offerActive, self.offerToken == token else { return }
                guard self.enabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      let selection, let placement = selection.placement else { self.hideOffer(); return }
                self.offer(placement, text: selection.text, pid: pid)
            }
        }
    }

    private func readSelection(pid: pid_t, token: Int, location: OfferLocation? = nil,
                               completion: @escaping (SelectionSnapshot?) -> Void) {
        pendingRead = SelectionRead(pid: pid, token: token, location: location, completion: completion)
        readNextSelection()
    }

    private func readNextSelection() {
        guard !readingSelection, let request = pendingRead else { return }
        pendingRead = nil
        readingSelection = true
        selectionQueue.async { [weak self] in
            let selection = Self.selection(in: request.pid, location: request.location)
            DispatchQueue.main.async {
                guard let self else { return }
                self.readingSelection = false
                if self.offerToken == request.token { request.completion(selection) }
                self.readNextSelection()
            }
        }
    }

    /// The focused element's selected text; nil when it cannot be read, and for password fields.
    static func selectedText() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return selection(in: app.processIdentifier)?.text
    }

    private static func selection(in pid: pid_t, location: OfferLocation? = nil) -> SelectionSnapshot? {
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
        let placement = location.flatMap { safeOfferPlacement(in: element, at: $0) }
        return SelectionSnapshot(text: text, placement: placement)
    }

    /// Only place offers beside measured glyphs in a focused text surface. The
    /// geometry lookup stays on the selection queue and drops slow or incomplete AX data.
    private static func safeOfferPlacement(in element: AXUIElement, at location: OfferLocation) -> TranslationOfferPlacement? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.16
        func attribute<T>(_ name: String) -> T? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            return FieldContextReader.copy(element, name)
        }
        func parameter(_ name: String, _ input: CFTypeRef) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var output: CFTypeRef?
            return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, input, &output) == .success ? output : nil
        }
        guard let role: String = attribute(kAXRoleAttribute),
              [kAXTextAreaRole, kAXTextFieldRole, kAXStaticTextRole].contains(role),
              let position: CFTypeRef = attribute(kAXPositionAttribute),
              let size: CFTypeRef = attribute(kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              let selected = FieldContextReader.selectedRange(element),
              selected.location >= 0, selected.length > 0, selected.location <= Int.max - selected.length,
              let visible: CFTypeRef = attribute(kAXVisibleCharacterRangeAttribute),
              let visibleRange = axRange(visible), visibleRange.length > 0 else { return nil }
        var topLeft = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &topLeft),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0,
              [topLeft.x, topLeft.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite) else { return nil }
        let field = NSRect(x: topLeft.x, y: location.primaryTop - topLeft.y - dimensions.height,
                           width: dimensions.width, height: dimensions.height)
        func line(for index: Int) -> Int? {
            guard let line = parameter(kAXLineForIndexParameterizedAttribute, NSNumber(value: index)) as? NSNumber,
                  (0..<Int.max - 2).contains(line.intValue) else { return nil }
            return line.intValue
        }
        func bounds(of line: Int) -> NSRect? {
            guard let value = parameter(kAXRangeForLineParameterizedAttribute, NSNumber(value: line)),
                  var range = axRange(value) else { return nil }
            if range.length > 0 {
                // AppKit may expand a range that includes its newline to the
                // full line width. Exclude only confirmed line terminators.
                let count = min(2, range.length)
                var end = CFRange(location: range.location + range.length - count, length: count)
                if let tail = AXValueCreate(.cfRange, &end),
                   let suffix = parameter(kAXStringForRangeParameterizedAttribute, tail) as? String,
                   suffix.utf16.count == count {
                    let terminators = suffix.unicodeScalars.reversed().prefix(while: CharacterSet.newlines.contains)
                    range.length -= terminators.count
                }
            }
            guard let axValue = AXValueCreate(.cfRange, &range),
                  let value = parameter(kAXBoundsForRangeParameterizedAttribute, axValue),
                  CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0,
                  [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else { return nil }
            return NSRect(x: rect.minX, y: location.primaryTop - rect.maxY, width: max(1, rect.width), height: rect.height)
        }
        var pointer = CGPoint(x: location.pointer.x, y: location.primaryTop - location.pointer.y)
        let hovered = AXValueCreate(.cgPoint, &pointer)
            .flatMap { parameter(kAXRangeForPositionParameterizedAttribute, $0) }.flatMap { axRange($0) }
        let endOfSelection = selected.location + selected.length - 1
        let index = hovered.map { min(endOfSelection, max(selected.location, $0.location)) } ?? endOfSelection
        guard let anchor = line(for: index), let anchorBounds = bounds(of: anchor),
              let first = line(for: visibleRange.location),
              let last = line(for: visibleRange.location + visibleRange.length - 1),
              first <= anchor, anchor <= last else { return nil }
        let lower = max(first, anchor - 2)
        let upper = min(last, anchor + 2)
        var measured = [NSRect]()
        for line in lower...upper {
            guard let rect = line == anchor ? anchorBounds : bounds(of: line) else { return nil }
            measured.append(rect)
        }
        return TranslationOfferPlacement.frame(near: location.pointer, anchor: anchorBounds,
                                               in: field.intersection(location.screen), rows: measured,
                                               allVisibleRows: lower == first && upper == last).map {
            TranslationOfferPlacement(button: $0, sourceLine: anchorBounds)
        }
    }

    private static func axRange(_ value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0,
              range.length >= 0, range.location <= Int.max - range.length else { return nil }
        return range
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

    private func offer(_ placement: TranslationOfferPlacement, text: String, pid: pid_t) {
        let token = offerToken
        dot.showDot(in: placement.button, hoverChanged: { [weak self] hovering in
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
            self.readSelection(pid: pid, token: validationToken) { [weak self] selection in
                guard let self, self.offerActive, self.offerToken == validationToken else { return }
                self.offerActive = false
                guard self.enabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      selection?.text == text else { return }
                self.closeBubble()
                let job = Job(text: text, target: Self.target(for: text, preferred: self.preferredTarget()),
                              anchor: placement.resultAnchor)
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
        let retry: (() -> Void)? = canRetry ? { [weak self] in self?.run(job) } : nil
        bubble.showBubble(state, target: job.target, at: job.anchor, retry: retry) { [weak self] in self?.closeBubble() }
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

struct TranslationOfferPlacement {
    let button: NSRect
    let sourceLine: NSRect

    var resultAnchor: NSRect {
        // Align to the button horizontally and clear its source line vertically.
        NSRect(x: button.minX, y: min(button.minY, sourceLine.minY), width: button.width,
               height: max(button.maxY, sourceLine.maxY) - min(button.minY, sourceLine.minY))
    }

    static func frame(near pointer: NSPoint, anchor: NSRect, in field: NSRect, rows: [NSRect],
                      allVisibleRows: Bool = false) -> NSRect? {
        guard let first = rows.first, !field.isEmpty else { return nil }
        let size = TranslationSunset.displaySize
        let span = rows.dropFirst().reduce(first) { $0.union($1) }
        let measuredBand = NSRect(x: field.minX, y: span.minY, width: field.width, height: span.height)
        let visible = allVisibleRows ? field : field.intersection(measuredBand)
        guard visible.width >= size.width, visible.height >= size.height else { return nil }
        let centre = (anchor.midY - size.height / 2).rounded()
        let y = min(visible.maxY - size.height, max(visible.minY, centre))
        let clearance: CGFloat = 3
        let occupied = rows.filter { $0.maxY + clearance > y && $0.minY - clearance < y + size.height }
        guard let left = occupied.map(\.minX).min(), let right = occupied.map(\.maxX).max() else { return nil }

        // The complete hit area stays in the measured field. Never clamp a
        // candidate toward text when it would otherwise fall off the display.
        let sideFrames = [floor(left - clearance - size.width), ceil(right + clearance)].map {
            NSRect(origin: NSPoint(x: $0, y: y), size: size)
        }
        func distance(_ rect: NSRect) -> CGFloat {
            hypot(rect.midX - pointer.x, rect.midY - pointer.y)
        }
        func nearest(_ candidates: [NSRect]) -> NSRect? {
            candidates.filter { visible.contains($0) && distance($0) <= 110 }
                .min { distance($0) < distance($1) }
        }
        if let side = nearest(sideFrames) { return side }

        // Let a verified empty band accommodate the whole button, including its hit area.
        let x = min(floor(visible.maxX - size.width), max(ceil(visible.minX), (pointer.x - size.width / 2).rounded()))
        let gaps = rows.flatMap { row in
            [floor(row.minY - clearance - size.height), ceil(row.maxY + clearance)].map {
                NSRect(origin: NSPoint(x: x, y: $0), size: size)
            }
        }
        return nearest(gaps.filter { gap in
            rows.allSatisfy { !gap.intersects($0.insetBy(dx: -clearance, dy: -clearance)) }
        })
    }
}

struct TranslationBubblePlacement {
    static let margin: CGFloat = 8
    private static let controlsHeight: CGFloat = 116
    let screen: NSRect
    let left: CGFloat
    let edge: CGFloat
    let above: Bool

    init(near anchor: NSRect, in screen: NSRect, existing: NSRect? = nil, above existingSide: Bool = false) {
        self.screen = screen
        if let existing {
            above = existingSide
            left = existing.minX
            edge = above ? existing.minY : existing.maxY
        } else {
            let belowEdge = anchor.minY - 12
            let aboveEdge = anchor.maxY + 12
            let belowRoom = belowEdge - screen.minY - Self.margin
            let aboveRoom = screen.maxY - Self.margin - aboveEdge
            above = belowRoom < Self.controlsHeight + Self.readingHeight(in: screen) && aboveRoom > belowRoom
            left = anchor.midX + 8
            edge = above ? aboveEdge : belowEdge
        }
    }

    private static func readingHeight(in screen: NSRect) -> CGFloat { min(380, screen.height * 0.50) }

    var maxTextHeight: CGFloat {
        let remaining = above ? screen.maxY - edge : edge - screen.minY
        // If dragged to a screen edge, preserve a usable scroll viewport.
        return min(Self.readingHeight(in: screen), max(112, remaining - Self.margin - Self.controlsHeight))
    }

    func origin(for size: NSSize) -> NSPoint {
        NSPoint(x: left, y: above ? edge : edge - size.height)
    }
}

enum SelectionBubble: Equatable {
    case loading
    case done(String)
    case failed(String, partial: String?)
}

/// A borderless, non-activating panel holding the dot or the translation.
final class SelectionPanel {
    private final class Panel: TextShortcutPanel {
        var allowsTextFocus = false
        var onEscape: (() -> Void)?
        override var canBecomeKey: Bool { allowsTextFocus }
        override var canBecomeMain: Bool { false }

        override func sendEvent(_ event: NSEvent) {
            if event.type == .keyDown, event.keyCode == 53, let onEscape { onEscape(); return }
            super.sendEvent(event)
        }
    }

    private let allowsTextFocus: Bool
    init(allowsTextFocus: Bool = false) { self.allowsTextFocus = allowsTextFocus }

    private var existingPanel: Panel?
    private var panel: Panel {
        if let existingPanel { return existingPanel }
        let p = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.allowsTextFocus = allowsTextFocus
        p.becomesKeyOnlyIfNeeded = true
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
    private var bubbleAbove = false

    func showDot(in frame: NSRect, hoverChanged: @escaping (Bool) -> Void = { _ in }, action: @escaping () -> Void) {
        show(SelectionDotView(action: action, hoverChanged: hoverChanged), castsShadow: false, fixedFrame: frame)
    }

    func showBubble(_ state: SelectionBubble, target: String, at anchor: NSRect, title: String? = nil,
                    retry: (() -> Void)?, close: @escaping () -> Void) {
        panel.onEscape = close
        panel.title = title ?? ""
        let existing = panel.isVisible ? panel.frame : nil
        let point = existing.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: anchor.midX, y: anchor.midY)
        let screen = screenFrame(at: point)
        let placement = TranslationBubblePlacement(near: anchor, in: screen, existing: existing, above: bubbleAbove)
        bubbleAbove = placement.above
        show(SelectionBubbleView(state: state, target: target, title: title, contentWidth: min(416, screen.width - 56),
                                 maxTextHeight: placement.maxTextHeight,
                                 retry: retry, close: close,
                                 drag: { [weak self] in self?.drag() }, dragEnded: { [weak self] in self?.dragOffset = nil }),
             bubblePlacement: placement)
    }

    /// Any other draggable card in this panel; the view is given the two drag callbacks.
    func showCard<V: View>(at point: NSPoint, _ view: (_ drag: @escaping () -> Void, _ dragEnded: @escaping () -> Void) -> V) {
        anchor = point
        show(view({ [weak self] in self?.drag() }, { [weak self] in self?.dragOffset = nil }))
    }

    func hide() {
        guard let panel = existingPanel else { return }
        dragOffset = nil
        panel.onEscape = nil
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

    private func show<V: View>(_ view: V, castsShadow: Bool = true, fixedFrame: NSRect? = nil,
                               bubblePlacement: TranslationBubblePlacement? = nil) {
        let host = FirstClickHostingView(rootView: view)
        let size = fixedFrame?.size ?? host.fittingSize
        // A panel already open stays where it is (the user may have moved it), its top edge fixed.
        let top = panel.isVisible ? panel.frame.maxY : nil
        let left = panel.frame.minX
        panel.contentView = host
        panel.setContentSize(size)
        AppWindowStyle.fixSize(panel, to: size)
        AppWindowStyle.round(panel)
        panel.hasShadow = castsShadow
        if let fixedFrame {
            panel.setFrameOrigin(fixedFrame.origin)
            panel.orderFrontRegardless()
            return
        }
        let screen = bubblePlacement?.screen ?? screenFrame(at: top.map { NSPoint(x: left + size.width / 2, y: $0 - 1) } ?? anchor)
        var origin = bubblePlacement?.origin(for: size) ?? top.map { NSPoint(x: left, y: $0 - size.height) }
            ?? NSPoint(x: anchor.x + 8, y: anchor.y - size.height - 12)
        if bubblePlacement == nil && top == nil && origin.y < screen.minY { origin.y = anchor.y + 16 }
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

/// The card's controls accept the first click even while the parent app is inactive.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The small hit area includes the spaces between the waveform bars.
struct SelectionDotView: View {
    let action: () -> Void
    var hoverChanged: (Bool) -> Void = { _ in }

    var body: some View {
        Button(action: action) { TranslationSunset(hoverChanged: hoverChanged) }
            .buttonStyle(TranslationDotPressStyle())
            .frame(width: TranslationSunset.displaySize.width, height: TranslationSunset.displaySize.height)
            .contentShape(Rectangle())
            .accessibilityLabel(SelectionTranslator.featureName)
            .help(SelectionTranslator.featureName)
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
    var title: String? = nil
    let contentWidth: CGFloat
    let maxTextHeight: CGFloat
    let retry: (() -> Void)?
    let close: () -> Void
    let drag: () -> Void
    let dragEnded: () -> Void
    @State private var copyFeedback: UUID?
    @State private var selectedText: String?

    private var language: TranslateLanguage? { TranslateLanguage(rawValue: target) }
    private var isEastAsian: Bool { language == .zh || language == .ja || language == .ko }

    private var translatedFont: NSFont {
        if language == .zh { return InterfaceTypography.localizedAppKit(16) }
        return .systemFont(ofSize: 16)
    }

    private static let latinParagraph = readingParagraph(eastAsian: false)
    private static let eastAsianParagraph = readingParagraph(eastAsian: true)

    private static func readingParagraph(eastAsian: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = eastAsian ? 27 : 25
        style.paragraphSpacing = 10
        if eastAsian { style.lineBreakStrategy = .standard }
        return style
    }

    private var copyableText: String? {
        switch state {
        case .done(let text): return text
        case .failed(_, let partial): return partial
        case .loading: return nil
        }
    }

    private var copyLabel: String {
        if copyFeedback != nil { return L10n.text("已复制") }
        return L10n.text(selectedText == nil ? "复制全文" : "复制所选文字")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                HStack {
                    let languageLabel = language?.label ?? target
                    Text(title.map { $0 + " · " + languageLabel } ?? languageLabel)
                        .font(Theme.captionFont).foregroundColor(Theme.secondary)
                    Spacer(minLength: 8)
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in drag() }.onEnded { _ in dragEnded() })
                if let text = copyableText, !text.isEmpty {
                    IconButton(symbol: copyFeedback == nil ? "doc.on.doc" : "checkmark",
                               help: copyLabel, size: 28, symbolSize: 13) {
                        Inserter.shared.setString(selectedText ?? text)
                        copyFeedback = UUID()
                    }
                    .accessibilityLabel(copyLabel)
                }
                IconButton(symbol: "xmark", help: L10n.text("关闭"), size: 28, symbolSize: 12, feedback: .fixed, action: close)
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
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 18)
        .resetCopyFeedback($copyFeedback)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.tile))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.border).allowsHitTesting(false))
    }

    private func translationText(_ text: String) -> some View {
        SelectableText(text: text, font: translatedFont, color: NSColor(Theme.ink), maxLines: 0,
                       paragraphStyle: isEastAsian ? Self.eastAsianParagraph : Self.latinParagraph,
                       maxViewportHeight: maxTextHeight, acceptsInactiveClick: true,
                       onSelectionChange: { selectedText = $0 }, onPlainClick: {})
    }
}

import AppKit
import ApplicationServices

// Real-app paste check (Tools/paste-check.sh): drives TextEdit and browsers through the
// production Inserter, FieldContextReader, RecordingBar and BetaPanel. It moves the mouse,
// opens documents and tabs and pastes, so it is run by hand, never in CI. The terminal
// running it needs the Accessibility permission.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
let mode = CommandLine.arguments.dropFirst().first ?? "all"

func pump(_ s: Double) {
    let end = Date().addingTimeInterval(s)
    while Date() < end {
        if let ev = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
            NSApp.sendEvent(ev)
        }
    }
}
func osa(_ script: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript"); p.arguments = ["-e", script]
    p.standardOutput = Pipe(); try? p.run(); p.waitUntilExit()
}
func attr<T>(_ e: AXUIElement, _ a: String) -> T? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, a as CFString, &raw) == .success, let v = raw else { return nil }
    return v as? T
}
func focusedElement() -> AXUIElement? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &raw) == .success,
          let v = raw, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func value(_ e: AXUIElement) -> String { attr(e, kAXValueAttribute) ?? "" }
func setCaret(_ e: AXUIElement, _ loc: Int) {
    var r = CFRange(location: loc, length: 0)
    AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
}
func paste(_ text: String) -> PasteResult {
    var out: PasteResult = .eventFailed
    var done = false
    Inserter.shared.insert(text) { r, _ in out = r; done = true }
    for _ in 0..<40 where !done { pump(0.05) }
    pump(0.4)
    return out
}
func click(_ p: NSPoint) {
    // AppKit point (bottom-left origin) -> CG global (top-left origin).
    let h = NSScreen.screens[0].frame.height
    let q = CGPoint(x: p.x, y: h - p.y)
    let src = CGEventSource(stateID: .combinedSessionState)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
    pump(0.1)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
    pump(0.08)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
    pump(0.4)
}

var failures = 0
func report(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  [" + detail + "]"))
    if !ok { failures += 1 }
}

/// A fresh TextEdit document holding `text`, focused, with the caret at `caret`.
func freshDoc(_ text: String, caret: Int) -> AXUIElement? {
    osa("tell application \"TextEdit\" to make new document with properties {text:\"\(text)\"}")
    osa("tell application \"TextEdit\" to activate")
    pump(0.8)
    guard let e = focusedElement() else { return nil }
    setCaret(e, caret)
    pump(0.2)
    return e
}

let te = "com.apple.TextEdit"
print("shell trusted=", AXIsProcessTrusted())

if mode == "all" || mode == "basic" {
    if let e = freshDoc("AAAABBBB", caret: 4) {
        let r = paste("X")
        report("1 plain paste at the cursor", value(e) == "AAAAXBBBB", value(e) + " " + String(describing: r))
    } else { report("1 plain paste at the cursor", false, "no focused element") }
}

if mode == "all" || mode == "anchor" {
    if let e = freshDoc("AAAABBBB", caret: 4) {
        let field = FieldContextReader.capture(bundleId: te)
        setCaret(e, 8)   // the cursor drifts to the end while the user speaks
        pump(0.2)
        let restored = field.map { FieldContextReader.restoreCaret($0) } ?? .unknown
        _ = paste("X")
        report("2 cursor moved in the same field -> first position", value(e) == "AAAAXBBBB", value(e) + " restored=" + String(describing: restored))
    }
    if let e = freshDoc("AAAABBBB", caret: 4) {
        let field = FieldContextReader.capture(bundleId: te)
        AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, "ZZAAAABBBB" as CFString)
        setCaret(e, 10)
        pump(0.2)
        let restored = field.map { FieldContextReader.restoreCaret($0) } ?? .unknown
        _ = paste("X")
        report("3 text before the cursor changed -> current cursor", restored == .sameField && value(e) == "ZZAAAABBBBX", value(e) + " restored=" + String(describing: restored))
    }
    if let e1 = freshDoc("AAAABBBB", caret: 4) {
        let field = FieldContextReader.capture(bundleId: te)
        let e2 = freshDoc("CCCC", caret: 4)
        let restored = field.map { FieldContextReader.restoreCaret($0) } ?? .unknown
        pump(0.3)
        _ = paste("X")
        report("4 another window of the same app -> first window", value(e1) == "AAAAXBBBB" && (e2.map(value) ?? "") == "CCCC",
               value(e1) + " | " + (e2.map(value) ?? "-") + " restored=" + String(describing: restored))
    }
}

if mode == "all" || mode == "pill" {
    if let e = freshDoc("AAAABBBB", caret: 4) {
        let bar = RecordingBar()
        var pasted: PasteResult?
        bar.onStop = { pasted = paste("X") }
        bar.showRecording(destination: te)
        pump(0.6)
        if let panel = NSApp.windows.first(where: { $0 is PillPanel && $0.isVisible }) {
            let f = panel.frame
            click(NSPoint(x: f.maxX - 4 - PillView.buttonSize / 2, y: f.midY))
            pump(0.5)
            report("5 pill ✓ click pastes into the field", value(e) == "AAAAXBBBB" && pasted != nil,
                   value(e) + " key=" + String(panel.isKeyWindow) + " fired=" + String(pasted != nil))
        } else { report("5 pill ✓ click pastes into the field", false, "pill not on screen") }
        bar.hide()
        pump(0.3)
    }
}

if mode == "all" || mode == "beta" {
    if let e = freshDoc("AAAABBBB", caret: 4) {
        let field = FieldContextReader.capture(bundleId: te)
        let panel = BetaPanel()
        var generated = false
        panel.onSkip = { _ in generated = true }
        panel.show(info: BetaInfo(sessionId: "s", questions: ["要读哪些文件？"], confirmed: ["目标"], goals: nil, round: 1,
                                  ready: false, notice: nil, issues: nil, patched: nil), hotkey: "fn")
        pump(0.8)
        // Click the panel's primary button (bottom-right) the way a user would.
        if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is PillPanel) && $0.frame.width >= 400 }) {
            click(NSPoint(x: w.frame.maxX - 40, y: w.frame.minY + 26))
            let wasKey = w.isKeyWindow
            panel.hide()
            pump(0.3)
            if let field { FieldContextReader.restoreCaret(field) }
            _ = paste("X")
            report("6 prompt mode panel click, then paste into the field", value(e) == "AAAAXBBBB",
                   value(e) + " panelKeyAfterClick=" + String(wasKey) + " generated=" + String(generated))
        } else { report("6 prompt mode panel click, then paste into the field", false, "panel not found") }
    }
}


if mode == "all" || mode == "selection" {
    // 选中即翻译: a mouse drag over text shows the button; a click shows the bubble; the app
    // being read keeps its focus and its selection.
    if let e = freshDoc("Hello world from TypeLeast", caret: 0) {
        let translator = SelectionTranslator()
        var asked: (String, String)?
        translator.translate = { text, target, done in asked = (text, target); done(.success("你好，世界")) }
        translator.preferredTarget = { "en" }
        translator.start()
        var range = CFRange(location: 0, length: 11)
        var raw: CFTypeRef?
        var rect = CGRect.zero
        if AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                      AXValueCreate(.cfRange, &range)!, &raw) == .success, let raw {
            AXValueGetValue(raw as! AXValue, .cgRect, &rect)
        }
        let from = CGPoint(x: rect.minX + 1, y: rect.midY), to = CGPoint(x: rect.maxX - 1, y: rect.midY)
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?.post(tap: .cghidEventTap)
        pump(0.1)
        for i in 1...10 {
            let p = CGPoint(x: from.x + (to.x - from.x) * Double(i) / 10, y: from.y)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            pump(0.03)
        }
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
        pump(0.8)
        let button = NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }
        report("S1 a drag selection shows the 翻译 button", button != nil && SelectionTranslator.selectedText() == "Hello world",
               "selected=" + (SelectionTranslator.selectedText() ?? "nil"))
        if let button {
            click(NSPoint(x: button.frame.midX, y: button.frame.midY))
            pump(0.6)
            let bubble = NSApp.windows.first { $0.isVisible && $0.level == .popUpMenu }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            report("S2 a click translates the selection into a bubble", asked?.0 == "Hello world" && asked?.1 == "zh" && (bubble?.frame.width ?? 0) > 300,
                   "asked=" + String(describing: asked) + " bubbleWidth=" + String(describing: bubble?.frame.width))
            report("S3 the app keeps focus and selection", front == te && SelectionTranslator.selectedText() == "Hello world" && !(bubble?.isKeyWindow ?? true),
                   "front=" + front + " selected=" + (SelectionTranslator.selectedText() ?? "nil"))
        }
        translator.stop()
    }
}

if mode.hasPrefix("browser:") {
    // browser:<App name>:<bundle id>
    let parts = mode.split(separator: ":").map(String.init)
    let name = parts[1], bundle = parts[2]
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PASTECHECK_WEB"] ?? "web")
    func open(_ file: String, _ query: String = "") {
        let url = dir.appendingPathComponent(file).absoluteString + query
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-a", name, url]
        try? p.run(); p.waitUntilExit()
        pump(3.0)
    }
    func closeOurTabs() {
        osa("tell application \"\(name)\" to close (every tab of every window whose URL contains \"pastecheck-\")")
        pump(0.5)
    }
    func textAreas() -> [AXUIElement] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else { return [] }
        let appEl = AXUIElementCreateApplication(pid)
        FieldContextReader.exposeContent(bundleId: bundle)
        var found: [AXUIElement] = []
        for _ in 0..<8 where found.isEmpty {
            pump(0.8)
            // Only our page's window: a browser may float a bubble window in front of it.
            let windows: [AXUIElement] = attr(appEl, kAXWindowsAttribute) ?? []
            for win in windows where ((attr(win, kAXTitleAttribute) as String?) ?? "").contains("pastecheck") { walkFrom(win) }
        }
        return found
        func walkFrom(_ win: AXUIElement) {
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 30, found.count < 3 else { return }
            if (attr(e, kAXRoleAttribute) as String?) == "AXTextArea" { found.append(e); return }
            for c in (attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth + 1) }
        }
        walk(win, 0)
        }
    }
    func focusArea(_ e: AXUIElement, _ loc: Int) {
        AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pump(0.3)
        setCaret(e, loc)
        pump(0.3)
    }
    // B1: another field on the same page took focus while the user spoke.
    open("pastecheck-a.html")
    let areas = textAreas()
    if areas.count >= 2 {
        focusArea(areas[0], 4)
        let field = FieldContextReader.capture(bundleId: bundle)
        focusArea(areas[1], 4)
        let moved = focusedElement().map { value($0) } ?? "-"
        let restored = field.map { FieldContextReader.restoreCaret($0) } ?? .unknown
        _ = paste("X")
        report("B1 \(name): other field on the page -> first field", value(areas[0]) == "AAAAXBBBB" && value(areas[1]) == "CCCC",
               value(areas[0]) + " | " + value(areas[1]) + " movedTo=" + moved + " restored=" + String(describing: restored) + " anchor=" + String(field?.range != nil))
    } else { report("B1 \(name): other field on the page -> first field", false, "text areas found: \(areas.count)") }
    // B3: a click on a blank part of the page took focus away from the field.
    closeOurTabs()
    open("pastecheck-a.html")
    if let first = textAreas().first, let area: AXUIElement = attr(first, kAXParentAttribute) {
        focusArea(first, 4)
        let field = FieldContextReader.capture(bundleId: bundle)
        var pos = CGPoint.zero, size = CGSize.zero
        if let p: AXValue = attr(area, kAXPositionAttribute) { AXValueGetValue(p, .cgPoint, &pos) }
        if let z: AXValue = attr(area, kAXSizeAttribute) { AXValueGetValue(z, .cgSize, &size) }
        // CG top-left point -> AppKit point for click(): a spot well below the two fields.
        let h = NSScreen.screens[0].frame.height
        click(NSPoint(x: pos.x + size.width / 2, y: h - (pos.y + min(size.height - 20, 400))))
        let after = focusedElement().map { (attr($0, kAXRoleAttribute) as String?) ?? "?" } ?? "nil"
        let restored = field.map { FieldContextReader.restoreCaret($0) } ?? .unknown
        _ = paste("X")
        report("B3 \(name): clicked a blank part of the page -> first field", value(first) == "AAAAXBBBB",
               value(first) + " focusAfterClick=" + after + " restored=" + String(describing: restored) + " anchor=" + String(field?.range != nil))
    } else { report("B3 \(name): clicked a blank part of the page", false, "no text area") }
    // B2: another tab is in front: the first field is gone, so nothing is pasted.
    closeOurTabs()
    open("pastecheck-a.html")
    if let first = textAreas().first {
        focusArea(first, 4)
        let field = FieldContextReader.capture(bundleId: bundle)
        open("pastecheck-c.html")
        if let other = textAreas().first { focusArea(other, 4) }
        let before = focusedElement().map(value) ?? "-"
        let restored = field.map { FieldContextReader.restoreCaret($0) } ?? .unknown
        let now = focusedElement().map(value) ?? "-"
        report("B2 \(name): tab switched -> back to the first field, or no paste", restored == .lost || (restored == .restored && now == "AAAABBBB"),
               "focusBefore=" + before + " restored=" + String(describing: restored) + " focusNow=" + (focusedElement().map(value) ?? "-"))
    } else { report("B2 \(name): tab switched", false, "no text area") }
    closeOurTabs()
}
osa("tell application \"TextEdit\" to close every document saving no")
print("FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)

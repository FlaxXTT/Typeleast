import AppKit
import Carbon.HIToolbox

// Direct insertion and explicit clipboard actions.

struct ClipboardSnapshot {
    var items: [[NSPasteboard.PasteboardType: Data]]
}

enum PasteResult {
    case pasted
    /// Text was sent, but the target did not acknowledge that it inserted it.
    case unverified
    case secureInput
    case accessibilityRequired
    case eventFailed

    var ok: Bool { self == .pasted || self == .unverified }

    var message: String {
        switch self {
        case .pasted: return L10n.text("已写入")
        case .unverified: return L10n.text("已发送文字，请确认是否写入。")
        case .secureInput: return L10n.text("安全输入已开启，未写入。")
        case .accessibilityRequired: return L10n.text("请允许辅助功能后再写入。")
        case .eventFailed: return L10n.text("无法写入当前输入框。")
        }
    }
}

final class Inserter {
    static let shared = Inserter()

    enum NewlineMode {
        case none
        case editorReturn
        case composerShiftReturn

        var flags: CGEventFlags { self == .composerShiftReturn ? .maskShift : [] }
    }

    // MARK: clipboard

    func snapshot() -> ClipboardSnapshot {
        let pb = NSPasteboard.general
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        if let pbItems = pb.pasteboardItems {
            for it in pbItems {
                var dict: [NSPasteboard.PasteboardType: Data] = [:]
                for t in it.types {
                    if let d = it.data(forType: t) { dict[t] = d }
                }
                items.append(dict)
            }
        }
        return ClipboardSnapshot(items: items)
    }

    @discardableResult
    func setString(_ text: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return pb.changeCount
    }

    /// A numbered or bulleted list starts on its own line: when the cursor follows other text on
    /// the same line (or what precedes it could not be read), a line break goes first.
    static func separatingList(_ text: String, before: String?) -> String {
        guard text.range(of: #"^\s*(\d{1,3}[.、．)）](?!\d)|[-*•]\s)\s*\S"#, options: .regularExpression) != nil else { return text }
        if let before {
            let line = before.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return text }
        }
        return "\n" + text
    }

    func restore(_ snap: ClipboardSnapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snap.items.isEmpty else { return }
        var restored: [NSPasteboardItem] = []
        for dict in snap.items {
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            restored.append(item)
        }
        pb.writeObjects(restored)
    }

    // MARK: paste

    static func isSecureInputEnabled() -> Bool { IsSecureEventInputEnabled() }
    static func isAccessibilityTrusted() -> Bool { AXIsProcessTrusted() }
    static var pasteModifiersReleased: Bool {
        let held: CGEventFlags = [.maskAlternate, .maskShift, .maskControl, .maskCommand, .maskSecondaryFn]
        return CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty
    }

    /// Browsers whose web text fields Accessibility cannot read. They copy nothing when nothing
    /// is selected (unlike editors such as VS Code, which copy the whole line), so a ⌘C there
    /// reads exactly the selection.
    static let copySelectionApps = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
                                    "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
                                    "org.mozilla.firefox"]

    static func readsSelectionByCopy(_ bundleId: String) -> Bool {
        copySelectionApps.contains { bundleId == $0 || bundleId.hasPrefix($0 + ".") }
    }

    /// The frontmost app's selection, read with a synthesised ⌘C once ⌥ ⇧ ⌃ are let go (so the
    /// app does not see ⌥⌘C); the clipboard is put back. nil when nothing was copied.
    func copySelection(whileFrontmost pid: pid_t? = nil, completion: @escaping (String?) -> Void) {
        let held: CGEventFlags = [.maskAlternate, .maskShift, .maskControl, .maskCommand]
        func waitForRelease(_ tries: Int) {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty || tries == 0 { copy() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { waitForRelease(tries - 1) } }
        }
        func copy() {
            if let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                completion(nil)
                return
            }
            let pb = NSPasteboard.general
            let snap = snapshot()
            let before = pb.changeCount
            guard !Inserter.isSecureInputEnabled(), postCommand(0x08) else { completion(nil); return } // kVK_ANSI_C
            func check(_ tries: Int) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if pb.changeCount != before {
                        let text = pb.string(forType: .string)
                        self.restore(snap)
                        completion(text)
                    } else if tries > 0 { check(tries - 1) } else { completion(nil) }
                }
            }
            check(8)
        }
        waitForRelease(40)
    }

    private func postCommand(_ key: CGKeyCode) -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Replace the selection (or insert at the caret) without using the pasteboard.
    func insert(_ text: String, into app: NSRunningApplication, canPost: () -> Bool) -> PasteResult {
        guard !Self.isSecureInputEnabled() else { return .secureInput }
        guard Self.isAccessibilityTrusted() else { return .accessibilityRequired }
        guard canPost(), !text.isEmpty else { return .eventFailed }

        let target = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.25)
        let bundleID = app.bundleIdentifier ?? ""
        let isTerminal = TerminalGuard.isTerminal(bundleID)
        let isAgentComposerApp = bundleID == "com.openai.codex" || bundleID == "ai.opencode.desktop"
        func focusedElement() -> AXUIElement? {
            if isAgentComposerApp,
               let systemFocus = FieldContextReader.focusedElement(ofApp: bundleID) {
                return systemFocus
            }
            return FieldContextReader.copy(target, kAXFocusedUIElementAttribute)
        }
        let focus = focusedElement()
        var newlineMode = NewlineMode.none
        if let focus {
            AXUIElementSetMessagingTimeout(focus, 0.25)
            let subrole: String? = FieldContextReader.copy(focus, kAXSubroleAttribute)
            if subrole == kAXSecureTextFieldSubrole as String { return .secureInput }
            if bundleID == "com.microsoft.VSCode" || isAgentComposerApp {
                let role: String? = FieldContextReader.copy(focus, kAXRoleAttribute)
                var element = focus
                for _ in 0..<(isAgentComposerApp ? 4 : 1) {
                    let classes: [String] = FieldContextReader.copy(element, "AXDOMClassList") ?? []
                    newlineMode = Self.newlineMode(bundleID: bundleID, role: role, classes: classes)
                    guard newlineMode == .none, isAgentComposerApp,
                          let parent: AXUIElement = FieldContextReader.copy(element, kAXParentAttribute) else { break }
                    element = parent
                }
            }
            // The verified keyboard adapters cover editors whose AX writes do not update
            // the document. All other fields use the same capability-based AX path.
            if !isTerminal, newlineMode == .none,
               let result = Self.writeThroughAccessibility(text, to: focus, canWrite: {
                   canPost() && !Self.isSecureInputEnabled()
                       && (focusedElement().map { CFEqual(focus, $0) } ?? false)
               }) {
                return result
            }
        }
        if bundleID == "com.openai.codex", newlineMode == .none {
            DiagnosticsLog.write("delivery.codex-field", ["code": "composer-not-identified"])
        }
        guard newlineMode != .none || isTerminal || focus.map(FieldContextReader.canReceiveTextEvents) == true,
              let commands = Self.textEvents(text, allowsEditorNewlines: newlineMode != .none) else { return .eventFailed }
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .privateState) else { return .accessibilityRequired }
        var sent = false
        for command in commands {
            if command == nil {
                let current = focusedElement()
                guard let focus, let current, CFEqual(focus, current) else { return sent ? .unverified : .eventFailed }
            }
            let key: CGKeyCode = command == nil ? CGKeyCode(kVK_Return) : 0
            guard canPost(), !Self.isSecureInputEnabled(),
                  let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
                return sent ? .unverified : .eventFailed
            }
            down.flags = command == nil ? newlineMode.flags : []
            up.flags = down.flags
            command?.withUnsafeBufferPointer {
                down.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                up.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
            down.postToPid(app.processIdentifier)
            up.postToPid(app.processIdentifier)
            sent = true
        }
        return sent ? .unverified : .eventFailed
    }

    private static func writeThroughAccessibility(_ text: String, to field: AXUIElement,
                                                   canWrite: () -> Bool) -> PasteResult? {
        func isSettable(_ attribute: CFString) -> Bool {
            var settable = DarwinBoolean(false)
            return AXUIElementIsAttributeSettable(field, attribute, &settable) == .success && settable.boolValue
        }

        // For an empty text area, AXValue can insert the entire multiline value.
        // Some editors accept an AXSelectedText write without changing an empty field.
        let value = kAXValueAttribute as CFString
        if text.utf8.contains(10) || text.utf8.contains(13),
           FieldContextReader.copy(field, kAXRoleAttribute) as String? == kAXTextAreaRole,
           isSettable(value),
           let original: String = FieldContextReader.copy(field, kAXValueAttribute),
           original.isEmpty {
            guard canWrite() else { return .eventFailed }
            let latestValue: String? = FieldContextReader.copy(field, kAXValueAttribute)
            guard latestValue == "" else { return .eventFailed }
            switch AXUIElementSetAttributeValue(field, value, text as CFString) {
            case .success:
                let actual: String? = FieldContextReader.copy(field, kAXValueAttribute)
                guard actual == text else { return .unverified }
                let selectedRange = kAXSelectedTextRangeAttribute as CFString
                if isSettable(selectedRange), canWrite() {
                    var caret = CFRange(location: text.utf16.count, length: 0)
                    if let range = AXValueCreate(.cfRange, &caret) {
                        AXUIElementSetAttributeValue(field, selectedRange, range)
                    }
                }
                return .pasted
            case .attributeUnsupported, .notImplemented: break
            case .cannotComplete: return .unverified
            default: return .eventFailed
            }
        }

        let selection = kAXSelectedTextAttribute as CFString
        guard isSettable(selection) else { return nil }
        guard canWrite() else { return .eventFailed }
        switch AXUIElementSetAttributeValue(field, selection, text as CFString) {
        case .success: return .pasted
        case .attributeUnsupported, .notImplemented: return nil
        // The app may already have applied a timed-out write. Never replay it.
        case .cannotComplete: return .unverified
        default: return .eventFailed
        }
    }

    static func newlineMode(bundleID: String, role: String?, classes: [String]) -> NewlineMode {
        if bundleID == "com.microsoft.VSCode", role == kAXTextAreaRole,
           classes.contains(where: { $0 == "native-edit-context" || $0 == "inputarea" }) { return .editorReturn }
        if bundleID == "com.openai.codex", classes.contains("ProseMirror") { return .composerShiftReturn }
        if bundleID == "ai.opencode.desktop", role == kAXTextAreaRole,
           classes.contains("pe-[var(--composer-scroll-end)]"), classes.contains("whitespace-pre-wrap") {
            return .composerShiftReturn
        }
        return .none
    }

    /// A nil element denotes the identified editor's line-break shortcut.
    static func textEvents(_ text: String, allowsEditorNewlines: Bool) -> [[UInt16]?]? {
        guard allowsEditorNewlines else {
            return safeForTextEvents(text) ? unicodeChunks(text).map(Optional.some) : nil
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        guard lines.allSatisfy({ $0.isEmpty || safeForTextEvents($0) }) else { return nil }
        var events: [[UInt16]?] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { events.append(nil) }
            events.append(contentsOf: unicodeChunks(line).map(Optional.some))
        }
        return events
    }

    static func safeForTextEvents(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) || $0.value == 0x200C || $0.value == 0x200D
        } && text.rangeOfCharacter(from: .newlines) == nil
    }

    /// Keep sequences such as emoji together whenever they fit within one event.
    static func unicodeChunks(_ text: String) -> [[UInt16]] {
        let limit = 20
        var chunks: [[UInt16]] = []
        var pending: [UInt16] = []
        func append(_ units: [UInt16]) {
            if pending.count + units.count > limit {
                chunks.append(pending)
                pending = []
            }
            pending.append(contentsOf: units)
        }
        for character in text {
            let units = Array(character.utf16)
            if units.count <= limit {
                append(units)
            } else {
                for scalar in character.unicodeScalars { append(Array(scalar.utf16)) }
            }
        }
        if !pending.isEmpty { chunks.append(pending) }
        return chunks
    }

    /// Ask macOS to prompt for the Accessibility grant.
    ///
    /// Only the system can grant this: TCC records the decision and a user must
    /// flip the switch. Passing the prompt option makes macOS show its own
    /// "open System Settings" dialog, which is the only reliable re-entry point
    /// after a denial (once denied, an app cannot re-prompt silently).
    @discardableResult
    static func requestAccessibilityPrompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Reset this app's Accessibility decision so the system will offer it again.
    ///
    /// Needed because a denial is otherwise sticky: `tccutil reset` clears the
    /// record and the next permission check is treated as a first request.
    @discardableResult
    static func resetAccessibilityDecision() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.dsh.voice"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let u = url { NSWorkspace.shared.open(u) }
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        if let u = url { NSWorkspace.shared.open(u) }
    }
}

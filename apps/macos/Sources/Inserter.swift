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

    private var temporaryPasteChangeCount: Int?

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

    /// Temporarily stage plain text for the target application's normal Paste action.
    func insert(_ text: String, into app: NSRunningApplication, canPost: () -> Bool) -> PasteResult {
        guard !Self.isSecureInputEnabled() else { return .secureInput }
        guard Self.isAccessibilityTrusted(), CGPreflightPostEventAccess() else { return .accessibilityRequired }
        guard !text.isEmpty, canPost() else { return .eventFailed }

        let pasteboard = NSPasteboard.general
        // Let the previous target read its text before staging another payload.
        guard temporaryPasteChangeCount != pasteboard.changeCount else { return .eventFailed }
        let original = snapshot()
        guard canPost(), !Self.isSecureInputEnabled() else { return .eventFailed }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(original)
            return .eventFailed
        }
        let stagedChangeCount = pasteboard.changeCount
        temporaryPasteChangeCount = stagedChangeCount
        guard canPost(), NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              !Self.isSecureInputEnabled(), postCommand(CGKeyCode(kVK_ANSI_V)) else {
            finishTemporaryPaste(stagedChangeCount, original: original)
            return .eventFailed
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.finishTemporaryPaste(stagedChangeCount, original: original)
        }
        return .unverified
    }

    private func finishTemporaryPaste(_ changeCount: Int, original: ClipboardSnapshot) {
        if NSPasteboard.general.changeCount == changeCount {
            restore(original)
        }
        if temporaryPasteChangeCount == changeCount {
            temporaryPasteChangeCount = nil
        }
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

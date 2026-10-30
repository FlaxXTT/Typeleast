import AppKit
import Carbon.HIToolbox

// Inserter.swift - clipboard + synthesized Cmd+V, with clipboard restore.

struct ClipboardSnapshot {
    var items: [[NSPasteboard.PasteboardType: Data]]
    var changeCount: Int
}

enum PasteResult {
    case pasted
    /// The Cmd+V was posted, but delivery could not be confirmed and the
    /// Accessibility grant is missing. This is NOT a known failure: on many
    /// machines the paste lands anyway, and telling the user it failed when the
    /// text actually appeared is worse than staying quiet about the uncertainty.
    case unverified
    case secureInput
    case eventFailed

    var ok: Bool { self == .pasted || self == .unverified }

    var message: String {
        switch self {
        case .pasted: return L10n.text("已粘贴")
        case .unverified: return L10n.text("已粘贴。没看到请按 ⌘V，或允许辅助功能")
        case .secureInput: return L10n.text("安全输入已开启，已复制到剪贴板")
        case .eventFailed: return L10n.text("无法粘贴，已复制到剪贴板")
        }
    }
}

/// Where a finished dictation may be pasted.
enum PasteTarget {
    /// Only into the app the dictation started in. Cleanup takes about a second, and a
    /// paste that follows the user to another window (a terminal, a chat) is worse than
    /// no paste at all. An unknown starting app cannot be checked, so it is allowed.
    static func matches(expected: String, frontmost: String) -> Bool {
        expected.isEmpty || expected == frontmost
    }
}

final class Inserter {
    static let shared = Inserter()

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
        return ClipboardSnapshot(items: items, changeCount: pb.changeCount)
    }

    @discardableResult
    func setString(_ text: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return pb.changeCount
    }

    /// Apps that turn pasted HTML/RTF lists into real lists. Everything else (chat,
    /// code editors, terminals) gets the plain "1. …" text, which is what they want.
    static let richListApps: Set<String> = [
        "com.apple.Notes", "com.apple.mail", "com.apple.Pages", "com.apple.iWork.Pages",
        "com.microsoft.Word", "com.microsoft.Outlook", "com.apple.TextEdit", "notion.id",
    ]

    /// HTML for text containing "1. " numbered lines, or nil when there is no list.
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

    static func listHTML(for text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let numbered = lines.filter { $0.range(of: #"^\s*\d{1,2}[.)]\s+"#, options: .regularExpression) != nil }
        guard numbered.count >= 2 else { return nil }
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = ""
        var inList = false
        for line in lines {
            if let r = line.range(of: #"^\s*\d{1,2}[.)]\s+"#, options: .regularExpression) {
                if !inList { html += "<ol>"; inList = true }
                html += "<li>" + escape(String(line[r.upperBound...])) + "</li>"
            } else {
                if inList { html += "</ol>"; inList = false }
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { html += "<p>" + escape(line) + "</p>" }
            }
        }
        if inList { html += "</ol>" }
        return "<meta charset=\"utf-8\"><div style=\"font-family:-apple-system\">" + html + "</div>"
    }

    /// Plain text plus, for a list, HTML and RTF flavours of the same content.
    @discardableResult
    func setRich(_ text: String, html: String) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(html, forType: .html)
        if let data = html.data(using: .utf8),
           let attributed = NSAttributedString(html: data, documentAttributes: nil),
           let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) {
            item.setData(rtf, forType: .rtf)
        }
        pb.writeObjects([item])
        return pb.changeCount
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

    /// Synthesise Cmd+V. Construction needs no permission; delivery may.
    func postCommandV() -> Bool { postCommand(0x09) } // kVK_ANSI_V

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
    func copySelection(completion: @escaping (String?) -> Void) {
        let held: CGEventFlags = [.maskAlternate, .maskShift, .maskControl, .maskCommand]
        func waitForRelease(_ tries: Int) {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty || tries == 0 { copy() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { waitForRelease(tries - 1) } }
        }
        func copy() {
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

    /// Full insert: put text on the pasteboard, paste it, then restore the clipboard.
    /// Returns the result plus whether the clipboard was restored (left intact on failure).
    func insert(_ text: String, richHTML: String? = nil,
                completion: @escaping (PasteResult, Bool) -> Void) {
        let snap = snapshot()
        let before = richHTML.map { setRich(text, html: $0) } ?? setString(text)

        if Inserter.isSecureInputEnabled() {
            completion(.secureInput, false)
            return
        }
        guard postCommandV() else {
            completion(.eventFailed, false)
            return
        }
        let result: PasteResult = Inserter.isAccessibilityTrusted() ? .pasted : .unverified
        let shouldRestore = (result == .pasted) && snap.changeCount >= 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            var restored = false
            if shouldRestore {
                let pb = NSPasteboard.general
                // Only restore when nothing else wrote to the pasteboard meanwhile.
                if pb.changeCount == before || pb.string(forType: .string) == text {
                    self.restore(snap)
                    restored = true
                }
            }
            completion(result, restored)
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

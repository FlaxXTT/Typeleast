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

    /// Whether the menu should offer the permission path.
    var needsAccessibility: Bool { self == .unverified }

    var message: String {
        switch self {
        case .pasted: return "已粘贴"
        case .unverified: return "已粘贴（未验证）· 若文字没出现请按 ⌘V，或在菜单里申请辅助功能权限"
        case .secureInput: return "当前输入被安全键盘保护，已复制到剪贴板"
        case .eventFailed: return "无法构造粘贴事件，已复制到剪贴板"
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
    func postCommandV() -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Full insert: put text on the pasteboard, wait for the paste, optionally restore.
    /// Returns the result plus whether the clipboard was restored (left intact on failure).
    func insert(_ text: String, mode: InsertionMode, restoreClipboard: Bool, richHTML: String? = nil,
                completion: @escaping (PasteResult, Bool) -> Void) {
        let snap = snapshot()
        let before = richHTML.map { setRich(text, html: $0) } ?? setString(text)

        if mode != .autoPaste {
            completion(.pasted, false)
            return
        }
        if Inserter.isSecureInputEnabled() {
            completion(.secureInput, false)
            return
        }
        guard postCommandV() else {
            completion(.eventFailed, false)
            return
        }
        let result: PasteResult = Inserter.isAccessibilityTrusted() ? .pasted : .unverified
        let shouldRestore = (result == .pasted) && restoreClipboard && snap.changeCount >= 0
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

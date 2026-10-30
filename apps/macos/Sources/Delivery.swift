import AppKit

// Delivery.swift - where a finished dictation goes: the text the target receives, the checks
// that decide whether it may be pasted, and the paste itself. No UI and no history here: the
// controller turns the outcome into the pill, the hint and History's "inserted" flag.

/// Where a finished dictation may be pasted.
enum PasteTarget {
    /// Only into the app the dictation started in. Cleanup takes about a second, and a
    /// paste that follows the user to another window (a terminal, a chat) is worse than
    /// no paste at all. An unknown starting app cannot be checked, so it is allowed.
    static func matches(expected: String, frontmost: String) -> Bool {
        expected.isEmpty || expected == frontmost
    }
}

enum DeliveryOutcome: Equatable {
    /// The paste was sent; the result says whether it could be confirmed.
    case pasted(PasteResult)
    /// Another app is in front now: nothing was pasted.
    case appChanged
    /// The field the dictation started in is gone (closed, another tab): nothing was pasted.
    case fieldLost
}

enum Delivery {
    /// The text as the target should receive it. A terminal gets one line without control
    /// characters, which reduces accidental command execution; elsewhere a list never starts
    /// right after the text the cursor follows.
    static func prepare(_ text: String, appBundleId: String, field: FocusedField?) -> String {
        TerminalGuard.isTerminal(appBundleId) ? TerminalGuard.safeText(text, bundleId: appBundleId)
            : Inserter.separatingList(text, before: field?.bundleId == appBundleId ? field?.context.before : nil)
    }

    /// Paste `text` (already prepared) where the dictation started.
    static func deliver(_ text: String, appBundleId: String, field: FocusedField?,
                        completion: @escaping (DeliveryOutcome) -> Void) {
        // The user may have moved on while the text was being cleaned up. Pasting into
        // whatever is in front now could type into a terminal or the wrong chat, so nothing
        // is pasted and the clipboard is left alone; the text is in History.
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard PasteTarget.matches(expected: appBundleId, frontmost: frontmost) else { return completion(.appChanged) }
        // The cursor the user placed first is where the text goes, even if it moved meanwhile.
        if let field, field.bundleId == appBundleId, FieldContextReader.restoreCaret(field) == .lost {
            return completion(.fieldLost)
        }
        let rich = Inserter.richListApps.contains(appBundleId) ? Inserter.listHTML(for: text) : nil
        Inserter.shared.insert(text, richHTML: rich) { result, _ in completion(.pasted(result)) }
    }
}

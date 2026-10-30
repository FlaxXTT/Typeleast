import AppKit
import ApplicationServices

// FieldContext.swift - what is already in the box the user is dictating into.
//
// Context for accuracy: the words around the cursor tell the model which homophone, name or term is meant. It is read through the
// Accessibility API the app already holds for pasting, only at the moment a
// dictation starts, never from secure fields or password managers, and only the
// text near the cursor is kept. It travels to the local service, which redacts it
// before anything reaches a model.

/// The JSON body sent (base64) in `x-voice-context`.
struct FieldContext: Codable, Equatable {
    var before: String
    var selected: String
    var after: String
    var windowTitle: String

    var isEmpty: Bool { before.isEmpty && selected.isEmpty && after.isEmpty && windowTitle.isEmpty }

    func encoded() -> Data? { isEmpty ? nil : try? JSONEncoder().encode(self) }
}

/// A focused text element captured at dictation start. Where the cursor was then is
/// where the text goes: `range` puts it back if it moved while the user was speaking.
struct FocusedField {
    let element: AXUIElement
    let bundleId: String
    let context: FieldContext
    var range: CFRange? = nil
}

/// Whether a caret position captured at dictation start still points at the same place.
enum CaretAnchor {
    /// True when the text before `location` still ends with what preceded the cursor then,
    /// and the selection then is still selectable. Edits elsewhere in the field are fine;
    /// an edit before the cursor shifts the offset, so the anchor is not used.
    static func stillValid(before: String, selected: String, value: String, location: Int, length: Int) -> Bool {
        let ns = value as NSString
        guard location >= 0, length >= 0, location + length <= ns.length else { return false }
        // NSString answers false for an empty prefix or suffix, so those are checked first.
        guard before.isEmpty || (ns.substring(to: location) as NSString).hasSuffix(before) else { return false }
        return selected.isEmpty || (ns.substring(with: NSRange(location: location, length: length)) as NSString).hasPrefix(selected)
    }
}

enum FieldContextReader {
    /// Characters kept before / after the cursor.
    static let beforeLimit = 600
    static let afterLimit = 200

    /// Apps whose fields are never read, whatever their role says.
    static let blockedBundlePrefixes = [
        "com.1password", "com.agilebits", "com.bitwarden", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.lastpass", "com.dashlane", "org.keepassxc",
    ]

    static func isBlocked(bundleId: String) -> Bool {
        blockedBundlePrefixes.contains { bundleId.hasPrefix($0) }
    }

    /// Read the focused field of the frontmost app. Returns nil when not trusted, when
    /// nothing editable is focused, for secure fields and for blocked apps.
    static func capture(bundleId: String) -> FocusedField? {
        guard AXIsProcessTrusted(), !isBlocked(bundleId: bundleId) else { return nil }
        let system = AXUIElementCreateSystemWide()
        // A busy target app must never stall the hotkey path.
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let element: AXUIElement = copy(system, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)

        let subrole: String? = copy(element, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) { return nil }

        let readable: String? = copy(element, kAXValueAttribute)
        let value = readable ?? ""
        let selected: String = copy(element, kAXSelectedTextAttribute) ?? ""
        var before = ""
        var after = ""
        var anchor: CFRange?
        let ns = value as NSString
        if let range = selectedRange(element), range.location != kCFNotFound,
           range.location >= 0, range.location + range.length <= ns.length {
            // Only a field whose text can be read again can be checked before the paste.
            if readable != nil { anchor = range }
            let start = max(0, range.location - beforeLimit)
            before = ns.substring(with: NSRange(location: start, length: range.location - start))
            let tail = range.location + range.length
            after = ns.substring(with: NSRange(location: tail, length: min(afterLimit, ns.length - tail)))
        } else if !value.isEmpty {
            before = ns.length > beforeLimit ? ns.substring(from: ns.length - beforeLimit) : value
        }
        let context = FieldContext(before: before, selected: String(selected.prefix(400)),
                                   after: after, windowTitle: windowTitle() ?? "")
        return FocusedField(element: element, bundleId: bundleId, context: context, range: anchor)
    }

    enum CaretRestore: Equatable {
        /// Focus and cursor are back where the dictation started.
        case restored
        /// Focus is in the starting field, but the cursor stays where it is now: the text
        /// before the starting point changed, or the field refused the position.
        case sameField
        /// Nothing was captured at the start (no Accessibility, no text field): paste as is.
        case unknown
        /// The starting field is gone or cannot take focus back (closed, another tab).
        case lost
    }

    /// Put focus and the cursor back where the dictation started, before the paste.
    /// The cursor is only moved when the text before that point is unchanged, so the
    /// text never lands at a stale offset.
    @discardableResult
    static func restoreCaret(_ field: FocusedField) -> CaretRestore {
        guard let range = field.range, AXIsProcessTrusted() else { return .unknown }
        let element = field.element
        AXUIElementSetMessagingTimeout(element, 0.25)
        // A field that no longer answers was closed or left with its page.
        guard let value: String = copy(element, kAXValueAttribute) else { return .lost }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        func focusedHere() -> Bool {
            let focused: AXUIElement? = copy(system, kAXFocusedUIElementAttribute)
            return focused.map { CFEqual($0, element) } ?? false
        }
        if !focusedHere() {
            // The field may sit in another window of the same app: bring that window forward first.
            if let window: AXUIElement = copy(element, kAXWindowAttribute) {
                AXUIElementSetMessagingTimeout(window, 0.25)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            // A browser switches back to the field's tab first; give it a moment.
            var back = focusedHere()
            for _ in 0..<4 where !back {
                usleep(50_000)
                back = focusedHere()
            }
            guard back else { return .lost }
        }
        guard CaretAnchor.stillValid(before: field.context.before, selected: field.context.selected,
                                     value: value, location: range.location, length: range.length) else { return .sameField }
        if let current = selectedRange(element), current.location == range.location, current.length == range.length {
            return .restored
        }
        var wanted = range
        guard let axRange = AXValueCreate(.cfRange, &wanted),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else { return .sameField }
        return .restored
    }

    /// The whole current value of an element captured earlier, for the edit learner.
    static func currentValue(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return copy(element, kAXValueAttribute)
    }

    // MARK: helpers

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement) as? T
        }
        return value as? T
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func windowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let window: AXUIElement = copy(element, kAXFocusedWindowAttribute) else { return nil }
        let title: String? = copy(window, kAXTitleAttribute)
        return title.map { String($0.prefix(200)) }
    }
}

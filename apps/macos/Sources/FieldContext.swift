import AppKit
import ApplicationServices

// FieldContext.swift - what is already in the box the user is dictating into.
//
// This is the context Reference relies on for accuracy: the words around the cursor
// tell the model which homophone, name or term is meant. It is read through the
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

/// A focused text element captured at dictation start, kept so the edit learner can
/// read the same element again after the paste.
struct FocusedField {
    let element: AXUIElement
    let bundleId: String
    let context: FieldContext
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

        let value: String = copy(element, kAXValueAttribute) ?? ""
        let selected: String = copy(element, kAXSelectedTextAttribute) ?? ""
        var before = ""
        var after = ""
        let ns = value as NSString
        if let range = selectedRange(element), range.location != kCFNotFound,
           range.location >= 0, range.location + range.length <= ns.length {
            let start = max(0, range.location - beforeLimit)
            before = ns.substring(with: NSRange(location: start, length: range.location - start))
            let tail = range.location + range.length
            after = ns.substring(with: NSRange(location: tail, length: min(afterLimit, ns.length - tail)))
        } else if !value.isEmpty {
            before = ns.length > beforeLimit ? ns.substring(from: ns.length - beforeLimit) : value
        }
        let context = FieldContext(before: before, selected: String(selected.prefix(400)),
                                   after: after, windowTitle: windowTitle() ?? "")
        return FocusedField(element: element, bundleId: bundleId, context: context)
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

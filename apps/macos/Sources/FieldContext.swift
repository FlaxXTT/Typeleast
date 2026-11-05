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
    /// The whole selected text (context.selected is cut short): 提示词模式's draft and 翻译's input.
    var selection: String = ""
}

/// Whether a caret position captured at dictation start still points at the same place.
enum CaretAnchor {
    /// Where the cursor was, found by the text around it: the offset just after `before`, where `after`
    /// follows. Nil when that text is not there, or is there more than once. An empty field has one place.
    static func locate(before: String, after: String, in value: String) -> Int? {
        let ns = value as NSString
        if before.isEmpty && after.isEmpty { return ns.length == 0 ? 0 : nil }
        // Only the text nearest the cursor: the rest may have been edited meanwhile.
        let near = String(before.suffix(60)), next = String(after.prefix(60))
        let needle = near + next
        let first = ns.range(of: needle, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let rest = NSRange(location: first.location + 1, length: ns.length - first.location - 1)
        guard rest.length <= 0 || ns.range(of: needle, options: .literal, range: rest).location == NSNotFound else { return nil }
        return first.location + (near as NSString).length
    }

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

    /// Chromium browsers show a web page's fields to Accessibility only once an assistive
    /// app asks for it (AXEnhancedUserInterface, as screen readers do). Until then the field
    /// and cursor in a page cannot be read, so the starting position cannot be kept.
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.microsoft.edgemac.beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    private static let exposedLock = NSLock()
    private static var exposedPids = Set<pid_t>()

    /// Ask the app to expose its web content (Chromium) or its whole tree (Electron, through
    /// AXManualAccessibility; other apps ignore it). Once per process. True when it was just
    /// asked, so the caller can give the app a moment to build the tree.
    @discardableResult
    static func exposeContent(bundleId: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return false }
        let pid = app.processIdentifier
        exposedLock.lock()
        let fresh = exposedPids.insert(pid).inserted
        exposedLock.unlock()
        guard fresh else { return false }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        // The return codes are not meaningful here: Chrome reports an error and still complies.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if chromiumBrowsers.contains(bundleId) {
            AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        return true
    }

    /// Read the focused field of the frontmost app. Returns nil when not trusted, when
    /// nothing editable is focused, for secure fields and for blocked apps.
    static func capture(bundleId: String) -> FocusedField? {
        guard AXIsProcessTrusted(), !isBlocked(bundleId: bundleId) else { return nil }
        var focused = focusedElement(ofApp: bundleId)
        if exposeContent(bundleId: bundleId) {
            // The first time, the app builds its tree now: wait up to a second for the field.
            for _ in 0..<10 where !isTextField(focused) {
                usleep(100_000)
                focused = focusedElement(ofApp: bundleId)
            }
        }
        guard let element = focused else { return nil }
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
            // Only a real text field whose text can be read again is worth coming back to. Electron
            // apps (Claude, Codex) report a text-less group here, with a range that means nothing.
            if readable != nil, textFieldRoles.contains(copy(element, kAXRoleAttribute) ?? "") { anchor = range }
            let start = max(0, range.location - beforeLimit)
            before = ns.substring(with: NSRange(location: start, length: range.location - start))
            let tail = range.location + range.length
            after = ns.substring(with: NSRange(location: tail, length: min(afterLimit, ns.length - tail)))
        } else if !value.isEmpty {
            before = ns.length > beforeLimit ? ns.substring(from: ns.length - beforeLimit) : value
        }
        let context = FieldContext(before: before, selected: String(selected.prefix(400)),
                                   after: after, windowTitle: windowTitle(ofApp: bundleId) ?? "")
        return FocusedField(element: element, bundleId: bundleId, context: context, range: anchor,
                            selection: String(selected.prefix(selectionLimit)))
    }

    /// The frontmost app as the target when its field cannot be read (a web page in Chrome): the text
    /// is pasted wherever its focus is, over the selection that is still there.
    static func frontmostApp(bundleId: String, selection: String) -> FocusedField? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleId else { return nil }
        return FocusedField(element: AXUIElementCreateApplication(app.processIdentifier), bundleId: bundleId,
                            context: FieldContext(before: "", selected: "", after: "", windowTitle: ""),
                            selection: String(selection.prefix(selectionLimit)))
    }

    /// Longest selection taken as a draft or translated (the service's own limit is 24000).
    static let selectionLimit = 20000

    /// Where the captured cursor or selection is on screen, in Cocoa coordinates, when the app says.
    static func caretRect(_ field: FocusedField) -> NSRect? {
        guard var range = field.range, let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        AXUIElementSetMessagingTimeout(field.element, 0.25)
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(field.element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         axRange, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect), rect.height > 0,
              let primary = NSScreen.screens.first else { return nil }
        // Accessibility measures from the top-left of the primary screen.
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: max(rect.width, 1), height: rect.height)
    }

    enum CaretRestore: Equatable {
        /// Focus and cursor are back where the dictation started.
        case restored
        /// Focus is in the starting field, but the cursor stays where it is now: the text
        /// before the starting point changed, or the field refused the position.
        case sameField
        /// Nothing was captured at the start (no Accessibility, no text field): paste as is.
        case unknown
        /// The starting field still exists, but the user is somewhere else (another tab or window).
        case elsewhere
        /// The handle no longer answers, and what has focus now is not recognisably that field.
        case gone
    }

    private static let textFieldRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]
    /// Focus on one of these is not a place to type; anything else may be an editor that reads as a group.
    private static let notEditableRoles: Set<String> = ["AXWebArea", "AXWindow", "AXApplication", "AXList", "AXOutline", "AXTable",
                                                        "AXButton", "AXScrollArea", "AXToolbar", "AXMenu", "AXMenuItem"]

    /// What has focus in `bundleId`. The system-wide focus may already belong to another app
    /// (the user switched right after the key), and that app's field must not become the target.
    static func focusedElement(ofApp bundleId: String) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        // A busy target app must never stall the hotkey path.
        AXUIElementSetMessagingTimeout(system, 0.25)
        if let element: AXUIElement = copy(system, kAXFocusedUIElementAttribute) {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleId {
                return element
            }
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
        let target = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.25)
        return copy(target, kAXFocusedUIElementAttribute)
    }

    /// Whether a paste need wait no longer: the user is at the starting field. Changes nothing,
    /// so it can be asked repeatedly while the user works elsewhere.
    static func isBackAtField(_ field: FocusedField) -> Bool {
        guard field.range != nil else { return true }
        AXUIElementSetMessagingTimeout(field.element, 0.25)
        let alive: String? = copy(field.element, kAXValueAttribute)
        if alive != nil {
            if focusedElement(ofApp: field.bundleId).map({ CFEqual($0, field.element) }) == true { return true }
            return recognise(field)?.caret != nil
        }
        return recognise(field) != nil
    }

    /// The starting field under its new handle: its text around the cursor is still there, or
    /// failing that it is the same window (a browser's other tab has another title). With the
    /// caret offset, when the text around it could be found.
    private static func recognise(_ field: FocusedField) -> (element: AXUIElement, caret: Int?)? {
        guard let element = focusedElement(ofApp: field.bundleId) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        let role: String = copy(element, kAXRoleAttribute) ?? ""
        if notEditableRoles.contains(role) { return nil }
        let sameWindow = field.context.windowTitle.isEmpty || field.context.windowTitle == (windowTitle(ofApp: field.bundleId) ?? "")
        guard textFieldRoles.contains(role), let value: String = copy(element, kAXValueAttribute) else {
            return sameWindow ? (element, nil) : nil
        }
        if let caret = CaretAnchor.locate(before: field.context.before, after: field.context.after, in: value) { return (element, caret) }
        return sameWindow ? (element, nil) : nil
    }

    private static func refind(_ field: FocusedField) -> CaretRestore {
        guard let found = recognise(field) else { return .gone }
        guard let caret = found.caret else { return .sameField }
        var wanted = CFRange(location: caret, length: 0)
        guard let axRange = AXValueCreate(.cfRange, &wanted),
              AXUIElementSetAttributeValue(found.element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else { return .sameField }
        return .restored
    }

    /// Put focus and the cursor back where the dictation started, before the paste.
    /// The cursor is only moved when the text before that point is unchanged, so the
    /// text never lands at a stale offset.
    @discardableResult
    static func restoreCaret(_ field: FocusedField) -> CaretRestore {
        guard let range = field.range, AXIsProcessTrusted() else { return .unknown }
        let element = field.element
        AXUIElementSetMessagingTimeout(element, 0.25)
        // Apps rebuild their elements (Electron whenever it is reactivated), so a field that no longer
        // answers may well be the one that has focus now, under a new handle.
        guard let value: String = copy(element, kAXValueAttribute) else { return refind(field) }
        func focusedHere() -> Bool {
            focusedElement(ofApp: field.bundleId).map { CFEqual($0, element) } ?? false
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
            // Coming back to a tab can give the same field a second handle: the text around the
            // cursor says so. Being merely in the same window does not: that may be another field.
            guard back else { return recognise(field)?.caret == nil ? .elsewhere : refind(field) }
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

    private static func isTextField(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        return selectedRange(element) != nil
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

    private static func windowTitle(ofApp bundleId: String) -> String? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let window: AXUIElement = copy(element, kAXFocusedWindowAttribute) else { return nil }
        let title: String? = copy(window, kAXTitleAttribute)
        return title.map { String($0.prefix(200)) }
    }
}

import AppKit

// Delivery.swift - where a finished dictation goes: the text the target receives, the checks
// that decide whether it may be pasted, and the paste itself. No UI and no history here: the
// controller turns the outcome into the pill, the hint and History's "inserted" flag.
//
// The place of the first cursor is where the text goes. When the user is not there yet (another
// app, another tab), the text waits for them instead of being dropped or following them elsewhere.

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
    /// Another app stayed in front for the whole wait: nothing was pasted.
    case appChanged
    /// The user did not come back to the starting field during the wait: nothing was pasted.
    case fieldLost
    /// A new dictation or paste took over: nothing was pasted.
    case superseded
}

enum DeliveryWait: Equatable {
    case app
    case field
}

enum Delivery {
    /// How long finished text waits for the user to come back.
    static var waitLimit: TimeInterval = 180
    private static let tick: TimeInterval = 0.3
    /// A reactivated app needs a moment to give the keyboard back to its field.
    private static let settle: TimeInterval = 0.25

    private final class Waiting {
        let finish: (DeliveryOutcome) -> Void
        var timer: Timer?
        var wasFrontmost: Bool
        var reason: DeliveryWait
        var checking = false
        init(reason: DeliveryWait, wasFrontmost: Bool, finish: @escaping (DeliveryOutcome) -> Void) {
            self.reason = reason; self.wasFrontmost = wasFrontmost; self.finish = finish
        }
    }
    private static var waiting: Waiting?

    /// The text as the target should receive it. A terminal gets one line without control
    /// characters, which reduces accidental command execution; elsewhere a list never starts
    /// right after the text the cursor follows.
    static func prepare(_ text: String, appBundleId: String, field: FocusedField?) -> String {
        TerminalGuard.isTerminal(appBundleId) ? TerminalGuard.safeText(text, bundleId: appBundleId)
            : Inserter.separatingList(text, before: field?.bundleId == appBundleId && field?.range != nil ? field?.context.before : nil)
    }

    private static func isFrontmost(_ appBundleId: String) -> Bool {
        PasteTarget.matches(expected: appBundleId, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    /// Put the cursor back. Nil when it is there, or the reason it is not.
    private static func bringBack(appBundleId: String, field: FocusedField?) -> DeliveryWait? {
        guard isFrontmost(appBundleId) else { return .app }
        guard let field, field.bundleId == appBundleId else { return nil }
        switch FieldContextReader.restoreCaret(field) {
        case .elsewhere, .gone: return .field
        case .restored, .sameField, .unknown: return nil
        }
    }

    private static func paste(_ text: String, appBundleId: String, completion: @escaping (DeliveryOutcome) -> Void) {
        let rich = Inserter.richListApps.contains(appBundleId) ? Inserter.listHTML(for: text) : nil
        Inserter.shared.insert(text, richHTML: rich) { result, _ in completion(.pasted(result)) }
    }

    /// Whatever was waiting gives way to something newer.
    static func cancelWaiting() {
        guard let old = waiting else { return }
        waiting = nil
        old.timer?.invalidate()
        old.finish(.superseded)
    }

    /// Paste `text` (already prepared) where the dictation started: now, or as soon as the user is back there.
    static func deliver(_ text: String, appBundleId: String, field: FocusedField?,
                        onWaiting: @escaping (DeliveryWait) -> Void = { _ in },
                        completion: @escaping (DeliveryOutcome) -> Void) {
        cancelWaiting()
        guard let reason = bringBack(appBundleId: appBundleId, field: field) else {
            return paste(text, appBundleId: appBundleId, completion: completion)
        }
        DiagnosticsLog.write("delivery.wait", ["code": reason == .app ? "app" : "field"])
        onWaiting(reason)
        let wait = Waiting(reason: reason, wasFrontmost: isFrontmost(appBundleId), finish: completion)
        waiting = wait
        let started = Date()
        let timer = Timer(timeInterval: tick, repeats: true) { _ in
            guard waiting === wait, !wait.checking else { return }
            let front = isFrontmost(appBundleId)
            let returned = front && !wait.wasFrontmost
            wait.wasFrontmost = front
            // While the user works elsewhere in the app, only look: bringing the field back is for
            // the moment they return, or it would keep pulling them away.
            if front, returned || field.map(FieldContextReader.isBackAtField) ?? true {
                wait.checking = true
                DispatchQueue.main.asyncAfter(deadline: .now() + (returned ? settle : 0)) {
                    wait.checking = false
                    guard waiting === wait else { return }
                    if let still = bringBack(appBundleId: appBundleId, field: field) {
                        wait.reason = still
                        return
                    }
                    waiting = nil
                    wait.timer?.invalidate()
                    paste(text, appBundleId: appBundleId, completion: wait.finish)
                }
                return
            }
            wait.reason = front ? .field : .app
            if Date().timeIntervalSince(started) >= waitLimit {
                waiting = nil
                wait.timer?.invalidate()
                DiagnosticsLog.write("delivery.gave-up", ["code": wait.reason == .app ? "app" : "field"])
                wait.finish(wait.reason == .app ? .appChanged : .fieldLost)
            }
        }
        wait.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

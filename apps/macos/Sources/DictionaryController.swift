import Foundation

// Legacy controller port. It now observes whole output revisions for confirmation only.
// Vocabulary entry points return empty data and never persist model guesses.

final class DictionaryController {
    private let settings: Settings
    private let watcher = EditWatcher()
    private let setHint: (String) -> Void
    private let changed: () -> Void

    init(settings: Settings, setHint: @escaping (String) -> Void, changed: @escaping () -> Void) {
        self.settings = settings
        self.setHint = setHint
        self.changed = changed

    }

    /// The entries sent with a dictation ("word" or "heard=word").
    var serviceEntries: [String] { [] }

    /// Entries marked 「不发给模型」: the service only fixes their heard-as spellings locally.
    var localEntries: [String] { [] }

    /// A paste landed in `field`: watch it for a fix of `text`.
    func pasted(_ text: String, into field: FocusedField, onRevision: ((String) -> Void)? = nil) {
        guard settings.autoLearn, let onRevision else { return }
        watcher.watch(field: field, inserted: text, onRevision: onRevision)
    }

    /// The next dictation starts: the user is usually done fixing the last one.
    func dictationStarting() { watcher.check() }

    /// The user switched to `bundleId`: leaving the app a dictation went into ends the watch.
    func appActivated(_ bundleId: String?) {
        if let watched = watcher.watchedBundleId, bundleId != watched { watcher.check() }
    }

    /// Retired vocabulary callback; kept for response compatibility.
    func received(_ candidates: [SuggestionCandidate]) { /* Model guesses are never learned. */ }

    /// A word the user selected in History: added by hand. One already in the dictionary is
    /// left as it is, with what it is often heard as.
    func addFromHistory(_ word: String) {}

}

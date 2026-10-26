import Foundation

// DictionaryController.swift - everything that adds words to the dictionary as one piece:
// learning a word the user corrects after a paste (EditWatcher), suggestions from what the
// cleanup model corrected (WordSuggestions), a word picked in History, and the "已加入词典 ·
// 撤销" toast. The words themselves live in Settings and go with every dictation.

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
    var serviceEntries: [String] { settings.words.filter { $0.localOnly != true && PreferenceExamples.shared.references($0) }.map(\.word) }

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

    /// The service has already filtered these pairs; learn them without a confirmation step.
    func received(_ candidates: [SuggestionCandidate]) { /* Model guesses are never learned. */ }

    /// A word the user selected in History: added by hand. One already in the dictionary is
    /// left as it is, with what it is often heard as.
    func addFromHistory(_ word: String) {
        let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.words.contains(where: { $0.word.caseInsensitiveCompare(word) == .orderedSame }) {
            setHint(L10n.text("「{0}」已在词典里", word))
            return
        }
        if settings.addWord(word, source: .manual) { setHint(L10n.text("已把「") + word + L10n.text("」加入词典")) }
        changed()
    }

}

import Foundation

// DictionaryController.swift - everything that adds words to the dictionary as one piece:
// learning a word the user corrects after a paste (EditWatcher), suggestions from what the
// cleanup model corrected (WordSuggestions), a word picked in History, and the "已加入词典 ·
// 撤销" toast. The words themselves live in Settings and go with every dictation.

final class DictionaryController {
    private let settings: Settings
    private let watcher = EditWatcher()
    private let toast = LearnedToast()
    private let setHint: (String) -> Void
    private let changed: () -> Void

    init(settings: Settings, setHint: @escaping (String) -> Void, changed: @escaping () -> Void) {
        self.settings = settings
        self.setHint = setHint
        self.changed = changed
        watcher.onLearn = { [weak self] word in self?.learned(word) }
    }

    /// The entries sent with a dictation ("word" or "heard=word").
    var serviceEntries: [String] { settings.hostDictionary }

    /// Entries marked 「不发给模型」: the service only fixes their heard-as spellings locally.
    var localEntries: [String] { settings.localDictionary }

    /// A paste landed in `field`: watch it for a fix of `text`.
    func pasted(_ text: String, into field: FocusedField) {
        guard settings.autoLearn else { return }
        watcher.watch(field: field, inserted: text)
    }

    /// The next dictation starts: the user is usually done fixing the last one.
    func dictationStarting() { watcher.check() }

    /// The user switched to `bundleId`: leaving the app a dictation went into ends the watch.
    func appActivated(_ bundleId: String?) {
        if let watched = watcher.watchedBundleId, bundleId != watched { watcher.check() }
    }

    /// Terms the cleanup model corrected become suggestions on the Dictionary page.
    func received(_ candidates: [SuggestionCandidate]) {
        guard settings.autoLearn else { return }
        for pair in candidates.prefix(8) where pair.isValid {
            settings.suggest(word: pair.word, heardAs: pair.heardAs)
        }
    }

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

    private func learned(_ word: String) {
        guard settings.autoLearn, settings.addWord(word, source: .auto),
              let id = settings.words.first(where: { $0.word == word })?.id else { return }
        setHint(L10n.text("已把「") + word + L10n.text("」加入词典"))
        toast.show(word: word) { [weak self] in
            guard let self else { return }
            self.settings.removeWord(id: id)
            self.setHint(L10n.text("已从词典删除「{0}」", word))
            self.changed()
        }
        changed()
    }
}

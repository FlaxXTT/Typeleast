import Foundation

struct VocabularyArchive: Codable {
    var version = 1
    var words: [LocalWord] = []
    var suggestions: [WordSuggestion] = []
    var dismissed: [String] = []
}

enum VocabularyStorage {
    static let key = "voice.vocabulary.sealed.v1"
    static func read(_ defaults: UserDefaults) -> VocabularyArchive? {
        guard let stored = defaults.data(forKey: key), let key = HistorySeal.key(create: false),
              let plain = HistorySeal.open(stored, key: key), let archive = try? JSONDecoder().decode(VocabularyArchive.self, from: plain), archive.version == 1 else { return nil }
        return archive
    }
    static func write(_ archive: VocabularyArchive, to defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: key) != nil, read(defaults) == nil { return false }
        guard let key = HistorySeal.key(create: true), let plain = try? JSONEncoder().encode(archive), let sealed = HistorySeal.seal(plain, key: key) else { return false }
        defaults.set(sealed, forKey: Self.key)
        // Remove only obsolete plain storage, after the encrypted replacement exists.
        for legacy in ["voice.words.v2","voice.dictionary","voice.wordSuggestions","voice.dismissedSuggestions"] { defaults.removeObject(forKey: legacy) }
        return true
    }
}

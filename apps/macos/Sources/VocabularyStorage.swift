import Foundation

struct VocabularyArchive: Codable {
    var version = 1
    var words: [LocalWord] = []
    var suggestions: [WordSuggestion] = []
    var dismissed: [String] = []
}

enum VocabularyStorage {
    static func purge(_ defaults: UserDefaults) {
        for key in [Self.key,"voice.words.v2","voice.dictionary","voice.wordSuggestions","voice.dismissedSuggestions"] { defaults.removeObject(forKey:key) }
        defaults.set(true, forKey:"voice.vocabularyRemoved.v1")
    }
    static let key = "voice.vocabulary.sealed.v1"
}

import Foundation
import AppKit

func personalizationPolicyTests() {
    let suite = "typeleast.tests.policy." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); KeychainStore.stub = [:]; HistorySeal.reset() }
    KeychainStore.stub = [:]; HistorySeal.reset()
    let settings = Settings(defaults: defaults)
    settings.addWord("Acme", source: .manual)
    settings.addWord("Kubernetes", heardAs: "库伯内蒂斯", source: .manual)
    let dictionary = DictionaryController(settings: settings, setHint: { _ in }, changed: {})
    checkEq("every word goes with a dictation", Set(dictionary.serviceEntries), ["Acme", "库伯内蒂斯=Kubernetes"])
    let rules = dictionary.policy()["rules"] as! [[String: Any]]
    checkEq("a heard-as spelling is the only replacement rule", rules.map { $0["heard"] as! String }, ["库伯内蒂斯"])
    let wire = dictionary.policy(disabled: true)
    let payload = ServiceClient.dictateBody(wav: Data([1,2]), dictionary: ["Acme"], personalization: wire)
    let metadata = try! JSONSerialization.jsonObject(with: payload.body.prefix(payload.dictionaryBytes)) as! [Any]
    checkEq("one policy block travels in local metadata", metadata.compactMap { $0 as? [String:Any] }.filter { $0["personalization"] != nil }.count, 1)
    let large = ServiceClient.dictateBody(wav: Data([1,2]), dictionary: Array(repeating: String(repeating: "字", count: 120), count: 2000), personalization: wire)
    check("large personalization cannot break audio delivery", large.dictionaryBytes < 256 * 1024 && large.body.suffix(2) == Data([1,2]))
    let small = try! JSONSerialization.jsonObject(with: large.body.prefix(large.dictionaryBytes)) as! [[String:Any]]
    checkEq("oversized metadata safely disables personalization", (small[0]["personalization"] as? [String:Any])?["disabled"] as? Bool, true)
    let vocabularyDefaults = UserDefaults(suiteName: suite + ".vocabulary")!
    defer { vocabularyDefaults.removePersistentDomain(forName: suite + ".vocabulary") }
    let legacyWords = [LocalWord(id: "legacy-vocabulary", word: "PrivateFixtureTerm", source: .auto, addedAt: Date())]
    vocabularyDefaults.set(try! JSONEncoder().encode(legacyWords), forKey: "voice.words.v2")
    let wordSettings = Settings(defaults: vocabularyDefaults)
    checkEq("legacy vocabulary survives encrypted migration", wordSettings.words, legacyWords)
    check("plain vocabulary removed only after encrypted migration", vocabularyDefaults.data(forKey: "voice.words.v2") == nil && vocabularyDefaults.data(forKey: VocabularyStorage.key) != nil)
    check("vocabulary ciphertext does not contain its plain term", vocabularyDefaults.data(forKey: VocabularyStorage.key)!.range(of: Data("PrivateFixtureTerm".utf8)) == nil)
    vocabularyDefaults.set(Data("unreadable fixture".utf8), forKey: VocabularyStorage.key)
    wordSettings.words = []
    check("unreadable vocabulary is not overwritten", wordSettings.vocabularyProblem != nil && vocabularyDefaults.data(forKey: VocabularyStorage.key) == Data("unreadable fixture".utf8))
}


import Foundation
import AppKit
import SwiftUI

func personalizationPolicyTests() {
    let suite = "typeleast.tests.policy." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite); KeychainStore.stub = [:]; HistorySeal.reset() }
    KeychainStore.stub = [:]; HistorySeal.reset()
    let preferences = PreferenceExamples(defaults: defaults)
    let path = ProcessInfo.processInfo.environment["TYPELEAST_DICTIONARY_CONTRACT"]!
    let fixture = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    for item in fixture["vocabularyCases"] as! [[String: Any]] {
        let word = LocalWord(id: item["id"] as! String, word: "Acme", heardAs: item["heard"] as? String, source: LocalWord.Source(rawValue: item["source"] as! String)!, addedAt: Date())
        checkEq("shared reference authority: " + word.id, preferences.references(word), item["reference"] as! Bool)
        checkEq("shared replacement authority: " + word.id, preferences.replaces(word), item["replacement"] as! Bool)
    }
    var rule = LocalWord(id: "fake-rule", word: "Acme", heardAs: "Acmee", source: .manual, addedAt: Date())
    check("old manual mapping is not enabled", !preferences.replaces(rule))
    preferences.setRule(rule, true)
    check("explicit enable grants a rule", preferences.replaces(rule))
    preferences.exclude("ＡＣＭＥ")
    check("fullwidth exclusion pauses rule", !preferences.replaces(rule))
    preferences.restore("ＡＣＭＥ")
    check("restore preserves previous approval", preferences.replaces(rule))
    rule.heardAs = "Another"
    check("changed rule requires fresh approval", !preferences.replaces(rule))
    let automatic = LocalWord(id: "fake-auto", word: "Acme", source: .auto, addedAt: Date())
    check("old automatic terms remain disabled", !preferences.references(automatic))
    preferences.setReference(automatic.id, true)
    check("user may confirm old vocabulary", preferences.references(automatic))
    preferences.exclude("Acme")
    check("global exclusion pauses personal term", !preferences.references(automatic))
    let reload = PreferenceExamples(defaults: defaults)
    check("encrypted overrides survive reload", reload.isExcluded("ACME") && reload.wordStates[automatic.id] == true)
    let wire = reload.wirePolicy(words: [rule], disabled: true)
    let payload = ServiceClient.dictateBody(wav: Data([1,2]), dictionary: ["Acme"], personalization: wire)
    let metadata = try! JSONSerialization.jsonObject(with: payload.body.prefix(payload.dictionaryBytes)) as! [Any]
    checkEq("one policy block travels in local metadata", metadata.compactMap { $0 as? [String:Any] }.filter { $0["personalization"] != nil }.count, 1)
    let large = ServiceClient.dictateBody(wav: Data([1,2]), dictionary: Array(repeating: String(repeating: "字", count: 120), count: 2000), personalization: wire)
    check("large personalization cannot break audio delivery", large.dictionaryBytes < 256 * 1024 && large.body.suffix(2) == Data([1,2]))
    let small = try! JSONSerialization.jsonObject(with: large.body.prefix(large.dictionaryBytes)) as! [[String:Any]]
    checkEq("oversized metadata safely disables personalization", (small[0]["personalization"] as? [String:Any])?["disabled"] as? Bool, true)
    var legacy = PreferenceExample(historyId: "legacy-fixture", raw: "请发报告", aiText: "发送报告。", correctedText: "请发报告。")
    legacy.confirmed = true
    let key = HistorySeal.key(create: true)!
    defaults.set(HistorySeal.seal(try! JSONEncoder().encode([legacy]), key: key)!, forKey: "voice.preferenceExamples.sealed.v1")
    let upgraded = PreferenceExamples(defaults: defaults)
    checkEq("legacy encrypted example array remains readable", upgraded.entries.count, 1)
    upgraded.exclude("Acme")
    check("legacy records survive saving the new archive", PreferenceExamples(defaults: defaults).entries.first?.historyId == legacy.historyId)
    defaults.set(Data("broken fixture".utf8), forKey: "voice.preferenceExamples.sealed.v1")
    let unavailable = PreferenceExamples(defaults: defaults)
    unavailable.setRule(rule, true)
    check("failed permission save cannot enable a rule", !unavailable.replaces(rule) && defaults.data(forKey: "voice.preferenceExamples.sealed.v1") == Data("broken fixture".utf8))
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
    defaults.set("background", forKey: "voice.explanationMarkers.v1")
    let settings = Settings(defaults: defaults)
    checkEq("old marker selection migrates to short form", settings.explanationMarkers, "note")
    settings.explanationMarkers = ""
    checkEq("marker opt-out is retained", Settings(defaults: defaults).explanationMarkers, "")
}

func renderPersonalizationFixtures(output: String) throws {
    guard output.hasPrefix("/private/tmp/"), let home = ProcessInfo.processInfo.environment["TYPELEAST_HOME"], home.hasPrefix("/private/tmp/"), Bundle.main.bundleIdentifier != "com.dsh.voice" else { exit(2) }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "voice.preferenceExamples.sealed.v1")
    let app = NSApplication.shared
    let prefs = PreferenceExamples.shared
    let term = LocalWord(id: "fixture-term", word: "Acme", source: .manual, addedAt: Date())
    let rule = LocalWord(id: "fixture-rule", word: "Acme", heardAs: "Acmee", source: .manual, addedAt: Date(), localOnly: true)
    let old = LocalWord(id: "fixture-old", word: "LegacyTerm", source: .auto, addedAt: Date())
    Settings.shared.words = [term,rule,old]; Settings.shared.explanationMarkers = "note"
    prefs.prepare(historyId: "fixture", raw: "请把报告发给产品团队", aiText: "请将报告发送给产品团队。")
    prefs.setRule(rule, true); prefs.exclude("LegacyTerm")
    for language in ["zh-Hans","en"] {
        L10n.language = language
        for dark in [false,true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for tab in 0...2 {
                let model = AppModel()
                let view = NSHostingView(rootView: DictionaryPage(initialTab: tab).background(Theme.window).environmentObject(model).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 720,height: 780),styleMask: [.titled],backing: .buffered,defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view;view.frame = NSRect(x: 0,y: 0,width: 720,height: 780)
                window.layoutIfNeeded();RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds,to: bitmap)
                    try bitmap.representation(using: .png,properties: [:])?.write(to: URL(fileURLWithPath: output+"/preferences-\(tab)-\(language)-\(dark ? "dark" : "light").png"))
                }
                window.orderOut(nil)
            }
        }
    }
    defaults.removeObject(forKey: "voice.preferenceExamples.sealed.v1")
    defaults.removeObject(forKey: "voice.words.v2")
    defaults.removeObject(forKey: VocabularyStorage.key)
}

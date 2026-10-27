import Foundation
import AppKit
import SwiftUI

func personalizationPolicyTests() {
    let suite="typeleast.tests.retired."+UUID().uuidString
    let defaults=UserDefaults(suiteName:suite)!
    defer {defaults.removePersistentDomain(forName:suite);KeychainStore.stub=[:];HistorySeal.reset()}
    KeychainStore.stub=[:];HistorySeal.reset()
    var example=PreferenceExample(historyId:"fictional",raw:"请把报告发给团队",aiText:"请将报告发送给团队。",correctedText:"请发报告给团队。")
    example.confirmed=true
    let key=HistorySeal.key(create:true)!
    let old=PersonalizationArchive(formatVersion:2,entries:[example],excluded:["Legacy"],wordStates:["old":true],ruleStates:["old-rule":true])
    defaults.set(HistorySeal.seal(try! JSONEncoder().encode(old),key:key)!,forKey:"voice.preferenceExamples.sealed.v1")
    defaults.set(Data("retired vocabulary".utf8),forKey:VocabularyStorage.key)
    defaults.set(["Legacy"],forKey:"voice.dictionary")
    let preferences=PreferenceExamples(defaults:defaults)
    checkEq("retirement preserves confirmed expressions",preferences.entries.count,1)
    check("retirement clears vocabulary payload and legacy words",defaults.object(forKey:VocabularyStorage.key)==nil && defaults.object(forKey:"voice.dictionary")==nil)
    let plain=HistorySeal.open(defaults.data(forKey:"voice.preferenceExamples.sealed.v1")!,key:key)!
    let archive=try! JSONDecoder().decode(PersonalizationArchive.self,from:plain)
    check("mixed archive retains examples without word permissions",archive.formatVersion==3 && archive.entries.count==1 && archive.excluded.isEmpty && archive.ruleStates.isEmpty && archive.wordStates.isEmpty)
    checkEq("retirement survives another start",PreferenceExamples(defaults:defaults).entries.count,1)
    let settings=Settings(defaults:defaults)
    check("retired words cannot be restored by an old setter",!settings.addWord("Legacy",source:.manual) && settings.words.isEmpty)
    defaults.set(Data("unreadable".utf8),forKey:"voice.preferenceExamples.sealed.v1")
    defaults.set(Data("retain until examples can be read".utf8),forKey:VocabularyStorage.key)
    _=PreferenceExamples(defaults:defaults)
    check("unreadable examples stop destructive mixed cleanup",defaults.data(forKey:VocabularyStorage.key) != nil)
    let policy=preferences.wirePolicy(disabled:true)
    check("wire policy has no word permissions",policy["excluded"]==nil && policy["rules"]==nil && policy["disabled"] as? Bool==true)
    let response=try! JSONDecoder().decode(DictateResponse.self,from:Data("{\"text\":\"\",\"raw\":\"原文\",\"clarification\":{\"question\":\"检查\",\"evidence\":\"\",\"kind\":\"quality\",\"candidate\":\"草稿\",\"reason\":\"incomplete-output\"}}".utf8))
    check("quality hold preserves editable draft with no insertable text",response.text.isEmpty && response.clarification?.candidate=="草稿")
}

func renderPersonalizationFixtures(output: String) throws {
    guard output.hasPrefix("/private/tmp/"), let home = ProcessInfo.processInfo.environment["TYPELEAST_HOME"], home.hasPrefix("/private/tmp/"), Bundle.main.bundleIdentifier != "com.dsh.voice" else { exit(2) }
    try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "voice.preferenceExamples.sealed.v1")
    let app = NSApplication.shared
    let prefs = PreferenceExamples.shared
    Settings.shared.explanationMarkers = "note"
    prefs.prepare(historyId: "fixture", raw: "请把报告发给产品团队", aiText: "请将报告发送给产品团队。")
    for language in ["zh-Hans","en"] {
        L10n.language = language
        for dark in [false,true] {
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for tab in 0...0 {
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

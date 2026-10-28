import Foundation
import Combine

/// Actual dictation and its explicit human revision. Never reconstructed from old vocabulary.
struct PreferenceExample: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    let historyId: String
    let raw: String
    let aiText: String
    var correctedText: String
    var createdAt = Date()
    var confirmed = false
    var enabled = true
    var valid: Bool {
        !id.isEmpty && id.count <= 64 && !historyId.isEmpty && [raw, aiText, correctedText].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4000 }
            && correctedText != aiText
    }
    var wire: [String: Any] { ["id": id, "raw": raw, "aiText": aiText, "correctedText": correctedText, "confirmed": confirmed, "enabled": enabled] }
}

/// Encrypted with the existing history key; pending observations live in memory until confirmed.
struct PersonalizationArchive: Codable {
    var formatVersion = 2
    var entries: [PreferenceExample]
    var excluded: [String] = []
    var wordStates: [String: Bool] = [:]
    var ruleStates: [String: Bool] = [:]
}

final class PreferenceExamples: ObservableObject {
    static let shared = PreferenceExamples()
    @Published private(set) var entries: [PreferenceExample] = []
    @Published private(set) var pending: [PreferenceExample] = []
    @Published private(set) var problem: String?
    @Published private(set) var excluded: [String] = []
    @Published private(set) var wordStates: [String: Bool] = [:]
    @Published private(set) var ruleStates: [String: Bool] = [:]
    private let defaults: UserDefaults
    private let storageKey = "voice.preferenceExamples.sealed.v1"
    private var locked = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let stored = defaults.data(forKey: storageKey) else { return }
        guard let key = HistorySeal.key(create: false), let plain = HistorySeal.open(stored, key: key) else {
            locked = true; problem = "preferences-unavailable"; return
        }
        let archive = (try? JSONDecoder().decode(PersonalizationArchive.self, from: plain))
            ?? (try? JSONDecoder().decode([PreferenceExample].self, from: plain)).map { PersonalizationArchive(entries: $0) }
        guard let archive, archive.formatVersion == 2, archive.entries.count <= 100, archive.entries.allSatisfy({ $0.valid && $0.confirmed }), archive.excluded.count <= 512, archive.wordStates.count <= 2000, archive.ruleStates.count <= 2000 else {
            locked = true; problem = "preferences-unavailable"; return
        }
        entries = archive.entries; excluded = archive.excluded; wordStates = archive.wordStates; ruleStates = archive.ruleStates
    }
    func prepare(historyId: String, raw: String, aiText: String) {
        guard !raw.isEmpty, !aiText.isEmpty, raw.count <= 4000, aiText.count <= 4000 else { problem = "preferences-limit"; return }
        pending.removeAll { $0.historyId == historyId }
        pending.insert(PreferenceExample(historyId: historyId, raw: raw, aiText: aiText, correctedText: aiText), at: 0)
        pending = Array(pending.prefix(5))
    }
    func offer(historyId: String, raw: String, aiText: String, corrected: String) {
        let item = PreferenceExample(historyId: historyId, raw: raw, aiText: aiText, correctedText: corrected)
        guard item.valid, !entries.contains(where: { $0.historyId == historyId && $0.correctedText == corrected }) else { return }
        pending.removeAll { $0.historyId == historyId }
        pending.insert(item, at: 0)
        pending = Array(pending.prefix(5))
    }
    @discardableResult func confirm(_ candidate: PreferenceExample) -> Bool {
        guard candidate.valid, entries.count < 100 || entries.contains(where: { $0.id == candidate.id }) else { problem = "preferences-limit"; return false }
        var item = candidate; item.confirmed = true
        guard persist([item] + entries.filter { $0.id != item.id }) else { return false }
        pending.removeAll { $0.id == item.id || $0.historyId == item.historyId }
        return true
    }
    func stageRevision(_ id: String, _ text: String) { guard text.count <= 4000, let index = pending.firstIndex(where: { $0.id == id }) else { return }; pending[index].correctedText = text }
    func clearPending() { pending.removeAll() }
    func dismiss(_ id: String) { pending.removeAll { $0.id == id } }
    func setEnabled(_ id: String, _ value: Bool) {
        var next = entries
        guard let i = next.firstIndex(where: { $0.id == id }) else { return }
        next[i].enabled = value; _ = persist(next)
    }
    func remove(_ id: String) { _ = persist(entries.filter { $0.id != id }) }
    var wireExamples: [[String: Any]] { Array(entries.filter { $0.confirmed && $0.enabled }.prefix(20)).map(\.wire) }
    func isExcluded(_ term: String) -> Bool { let key = term.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); return excluded.contains { $0.precomposedStringWithCompatibilityMapping.lowercased() == key } }
    func references(_ word: LocalWord) -> Bool { word.localOnly != true && !isExcluded(word.word) && (wordStates[word.id] ?? (word.source == .manual && (word.heardAs?.isEmpty ?? true))) }
    func replaces(_ word: LocalWord) -> Bool { !isExcluded(word.word) && !isExcluded(word.replacementHeard ?? "") && word.replacementHeard != nil && ruleStates[word.approvalKey] == true }
    func setReference(_ id: String, _ value: Bool) { let old = wordStates; wordStates[id] = value; if !persist(entries) { wordStates = old } }
    func setRule(_ word: LocalWord, _ value: Bool) { let old = ruleStates; ruleStates = ruleStates.filter { !$0.key.hasPrefix(word.id + "|") }; ruleStates[word.approvalKey] = value; if !persist(entries) { ruleStates = old } }
    func exclude(_ term: String) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 120, excluded.count < 512, !isExcluded(term) else { return }
        let old = excluded; excluded.append(term); if !persist(entries) { excluded = old }
    }
    func restore(_ term: String) { let old = excluded; excluded.removeAll { $0.precomposedStringWithCompatibilityMapping.lowercased() == term.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCompatibilityMapping.lowercased() }; if !persist(entries) { excluded = old } }
    func wirePolicy(words: [LocalWord], disabled: Bool = false) -> [String: Any] {
        let rules: [[String: Any]] = words.filter { replaces($0) && ($0.replacementHeard != nil) }.prefix(128).map {
            ["id": $0.id, "heard": $0.replacementHeard!, "word": $0.word, "enabled": true]
        }
        return ["version": 1, "disabled": disabled, "excluded": Array(excluded.prefix(512)), "rules": rules]
    }
    private func persist(_ next: [PreferenceExample]) -> Bool {
        guard excluded.count <= 512, wordStates.count <= 2000, ruleStates.count <= 2000 else { problem = "preferences-limit"; return false }
        guard !locked, let key = HistorySeal.key(create: true), let plain = try? JSONEncoder().encode(PersonalizationArchive(entries: next, excluded: excluded, wordStates: wordStates, ruleStates: ruleStates)),
              let sealed = HistorySeal.seal(plain, key: key) else { problem = "preferences-unavailable"; return false }
        defaults.set(sealed, forKey: storageKey)
        entries = next; problem = nil; return true
    }
}

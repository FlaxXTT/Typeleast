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
final class PreferenceExamples: ObservableObject {
    static let shared = PreferenceExamples()
    @Published private(set) var entries: [PreferenceExample] = []
    @Published private(set) var pending: [PreferenceExample] = []
    @Published private(set) var problem: String?
    private let defaults: UserDefaults
    private let storageKey = "voice.preferenceExamples.sealed.v1"
    private var locked = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let stored = defaults.data(forKey: storageKey) else { return }
        guard let key = HistorySeal.key(create: false), let plain = HistorySeal.open(stored, key: key),
              let decoded = try? JSONDecoder().decode([PreferenceExample].self, from: plain),
              decoded.count <= 100, decoded.allSatisfy({ $0.valid && $0.confirmed }) else {
            locked = true; problem = "preferences-unavailable"; return
        }
        entries = decoded
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
    func clearPending() { pending.removeAll() }
    func dismiss(_ id: String) { pending.removeAll { $0.id == id } }
    func setEnabled(_ id: String, _ value: Bool) {
        var next = entries
        guard let i = next.firstIndex(where: { $0.id == id }) else { return }
        next[i].enabled = value; _ = persist(next)
    }
    func remove(_ id: String) { _ = persist(entries.filter { $0.id != id }) }
    var wireExamples: [[String: Any]] { Array(entries.filter { $0.confirmed && $0.enabled }.prefix(20)).map(\.wire) }
    private func persist(_ next: [PreferenceExample]) -> Bool {
        guard !locked, let key = HistorySeal.key(create: true), let plain = try? JSONEncoder().encode(next),
              let sealed = HistorySeal.seal(plain, key: key) else { problem = "preferences-unavailable"; return false }
        defaults.set(sealed, forKey: storageKey)
        entries = next; problem = nil; return true
    }
}

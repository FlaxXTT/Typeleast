import Foundation

// History.swift - local (UserDefaults) history of dictations, kept for the user's
// chosen retention (Typeless: Forever / 1 year / 1 month / 1 week / 24 hours / Never).

struct LocalHistoryEntry: Codable, Equatable, Identifiable {
    var id: String
    var ts: Date
    var app: String?
    var language: String
    var strength: String
    var raw: String
    var text: String
    var fallback: Bool
    var fallbackReason: String?
    var model: String?
    var msTotal: Double?
    /// Kept only when "retry same audio" (keepAudio24h) is enabled.
    var audioPath: String?
    var inserted: Bool
    /// Length of the recording, for the Home statistics. Absent on old entries.
    var seconds: Double?
    /// 翻译模式: the target language, so a retry translates again. Absent otherwise.
    var translated: String? = nil

    var title: String {
        let t = text.isEmpty ? raw : text
        let flat = t.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= 42 { return flat.isEmpty ? L10n.text("(空)") : flat }
        return String(flat.prefix(42)) + "…"
    }

    var displayText: String { text.isEmpty ? raw : text }
}

/// Numbers shown on the Home page.
struct DictationStats: Equatable {
    var dictations = 0
    /// CJK characters plus latin words: the unit people mean by "字".
    var words = 0
    var speakingSeconds: Double = 0
    /// Typing the same text at 60 字/min (CJK) or 40 words/min, minus the time spent speaking.
    var savedSeconds: Double = 0

    /// 字 per minute of speech.
    var wordsPerMinute: Int {
        speakingSeconds > 1 ? Int((Double(words) / (speakingSeconds / 60)).rounded()) : 0
    }

    static func countWords(_ text: String) -> (cjk: Int, latin: Int) {
        var cjk = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF: cjk += 1
            default: break
            }
        }
        let latin = text.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).count
        return (cjk, latin)
    }

    static func compute(_ entries: [LocalHistoryEntry]) -> DictationStats {
        var stats = DictationStats()
        for entry in entries where !entry.displayText.isEmpty {
            let counts = countWords(entry.displayText)
            stats.dictations += 1
            stats.words += counts.cjk + counts.latin
            let speaking = entry.seconds ?? Double(counts.cjk) / 3.5 + Double(counts.latin) / 2.5
            stats.speakingSeconds += speaking
            let typing = Double(counts.cjk) / 60 * 60 + Double(counts.latin) / 40 * 60
            stats.savedSeconds += max(0, typing - speaking)
        }
        return stats
    }
}

final class HistoryStore {
    static let shared = HistoryStore()
    static let didChange = Notification.Name("DshVoiceHistoryDidChange")
    /// Hard cap so UserDefaults stays small whatever the retention says.
    static let limit = 2000

    private let key = "voice.history.v1"
    private let d = UserDefaults.standard
    private(set) var entries: [LocalHistoryEntry] = []

    init() { load() }

    func load() {
        guard let data = d.data(forKey: key) else { entries = []; return }
        entries = (try? JSONDecoder().decode([LocalHistoryEntry].self, from: data)) ?? []
    }

    func save() {
        if let data = try? JSONEncoder().encode(entries) { d.set(data, forKey: key) }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: HistoryStore.didChange, object: nil)
        }
    }

    var stats: DictationStats { DictationStats.compute(entries) }

    var last: LocalHistoryEntry? { entries.first }

    func add(_ e: LocalHistoryEntry) {
        entries.insert(e, at: 0)
        applyRetention(Settings.shared.historyRetention, saving: false)
        if entries.count > HistoryStore.limit {
            for dropped in entries[HistoryStore.limit...] { removeAudio(dropped) }
            entries.removeLast(entries.count - HistoryStore.limit)
        }
        save()
    }

    func update(id: String, mutate: (inout LocalHistoryEntry) -> Void) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[idx]
        mutate(&e)
        entries[idx] = e
        save()
    }

    func remove(id: String) {
        if let e = entries.first(where: { $0.id == id }) { removeAudio(e) }
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        for e in entries { removeAudio(e) }
        entries.removeAll()
        save()
    }

    /// Drop entries older than the retention window. "Never" keeps only the entry
    /// just added, until the next one arrives, so "paste last" still works.
    func applyRetention(_ retention: HistoryRetention, saving: Bool = true) {
        guard let window = retention.seconds else { return }
        let before = entries.count
        if window == 0 {
            for dropped in entries.dropFirst() { removeAudio(dropped) }
            entries = Array(entries.prefix(1))
        } else {
            let cutoff = Date().addingTimeInterval(-window)
            for dropped in entries where dropped.ts < cutoff { removeAudio(dropped) }
            entries.removeAll { $0.ts < cutoff }
        }
        if saving, entries.count != before { save() }
    }

    private func removeAudio(_ e: LocalHistoryEntry) {
        if let p = e.audioPath { try? FileManager.default.removeItem(atPath: p) }
    }

    /// Delete retained temp WAVs older than 24h (and any orphan audio whose entry is gone).
    func pruneAudio(olderThan: TimeInterval = 24 * 3600) {
        let cutoff = Date().addingTimeInterval(-olderThan)
        var changed = false
        for i in entries.indices {
            guard let p = entries[i].audioPath else { continue }
            if entries[i].ts < cutoff || !FileManager.default.fileExists(atPath: p) {
                if FileManager.default.fileExists(atPath: p) { try? FileManager.default.removeItem(atPath: p) }
                entries[i].audioPath = nil
                changed = true
            }
        }
        if changed { save() }
        let tmp = NSTemporaryDirectory()
        if let names = try? FileManager.default.contentsOfDirectory(atPath: tmp) {
            for n in names where n.hasPrefix("dsh-voice-") && n.hasSuffix(".wav") {
                let full = tmp + n
                if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                   let modified = attrs[.modificationDate] as? Date, modified < cutoff {
                    try? FileManager.default.removeItem(atPath: full)
                }
            }
        }
    }

    static func newID() -> String { UUID().uuidString }
}

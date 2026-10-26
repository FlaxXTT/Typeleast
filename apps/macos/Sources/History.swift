import CryptoKit
import Foundation

// History.swift - local (UserDefaults) history of dictations, kept for the user's
// chosen retention (Forever / 1 year / 1 month / 1 week / 24 hours / Never).

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
    var explanationMarkers: String? = nil
    var personalization: PersonalizationTrace? = nil
    var variants: String? = nil

    var title: String {
        let t = text.isEmpty ? raw : text
        let flat = t.replacingOccurrences(of: "\n", with: " ")
        if flat.count <= 42 { return flat.isEmpty ? L10n.text("（空）") : flat }
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

/// History at rest is sealed with AES-GCM. The key is made on first use and kept in
/// this Mac's Keychain. Preferences do not contain plaintext dictation.
/// Retained recordings are sealed the same way.
enum HistorySeal {
    static let account = "history-encryption-key"
    private static var cached: SymmetricKey?

    static func key(create: Bool) -> SymmetricKey? {
        if let cached { return cached }
        if let saved = KeychainStore.read(account: account) {
            guard let data = Data(base64Encoded: saved), data.count == 32 else { return nil }
            cached = SymmetricKey(data: data)
            return cached
        }
        guard create else { return nil }
        // A key still waiting in an old hand-over file is the one the stored history needs:
        // try it again, and never make a new key that could not open that history.
        if KeychainHandoff.pending(account: account) {
            KeychainHandoff.restoreIfPresent()
            if let saved = KeychainStore.read(account: account), let data = Data(base64Encoded: saved), data.count == 32 {
                cached = SymmetricKey(data: data)
                return cached
            }
            return nil
        }
        let fresh = SymmetricKey(size: .bits256)
        guard KeychainStore.create(fresh.withUnsafeBytes { Data($0) }.base64EncodedString(), account: account) else { return nil }
        cached = fresh
        return fresh
    }

    /// Test seam: forget the cached key.
    static func reset() { cached = nil }

    static func seal(_ data: Data, key: SymmetricKey) -> Data? { try? AES.GCM.seal(data, using: key).combined }

    static func open(_ data: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    /// Seal a recording in place ("x.wav" -> "x.wav.sealed"); the plain file is removed.
    /// Returns the new path, or nil when it could not be sealed (the plain file stays).
    static func sealFile(atPath path: String, removePlain: Bool = true) -> String? {
        if path.hasSuffix(".sealed") { return path }
        guard let key = key(create: true), let plain = FileManager.default.contents(atPath: path),
              let sealed = seal(plain, key: key) else { return nil }
        let target = path + ".sealed"
        do {
            try sealed.write(to: URL(fileURLWithPath: target), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
            if removePlain { try FileManager.default.removeItem(atPath: path) }
        } catch { return nil }
        return target
    }

    /// The recording's bytes, opening a sealed file in memory.
    static func readAudio(_ url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        guard url.path.hasSuffix(".sealed") else { return data }
        guard let key = key(create: false), let plain = open(data, key: key) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return plain
    }
}

final class HistoryStore {
    static let shared = HistoryStore()
    static let didChange = Notification.Name("DshVoiceHistoryDidChange")
    /// Hard cap so UserDefaults stays small whatever the retention says.
    static let limit = 2000

    /// Plain JSON written by older versions; read once, then replaced by the sealed copy.
    private let plainKey = "voice.history.v1"
    private let sealedKey = "voice.history.sealed.v1"
    private let d: UserDefaults
    private var locked = false
    private(set) var persistenceProblem: String?
    private(set) var entries: [LocalHistoryEntry] = []

    init(defaults: UserDefaults = .standard) {
        d = defaults
        load()
    }

    func load() {
        if let sealed = d.data(forKey: sealedKey) {
            // Without the key (a Keychain that was reset) the old history cannot be read.
            guard let key = HistorySeal.key(create: false), let data = HistorySeal.open(sealed, key: key),
                  let decoded = try? JSONDecoder().decode([LocalHistoryEntry].self, from: data) else {
                entries = []; locked = true; persistenceProblem = "history-unavailable"; return
            }
            entries = decoded; locked = false; persistenceProblem = nil
            if entries.contains(where: { $0.audioPath.map(Self.ownedPlainAudio) == true }) { persist() }
            return
        }
        guard let data = d.data(forKey: plainKey) else { entries = []; return }
        guard let decoded = try? JSONDecoder().decode([LocalHistoryEntry].self, from: data) else {
            locked = true; persistenceProblem = "history-unavailable"; return
        }
        entries = decoded
        persist()
    }

    /// Only migrate recordings created by this app in its temporary directory.
    private static func ownedPlainAudio(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent() == URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL
            && url.lastPathComponent.hasPrefix("dsh-voice-") && url.pathExtension == "wav"
    }

    /// Stage encrypted audio, then save its paths before removing the original audio.
    /// Failure preserves the old preferences and recordings; no plaintext fallback.
    /// "从不保存": the last entry lives in memory only, for "paste last", and nothing is on disk.
    var keepsNothing: () -> Bool = { Settings.shared.historyRetention.seconds == 0 }

    private func persist() {
        if keepsNothing() {
            d.removeObject(forKey: sealedKey)
            d.removeObject(forKey: plainKey)
            persistenceProblem = nil
            return
        }
        guard !locked, let key = HistorySeal.key(create: true) else {
            persistenceProblem = "history-unavailable"; return
        }
        var next = entries
        var originals: [String] = []
        for i in next.indices {
            guard let path = next[i].audioPath, Self.ownedPlainAudio(path) else { continue }
            if !FileManager.default.fileExists(atPath: path) {
                // Recover after a crash between saving the new paths and removing originals.
                let sealed = path + ".sealed"
                if (try? HistorySeal.readAudio(URL(fileURLWithPath: sealed))) != nil { next[i].audioPath = sealed }
                continue
            }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let target = HistorySeal.sealFile(atPath: path, removePlain: false) else {
                persistenceProblem = "history-unavailable"; return
            }
            next[i].audioPath = target
            originals.append(path)
        }
        guard let data = try? JSONEncoder().encode(next), let sealed = HistorySeal.seal(data, key: key) else {
            persistenceProblem = "history-unavailable"; return
        }
        d.set(sealed, forKey: sealedKey)
        // Flush the migrated paths before removing the only plaintext copy.
        guard d.synchronize() else { persistenceProblem = "history-unavailable"; return }
        d.removeObject(forKey: plainKey)
        entries = next
        persistenceProblem = nil
        for path in originals {
            do { try FileManager.default.removeItem(atPath: path) }
            catch { persistenceProblem = "history-unavailable" }
        }
    }

    func save() {
        persist()
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
        d.removeObject(forKey: plainKey)
        d.removeObject(forKey: sealedKey)
        locked = false; persistenceProblem = nil
        DispatchQueue.main.async { NotificationCenter.default.post(name: HistoryStore.didChange, object: nil) }
    }

    /// Drop entries older than the retention window. "Never" keeps only the entry
    /// just added, in memory, until the next one arrives, so "paste last" still works;
    /// no recording is kept with it (as on Windows), since nothing may stay on disk.
    func applyRetention(_ retention: HistoryRetention, saving: Bool = true) {
        guard let window = retention.seconds else { return }
        let before = entries.count
        if window == 0 {
            for dropped in entries { removeAudio(dropped) }
            entries = Array(entries.prefix(1))
            if !entries.isEmpty { entries[0].audioPath = nil }
        } else {
            let cutoff = Date().addingTimeInterval(-window)
            for dropped in entries where dropped.ts < cutoff { removeAudio(dropped) }
            entries.removeAll { $0.ts < cutoff }
        }
        // "Never" also clears what is already stored, even when no entry was dropped.
        if saving, entries.count != before || window == 0 { save() }
    }

    private func removeAudio(_ e: LocalHistoryEntry) {
        if let p = e.audioPath { try? FileManager.default.removeItem(atPath: p) }
    }

    /// How long a recording is kept for History's retry before it is deleted.
    static let audioLifetime: TimeInterval = 5 * 60

    /// Delete retained recordings older than `audioLifetime` (and any orphan audio whose entry is gone).
    func pruneAudio(olderThan: TimeInterval = HistoryStore.audioLifetime) {
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
            for n in names where n.hasPrefix("dsh-voice-") && (n.hasSuffix(".wav") || n.hasSuffix(".wav.sealed")) {
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

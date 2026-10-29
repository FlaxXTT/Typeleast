import Foundation

// EditLearner.swift - learn a word when the user fixes it right after a dictation.
//
// After inserting, the field is read again and what became of the inserted text is sent to
// the local service (`POST /learned-word`), which decides, by the same rule as on Windows,
// whether it was a spelling fix and which word to add under "Auto-added": one short
// substitution that SOUNDS like what was recognised (pinyin or letters), learned as
// vocabulary, never as a hard "always replace A with B" rule. Nothing leaves the computer.

enum EditLearner {
    /// Locate what became of the inserted text inside the field's current value,
    /// using the text that surrounded the cursor when the dictation started.
    static func editedRegion(before: String, after: String, now: String) -> String? {
        let anchorBefore = String(before.suffix(30))
        let anchorAfter = String(after.prefix(30))
        var start = now.startIndex
        if !anchorBefore.isEmpty {
            guard let found = now.range(of: anchorBefore) else { return nil }
            start = found.upperBound
        }
        var end = now.endIndex
        if !anchorAfter.isEmpty {
            guard let found = now.range(of: anchorAfter, range: start..<now.endIndex) else { return nil }
            end = found.lowerBound
        }
        return String(now[start..<end])
    }
}

/// When to judge an edit: the field is read every few seconds after a paste; once the
/// pasted text has been edited and the field then stayed the same for `settle`, the user
/// is done fixing it. Nothing is judged after `window`. `edited` says whether a value
/// differs from the pasted text (the paste itself may land after the first read).
struct EditPoll {
    static let interval: TimeInterval = 3
    static let settle: TimeInterval = 6
    static let window: TimeInterval = 120

    enum Step: Equatable { case wait, judge(String), stop }

    private let start: Date
    private let edited: (String) -> Bool
    private var last: String?
    private var lastChange: Date

    init(start: Date, edited: @escaping (String) -> Bool) {
        self.start = start
        self.edited = edited
        lastChange = start
    }

    /// The field's value at `at` (nil: it cannot be read any more).
    mutating func feed(_ value: String?, at: Date) -> Step {
        guard let value else { return .stop }
        if value != last {
            last = value
            lastChange = at
        }
        if at.timeIntervalSince(lastChange) >= EditPoll.settle, edited(value) { return .judge(value) }
        return at.timeIntervalSince(start) >= EditPoll.window ? .stop : .wait
    }

    /// Judge now (the next dictation started, or the user left the app): the value if it was edited.
    func final(_ value: String?) -> String? {
        guard let value, edited(value) else { return nil }
        return value
    }
}

/// Watches the field a dictation was pasted into and reports a learned word.
final class EditWatcher {
    var onLearn: ((String) -> Void)?
    /// Asks the service which word an edit teaches (nil: none, or the service did not answer).
    /// Called off the main thread.
    var learnedWord: (_ inserted: String, _ edited: String) -> String? = {
        try? ServiceClient.shared.learnedWordSync(inserted: $0, edited: $1)
    }

    private var pending: (field: FocusedField, inserted: String, poll: EditPoll)?
    private var timer: Timer?

    var watchedBundleId: String? { pending?.field.bundleId }

    /// Start watching after a successful paste. Replaces any earlier watch (judged first).
    func watch(field: FocusedField, inserted: String) {
        check()
        let before = field.context.before, after = field.context.after
        let poll = EditPoll(start: Date()) { now in
            EditLearner.editedRegion(before: before, after: after, now: now).map { $0 != inserted } ?? false
        }
        pending = (field, inserted, poll)
        let t = Timer(timeInterval: EditPoll.interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard var p = pending else { return stop() }
        let step = p.poll.feed(FieldContextReader.currentValue(of: p.field.element), at: Date())
        pending = p
        switch step {
        case .wait: return
        case .stop: stop()
        case .judge(let value): stop(); judge(p, now: value)
        }
    }

    /// Judge what is in the field now (called when the next dictation starts or the user
    /// switches to another app, which is when people have usually finished fixing).
    func check() {
        guard let p = pending else { return }
        let value = p.poll.final(FieldContextReader.currentValue(of: p.field.element))
        stop()
        if let value { judge(p, now: value) }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        pending = nil
    }

    private func judge(_ p: (field: FocusedField, inserted: String, poll: EditPoll), now: String) {
        guard let region = EditLearner.editedRegion(before: p.field.context.before, after: p.field.context.after, now: now),
              region.count <= p.inserted.count * 2 + 40 else { return }
        let inserted = p.inserted, ask = learnedWord
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let word = ask(inserted, region) else { return }
            DispatchQueue.main.async { self?.onLearn?(word) }
        }
    }
}

/// A term the cleanup model corrected, offered on the Dictionary page until added or ignored.
struct WordSuggestion: Codable, Equatable, Identifiable {
    var word: String
    var heardAs: String
    var count: Int
    var lastSeen: Date
    var id: String { word.lowercased() }
}

/// Local storage merging for suggestions supplied by the service. Detection lives only in Node.
enum WordSuggestions {
    static let limit = 30

    static func validCandidate(word: String, heardAs: String) -> Bool {
        (2...30).contains(word.utf16.count) && (1...30).contains(heardAs.utf16.count) &&
        !(word + heardAs).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
        !word.contains("=") && !heardAs.contains("=") &&
        !word.trimmingCharacters(in: .whitespaces).isEmpty && !heardAs.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Add one sighting: words already in the dictionary or ignored are left out; the newest first.
    static func merge(_ list: [WordSuggestion], word: String, heardAs: String, at now: Date,
                      known: Set<String>, dismissed: Set<String>) -> [WordSuggestion] {
        let key = word.lowercased()
        guard !known.contains(key), !dismissed.contains(key) else { return list }
        var out = list
        if let index = out.firstIndex(where: { $0.id == key }) {
            var s = out.remove(at: index)
            s.count += 1
            s.lastSeen = now
            out.insert(s, at: 0)
        } else {
            out.insert(WordSuggestion(word: word, heardAs: heardAs, count: 1, lastSeen: now), at: 0)
        }
        return Array(out.prefix(limit))
    }
}

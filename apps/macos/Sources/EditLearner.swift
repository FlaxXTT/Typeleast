import Foundation

// EditLearner.swift - learn a word when the user fixes it right after a dictation.
//
// Reference re-reads the field after inserting and adds the corrected word to the
// dictionary under "Auto-added". This does the same, conservatively:
//   * only one contiguous correction, short on both sides;
//   * the replacement must SOUND like what was recognised (pinyin or letters),
//     so a content edit ("明天" -> "后天") is never mistaken for a spelling fix;
//   * what is learned is the corrected word as vocabulary, never a hard
//     "always replace A with B" rule, so a real word like 公式 is never rewritten.

enum EditLearner {
    /// Longest span, in characters, that can count as one corrected word.
    static let maxSpan = 16
    /// Phonetic similarity a correction needs to count as a spelling fix.
    static let minSimilarity = 0.5

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

    /// The single corrected span, or nil when the edit is not one short substitution.
    static func correction(inserted: String, edited: String) -> (from: String, to: String, coreFrom: String, coreTo: String)? {
        let a = Array(inserted)
        let b = Array(edited)
        guard a != b, !a.isEmpty, !b.isEmpty else { return nil }
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var lo = prefix
        var hiA = a.count - suffix
        var hiB = b.count - suffix
        // Pure insertions and deletions are edits, not spelling fixes.
        guard hiA > lo, hiB > lo else { return nil }
        // What actually changed, before growing to a word: the sound check compares
        // this, so a shared neighbour ("天" in 明天/后天) cannot make a content edit
        // look like a spelling fix.
        let coreFrom = String(a[lo..<hiA])
        let coreTo = String(b[lo..<hiB])
        // Grow to whole latin words, and give a one-character CJK fix its neighbour so
        // the learned unit is a word ("公司"), not a lone character ("司").
        while lo > 0, isWordChar(a[lo - 1]) && (isWordChar(a[lo]) || isWordChar(b[lo])) { lo -= 1 }
        while hiA < a.count, hiB < b.count, isWordChar(a[hiA]) && (isWordChar(a[hiA - 1]) || isWordChar(b[hiB - 1])) {
            hiA += 1
            hiB += 1
        }
        if hiB - lo == 1, isCJK(b[lo]) {
            if lo > 0, isCJK(a[lo - 1]) { lo -= 1 } else if hiA < a.count, hiB < b.count, isCJK(b[hiB]) { hiA += 1; hiB += 1 }
        }
        let from = String(a[lo..<hiA]).trimmingCharacters(in: .whitespaces)
        let to = String(b[lo..<hiB]).trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty, from.count <= maxSpan, to.count <= maxSpan,
              !to.contains("\n"), to.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        return (from, to, coreFrom, coreTo)
    }

    /// The word to add to the dictionary for this edit, if it looks like a spelling fix.
    static func learnedWord(inserted: String, edited: String) -> String? {
        guard let pair = correction(inserted: inserted, edited: edited), pair.to.count >= 2 else { return nil }
        // Chinese is judged on the changed characters; latin on the whole word, since a
        // typo fix changes a single letter of it.
        let chinese = pair.coreFrom.contains(where: isCJK) || pair.coreTo.contains(where: isCJK)
        let score = chinese ? similarity(heard: pair.coreFrom, corrected: pair.coreTo)
                            : similarity(heard: pair.from, corrected: pair.to)
        return score >= minSimilarity ? pair.to : nil
    }

    /// How alike two spellings sound: pinyin for Chinese, letters for everything else,
    /// with syllable initials as a second chance ("第四批" ~ "DSH").
    static func similarity(heard: String, corrected: String) -> Double {
        let a = phonetic(heard)
        let b = phonetic(corrected)
        guard !a.full.isEmpty, !b.full.isEmpty else { return 0 }
        let full = ratio(a.full, b.full)
        let initials = ratio(a.initials, b.initials)
        let mixed = max(ratio(a.initials, b.full), ratio(a.full, b.initials))
        // Consonant skeletons: "depuxike" ~ "deepseek" as "dpxk" ~ "dpsk".
        let skeleton = ratio(consonants(a.full), consonants(b.full))
        return max(full, initials * 0.9, mixed * 0.9, skeleton * 0.9)
    }

    /// Lowercase latin rendering (pinyin for CJK) and the first letter of each syllable/word.
    static func phonetic(_ text: String) -> (full: String, initials: String) {
        let latin = NSMutableString(string: text)
        CFStringTransform(latin, nil, kCFStringTransformToLatin, false)
        CFStringTransform(latin, nil, kCFStringTransformStripCombiningMarks, false)
        let lowered = (latin as String).lowercased()
        let words = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let full = words.joined()
        let hasCJK = text.contains(where: isCJK)
        // A latin acronym is its own initials; a CJK phrase's initials are its syllables'.
        let initials = hasCJK || words.count > 1 ? String(words.compactMap(\.first)) : full
        return (full, initials)
    }

    static func consonants(_ text: String) -> String {
        String(text.filter { !"aeiou".contains($0) })
    }

    static func ratio(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 0 }
        return 1 - Double(levenshtein(Array(a), Array(b))) / Double(longest)
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-" || c == ".")
    }
}

/// Watches the field a dictation was pasted into and reports a learned word.
final class EditWatcher {
    /// Edits later than this are someone else's writing, not a correction.
    static let window: TimeInterval = 180

    var onLearn: ((String) -> Void)?

    private var pending: (field: FocusedField, inserted: String, at: Date)?
    private var timer: Timer?

    /// Start watching after a successful paste. Replaces any earlier watch.
    func watch(field: FocusedField, inserted: String) {
        check()
        pending = (field, inserted, Date())
        timer?.invalidate()
        let t = Timer(timeInterval: 20, repeats: false) { [weak self] _ in self?.check() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Check now (called when the next dictation starts, which is when people have
    /// usually finished fixing the previous one).
    func check() {
        timer?.invalidate()
        timer = nil
        guard let p = pending else { return }
        pending = nil
        guard Date().timeIntervalSince(p.at) <= EditWatcher.window,
              let now = FieldContextReader.currentValue(of: p.field.element),
              let region = EditLearner.editedRegion(before: p.field.context.before, after: p.field.context.after, now: now),
              region.count <= p.inserted.count * 2 + 40,
              let word = EditLearner.learnedWord(inserted: p.inserted, edited: region) else { return }
        onLearn?(word)
    }
}

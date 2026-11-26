import Foundation

struct VocabularyRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var original: String
    var replacement: String
    var context = ""
}

enum Vocabulary {
    static func hotwords(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Match against the original text. Each span is replaced at most once.
    static func applying(_ rules: [VocabularyRule], to text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        struct Match {
            let range: NSRange
            let order: Int
            let contextual: Bool
            let replacement: String
        }
        var matches: [Match] = []
        let document = NSRange(text.startIndex..<text.endIndex, in: text)
        var sentences: [NSRange] = []
        if rules.contains(where: { !$0.context.isEmpty }) {
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) {
                _, range, _, _ in sentences.append(NSRange(range, in: text))
            }
        }
        let original = text as NSString
        for (index, rule) in rules.enumerated() {
            guard let first = rule.original.first, let last = rule.original.last, !rule.replacement.isEmpty else { continue }
            let leading = usesWordBoundary(first) ? #"(?<![\p{Latin}\p{N}_])"# : ""
            let trailing = usesWordBoundary(last) ? #"(?![\p{Latin}\p{N}_])"# : ""
            let escaped = NSRegularExpression.escapedPattern(for: rule.original)
            guard let regex = try? NSRegularExpression(pattern: leading + escaped + trailing, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: text, range: document) {
                if !rule.context.isEmpty {
                    guard let sentence = sentences.first(where: {
                        NSLocationInRange(match.range.location, $0) && NSMaxRange(match.range) <= NSMaxRange($0)
                    }), original.range(of: rule.context, options: .caseInsensitive, range: sentence).location != NSNotFound else { continue }
                }
                matches.append(Match(range: match.range, order: index, contextual: !rule.context.isEmpty,
                                     replacement: rule.replacement))
            }
        }
        guard !matches.isEmpty else { return text }
        matches.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            if $0.contextual != $1.contextual { return $0.contextual }
            return $0.order < $1.order
        }
        var accepted: [Match] = []
        var end = 0
        for match in matches where match.range.location >= end {
            accepted.append(match)
            end = NSMaxRange(match.range)
        }
        let result = NSMutableString(string: text)
        for match in accepted.reversed() {
            result.replaceCharacters(in: match.range, with: match.replacement)
        }
        return result as String
    }

    private static func usesWordBoundary(_ character: Character) -> Bool {
        character.isNumber || character == "_" ||
            String(character).range(of: #"\p{Latin}"#, options: .regularExpression) != nil
    }
}

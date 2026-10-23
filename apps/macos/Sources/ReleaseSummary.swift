import Foundation

/// Release notes are untrusted plain text, never HTML or executable instructions.
enum ReleaseSummary {
    static func text(_ markdown: String, language: String = L10n.language) -> String {
        let source = String(markdown.prefix(64000))
        let languages = language.hasPrefix("en") ? ["en", "zh"] : ["zh", "en"]
        var selected = source
        for language in languages {
            let marker = "<!-- typeleast-update:" + language + " -->"
            if let start = source.range(of: marker),
               let end = source.range(of: "<!-- /typeleast-update -->", range: start.upperBound..<source.endIndex) {
                selected = String(source[start.upperBound..<end.lowerBound]); break
            }
        }
        let lines = selected.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let bullets = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.map { String($0.dropFirst(2)) }
        let chosen = bullets.isEmpty ? lines.filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("|") && !$0.hasPrefix("<") } : bullets
        return chosen.prefix(4).map { line in
            let plain = line.replacingOccurrences(of: "\\[([^]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "[*`]", with: "", options: .regularExpression)
            return "• " + String(String(plain.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).prefix(140))
        }.joined(separator: "\n")
    }
}

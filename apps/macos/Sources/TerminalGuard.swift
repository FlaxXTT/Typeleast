import Foundation

// TerminalGuard.swift - text bound for a terminal is pasted as one line. A newline in
// pasted text runs a command in many shells, and the text comes from a model that also
// read the field's surroundings: a prompt injection there must not become a command that
// runs on paste. Control characters (escape sequences that could end bracketed paste)
// are dropped for the same reason.

enum TerminalGuard {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "com.mitchellh.ghostty", "com.raphaelamorim.rio", "org.tabby",
    ]

    static func isTerminal(_ bundleId: String) -> Bool { terminals.contains(bundleId) }

    /// The text to insert into `bundleId`: unchanged for ordinary apps, one safe line for terminals.
    static func safeText(_ text: String, bundleId: String) -> String {
        guard isTerminal(bundleId) else { return text }
        var out = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let isBreak = scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == "\u{2028}" || scalar == "\u{2029}"
            if isBreak { pendingSpace = !out.isEmpty; continue }
            // C0 / C1 controls and DEL: nothing a dictation needs, and escape sequences live here.
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { continue }
            if pendingSpace, out.last != " ", scalar != " " { out.append(" ") }
            pendingSpace = false
            out.unicodeScalars.append(scalar)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

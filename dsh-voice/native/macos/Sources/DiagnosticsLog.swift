import Foundation

// DiagnosticsLog.swift - a small local log of failures, so a "can't connect" report
// can be traced afterwards. It records event names, codes and timings only: never
// an API key, a token, or anything the user dictated.
//
// ~/Library/Logs/TypeLeast/typeleast.log, rotated to typeleast.log.1 at 256 KB.

enum DiagnosticsLog {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/TypeLeast", isDirectory: true)
    static let file = directory.appendingPathComponent("typeleast.log")
    static let maxBytes = 256 * 1024

    private static let queue = DispatchQueue(label: "TypeLeast.diagnostics")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Append one line: `<time> <event> key=value …`. Values are trimmed to one line.
    static func write(_ event: String, _ fields: KeyValuePairs<String, String> = [:]) {
        let time = formatter.string(from: Date())
        var line = time + " " + event
        for (key, value) in fields {
            let flat = value.replacingOccurrences(of: "\n", with: " ").prefix(300)
            line += " " + key + "=" + String(flat)
        }
        line += "\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path)[.size]) as? Int, size > maxBytes {
                let old = directory.appendingPathComponent("typeleast.log.1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: file, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: file)
            }
        }
    }
}

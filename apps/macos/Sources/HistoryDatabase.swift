import Foundation
import SQLite3

// HistoryDatabase.swift - the SQLite file behind History: one row per dictation.
//
// Each row keeps the whole entry sealed (AES-GCM, key in the Keychain) in `payload`, beside plain
// columns with no words in them (time, app, model, seconds…), so the data set can be queried and
// a change writes one row instead of everything. Sealing is the caller's: only sealed bytes get here.

struct StoredEntryRow {
    var id: String
    var ts: Date
    var app: String?
    var task: String?
    var language: String
    var strength: String
    var model: String?
    var fallback: Bool
    var inserted: Bool
    var seconds: Double?
    var msTotal: Double?
    var translated: String?
    var payload: Data
}

final class HistoryDatabase {
    private var db: OpaquePointer?
    /// Tells SQLite to copy a bound value before the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(db, 2000)
        // Deleted rows are overwritten, not left in free pages.
        guard run("PRAGMA secure_delete = ON"), run("""
            CREATE TABLE IF NOT EXISTS entries(
                id TEXT PRIMARY KEY, ts REAL NOT NULL, app TEXT, task TEXT, language TEXT NOT NULL, strength TEXT NOT NULL,
                model TEXT, fallback INTEGER NOT NULL, inserted INTEGER NOT NULL, seconds REAL, ms_total REAL, translated TEXT,
                payload BLOB NOT NULL)
            """), run("CREATE INDEX IF NOT EXISTS entries_ts ON entries(ts)"),
              run("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value BLOB NOT NULL)") else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    private func run(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// One statement: bind, then step it until it is done. False on any error.
    private func execute(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(statement, index, value, -1, Self.transient) } else { sqlite3_bind_null(statement, index) }
    }

    private func real(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }

    private func blob(_ statement: OpaquePointer, _ index: Int32, _ value: Data) {
        value.withUnsafeBytes { _ = sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
        if value.isEmpty { sqlite3_bind_zeroblob(statement, index, 0) }
    }

    private func readBlob(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    /// The sealed entries, newest first; nil when they cannot be read.
    func payloads() -> [Data]? {
        var out: [Data] = []
        let ok = execute("SELECT payload FROM entries ORDER BY ts DESC, rowid DESC", row: { out.append(self.readBlob($0, 0)) })
        return ok ? out : nil
    }

    var count: Int {
        var total = 0
        _ = execute("SELECT COUNT(*) FROM entries", row: { total = Int(sqlite3_column_int64($0, 0)) })
        return total
    }

    /// Write and remove rows, all or nothing.
    func apply(upserts: [StoredEntryRow], deletes: [String], clearProfile: Bool = false) -> Bool {
        guard run("BEGIN IMMEDIATE") else { return false }
        if clearProfile, !execute("DELETE FROM meta WHERE key = 'profile'") { _ = run("ROLLBACK"); return false }
        for id in deletes {
            guard execute("DELETE FROM entries WHERE id = ?", bind: { self.text($0, 1, id) }) else { _ = run("ROLLBACK"); return false }
        }
        for row in upserts {
            let ok = execute("""
                INSERT INTO entries(id, ts, app, task, language, strength, model, fallback, inserted, seconds, ms_total, translated, payload)
                VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                ON CONFLICT(id) DO UPDATE SET ts = ?2, app = ?3, task = ?4, language = ?5, strength = ?6, model = ?7,
                    fallback = ?8, inserted = ?9, seconds = ?10, ms_total = ?11, translated = ?12, payload = ?13
                """, bind: { s in
                self.text(s, 1, row.id)
                sqlite3_bind_double(s, 2, row.ts.timeIntervalSince1970)
                self.text(s, 3, row.app)
                self.text(s, 4, row.task)
                self.text(s, 5, row.language)
                self.text(s, 6, row.strength)
                self.text(s, 7, row.model)
                sqlite3_bind_int(s, 8, row.fallback ? 1 : 0)
                sqlite3_bind_int(s, 9, row.inserted ? 1 : 0)
                self.real(s, 10, row.seconds)
                self.real(s, 11, row.msTotal)
                self.text(s, 12, row.translated)
                self.blob(s, 13, row.payload)
            })
            guard ok else { _ = run("ROLLBACK"); return false }
        }
        guard run("COMMIT") else { _ = run("ROLLBACK"); return false }
        return true
    }

    func meta(_ key: String) -> Data? {
        var value: Data?
        _ = execute("SELECT value FROM meta WHERE key = ?", bind: { self.text($0, 1, key) }, row: { value = self.readBlob($0, 0) })
        return value
    }

    @discardableResult
    func setMeta(_ key: String, _ value: Data) -> Bool {
        execute("INSERT INTO meta(key, value) VALUES(?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2",
                bind: { self.text($0, 1, key); self.blob($0, 2, value) })
    }

    /// Every row and the stored description.
    func deleteAll() -> Bool {
        guard run("BEGIN IMMEDIATE") else { return false }
        guard run("DELETE FROM entries"), run("DELETE FROM meta"), run("COMMIT") else { _ = run("ROLLBACK"); return false }
        return true
    }
}

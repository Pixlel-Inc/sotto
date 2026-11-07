import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SearchHit: Sendable {
    public var recordingId: String
    public var title: String
    public var startedAt: Date
    public var start: Double
    public var speaker: String
    public var text: String
    public var snippet: String
}

/// Full-text index over every transcript (SQLite FTS5). It can always be rebuilt
/// from the recording folders, so it is safe to delete.
public final class SearchIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let library: Library
    private let lock = NSLock()

    public init(library: Library) throws {
        self.library = library
        try library.paths.ensure()
        guard sqlite3_open(library.paths.indexDB.path, &db) == SQLITE_OK else {
            throw SottoError.invalid("could not open search index at \(library.paths.indexDB.path)")
        }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS recordings(
              id TEXT PRIMARY KEY, title TEXT, started_at REAL, duration REAL,
              status TEXT, indexed_at REAL)
            """)
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS segments USING fts5(
              recording_id UNINDEXED, start UNINDEXED, speaker, text,
              tokenize='porter unicode61')
            """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SottoError.invalid("sqlite: \(msg)")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SottoError.invalid("sqlite: \(String(cString: sqlite3_errmsg(db)))")
        }
        return stmt
    }

    /// Brings the index up to date with the folders on disk.
    public func sync() {
        lock.lock(); defer { lock.unlock() }
        var indexed: [String: Double] = [:]
        if let stmt = try? prepare("SELECT id, indexed_at FROM recordings") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                indexed[String(cString: sqlite3_column_text(stmt, 0))] = sqlite3_column_double(stmt, 1)
            }
            sqlite3_finalize(stmt)
        }
        let metas = library.allMetas()
        let present = Set(metas.map(\.id))
        for meta in metas {
            let changed = [library.metaModified(meta.id), library.transcriptModified(meta.id)]
                .compactMap { $0?.timeIntervalSince1970 }.max() ?? 0
            if let at = indexed[meta.id], at >= changed { continue }
            try? indexLocked(meta)
        }
        for id in indexed.keys where !present.contains(id) {
            try? removeLocked(id)
        }
    }

    public func reindex(_ id: String) throws {
        lock.lock(); defer { lock.unlock() }
        try indexLocked(try library.loadMeta(id))
    }

    private func removeLocked(_ id: String) throws {
        for sql in ["DELETE FROM segments WHERE recording_id = ?", "DELETE FROM recordings WHERE id = ?"] {
            let stmt = try prepare(sql)
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    private func indexLocked(_ meta: RecordingMeta) throws {
        try exec("BEGIN")
        do {
            try removeLocked(meta.id)
            let r = try prepare("INSERT INTO recordings(id, title, started_at, duration, status, indexed_at) VALUES(?,?,?,?,?,?)")
            sqlite3_bind_text(r, 1, meta.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(r, 2, meta.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(r, 3, meta.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(r, 4, meta.duration)
            sqlite3_bind_text(r, 5, meta.status.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(r, 6, Date().timeIntervalSince1970)
            sqlite3_step(r)
            sqlite3_finalize(r)
            if let t = library.loadTranscript(meta.id) {
                let s = try prepare("INSERT INTO segments(recording_id, start, speaker, text) VALUES(?,?,?,?)")
                for seg in t.segments {
                    sqlite3_reset(s)
                    sqlite3_bind_text(s, 1, meta.id, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(s, 2, seg.start)
                    sqlite3_bind_text(s, 3, meta.displayName(for: seg.speaker, ownerName: library.config.ownerName), -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(s, 4, seg.text, -1, SQLITE_TRANSIENT)
                    sqlite3_step(s)
                }
                sqlite3_finalize(s)
            }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Turns what a person typed into a safe FTS query: every word must appear.
    /// Words in "double quotes" are kept together as a phrase.
    static func ftsQuery(_ input: String) -> String {
        var parts: [String] = []
        var rest = Substring(input)
        while let open = rest.firstIndex(of: "\"") {
            let before = rest[rest.startIndex..<open]
            parts += words(before)
            let after = rest.index(after: open)
            if let close = rest[after...].firstIndex(of: "\"") {
                let phrase = rest[after..<close].replacingOccurrences(of: "\"", with: "")
                if !phrase.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("\"\(phrase)\"") }
                rest = rest[rest.index(after: close)...]
            } else {
                rest = rest[after...]
            }
        }
        parts += words(rest)
        return parts.joined(separator: " ")
    }

    private static func words(_ s: Substring) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { "\"\($0)\"" }
    }

    public func search(_ query: String, limit: Int = 20, recordingId: String? = nil) throws -> [SearchHit] {
        sync()
        let fts = SearchIndex.ftsQuery(query)
        guard !fts.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        var sql = """
            SELECT s.recording_id, r.title, r.started_at, s.start, s.speaker, s.text,
                   snippet(segments, 3, '**', '**', ' ... ', 24)
            FROM segments s JOIN recordings r ON r.id = s.recording_id
            WHERE segments MATCH ?
            """
        if recordingId != nil { sql += " AND s.recording_id = ?" }
        sql += " ORDER BY bm25(segments) LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var i: Int32 = 1
        sqlite3_bind_text(stmt, i, fts, -1, SQLITE_TRANSIENT); i += 1
        if let rid = recordingId { sqlite3_bind_text(stmt, i, rid, -1, SQLITE_TRANSIENT); i += 1 }
        sqlite3_bind_int(stmt, i, Int32(limit))
        var hits: [SearchHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            hits.append(SearchHit(
                recordingId: String(cString: sqlite3_column_text(stmt, 0)),
                title: String(cString: sqlite3_column_text(stmt, 1)),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                start: sqlite3_column_double(stmt, 3),
                speaker: String(cString: sqlite3_column_text(stmt, 4)),
                text: String(cString: sqlite3_column_text(stmt, 5)),
                snippet: String(cString: sqlite3_column_text(stmt, 6))))
        }
        return hits
    }
}

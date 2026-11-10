import Foundation
import GRDB

/// IOS-012: what the dev-only Diagnostics screen can say about the local database. Counts and states only:
/// no row content, so it can never carry body weight (ADR-064), notes, titles or tokens (AGENTS rule 6).
public struct DatabaseDiagnostics: Codable, Equatable, Sendable {
    public struct TableCount: Codable, Equatable, Sendable {
        public var name: String
        public var rows: Int
        /// Rows still waiting for sync (`dirty = 1`); nil for tables without a `dirty` column.
        public var dirty: Int?
    }

    public struct OutboxState: Codable, Equatable, Sendable {
        public var state: String
        public var count: Int
        public var maxAttempts: Int
        public var oldestCreatedAt: String?
        /// Last error text of that state, redacted and cut to 120 characters.
        public var lastError: String?
    }

    public var migrations: [String]
    public var tables: [TableCount]
    public var outbox: [OutboxState]
    public var cursorScopes: [String]

    public static func read(_ reader: any DatabaseReader) throws -> DatabaseDiagnostics {
        try reader.read { db in
            let migrations = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name")
            let tables = try names.map { name -> TableCount in
                let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quoted)") ?? 0
                let hasDirty = try Bool.fetchOne(db, sql: "SELECT COUNT(*) > 0 FROM pragma_table_info(?) WHERE name = 'dirty'", arguments: [name]) ?? false
                let dirty = hasDirty ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(quoted) WHERE dirty = 1") : nil
                return TableCount(name: name, rows: rows, dirty: dirty)
            }
            let outbox = try Row.fetchAll(db, sql: """
                SELECT state, COUNT(*) AS n, MAX(attempts) AS attempts, MIN(created_at) AS oldest,
                       (SELECT last_error FROM sync_outbox e WHERE e.state = o.state AND e.last_error IS NOT NULL ORDER BY seq DESC LIMIT 1) AS err
                FROM sync_outbox o GROUP BY state ORDER BY state
                """).map { row in
                OutboxState(state: row["state"], count: row["n"], maxAttempts: row["attempts"] ?? 0, oldestCreatedAt: row["oldest"],
                            lastError: (row["err"] as String?).map { String(LogRedactor.redact($0).prefix(120)) })
            }
            let cursors = try String.fetchAll(db, sql: "SELECT scope FROM sync_cursor ORDER BY scope")
            return DatabaseDiagnostics(migrations: migrations, tables: tables, outbox: outbox, cursorScopes: cursors)
        }
    }
}

/// Removes credentials from text that leaves the app through a diagnostics export (AGENTS rule 6).
public enum LogRedactor {
    public static let marker = "‹redacted›"

    private static let patterns: [NSRegularExpression] = [
        #"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"#,             // JWT
        #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,                                    // Authorization header value
        #"(?i)\b(authorization|token|password|passwd|secret|api[_-]?key)\b["']?\s*[=:]\s*["']?[^\s,;"']+"#, // key=value pairs
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        patterns.reduce(text) { partial, regex in
            regex.stringByReplacingMatches(in: partial, range: NSRange(partial.startIndex..., in: partial), withTemplate: marker)
        }
    }
}

/// A titled block of an export; `render` redacts the whole text once more before it is shared.
public struct DiagnosticsSection: Equatable, Sendable {
    public var title: String
    public var lines: [String]

    public init(title: String, lines: [String]) {
        self.title = title
        self.lines = lines
    }
}

public enum DiagnosticsReport {
    public static func render(_ sections: [DiagnosticsSection], generatedAt: Date) -> String {
        var out = ["COAMI diagnostics", "Generated: \(DBText.time(generatedAt))", ""]
        for section in sections {
            out.append("## \(section.title)")
            out += section.lines.isEmpty ? ["(none)"] : section.lines
            out.append("")
        }
        return LogRedactor.redact(out.joined(separator: "\n"))
    }

    public static func lines(for db: DatabaseDiagnostics) -> [DiagnosticsSection] {
        [
            DiagnosticsSection(title: "Database migrations", lines: db.migrations),
            DiagnosticsSection(title: "Tables (rows, dirty)", lines: db.tables.map { "\($0.name): \($0.rows)" + ($0.dirty.map { ", dirty \($0)" } ?? "") }),
            DiagnosticsSection(title: "Sync outbox", lines: db.outbox.map {
                "\($0.state): \($0.count), max attempts \($0.maxAttempts), oldest \($0.oldestCreatedAt ?? "-")" + ($0.lastError.map { ", last error: \($0)" } ?? "")
            }),
            DiagnosticsSection(title: "Sync cursors (scopes only)", lines: db.cursorScopes),
        ]
    }
}

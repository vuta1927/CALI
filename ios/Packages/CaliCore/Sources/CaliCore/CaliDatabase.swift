import Foundation
import GRDB

/// Opens and migrates the local workout database (POC-002 schema "v1").
///
/// The schema is the minimum the single-writer coordinator needs (docs/03 §6): durable session state,
/// canonical set results, a transactional sync outbox and the `processed_commands` dedupe table.
/// TODO(IOS-001): replace with the full docs/04 local schema once POC-002 is GO; until then the app keeps
/// `LocalStore` for normal workouts and only the POC screen uses this database.
public enum CaliDatabase {
    /// Busy timeout for a second connection (e.g. a concurrent `BEGIN IMMEDIATE` from another
    /// connection/process). Inside one process, GRDB already serialises writes per writer.
    public static let defaultBusyTimeout: TimeInterval = 5

    public static func configuration(label: String = "CaliCore", busyTimeout: TimeInterval = defaultBusyTimeout) -> Configuration {
        var config = Configuration()
        config.label = label
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(busyTimeout)
        return config
    }

    /// File database in WAL mode (`DatabasePool`), migrated to the latest schema.
    public static func openPool(at url: URL, label: String = "CaliCore", busyTimeout: TimeInterval = defaultBusyTimeout) throws -> DatabasePool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: configuration(label: label, busyTimeout: busyTimeout))
        try migrator.migrate(pool)
        return pool
    }

    /// In-memory database for tests and previews.
    public static func openInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue(configuration: configuration(label: "CaliCore.memory"))
        try migrator.migrate(queue)
        return queue
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            // Durable session state. The full `SessionState` JSON is the source of truth; the scalar
            // columns are denormalised for queries and invariants (one active session at a time).
            try db.execute(sql: """
                CREATE TABLE local_session_state (
                    session_id TEXT PRIMARY KEY NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('active', 'completed', 'abandoned')),
                    phase TEXT NOT NULL,
                    revision INTEGER NOT NULL CHECK (revision >= 1),
                    phase_deadline_at TEXT,
                    state_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE UNIQUE INDEX local_session_state_one_active
                    ON local_session_state(status) WHERE status = 'active';

                CREATE TABLE set_results (
                    id TEXT PRIMARY KEY NOT NULL,
                    session_id TEXT NOT NULL REFERENCES local_session_state(session_id),
                    execution_id TEXT NOT NULL,
                    set_index INTEGER NOT NULL CHECK (set_index >= 1),
                    status TEXT NOT NULL,
                    record_json TEXT NOT NULL,
                    confirmed_at TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    UNIQUE (session_id, execution_id, set_index)
                );

                CREATE TABLE sync_outbox (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    mutation_id TEXT NOT NULL UNIQUE,
                    entity_type TEXT NOT NULL,
                    entity_id TEXT NOT NULL,
                    action TEXT NOT NULL CHECK (action IN ('upsert', 'delete')),
                    base_version INTEGER CHECK (base_version IS NULL OR base_version >= 0),
                    json TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending',
                    attempts INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    last_error TEXT
                );

                CREATE TABLE processed_commands (
                    command_id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL,
                    response_json TEXT NOT NULL,
                    processed_at TEXT NOT NULL
                );
                """)
        }
        return migrator
    }
}

/// Text encodings used in the database (UUID lowercase, ISO-8601 UTC with milliseconds).
enum DBText {
    static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    static func time(_ date: Date) -> String { formatter().string(from: date) }

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

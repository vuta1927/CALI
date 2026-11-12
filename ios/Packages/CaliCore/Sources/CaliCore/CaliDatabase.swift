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
        migrator.registerMigration("v2_content") { db in
            try db.execute(sql: contentSchemaV2)
        }
        migrator.registerMigration("v3_goals") { db in
            try db.execute(sql: goalsSchemaV3)
        }
        migrator.registerMigration("v4_body_measurements") { db in
            try db.execute(sql: bodyMeasurementsSchemaV4)
        }
        migrator.registerMigration("v5_sync_client") { db in
            try db.execute(sql: syncClientSchemaV5)
        }
        migrator.registerMigration("v6_sync_inbox") { db in
            try db.execute(sql: syncInboxSchemaV6)
        }
        migrator.registerMigration("v7_rest_between_exercises") { db in
            try db.execute(sql: restBetweenExercisesV7)
        }
        migrator.registerMigration("v8_set_result_tombstones") { db in
            try db.execute(sql: setResultTombstonesV8)
        }
        return migrator
    }

    /// CON-011: `planned_workouts.rest_between_exercises_seconds` (nullable; NULL = client default 60 s). Kept so an
    /// iOS upsert never wipes the server value.
    static let restBetweenExercisesV7 = """
        ALTER TABLE planned_workouts ADD COLUMN rest_between_exercises_seconds INTEGER
            CHECK (rest_between_exercises_seconds IS NULL OR rest_between_exercises_seconds BETWEEN 0 AND 3600);
        """

    /// IOS-023: a reopened skipped set is tombstoned (`deleted_at`, docs/08 §7: never hard-delete while unsynced)
    /// and done again under a new id, so "one result per set" holds for live rows only (like the server's partial
    /// unique index on `set_results(execution_id, set_index) WHERE deleted_at IS NULL`). SQLite cannot alter a
    /// table constraint: the table is rebuilt with the same columns plus `deleted_at`.
    static let setResultTombstonesV8 = """
        CREATE TABLE set_results_v7 (
            id TEXT PRIMARY KEY NOT NULL,
            session_id TEXT NOT NULL REFERENCES local_session_state(session_id),
            execution_id TEXT NOT NULL,
            set_index INTEGER NOT NULL CHECK (set_index >= 1),
            status TEXT NOT NULL,
            record_json TEXT NOT NULL,
            confirmed_at TEXT NOT NULL,
            revision INTEGER NOT NULL,
            deleted_at TEXT
        );
        INSERT INTO set_results_v7 (id, session_id, execution_id, set_index, status, record_json, confirmed_at, revision)
            SELECT id, session_id, execution_id, set_index, status, record_json, confirmed_at, revision FROM set_results;
        DROP TABLE set_results;
        ALTER TABLE set_results_v7 RENAME TO set_results;
        CREATE UNIQUE INDEX set_results_one_live_per_set
            ON set_results(session_id, execution_id, set_index) WHERE deleted_at IS NULL;
        """

    /// IOS-001: local mirror of the content entities after CON-003/004 (docs/04 "main tables mirror server
    /// business entities"), plus history, AI review, audit, settings, sync cursor, media cache and the record
    /// of the one-time `cali-poc.json` import. UUIDs are lowercase TEXT, instants ISO-8601 UTC TEXT, local
    /// dates `YYYY-MM-DD`.
    ///
    /// Synced entities carry `server_version` (NULL until the server acknowledges a version) and `dirty`
    /// (1 = changed locally since the last acknowledged version).
    /// IOS-007 slice 3: `ContentOutbox` turns dirty rows into outbox mutations in the same transaction as the edit (and at the
    /// start of each sync run); `dirty` is cleared when the server acknowledges the row as it still is.
    /// IOS-015: CON-005 phases (per revision) and goals (per lineage). Goals keep the full payload in `json`;
    /// `current` is computed on the device and never stored. Same sync columns as v2.
    static let goalsSchemaV3 = """
        CREATE TABLE plan_phases (
            id TEXT PRIMARY KEY NOT NULL,
            plan_id TEXT NOT NULL REFERENCES training_plans(id) ON DELETE CASCADE,
            order_index INTEGER NOT NULL CHECK (order_index >= 0),
            name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
            weeks INTEGER NOT NULL CHECK (weeks BETWEEN 1 AND 52),
            description TEXT CHECK (description IS NULL OR length(description) <= 500),
            deleted_at TEXT,
            updated_at TEXT NOT NULL,
            server_version INTEGER,
            dirty INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX plan_phases_plan ON plan_phases(plan_id, order_index);

        CREATE TABLE plan_goals (
            id TEXT PRIMARY KEY NOT NULL,
            plan_lineage_id TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('active', 'reached', 'achieved', 'missed', 'archived')),
            pinned INTEGER NOT NULL DEFAULT 0,
            json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            server_version INTEGER,
            dirty INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX plan_goals_lineage ON plan_goals(plan_lineage_id);
        """

    /// IOS-007: the sync client's bookkeeping. Outbox rows written before this version hold domain values, not
    /// contract payloads (they were never uploadable, `TODO(IOS-001)`), so they are parked as `legacy` and never sent;
    /// their data is still in the local tables. New rows carry `payload_version = 2` (entity-payloads.schema.json).
    static let syncClientSchemaV5 = """
        ALTER TABLE sync_outbox ADD COLUMN payload_version INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE sync_outbox ADD COLUMN next_attempt_at TEXT;
        ALTER TABLE sync_outbox ADD COLUMN last_attempt_at TEXT;
        ALTER TABLE sync_outbox ADD COLUMN error_code TEXT;
        ALTER TABLE sync_outbox ADD COLUMN server_version INTEGER;
        ALTER TABLE sync_outbox ADD COLUMN server_entity_json TEXT;
        UPDATE sync_outbox SET state = 'legacy' WHERE state IN ('pending', 'sending');
        CREATE INDEX sync_outbox_state_seq ON sync_outbox(state, seq);

        ALTER TABLE local_session_state ADD COLUMN local_date TEXT;
        ALTER TABLE local_session_state ADD COLUMN timezone TEXT;

        -- Last server version known for each entity: the next mutation's baseVersion (docs/08 §3).
        CREATE TABLE sync_versions (
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            server_version INTEGER NOT NULL CHECK (server_version >= 0),
            PRIMARY KEY (entity_type, entity_id)
        );

        CREATE TABLE sync_state (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """

    /// IOS-007 slice 2: changes pulled from the server that have no local applier yet. The cursor moves past a page
    /// in the same transaction that stores it here, so nothing is lost; the content slice reads and clears these rows.
    static let syncInboxSchemaV6 = """
        CREATE TABLE sync_inbox (
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
            server_version INTEGER NOT NULL CHECK (server_version >= 1),
            change_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            received_at TEXT NOT NULL,
            PRIMARY KEY (entity_type, entity_id)
        );
        """

    /// IOS-018: CON-007 `body_measurements` (db/007). `value` is exact decimal text in kilograms (no float round
    /// trip, no unit column, ADR-063); more than 2 decimals is refused here as well as in the domain. This table is
    /// sensitive: it is only read by the app process, never through the App Group (ADR-064). Same sync columns as v2.
    static let bodyMeasurementsSchemaV4 = """
        CREATE TABLE body_measurements (
            id TEXT PRIMARY KEY NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('weight')),
            value TEXT NOT NULL CHECK (CAST(value AS REAL) BETWEEN 20 AND 500 AND value NOT GLOB '*.[0-9][0-9][0-9]*'),
            measured_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            server_version INTEGER,
            dirty INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX body_measurements_kind_measured ON body_measurements(kind, measured_at DESC) WHERE deleted_at IS NULL;
        """

    static let contentSchemaV2 = """
        ALTER TABLE local_session_state ADD COLUMN title TEXT NOT NULL DEFAULT '';

        CREATE TABLE exercises (
            id TEXT PRIMARY KEY NOT NULL,
            slug TEXT NOT NULL,
            name TEXT NOT NULL CHECK (length(trim(name)) > 0),
            type TEXT NOT NULL,
            catalog_version INTEGER NOT NULL CHECK (catalog_version >= 1),
            sort_index INTEGER NOT NULL,
            json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE training_plans (
            id TEXT PRIMARY KEY NOT NULL,
            lineage_id TEXT NOT NULL,
            title TEXT NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 120),
            revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
            status TEXT NOT NULL DEFAULT 'current' CHECK (status IN ('current', 'superseded')),
            parent_plan_id TEXT,
            kind TEXT NOT NULL DEFAULT 'weekly' CHECK (kind IN ('weekly', 'event')),
            event_date TEXT,
            event_name TEXT,
            primary_discipline TEXT NOT NULL CHECK (primary_discipline IN ('calisthenics', 'running', 'gym', 'mixed')),
            ended_at TEXT,
            end_reason TEXT CHECK (end_reason IS NULL OR end_reason IN ('completed', 'stopped')),
            end_note TEXT,
            archived_at TEXT,
            deleted_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            server_version INTEGER,
            dirty INTEGER NOT NULL DEFAULT 1
        );
        CREATE UNIQUE INDEX training_plans_one_current_per_lineage
            ON training_plans(lineage_id) WHERE status = 'current';

        CREATE TABLE plan_activations (
            id TEXT PRIMARY KEY NOT NULL,
            plan_lineage_id TEXT NOT NULL,
            from_date TEXT NOT NULL,
            to_date TEXT,
            timezone TEXT NOT NULL CHECK (length(timezone) BETWEEN 1 AND 64),
            end_reason TEXT CHECK (end_reason IS NULL OR end_reason IN ('paused', 'completed', 'stopped', 'deleted')),
            deleted_at TEXT,
            created_at TEXT NOT NULL,
            server_version INTEGER,
            dirty INTEGER NOT NULL DEFAULT 1,
            CHECK (to_date IS NULL OR to_date >= from_date)
        );
        CREATE INDEX plan_activations_lineage ON plan_activations(plan_lineage_id);

        CREATE TABLE planned_workouts (
            id TEXT PRIMARY KEY NOT NULL,
            plan_id TEXT NOT NULL REFERENCES training_plans(id) ON DELETE CASCADE,
            weekday INTEGER NOT NULL CHECK (weekday BETWEEN 1 AND 7),
            title TEXT NOT NULL CHECK (length(title) <= 120),
            focus TEXT NOT NULL DEFAULT '',
            order_index INTEGER NOT NULL CHECK (order_index >= 0),
            server_version INTEGER,
            dirty INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX planned_workouts_plan ON planned_workouts(plan_id, order_index);

        CREATE TABLE planned_exercises (
            id TEXT PRIMARY KEY NOT NULL,
            planned_workout_id TEXT NOT NULL REFERENCES planned_workouts(id) ON DELETE CASCADE,
            exercise_id TEXT NOT NULL REFERENCES exercises(id),
            order_index INTEGER NOT NULL CHECK (order_index >= 0),
            set_count INTEGER NOT NULL CHECK (set_count BETWEEN 1 AND 20),
            target_json TEXT NOT NULL,
            rest_seconds INTEGER NOT NULL CHECK (rest_seconds BETWEEN 0 AND 3600),
            server_version INTEGER,
            dirty INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX planned_exercises_workout ON planned_exercises(planned_workout_id, order_index);

        -- Finished sessions as shown in History. Live sessions are written by WorkoutCoordinator in the same
        -- transaction that makes them terminal; imported and sample rows come from the importer / seed.
        CREATE TABLE session_history (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            planned_workout_id TEXT,
            started_at TEXT NOT NULL,
            finished_at TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('completed', 'abandoned')),
            source TEXT NOT NULL CHECK (source IN ('live', 'imported', 'sample')),
            json TEXT NOT NULL
        );
        CREATE INDEX session_history_started ON session_history(started_at DESC);

        CREATE TABLE recommendations (
            id TEXT PRIMARY KEY NOT NULL,
            sort_index INTEGER NOT NULL,
            decision TEXT CHECK (decision IS NULL OR decision IN ('accepted', 'rejected')),
            json TEXT NOT NULL
        );

        -- Append-only. `id` is the commandId of the change, so a repeated command is a no-op.
        CREATE TABLE audit_log (
            id TEXT PRIMARY KEY NOT NULL,
            at TEXT NOT NULL,
            action TEXT NOT NULL,
            detail TEXT NOT NULL
        );
        CREATE INDEX audit_log_at ON audit_log(at DESC);

        CREATE TABLE app_settings (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            json TEXT NOT NULL
        );

        CREATE TABLE sync_cursor (
            scope TEXT PRIMARY KEY NOT NULL,
            cursor TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE media_cache (
            url TEXT PRIMARY KEY NOT NULL,
            local_name TEXT NOT NULL,
            byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
            content_type TEXT,
            etag TEXT,
            created_at TEXT NOT NULL,
            last_access_at TEXT NOT NULL
        );

        -- One row per legacy source that was imported; its presence makes the importer a no-op.
        CREATE TABLE legacy_imports (
            source TEXT PRIMARY KEY NOT NULL,
            imported_at TEXT NOT NULL,
            byte_count INTEGER NOT NULL,
            summary_json TEXT NOT NULL
        );
        """
}

/// Text encodings used in the database (UUID lowercase, ISO-8601 UTC with milliseconds).
enum DBText {
    static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    static func time(_ date: Date) -> String { formatter().string(from: date) }

    static func date(_ text: String) -> Date? { formatter().date(from: text) }

    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

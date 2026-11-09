import CaliDomain
import Foundation
import GRDB

/// Everything the app shows outside the workout player, read in one consistent snapshot.
public struct LocalContent: Equatable, Sendable {
    public var catalog: [Exercise]
    /// The plan the app edits today (single-plan UI until IOS-013): the most recently updated `current`
    /// revision, including a soft-deleted one so the "deleted" state survives a relaunch.
    public var plan: WorkoutPlan?
    /// Newest first.
    public var history: [CompletedSession]
    public var recommendations: [Recommendation]
    /// Newest first.
    public var audit: [AuditEntry]
    public var settings: AppSettings

    public init(
        catalog: [Exercise], plan: WorkoutPlan?, history: [CompletedSession], recommendations: [Recommendation],
        audit: [AuditEntry], settings: AppSettings
    ) {
        self.catalog = catalog
        self.plan = plan
        self.history = history
        self.recommendations = recommendations
        self.audit = audit
        self.settings = settings
    }
}

/// One atomic content edit. Every field is optional; what is set is written in a single transaction.
public struct ContentChange: Sendable {
    /// Upserted by id (exercises are never deleted: sessions and plans reference them).
    public var exercises: [Exercise]
    /// Upserts the plan and replaces its workouts / planned exercises with exactly these.
    public var plan: WorkoutPlan?
    /// Upserted by id.
    public var recommendations: [Recommendation]
    public var settings: AppSettings?
    /// The audit row of a user command. Its `id` is the `commandId`: when it already exists the whole
    /// change is skipped and `apply` returns `.duplicate` (repeat calls are safe, AGENTS rule 5).
    public var audit: AuditEntry?

    public init(
        exercises: [Exercise] = [], plan: WorkoutPlan? = nil, recommendations: [Recommendation] = [],
        settings: AppSettings? = nil, audit: AuditEntry? = nil
    ) {
        self.exercises = exercises
        self.plan = plan
        self.recommendations = recommendations
        self.settings = settings
        self.audit = audit
    }
}

public enum ContentApplyResult: Equatable, Sendable {
    case applied
    /// The audit `commandId` was already recorded; nothing was written.
    case duplicate
}

/// Initial content for an empty database (bundled catalog, starter plan, labelled sample data).
public struct ContentSeed: Sendable {
    public var catalog: [Exercise]
    public var plan: WorkoutPlan
    public var sampleHistory: [CompletedSession]
    public var sampleRecommendations: [Recommendation]
    public var settings: AppSettings

    public init(catalog: [Exercise], plan: WorkoutPlan, sampleHistory: [CompletedSession], sampleRecommendations: [Recommendation], settings: AppSettings = AppSettings()) {
        self.catalog = catalog
        self.plan = plan
        self.sampleHistory = sampleHistory
        self.sampleRecommendations = sampleRecommendations
        self.settings = settings
    }
}

/// Reads and writes catalog, plan, history, AI review, audit and settings rows.
///
/// It shares the coordinator's `DatabaseWriter`, so every write is serialised with workout commands on the
/// one writer of the app process (ADR-013); each `apply` is one `BEGIN IMMEDIATE` transaction.
public final class ContentStore: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: Reads

    /// `true` once a seed or an import has written settings (the database holds the user's content).
    public func isInitialized() throws -> Bool {
        try writer.read { db in try Self.isInitialized(db) }
    }

    public func load() throws -> LocalContent {
        try writer.read { db in try Self.load(db) }
    }

    // MARK: Writes

    @discardableResult
    public func apply(_ change: ContentChange, now: Date = Date(), timeZone: TimeZone = .current) throws -> ContentApplyResult {
        try writer.immediateTransaction { db in
            if let audit = change.audit, try Self.auditExists(db, id: audit.id) { return .duplicate }
            try Self.write(db, change, now: now, timeZone: timeZone)
            return .applied
        }
    }

    /// Writes the seed when the database has no content yet. Returns `false` (and writes nothing) otherwise.
    @discardableResult
    public func seedIfEmpty(_ seed: ContentSeed, now: Date = Date(), timeZone: TimeZone = .current) throws -> Bool {
        try writer.immediateTransaction { db in
            guard try !Self.isInitialized(db) else { return false }
            try Self.writeSeed(db, seed, now: now, timeZone: timeZone)
            return true
        }
    }

    /// Demo reset: deletes all content, history, sessions, outbox and processed commands, then writes the
    /// seed. `legacy_imports` is kept so an old JSON snapshot is never imported a second time.
    public func resetAll(to seed: ContentSeed, now: Date = Date(), timeZone: TimeZone = .current) throws {
        try writer.immediateTransaction { db in
            for table in [
                "planned_exercises", "planned_workouts", "plan_activations", "training_plans", "exercises",
                "session_history", "recommendations", "audit_log", "app_settings", "set_results",
                "local_session_state", "sync_outbox", "processed_commands",
            ] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try Self.writeSeed(db, seed, now: now, timeZone: timeZone)
        }
    }

    // MARK: Row writing (shared with the importer)

    static func isInitialized(_ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM app_settings)") ?? false
    }

    static func auditExists(_ db: Database, id: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM audit_log WHERE id = ?)", arguments: [DBText.id(id)]) ?? false
    }

    static func writeSeed(_ db: Database, _ seed: ContentSeed, now: Date, timeZone: TimeZone) throws {
        try write(db, ContentChange(exercises: seed.catalog, plan: seed.plan, recommendations: seed.sampleRecommendations, settings: seed.settings),
                  now: now, timeZone: timeZone)
        for session in seed.sampleHistory {
            try insertHistory(db, session, source: "sample")
        }
    }

    static func write(_ db: Database, _ change: ContentChange, now: Date, timeZone: TimeZone) throws {
        try upsertExercises(db, change.exercises, now: now)
        if let plan = change.plan {
            try upsertPlan(db, plan, now: now, timeZone: timeZone)
        }
        try upsertRecommendations(db, change.recommendations)
        if let settings = change.settings {
            try db.execute(sql: "INSERT INTO app_settings (id, json) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                           arguments: [try DBJSON.encode(settings)])
        }
        if let audit = change.audit {
            try insertAudit(db, audit)
        }
    }

    static func upsertExercises(_ db: Database, _ exercises: [Exercise], now: Date) throws {
        guard !exercises.isEmpty else { return }
        var nextIndex = (try Int.fetchOne(db, sql: "SELECT MAX(sort_index) FROM exercises") ?? -1) + 1
        for exercise in exercises {
            let existingIndex = try Int.fetchOne(db, sql: "SELECT sort_index FROM exercises WHERE id = ?", arguments: [DBText.id(exercise.id)])
            let index = existingIndex ?? nextIndex
            if existingIndex == nil { nextIndex += 1 }
            try db.execute(
                sql: """
                    INSERT INTO exercises (id, slug, name, type, catalog_version, sort_index, json, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET slug = excluded.slug, name = excluded.name, type = excluded.type,
                        catalog_version = excluded.catalog_version, json = excluded.json, updated_at = excluded.updated_at
                    """,
                arguments: [DBText.id(exercise.id), exercise.slug, exercise.name, exercise.type.rawValue, exercise.catalogVersion,
                            index, try DBJSON.encode(exercise), DBText.time(now)]
            )
        }
    }

    /// Upserts the plan row and makes its workouts / planned exercises match `plan` exactly.
    ///
    /// Single-plan UI rules until IOS-013 (docs/19 BR-10, ADR-040): a new, non-deleted plan is followed from
    /// today (one open activation); soft-deleting a plan closes its open activation with `deleted`.
    static func upsertPlan(_ db: Database, _ plan: WorkoutPlan, now: Date, timeZone: TimeZone, activationFrom: LocalDate? = nil) throws {
        let planId = DBText.id(plan.id)
        let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM training_plans WHERE id = ?)", arguments: [planId]) ?? false
        let discipline = try primaryDiscipline(db, plan)
        let today = LocalDate.today(at: now, in: timeZone)
        if exists {
            try db.execute(
                sql: """
                    UPDATE training_plans SET title = ?, primary_discipline = ?, deleted_at = ?, updated_at = ?, dirty = 1
                    WHERE id = ?
                    """,
                arguments: [plan.title, discipline, plan.deletedAt.map(DBText.time), DBText.time(now), planId]
            )
        } else {
            try db.execute(
                sql: """
                    INSERT INTO training_plans (id, lineage_id, title, revision, status, kind, primary_discipline, deleted_at, created_at, updated_at)
                    VALUES (?, ?, ?, 1, 'current', 'weekly', ?, ?, ?, ?)
                    """,
                arguments: [planId, planId, plan.title, discipline, plan.deletedAt.map(DBText.time), DBText.time(now), DBText.time(now)]
            )
            if plan.deletedAt == nil {
                try db.execute(
                    sql: """
                        INSERT INTO plan_activations (id, plan_lineage_id, from_date, timezone, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [DBText.id(UUID()), planId, DBText.date(activationFrom ?? today), timeZone.identifier, DBText.time(now)]
                )
            }
        }
        if plan.deletedAt != nil {
            // Close the open activation; never before it started.
            try db.execute(
                sql: """
                    UPDATE plan_activations SET to_date = MAX(from_date, ?), end_reason = 'deleted', dirty = 1
                    WHERE plan_lineage_id = (SELECT lineage_id FROM training_plans WHERE id = ?) AND to_date IS NULL AND deleted_at IS NULL
                    """,
                arguments: [DBText.date(today), planId]
            )
        }

        let keepWorkouts = plan.workouts.map { DBText.id($0.id) }
        try db.execute(
            sql: "DELETE FROM planned_workouts WHERE plan_id = ? AND id NOT IN (SELECT value FROM json_each(?))",
            arguments: [planId, try DBJSON.encode(keepWorkouts)]
        )
        for (workoutIndex, workout) in plan.workouts.enumerated() {
            let workoutId = DBText.id(workout.id)
            try db.execute(
                sql: """
                    INSERT INTO planned_workouts (id, plan_id, weekday, title, focus, order_index)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET plan_id = excluded.plan_id, weekday = excluded.weekday, title = excluded.title,
                        focus = excluded.focus, order_index = excluded.order_index, dirty = 1
                    """,
                arguments: [workoutId, planId, workout.weekday, workout.title, workout.focus, workoutIndex]
            )
            let keepExercises = workout.exercises.map { DBText.id($0.id) }
            try db.execute(
                sql: "DELETE FROM planned_exercises WHERE planned_workout_id = ? AND id NOT IN (SELECT value FROM json_each(?))",
                arguments: [workoutId, try DBJSON.encode(keepExercises)]
            )
            for (exerciseIndex, item) in workout.exercises.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO planned_exercises (id, planned_workout_id, exercise_id, order_index, set_count, target_json, rest_seconds)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET planned_workout_id = excluded.planned_workout_id, exercise_id = excluded.exercise_id,
                            order_index = excluded.order_index, set_count = excluded.set_count, target_json = excluded.target_json,
                            rest_seconds = excluded.rest_seconds, dirty = 1
                        """,
                    arguments: [DBText.id(item.id), workoutId, DBText.id(item.exerciseId), exerciseIndex, item.setCount,
                                try DBJSON.encode(item.target), item.restSeconds]
                )
            }
        }
    }

    /// docs/19 BR-10: one discipline → that discipline, several → `mixed`, none → `calisthenics`.
    static func primaryDiscipline(_ db: Database, _ plan: WorkoutPlan) throws -> String {
        let ids = Set(plan.workouts.flatMap { $0.exercises.map { DBText.id($0.exerciseId) } })
        guard !ids.isEmpty else { return "calisthenics" }
        let types = try String.fetchAll(db, sql: "SELECT DISTINCT type FROM exercises WHERE id IN (SELECT value FROM json_each(?))",
                                        arguments: [try DBJSON.encode(Array(ids))])
        let disciplines = Set(types.compactMap(ExerciseType.init(rawValue:)).map(discipline(for:)))
        return disciplines.count == 1 ? disciplines.first! : (disciplines.isEmpty ? "calisthenics" : "mixed")
    }

    /// CON-006 default discipline per exercise type (db/006 trigger).
    static func discipline(for type: ExerciseType) -> String {
        switch type {
        case .load: "gym"
        case .staticHold, .reps, .timedReps, .interval, .skillAttempt: "calisthenics"
        }
    }

    static func upsertRecommendations(_ db: Database, _ recommendations: [Recommendation]) throws {
        guard !recommendations.isEmpty else { return }
        var nextIndex = (try Int.fetchOne(db, sql: "SELECT MAX(sort_index) FROM recommendations") ?? -1) + 1
        for recommendation in recommendations {
            let existingIndex = try Int.fetchOne(db, sql: "SELECT sort_index FROM recommendations WHERE id = ?", arguments: [DBText.id(recommendation.id)])
            let index = existingIndex ?? nextIndex
            if existingIndex == nil { nextIndex += 1 }
            try db.execute(
                sql: """
                    INSERT INTO recommendations (id, sort_index, decision, json) VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET decision = excluded.decision, json = excluded.json
                    """,
                arguments: [DBText.id(recommendation.id), index, recommendation.decision?.rawValue, try DBJSON.encode(recommendation)]
            )
        }
    }

    static func insertAudit(_ db: Database, _ entry: AuditEntry) throws {
        try db.execute(sql: "INSERT INTO audit_log (id, at, action, detail) VALUES (?, ?, ?, ?)",
                       arguments: [DBText.id(entry.id), DBText.time(entry.at), entry.action, entry.detail])
    }

    /// Inserts a finished session; an existing row with the same id is kept (idempotent).
    static func insertHistory(_ db: Database, _ session: CompletedSession, source: String) throws {
        try db.execute(
            sql: """
                INSERT INTO session_history (id, title, planned_workout_id, started_at, finished_at, status, source, json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """,
            arguments: [DBText.id(session.id), session.title, session.plannedWorkoutId.map(DBText.id), DBText.time(session.startedAt),
                        DBText.time(session.finishedAt), session.status.rawValue, source, try DBJSON.encode(session)]
        )
    }

    // MARK: Row reading

    static func load(_ db: Database) throws -> LocalContent {
        let catalog = try String.fetchAll(db, sql: "SELECT json FROM exercises ORDER BY sort_index, rowid")
            .map { try DBJSON.decode(Exercise.self, $0) }
        let history = try String.fetchAll(db, sql: "SELECT json FROM session_history ORDER BY started_at DESC, rowid DESC")
            .map { try DBJSON.decode(CompletedSession.self, $0) }
        let recommendations = try String.fetchAll(db, sql: "SELECT json FROM recommendations ORDER BY sort_index, rowid")
            .map { try DBJSON.decode(Recommendation.self, $0) }
        let audit = try Row.fetchAll(db, sql: "SELECT * FROM audit_log ORDER BY at DESC, rowid DESC").map { row in
            AuditEntry(id: DBText.uuid(row["id"]) ?? UUID(), at: try parseTime(row["at"]), action: row["action"], detail: row["detail"])
        }
        let settings = try String.fetchOne(db, sql: "SELECT json FROM app_settings WHERE id = 1")
            .map { try DBJSON.decode(AppSettings.self, $0) } ?? AppSettings()
        return LocalContent(catalog: catalog, plan: try loadPlan(db), history: history, recommendations: recommendations,
                            audit: audit, settings: settings)
    }

    static func loadPlan(_ db: Database) throws -> WorkoutPlan? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, title, deleted_at FROM training_plans WHERE status = 'current'
            ORDER BY updated_at DESC, rowid DESC LIMIT 1
            """) else { return nil }
        let planId: String = row["id"]
        let workouts = try Row.fetchAll(db, sql: "SELECT * FROM planned_workouts WHERE plan_id = ? ORDER BY order_index, rowid", arguments: [planId])
            .map { workout -> PlannedWorkout in
                let workoutId: String = workout["id"]
                let exercises = try Row.fetchAll(
                    db, sql: "SELECT * FROM planned_exercises WHERE planned_workout_id = ? ORDER BY order_index, rowid", arguments: [workoutId]
                ).map { item in
                    PlannedExercise(
                        id: DBText.uuid(item["id"]) ?? UUID(), exerciseId: DBText.uuid(item["exercise_id"]) ?? UUID(),
                        setCount: item["set_count"], target: try DBJSON.decode(Prescription.self, item["target_json"]), restSeconds: item["rest_seconds"]
                    )
                }
                return PlannedWorkout(id: DBText.uuid(workoutId) ?? UUID(), weekday: workout["weekday"], title: workout["title"],
                                      focus: workout["focus"], exercises: exercises)
            }
        let deletedAt: String? = row["deleted_at"]
        return WorkoutPlan(deletedAt: try deletedAt.map(parseTime), id: DBText.uuid(planId) ?? UUID(), title: row["title"], workouts: workouts)
    }

    static func parseTime(_ text: String) throws -> Date {
        try DBJSON.decode(Date.self, "\"\(text)\"")
    }
}

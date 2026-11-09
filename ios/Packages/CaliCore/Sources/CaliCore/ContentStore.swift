import CaliDomain
import Foundation
import GRDB

/// Everything the app shows outside the workout player, read in one consistent snapshot.
public struct LocalContent: Equatable, Sendable {
    public var catalog: [Exercise]
    /// The `current` revision of every plan lineage, oldest first, including soft-deleted ones so history
    /// can still name them ("X (đã xoá)", MP-10).
    public var plans: [WorkoutPlan]
    /// Newest first.
    public var history: [CompletedSession]
    public var recommendations: [Recommendation]
    /// Newest first.
    public var audit: [AuditEntry]
    public var settings: AppSettings

    public init(
        catalog: [Exercise], plans: [WorkoutPlan], history: [CompletedSession], recommendations: [Recommendation],
        audit: [AuditEntry], settings: AppSettings
    ) {
        self.catalog = catalog
        self.plans = plans
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
    /// Each plan is upserted with its workouts / planned exercises replaced by exactly these, and its
    /// activation rows made to match `activations` (see `upsertPlan`).
    public var plans: [WorkoutPlan]
    /// Upserted by id.
    public var recommendations: [Recommendation]
    public var settings: AppSettings?
    /// `end_reason` of activations this change closes (CON-003: a closed activation records the lifecycle
    /// command that closed it). Written after the plans.
    public var activationEndReasons: [UUID: ActivationEndReason]
    /// The audit row of a user command. Its `id` is the `commandId`: when it already exists the whole
    /// change is skipped and `apply` returns `.duplicate` (repeat calls are safe, AGENTS rule 5).
    public var audit: AuditEntry?

    public init(
        exercises: [Exercise] = [], plans: [WorkoutPlan] = [], recommendations: [Recommendation] = [],
        settings: AppSettings? = nil, activationEndReasons: [UUID: ActivationEndReason] = [:], audit: AuditEntry? = nil
    ) {
        self.exercises = exercises
        self.plans = plans
        self.activationEndReasons = activationEndReasons
        self.recommendations = recommendations
        self.settings = settings
        self.audit = audit
    }
}

/// CON-003 `plan_activation.endReason`.
public enum ActivationEndReason: String, Codable, Sendable {
    case paused, completed, stopped, deleted
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

    /// Adds bundled exercises that this database has never had (a newer app version ships more), so an
    /// existing install gets them without a reset. Rows that exist, including the user's edits, are never
    /// touched. Returns how many were added.
    @discardableResult
    public func insertMissingExercises(_ exercises: [Exercise], now: Date = Date()) throws -> Int {
        try writer.immediateTransaction { db in
            guard try Self.isInitialized(db) else { return 0 }
            let existing = Set(try String.fetchAll(db, sql: "SELECT id FROM exercises"))
            let missing = exercises.filter { !existing.contains(DBText.id($0.id)) }
            if !missing.isEmpty { try Self.write(db, ContentChange(exercises: missing), now: now, timeZone: .current) }
            return missing.count
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

    /// The seed's starter plan is followed from today unless it brings its own activations (BR-10).
    static func writeSeed(_ db: Database, _ seed: ContentSeed, now: Date, timeZone: TimeZone) throws {
        var plan = seed.plan
        if plan.activations.isEmpty, plan.deletedAt == nil {
            plan.activations = [PlanActivation(id: UUID(), fromDate: LocalDate.today(at: now, in: timeZone), timezone: timeZone.identifier)]
        }
        if plan.createdAt == nil { plan.createdAt = now }
        try write(db, ContentChange(exercises: seed.catalog, plans: [plan], recommendations: seed.sampleRecommendations, settings: seed.settings),
                  now: now, timeZone: timeZone)
        for session in seed.sampleHistory {
            try insertHistory(db, session, source: "sample")
        }
    }

    static func write(_ db: Database, _ change: ContentChange, now: Date, timeZone: TimeZone) throws {
        try upsertExercises(db, change.exercises, now: now)
        for plan in change.plans {
            try upsertPlan(db, plan, now: now)
        }
        for (id, reason) in change.activationEndReasons {
            try db.execute(sql: "UPDATE plan_activations SET end_reason = ?, dirty = 1 WHERE id = ? AND to_date IS NOT NULL",
                           arguments: [reason.rawValue, DBText.id(id)])
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
    /// Activations: each one in `plan.activations` is upserted by id; a live row of the lineage that is not
    /// listed any more is cancelled (`deleted_at`, the tombstone sync sends as a delete). Lifecycle rules
    /// (which activation to open or close, I1/I2) are the caller's; the database only stores the result.
    static func upsertPlan(_ db: Database, _ plan: WorkoutPlan, now: Date) throws {
        let planId = DBText.id(plan.id)
        let lineageId = DBText.id(plan.lineageId)
        let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM training_plans WHERE id = ?)", arguments: [planId]) ?? false
        let discipline = try plan.primaryDiscipline?.rawValue ?? primaryDiscipline(db, plan)
        let fields: [(String, (any DatabaseValueConvertible)?)] = [
            ("title", plan.title), ("revision", plan.revision), ("kind", plan.kind.rawValue),
            ("event_date", plan.eventDate.map(DBText.date)), ("event_name", plan.eventName), ("primary_discipline", discipline),
            ("ended_at", plan.endedAt.map(DBText.time)), ("end_reason", plan.endReason?.rawValue), ("end_note", plan.endNote),
            ("archived_at", plan.archivedAt.map(DBText.time)), ("deleted_at", plan.deletedAt.map(DBText.time)),
        ]
        if exists {
            try db.execute(
                sql: "UPDATE training_plans SET \(fields.map { "\($0.0) = ?" }.joined(separator: ", ")), updated_at = ?, dirty = 1 WHERE id = ?",
                arguments: StatementArguments(fields.map(\.1) + [DBText.time(now), planId])
            )
        } else {
            let columns = ["id", "lineage_id", "status"] + fields.map(\.0) + ["created_at", "updated_at"]
            let values: [(any DatabaseValueConvertible)?] = [planId, lineageId, "current"] + fields.map(\.1)
                + [DBText.time(plan.createdAt ?? now), DBText.time(now)]
            try db.execute(
                sql: "INSERT INTO training_plans (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
                arguments: StatementArguments(values)
            )
        }

        let keepActivations = plan.activations.map { DBText.id($0.id) }
        try db.execute(
            sql: """
                UPDATE plan_activations SET deleted_at = ?, dirty = 1
                WHERE plan_lineage_id = ? AND deleted_at IS NULL AND id NOT IN (SELECT value FROM json_each(?))
                """,
            arguments: [DBText.time(now), lineageId, try DBJSON.encode(keepActivations)]
        )
        for activation in plan.activations {
            try db.execute(
                sql: """
                    INSERT INTO plan_activations (id, plan_lineage_id, from_date, to_date, timezone, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET from_date = excluded.from_date, to_date = excluded.to_date,
                        timezone = excluded.timezone, deleted_at = NULL,
                        end_reason = CASE WHEN excluded.to_date IS NULL THEN NULL ELSE plan_activations.end_reason END,
                        dirty = CASE WHEN plan_activations.from_date IS excluded.from_date AND plan_activations.to_date IS excluded.to_date
                                     THEN plan_activations.dirty ELSE 1 END
                    """,
                arguments: [DBText.id(activation.id), lineageId, DBText.date(activation.fromDate), activation.toDate.map(DBText.date),
                            activation.timezone, DBText.time(now)]
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
        case .distance, .duration: "running"
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
        let plans = try loadPlans(db)
        var lineageOfWorkout: [UUID: UUID] = [:]
        for plan in plans { for workout in plan.workouts { lineageOfWorkout[workout.id] = plan.lineageId } }
        let attributed = history.map { session -> CompletedSession in
            guard session.planLineageId == nil, let workoutId = session.plannedWorkoutId else { return session }
            var copy = session
            copy.planLineageId = lineageOfWorkout[workoutId]
            return copy
        }
        return LocalContent(catalog: catalog, plans: plans, history: attributed, recommendations: recommendations,
                            audit: audit, settings: settings)
    }

    static func loadPlans(_ db: Database) throws -> [WorkoutPlan] {
        try Row.fetchAll(db, sql: "SELECT * FROM training_plans WHERE status = 'current' ORDER BY created_at, rowid").map { row in
            let planId: String = row["id"]
            let lineageId: String = row["lineage_id"]
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
            let activations = try Row.fetchAll(db, sql: """
                SELECT id, from_date, to_date, timezone FROM plan_activations
                WHERE plan_lineage_id = ? AND deleted_at IS NULL ORDER BY from_date, rowid
                """, arguments: [lineageId]).compactMap { a -> PlanActivation? in
                    guard let id = DBText.uuid(a["id"]), let from = LocalDate(a["from_date"] as String) else { return nil }
                    return PlanActivation(id: id, fromDate: from, toDate: (a["to_date"] as String?).flatMap(LocalDate.init), timezone: a["timezone"])
                }
            func time(_ column: String) throws -> Date? { try (row[column] as String?).map(parseTime) }
            return WorkoutPlan(
                deletedAt: try time("deleted_at"), id: DBText.uuid(planId) ?? UUID(), title: row["title"], workouts: workouts,
                lineageId: DBText.uuid(lineageId), revision: row["revision"], kind: PlanKind(rawValue: row["kind"]) ?? .weekly,
                eventDate: (row["event_date"] as String?).flatMap(LocalDate.init), eventName: row["event_name"],
                primaryDiscipline: PlanDiscipline(rawValue: row["primary_discipline"]), endedAt: try time("ended_at"),
                endReason: (row["end_reason"] as String?).flatMap(PlanEndReason.init), endNote: row["end_note"],
                archivedAt: try time("archived_at"), createdAt: try time("created_at"), activations: activations
            )
        }
    }

    static func parseTime(_ text: String) throws -> Date {
        try DBJSON.decode(Date.self, "\"\(text)\"")
    }
}

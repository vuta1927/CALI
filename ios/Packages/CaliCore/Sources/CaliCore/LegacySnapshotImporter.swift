import CaliDomain
import Foundation
import GRDB

/// Moves the pre-IOS-001 JSON snapshot (`cali-poc.json`) into the GRDB store exactly once.
///
/// - Everything is written in one transaction together with a `legacy_imports` row; that row makes every
///   later run a no-op, so a crash or a second launch can never import twice.
/// - After COMMIT the file is renamed to `<name>.imported.json` and kept as the user's backup. A failed
///   rename is harmless: the `legacy_imports` row still blocks a second import.
/// - An unreadable or unsupported file is renamed to `<name>.unreadable-<unix>.json` (kept for inspection,
///   never overwritten) and nothing is written.
/// - docs/19 BR-10: the plan becomes a followed weekly plan whose activation starts on the day of the
///   first recorded session, or the snapshot creation day; a soft-deleted plan stays deleted with no
///   activation. The in-flight session (if any) is restored into `local_session_state` + `set_results`.
///
/// Imported rows are `dirty` and are not enqueued here; the sync run queues them (`ContentOutbox`) once there is an account.
public enum LegacySnapshotImporter {
    public static let source = "cali-poc.json"

    public struct Summary: Codable, Equatable, Sendable {
        public var exercises: Int
        public var usedFallbackCatalog: Bool
        public var plannedWorkouts: Int
        public var planDeleted: Bool
        public var history: Int
        public var recommendations: Int
        public var audit: Int
        public var restoredActiveSession: Bool
        public var restoredSetResults: Int
    }

    public enum Outcome: Equatable, Sendable {
        case noFile
        case alreadyImported
        case imported(Summary)
        /// The file could not be decoded (or has an unsupported schema) and was moved aside.
        case unreadable(movedTo: String?)
    }

    public static func importIfNeeded(
        fileURL: URL, writer: any DatabaseWriter, fallbackCatalog: [Exercise], now: Date = Date(), timeZone: TimeZone = .current
    ) throws -> Outcome {
        let alreadyImported = try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM legacy_imports WHERE source = ?)", arguments: [source]) ?? false
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return alreadyImported ? .alreadyImported : .noFile }
        if alreadyImported {
            moveAside(fileURL, suffix: "imported")
            return .alreadyImported
        }

        let data = try Data(contentsOf: fileURL)
        guard let snapshot = try? DomainJSON.makeDecoder().decode(PersistedSnapshot.self, from: data),
              snapshot.schemaVersion == PersistedSnapshot.currentSchema else {
            return .unreadable(movedTo: moveAside(fileURL, suffix: "unreadable-\(Int(now.timeIntervalSince1970))"))
        }

        let result: Outcome = try writer.immediateTransaction { db in
            guard try !(Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM legacy_imports WHERE source = ?)", arguments: [source]) ?? false) else {
                return .alreadyImported
            }
            let summary = try write(db, snapshot, fallbackCatalog: fallbackCatalog, now: now, timeZone: timeZone)
            try db.execute(
                sql: "INSERT INTO legacy_imports (source, imported_at, byte_count, summary_json) VALUES (?, ?, ?, ?)",
                arguments: [source, DBText.time(now), data.count, try DBJSON.encode(summary)]
            )
            return .imported(summary)
        }
        moveAside(fileURL, suffix: "imported")
        return result
    }

    static func write(_ db: Database, _ snapshot: PersistedSnapshot, fallbackCatalog: [Exercise], now: Date, timeZone: TimeZone) throws -> Summary {
        // Exercises referenced by the plan, history or the active session but missing from the snapshot
        // catalog come from the bundled catalog, so planned_exercises foreign keys always resolve.
        var catalog = snapshot.catalog ?? fallbackCatalog
        let known = Set(catalog.map(\.id))
        catalog += fallbackCatalog.filter { !known.contains($0.id) && referenced(snapshot).contains($0.id) }
        try ContentStore.upsertExercises(db, catalog, now: now)

        let firstSessionDay = (snapshot.history.filter { !$0.isSample }.map(\.startedAt) + [snapshot.active?.state.startedAt].compactMap { $0 })
            .min().map { LocalDate.today(at: $0, in: timeZone) }
        let activationFrom = firstSessionDay ?? LocalDate.today(at: snapshot.createdAt, in: timeZone)
        var plan = snapshot.plan
        if plan.deletedAt == nil, plan.activations.isEmpty {
            plan.activations = [PlanActivation(id: UUID(), fromDate: activationFrom, timezone: timeZone.identifier)]
        }
        if plan.createdAt == nil { plan.createdAt = snapshot.createdAt }
        try ContentStore.upsertPlan(db, plan, now: now)

        for session in snapshot.history {
            try ContentStore.insertHistory(db, session, source: session.isSample ? "sample" : "imported")
        }
        try ContentStore.upsertRecommendations(db, snapshot.recommendations)
        for entry in snapshot.audit where !(try ContentStore.auditExists(db, id: entry.id)) {
            try ContentStore.insertAudit(db, entry)
        }
        try db.execute(sql: "INSERT INTO app_settings (id, json) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
                       arguments: [try DBJSON.encode(snapshot.settings)])

        var restoredSets = 0
        if let active = snapshot.active, active.state.isActive,
           try String.fetchOne(db, sql: "SELECT session_id FROM local_session_state WHERE status = 'active'") == nil {
            try WorkoutCoordinator.insert(db, active.state, title: active.title)
            for record in active.records {
                try db.execute(
                    sql: """
                        INSERT INTO set_results (id, session_id, execution_id, set_index, status, record_json, confirmed_at, revision)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT DO NOTHING
                        """,
                    arguments: [DBText.id(record.setResultId), DBText.id(record.sessionId), DBText.id(record.key.executionId),
                                record.key.setIndex, record.status.rawValue, try DBJSON.encode(record), DBText.time(record.confirmedAt),
                                record.revision]
                )
                restoredSets += db.changesCount
            }
        }

        return Summary(
            exercises: catalog.count, usedFallbackCatalog: snapshot.catalog == nil,
            plannedWorkouts: snapshot.plan.workouts.count, planDeleted: snapshot.plan.deletedAt != nil,
            history: snapshot.history.count, recommendations: snapshot.recommendations.count, audit: snapshot.audit.count,
            restoredActiveSession: snapshot.active?.state.isActive == true && restoredSets == (snapshot.active?.records.count ?? 0),
            restoredSetResults: restoredSets
        )
    }

    private static func referenced(_ snapshot: PersistedSnapshot) -> Set<UUID> {
        var ids = Set(snapshot.plan.workouts.flatMap { $0.exercises.map(\.exerciseId) })
        ids.formUnion(snapshot.history.flatMap(\.exerciseIds))
        ids.formUnion(snapshot.active?.state.executions.map(\.exerciseId) ?? [])
        return ids
    }

    /// Renames `cali-poc.json` → `cali-poc.<suffix>.json` without overwriting; returns the new filename.
    @discardableResult
    private static func moveAside(_ url: URL, suffix: String) -> String? {
        let fm = FileManager.default
        let base = url.deletingPathExtension().lastPathComponent
        var target = url.deletingLastPathComponent().appendingPathComponent("\(base).\(suffix).json")
        var n = 1
        while fm.fileExists(atPath: target.path) {
            target = url.deletingLastPathComponent().appendingPathComponent("\(base).\(suffix)-\(n).json")
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
            return target.lastPathComponent
        } catch {
            return nil
        }
    }
}

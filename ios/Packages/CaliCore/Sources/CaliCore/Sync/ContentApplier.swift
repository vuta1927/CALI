import CaliDomain
import Foundation
import GRDB

/// IOS-007 slice 3b: writes pulled content (`sync_inbox`) into the local content tables.
///
/// A change is applied only when this device has no edit of that entity in flight (a dirty row, or a pending,
/// sending or conflicted mutation): the server's answer to our own mutation decides that case. A change that cannot be
/// applied yet (its parent plan or exercise is not here, a unique rule would break, the payload does not decode)
/// stays in the inbox and is tried again after the next page. Applied rows are marked `dirty = 0` with the server version,
/// so they are not echoed back.
enum ContentApplier {
    static let types: Set<String> = ["training_plan", "plan_activation", "plan_phase", "planned_workout", "planned_exercise", "plan_goal", "body_measurement"]

    /// Applies every applicable inbox row, repeating while a pass makes progress (parents arrive after children in a page).
    @discardableResult
    static func applyInbox(_ db: Database, now: Date) throws -> Int {
        var applied = 0
        for _ in 0..<6 {
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM sync_inbox ORDER BY received_at, rowid")
            var progress = 0
            for row in rows {
                let type: String = row["entity_type"]
                guard types.contains(type), let id = UUID(uuidString: row["entity_id"]) else { continue }
                let version: Int64 = row["server_version"]
                let known = try Int64.fetchOne(db, sql: "SELECT server_version FROM sync_versions WHERE entity_type = ? AND entity_id = ?", arguments: [type, DBText.id(id)]) ?? 0
                if version < known { // an acknowledged push of ours is newer than this change
                    try db.execute(sql: "DELETE FROM sync_inbox WHERE entity_type = ? AND entity_id = ?", arguments: [type, DBText.id(id)])
                    continue
                }
                guard try !hasLocalEdit(db, type: type, id: id),
                      let payload = try? DomainJSON.makeDecoder().decode(JSONValue.self, from: Data((row["payload_json"] as String).utf8)) else { continue }
                var applies = false
                do {
                    try db.inSavepoint {
                        applies = try apply(db, type: type, id: id, operation: row["operation"], version: version, payload: payload, now: now)
                        return applies ? .commit : .rollback
                    }
                } catch {
                    applies = false // the savepoint is rolled back; the row waits
                }
                if applies {
                    try db.execute(sql: "DELETE FROM sync_inbox WHERE entity_type = ? AND entity_id = ?", arguments: [type, DBText.id(id)])
                    progress += 1
                }
            }
            applied += progress
            if progress == 0 { break }
        }
        return applied
    }

    static func hasLocalEdit(_ db: Database, type: String, id: UUID) throws -> Bool {
        let dirty = try Bool.fetchOne(db, sql: "SELECT dirty = 1 FROM \(ContentOutbox.table(type)) WHERE id = ?", arguments: [DBText.id(id)]) ?? false
        if dirty { return true }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM sync_outbox WHERE entity_type = ? AND entity_id = ? AND state IN ('pending', 'sending', 'conflicted'))",
                                 arguments: [type, DBText.id(id)]) ?? false
    }

    // MARK: One entity

    /// `false` = cannot be applied now (nothing was written that matters: the caller rolls the savepoint back).
    static func apply(_ db: Database, type: String, id: UUID, operation: String, version: Int64, payload: JSONValue, now: Date) throws -> Bool {
        let table = ContentOutbox.table(type)
        let key = DBText.id(id)
        if operation == "delete" {
            if type == "planned_workout" || type == "planned_exercise" {
                try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [key])
            } else {
                let deletedAt = payload["deletedAt"]?.stringValue.flatMap(normalizeTime) ?? DBText.time(now)
                try db.execute(sql: "UPDATE \(table) SET deleted_at = ?, server_version = ?, dirty = 0 WHERE id = ? AND deleted_at IS NULL",
                               arguments: [deletedAt, version, key])
            }
            return true
        }
        guard case .object = payload else { return false }
        let ts = DBText.time(now)
        switch type {
        case "training_plan":
            guard let title = payload["title"]?.stringValue, let revision = payload["revision"]?.intValue, let status = payload["status"]?.stringValue else { return false }
            let lineage = payload["lineageId"]?.stringValue ?? key
            if status == "current" {
                // At most one current revision per lineage: the server's wins, unless the other one has an unsent edit.
                if try hasLocalEdit(db, type: type, id: id) { return false }
                let others = try Row.fetchAll(db, sql: "SELECT id FROM training_plans WHERE lineage_id = ? AND status = 'current' AND id != ?", arguments: [lineage, key])
                for other in others {
                    if let otherId = UUID(uuidString: other["id"]), try hasLocalEdit(db, type: type, id: otherId) { return false }
                }
                try db.execute(sql: "UPDATE training_plans SET status = 'superseded' WHERE lineage_id = ? AND status = 'current' AND id != ?", arguments: [lineage, key])
            }
            try db.execute(sql: """
                INSERT INTO training_plans (id, lineage_id, title, revision, status, parent_plan_id, kind, event_date, event_name, primary_discipline,
                    ended_at, end_reason, end_note, archived_at, created_at, updated_at, server_version, dirty)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, revision = excluded.revision, status = excluded.status,
                    parent_plan_id = excluded.parent_plan_id, kind = excluded.kind, event_date = excluded.event_date, event_name = excluded.event_name,
                    primary_discipline = excluded.primary_discipline, ended_at = excluded.ended_at, end_reason = excluded.end_reason,
                    end_note = excluded.end_note, archived_at = excluded.archived_at, deleted_at = NULL, updated_at = excluded.updated_at,
                    server_version = excluded.server_version, dirty = 0
                """, arguments: [key, lineage, title, revision, status, payload["parentPlanId"]?.stringValue, payload["kind"]?.stringValue ?? "weekly",
                                 payload["eventDate"]?.stringValue, payload["eventName"]?.stringValue, payload["primaryDiscipline"]?.stringValue ?? "calisthenics",
                                 payload["endedAt"]?.stringValue.flatMap(normalizeTime), payload["endReason"]?.stringValue, payload["endNote"]?.stringValue,
                                 payload["archivedAt"]?.stringValue.flatMap(normalizeTime), ts, ts, version])
        case "plan_activation":
            guard let lineage = payload["planLineageId"]?.stringValue, let from = payload["fromDate"]?.stringValue, let tz = payload["timezone"]?.stringValue else { return false }
            try db.execute(sql: """
                INSERT INTO plan_activations (id, plan_lineage_id, from_date, to_date, timezone, end_reason, created_at, server_version, dirty)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET plan_lineage_id = excluded.plan_lineage_id, from_date = excluded.from_date, to_date = excluded.to_date,
                    timezone = excluded.timezone, end_reason = excluded.end_reason, deleted_at = NULL, server_version = excluded.server_version, dirty = 0
                """, arguments: [key, lineage, from, payload["toDate"]?.stringValue, tz, payload["endReason"]?.stringValue, ts, version])
        case "plan_phase":
            guard let planId = payload["planId"]?.stringValue, try planExists(db, planId), let order = payload["orderIndex"]?.intValue,
                  let name = payload["name"]?.stringValue, let weeks = payload["weeks"]?.intValue else { return false }
            try db.execute(sql: """
                INSERT INTO plan_phases (id, plan_id, order_index, name, weeks, description, updated_at, server_version, dirty)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET plan_id = excluded.plan_id, order_index = excluded.order_index, name = excluded.name, weeks = excluded.weeks,
                    description = excluded.description, deleted_at = NULL, updated_at = excluded.updated_at, server_version = excluded.server_version, dirty = 0
                """, arguments: [key, planId, order, name, weeks, payload["description"]?.stringValue, ts, version])
        case "planned_workout":
            guard let planId = payload["planId"]?.stringValue, try planExists(db, planId), let weekday = payload["weekday"]?.intValue,
                  let order = payload["orderIndex"]?.intValue else { return false }
            // CON-011: absent or null ⇒ NULL (client default 60 s); out of range ⇒ row not applied.
            let restBetween = payload["restBetweenExercisesSeconds"]?.intValue
            if let restBetween, !(0...3600).contains(restBetween) { return false }
            try db.execute(sql: """
                INSERT INTO planned_workouts (id, plan_id, weekday, title, focus, order_index, rest_between_exercises_seconds, server_version, dirty)
                VALUES (?, ?, ?, ?, '', ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET plan_id = excluded.plan_id, weekday = excluded.weekday, title = excluded.title,
                    order_index = excluded.order_index, rest_between_exercises_seconds = excluded.rest_between_exercises_seconds,
                    server_version = excluded.server_version, dirty = 0
                """, arguments: [key, planId, weekday, payload["title"]?.stringValue ?? "", order, restBetween, version])
        case "planned_exercise":
            guard let workoutId = payload["plannedWorkoutId"]?.stringValue,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM planned_workouts WHERE id = ?)", arguments: [workoutId]) == true,
                  let exerciseId = payload["exerciseId"]?.stringValue,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM exercises WHERE id = ?)", arguments: [exerciseId]) == true,
                  let order = payload["orderIndex"]?.intValue, let sets = payload["setCount"]?.intValue, let rest = payload["restSeconds"]?.intValue,
                  let target = payload["target"], let targetData = try? SyncWireCoding.encoder().encode(target),
                  (try? DomainJSON.makeDecoder().decode(Prescription.self, from: targetData)) != nil else { return false }
            try db.execute(sql: """
                INSERT INTO planned_exercises (id, planned_workout_id, exercise_id, order_index, set_count, target_json, rest_seconds, server_version, dirty)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET planned_workout_id = excluded.planned_workout_id, exercise_id = excluded.exercise_id,
                    order_index = excluded.order_index, set_count = excluded.set_count, target_json = excluded.target_json,
                    rest_seconds = excluded.rest_seconds, server_version = excluded.server_version, dirty = 0
                """, arguments: [key, workoutId, exerciseId, order, sets, String(decoding: targetData, as: UTF8.self), rest, version])
        case "plan_goal":
            guard let data = try? SyncWireCoding.encoder().encode(payload), var goal = try? DomainJSON.makeDecoder().decode(PlanGoal.self, from: data) else { return false }
            let created = try String.fetchOne(db, sql: "SELECT created_at FROM plan_goals WHERE id = ?", arguments: [key]).flatMap(DBText.date)
            goal.createdAt = created ?? now
            goal.deletedAt = nil
            try db.execute(sql: """
                INSERT INTO plan_goals (id, plan_lineage_id, status, pinned, json, created_at, updated_at, server_version, dirty)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET plan_lineage_id = excluded.plan_lineage_id, status = excluded.status, pinned = excluded.pinned,
                    json = excluded.json, deleted_at = NULL, updated_at = excluded.updated_at, server_version = excluded.server_version, dirty = 0
                """, arguments: [key, DBText.id(goal.planLineageId), goal.status.rawValue, goal.pinned, try DBJSON.encode(goal), DBText.time(goal.createdAt ?? now), ts, version])
        case "body_measurement":
            guard payload["kind"]?.stringValue == "weight", let value = payload["value"]?.decimalValue, value >= 20, value <= 500,
                  let measured = payload["measuredAt"]?.stringValue.flatMap(normalizeTime) else { return false }
            let text = NSDecimalNumber(decimal: value).stringValue
            guard !text.contains(where: { $0 == "e" || $0 == "E" }), (text.split(separator: ".").dropFirst().first?.count ?? 0) <= 2 else { return false }
            try db.execute(sql: """
                INSERT INTO body_measurements (id, kind, value, measured_at, created_at, updated_at, server_version, dirty)
                VALUES (?, 'weight', ?, ?, ?, ?, ?, 0)
                ON CONFLICT(id) DO UPDATE SET value = excluded.value, measured_at = excluded.measured_at, deleted_at = NULL,
                    updated_at = excluded.updated_at, server_version = excluded.server_version, dirty = 0
                """, arguments: [key, text, measured, ts, ts, version])
        default:
            return false
        }
        return true
    }

    private static func planExists(_ db: Database, _ id: String) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM training_plans WHERE id = ?)", arguments: [id]) ?? false
    }

    private static func normalizeTime(_ text: String) -> String? {
        DomainJSON.date(text).map(DBText.time)
    }
}

extension JSONValue {
    var intValue: Int? {
        if case .number(let d) = self { return NSDecimalNumber(decimal: d).intValue }
        return nil
    }

    var decimalValue: Decimal? {
        if case .number(let d) = self { return d }
        return nil
    }
}

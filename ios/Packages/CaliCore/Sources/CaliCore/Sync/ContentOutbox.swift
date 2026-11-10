import CaliDomain
import Foundation
import GRDB

/// IOS-007 slice 3a: turns locally changed content rows (`dirty = 1`) into outbox mutations, in the same transaction
/// as the edit (`ContentStore.apply`) and again at the start of every sync run (so seeded, imported or earlier rows
/// reach the server once there is an account).
///
/// The payloads are the closed objects of `contracts/entity-payloads.schema.json`; fields the schema does not have
/// (`planned_workouts.focus`) do not leave the device. A row whose payload equals the last one queued for that entity
/// is not queued again, so re-saving a plan that did not change one workout sends nothing for it.
enum ContentOutbox {
    /// Parents before children, so one batch can carry a whole plan (server order is the order of `seq`).
    private static let order = ["training_plan", "plan_activation", "plan_phase", "planned_workout", "planned_exercise", "plan_goal", "body_measurement"]

    @discardableResult
    static func enqueueDirty(_ db: Database, now: Date) throws -> Int {
        var queued = 0
        for type in order {
            for item in try dirtyItems(db, type) {
                if try enqueue(db, type: type, id: item.id, action: item.action, payload: item.payload, now: now) { queued += 1 }
            }
        }
        return queued
    }

    /// A server acknowledgement clears `dirty` only when the row still says what was acknowledged; an edit made
    /// while the mutation was in flight keeps the row dirty and is queued by the next scan.
    static func acknowledge(_ db: Database, type: String, id: UUID, action: String, payload: JSONValue) throws {
        guard order.contains(type),
              let row = try Row.fetchOne(db, sql: "SELECT * FROM \(table(type)) WHERE id = ? AND dirty = 1", arguments: [DBText.id(id)]) else { return }
        let isDeleted = type != "planned_workout" && type != "planned_exercise" && (row["deleted_at"] as String?) != nil
        let current = isDeleted ? "delete" : "upsert"
        guard current == action else { return }
        if action == "upsert", try self.payload(type, row) != payload { return }
        try db.execute(sql: "UPDATE \(table(type)) SET dirty = 0 WHERE id = ?", arguments: [DBText.id(id)])
    }

    /// Delete mutations for rows the local write is about to remove for good (workouts and exercises have no
    /// tombstone column). Only entities the server may know about are sent.
    static func enqueueHardDeletes(_ db: Database, type: String, ids: [UUID], now: Date) throws {
        for id in ids where try wasEverQueued(db, type: type, id: id) {
            _ = try enqueue(db, type: type, id: id, action: "delete", payload: .object(["id": .string(DBText.id(id)), "deletedAt": .string(DBText.time(now))]), now: now)
        }
    }

    static func table(_ type: String) -> String {
        switch type {
        case "training_plan": "training_plans"
        case "plan_activation": "plan_activations"
        case "plan_phase": "plan_phases"
        case "planned_workout": "planned_workouts"
        case "planned_exercise": "planned_exercises"
        case "plan_goal": "plan_goals"
        default: "body_measurements"
        }
    }

    // MARK: Queueing

    private struct Item {
        var id: UUID
        var action: String
        var payload: JSONValue
    }

    private struct StoredEnvelope: Encodable {
        var mutationId: UUID
        var entityType: String
        var entityId: UUID
        var action: String
        var clientChangedAt: Date
        var payload: JSONValue
    }

    private static func wasEverQueued(_ db: Database, type: String, id: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM sync_versions WHERE entity_type = ?1 AND entity_id = ?2)
                OR EXISTS (SELECT 1 FROM sync_outbox WHERE entity_type = ?1 AND entity_id = ?2 AND payload_version = 2)
            """, arguments: [type, DBText.id(id)]) ?? false
    }

    @discardableResult
    private static func enqueue(_ db: Database, type: String, id: UUID, action: String, payload: JSONValue, now: Date) throws -> Bool {
        let last = try Row.fetchOne(db, sql: "SELECT action, json FROM sync_outbox WHERE entity_type = ? AND entity_id = ? AND payload_version = 2 ORDER BY seq DESC LIMIT 1",
                                    arguments: [type, DBText.id(id)])
        if action == "delete", last == nil, try !wasEverQueued(db, type: type, id: id) { return false } // the server never heard of it
        if let last, (last["action"] as String) == action,
           let old = try? DomainJSON.makeDecoder().decode(StoredPayload.self, from: Data((last["json"] as String).utf8)), old.payload == payload {
            return false
        }
        let mutationId = UUID()
        let envelope = StoredEnvelope(mutationId: mutationId, entityType: type, entityId: id, action: action, clientChangedAt: now, payload: payload)
        try db.execute(sql: """
            INSERT INTO sync_outbox (mutation_id, entity_type, entity_id, action, base_version, json, created_at, payload_version)
            VALUES (?, ?, ?, ?, NULL, ?, ?, 2)
            """, arguments: [DBText.id(mutationId), type, DBText.id(id), action, try DBJSON.encode(envelope), DBText.time(now)])
        return true
    }

    private struct StoredPayload: Decodable { var payload: JSONValue }

    // MARK: Row → payload

    private static func dirtyItems(_ db: Database, _ type: String) throws -> [Item] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table(type)) WHERE dirty = 1 ORDER BY rowid")
        return try rows.compactMap { row in
            guard let id = UUID(uuidString: row["id"]) else { return nil }
            let deleted: String? = type == "planned_workout" || type == "planned_exercise" ? nil : row["deleted_at"]
            if let deleted {
                return Item(id: id, action: "delete", payload: .object(["id": .string(DBText.id(id)), "deletedAt": .string(deleted)]))
            }
            return Item(id: id, action: "upsert", payload: try payload(type, row))
        }
    }

    private static func put(_ object: inout [String: JSONValue], _ key: String, _ value: String?) {
        if let value { object[key] = .string(value) }
    }

    static func payload(_ type: String, _ row: Row) throws -> JSONValue {
        var o: [String: JSONValue] = ["id": .string(row["id"])]
        func int(_ column: String) -> JSONValue { .number(Decimal(row[column] as Int)) }
        switch type {
        case "training_plan":
            o["title"] = .string(row["title"]); o["revision"] = int("revision"); o["status"] = .string(row["status"])
            o["lineageId"] = .string(row["lineage_id"]); o["kind"] = .string(row["kind"]); o["primaryDiscipline"] = .string(row["primary_discipline"])
            put(&o, "parentPlanId", row["parent_plan_id"]); put(&o, "eventDate", row["event_date"]); put(&o, "eventName", row["event_name"])
            put(&o, "endedAt", row["ended_at"]); put(&o, "endReason", row["end_reason"]); put(&o, "endNote", row["end_note"]); put(&o, "archivedAt", row["archived_at"])
        case "plan_activation":
            o["planLineageId"] = .string(row["plan_lineage_id"]); o["fromDate"] = .string(row["from_date"]); o["timezone"] = .string(row["timezone"])
            put(&o, "toDate", row["to_date"]); put(&o, "endReason", row["end_reason"])
        case "plan_phase":
            o["planId"] = .string(row["plan_id"]); o["orderIndex"] = int("order_index"); o["name"] = .string(row["name"]); o["weeks"] = int("weeks")
            put(&o, "description", row["description"])
        case "planned_workout":
            o["planId"] = .string(row["plan_id"]); o["weekday"] = int("weekday"); o["title"] = .string(row["title"]); o["orderIndex"] = int("order_index")
        case "planned_exercise":
            o["plannedWorkoutId"] = .string(row["planned_workout_id"]); o["exerciseId"] = .string(row["exercise_id"]); o["orderIndex"] = int("order_index")
            o["setCount"] = int("set_count"); o["restSeconds"] = int("rest_seconds")
            o["target"] = try DomainJSON.makeDecoder().decode(JSONValue.self, from: Data((row["target_json"] as String).utf8))
        case "plan_goal":
            guard case .object(let stored) = try DomainJSON.makeDecoder().decode(JSONValue.self, from: Data((row["json"] as String).utf8)) else { return .null }
            let allowed: Set = ["id", "planLineageId", "title", "indicatorId", "exerciseId", "baseline", "target", "scopePhaseId", "unlockAfterGoalId", "status", "achievedAt", "pinned", "note"]
            o = stored.filter { allowed.contains($0.key) && $0.value != .null }
            o["id"] = .string(row["id"]); o["status"] = .string(row["status"]); o["pinned"] = .bool(row["pinned"] as Bool)
        default: // body_measurement
            o["kind"] = .string(row["kind"]); o["measuredAt"] = .string(row["measured_at"])
            o["value"] = .number(Decimal(string: row["value"] as String, locale: Locale(identifier: "en_US_POSIX")) ?? 0)
        }
        return .object(o)
    }
}

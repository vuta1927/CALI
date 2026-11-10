import CaliDomain
import Foundation
import GRDB

/// IOS-007 slice 3b: the user's decisions on changes the server did not take (docs/08 §5). Nothing here is automatic and
/// nothing merges two versions.
///
/// - `keepLocal`: send the same change again as a new mutation based on the server's current version.
/// - `useServer`: write the server's version into the local content and drop this device's pending changes of that entity.
/// - `retry` (rejected): send again as a new mutation, e.g. after pausing a plan for `active_plan_limit`.
/// - `dismiss` (rejected): stop showing it; the local row keeps what the user entered.
public struct SyncConflictResolver: Sendable {
    let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) { self.writer = writer }

    public enum ResolverError: Error, Equatable { case notFound, notResolvableThisWay }

    /// Only content entities can take the server's version; sessions and sets are never overwritten from the server.
    public static func canUseServer(entityType: String) -> Bool { ContentApplier.types.contains(entityType) }

    public func keepLocal(seq: Int64) throws {
        try requeue(seq: seq, from: "conflicted", rebaseOnServerVersion: true)
    }

    public func retry(seq: Int64) throws {
        try requeue(seq: seq, from: "rejected", rebaseOnServerVersion: false)
    }

    public func dismiss(seq: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE sync_outbox SET state = 'dismissed' WHERE seq = ? AND state = 'rejected'", arguments: [seq])
            guard db.changesCount == 1 else { throw ResolverError.notFound }
        }
    }

    public func useServer(seq: Int64, now: Date = Date()) throws {
        try writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_outbox WHERE seq = ? AND state = 'conflicted'", arguments: [seq]) else { throw ResolverError.notFound }
            let type: String = row["entity_type"]
            guard Self.canUseServer(entityType: type), let id = UUID(uuidString: row["entity_id"]),
                  let text: String = row["server_entity_json"], let version: Int64 = row["server_version"],
                  let entity = try? DomainJSON.makeDecoder().decode(JSONValue.self, from: Data(text.utf8)) else { throw ResolverError.notResolvableThisWay }
            guard try ContentApplier.apply(db, type: type, id: id, operation: "upsert", version: version, payload: entity, now: now) else { throw ResolverError.notResolvableThisWay }
            try db.execute(sql: "UPDATE sync_outbox SET state = 'discarded' WHERE entity_type = ? AND entity_id = ? AND state IN ('pending', 'sending', 'conflicted')",
                           arguments: [type, DBText.id(id)])
            try Self.rememberVersion(db, type: type, id: id, version: version)
        }
    }

    private func requeue(seq: Int64, from state: String, rebaseOnServerVersion: Bool) throws {
        try writer.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_outbox WHERE seq = ? AND state = ?", arguments: [seq, state]) else { throw ResolverError.notFound }
            let type: String = row["entity_type"]
            guard let id = UUID(uuidString: row["entity_id"]), case .object(var envelope) = try DomainJSON.makeDecoder().decode(JSONValue.self, from: Data((row["json"] as String).utf8)) else { throw ResolverError.notFound }
            if rebaseOnServerVersion, let version = row["server_version"] as Int64? { try Self.rememberVersion(db, type: type, id: id, version: version) }
            let known = try Int.fetchOne(db, sql: "SELECT server_version FROM sync_versions WHERE entity_type = ? AND entity_id = ?", arguments: [type, DBText.id(id)]) ?? 0
            let mutationId = UUID()
            envelope["mutationId"] = .string(DBText.id(mutationId))
            // Same position in the queue (same seq), so later changes of the entity still go after it.
            try db.execute(sql: """
                UPDATE sync_outbox SET mutation_id = ?, json = ?, base_version = ?, state = 'pending', attempts = 0, next_attempt_at = NULL,
                    last_attempt_at = NULL, error_code = NULL, last_error = NULL, server_entity_json = NULL WHERE seq = ?
                """, arguments: [DBText.id(mutationId), try DBJSON.encode(JSONValue.object(envelope)), known, seq])
        }
    }

    private static func rememberVersion(_ db: Database, type: String, id: UUID, version: Int64) throws {
        try db.execute(sql: """
            INSERT INTO sync_versions (entity_type, entity_id, server_version) VALUES (?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET server_version = MAX(server_version, excluded.server_version)
            """, arguments: [type, DBText.id(id), version])
    }
}

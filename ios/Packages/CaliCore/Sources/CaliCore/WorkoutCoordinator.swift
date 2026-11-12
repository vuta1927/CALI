import CaliDomain
import Foundation
import GRDB

/// Stored answer to a command, replayed verbatim when the same `commandId` arrives again.
public struct CommandOutcome: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Reducer accepted the command; state, set results and outbox were written atomically.
        case applied
        /// Reducer (or a coordinator precondition such as `stale_view`) rejected it; nothing written but this row.
        case rejected
        /// The targeted set already had a canonical result (different `commandId`, same set): idempotent no-op
        /// that points at the existing `set_results.id` (docs/03 §7 #1).
        case alreadyResolved = "already_resolved"
    }

    public var commandId: UUID
    /// `CommandKind` raw value (`confirm_set`, `extend_rest`, …).
    public var kind: String
    public var status: Status
    public var sessionId: UUID?
    public var revision: Int?
    public var phase: String?
    public var phaseDeadlineAt: Date?
    /// `DomainError.code` or a coordinator code (`stale_view`, `needs_app`, `no_session`).
    public var errorCode: String?
    public var setResultIds: [UUID]
    public var processedAt: Date

    public init(
        commandId: UUID, kind: String, status: Status, sessionId: UUID?, revision: Int?, phase: String?,
        phaseDeadlineAt: Date?, errorCode: String?, setResultIds: [UUID], processedAt: Date
    ) {
        self.commandId = commandId
        self.kind = kind
        self.status = status
        self.sessionId = sessionId
        self.revision = revision
        self.phase = phase
        self.phaseDeadlineAt = phaseDeadlineAt
        self.errorCode = errorCode
        self.setResultIds = setResultIds
        self.processedAt = processedAt
    }
}

/// Result of `WorkoutCoordinator.handle`. Returned after COMMIT: the caller then publishes state,
/// reschedules notifications and updates the Live Activity (docs/03 §6, side effects outside the transaction).
public struct HandleResult: Sendable {
    public var outcome: CommandOutcome
    /// `true` when the `commandId` was already in `processed_commands` and nothing was written.
    public var replayed: Bool
    /// Durable session state after the command (or current state for a rejection/replay).
    public var state: SessionState?
    /// Domain events of THIS application only (empty on replay or rejection).
    public var events: [DomainEvent]
    /// The reducer error of THIS rejection, for user-facing messages (nil on success and on replay, where
    /// only `outcome.errorCode` is stored).
    public var error: DomainError? = nil
}

public enum CoordinatorError: Error, Equatable, Sendable {
    /// `UPDATE … WHERE revision = expected` touched no row. Cannot happen under BEGIN IMMEDIATE with a
    /// single writer; kept as the docs/03 §6 optimistic guard. The whole transaction rolls back.
    case revisionConflict(sessionId: UUID, expectedRevision: Int)
    /// Reducer output failed `SessionState.invariantViolations`; nothing is persisted.
    case invariantViolation([String])
}

/// Row counts for tests and the POC diagnostics screen.
public struct StoreCounts: Equatable, Sendable {
    public var sessions: Int
    public var setResults: Int
    public var outbox: Int
    public var processedCommands: Int
}

public struct OutboxEntry: Equatable, Sendable {
    public var seq: Int64
    public var mutationId: UUID
    public var entityType: String
    public var entityId: UUID
    public var action: String
    public var baseVersion: Int?
    public var state: String
}

/// Single writer for workout state (ADR-013): the app UI and the `LiveActivityIntent` (which runs in the
/// app process) both call this one coordinator. Every command runs in ONE `BEGIN IMMEDIATE` transaction:
///
///     dedupe commandId → load session → reduce → save state (expected revision) → set_results
///     → outbox → processed_commands → COMMIT
///
/// so a double tap, a retried intent or a crash between steps can never produce a second set result.
/// The widget extension never opens the database; it only renders `ContentState`.
public final class WorkoutCoordinator: Sendable {
    public let writer: any DatabaseWriter
    public let clock: any Clock

    public init(writer: any DatabaseWriter, clock: any Clock = SystemClock()) {
        self.writer = writer
        self.clock = clock
    }

    // MARK: Commands

    /// Applies a user command to the active session (or creates one). Safe to call repeatedly with the
    /// same command: the second call returns the stored outcome with `replayed == true`.
    /// `sessionTitle` is stored with a session that `createSession` creates and copied to its history row.
    public func handle(_ command: Command, sessionTitle: String? = nil) throws -> HandleResult {
        try writer.immediateTransaction { db in
            if let replay = try self.replay(db, commandId: command.commandId) { return replay }
            let state = try Self.loadActive(db)
            return try self.apply(db, state: state, command: command, now: self.clock.now(), sessionTitle: sessionTitle)
        }
    }

    /// A whole session entered by hand (IOS-014 race result, MP-07): `commands` must create, run and finish
    /// one session. They run in one transaction with `audit`; if any is refused nothing is written and
    /// the refusing result is returned. Repeating the call (same first commandId) replays its outcome.
    public func recordSession(_ commands: [Command], sessionTitle: String, audit: AuditEntry? = nil) throws -> HandleResult {
        guard let first = commands.first, case .createSession = first else {
            preconditionFailure("recordSession needs createSession first")
        }
        do {
            return try writer.immediateTransaction { db in
                if let replay = try self.replay(db, commandId: first.commandId) { return replay }
                var state = try Self.loadActive(db)
                var last: HandleResult?
                let now = self.clock.now()
                for command in commands {
                    let result = try self.apply(db, state: state, command: command, now: now, sessionTitle: sessionTitle)
                    guard result.outcome.status == .applied else { throw ManualSessionRefused(result: result) }
                    state = result.state
                    last = result
                }
                guard let last, last.state?.phase.isTerminal == true else {
                    preconditionFailure("recordSession commands must end the session")
                }
                if let audit { try ContentStore.insertAudit(db, audit) }
                return last
            }
        } catch let refused as ManualSessionRefused {
            return refused.result
        }
    }

    private struct ManualSessionRefused: Error {
        let result: HandleResult
    }

    /// Entry point for Live Activity buttons. The `commandId` is derived from (session, rendered revision,
    /// action), so taps on the same rendered snapshot deduplicate; a snapshot older than the durable state
    /// is rejected as `stale_view` instead of acting on a set the user is no longer looking at.
    public func handleLiveActivityAction(sessionId: UUID, renderedRevision: Int, action: LiveActivityAction) throws -> HandleResult {
        let commandId = CommandIdentity.liveActivityCommandId(sessionId: sessionId, revision: renderedRevision, action: action)
        let kind: CommandKind = switch action {
        case .extendRest30: .extendRest
        case .confirmCurrentSet: .confirmSet
        }
        return try writer.immediateTransaction { db in
            if let replay = try self.replay(db, commandId: commandId) { return replay }
            let now = self.clock.now()
            guard let state = try Self.load(db, sessionId: sessionId) else {
                return try self.reject(db, commandId: commandId, kind: kind, code: "no_session", state: nil, now: now)
            }
            guard state.revision == renderedRevision else {
                return try self.reject(db, commandId: commandId, kind: kind, code: "stale_view", state: state, now: now)
            }
            switch Self.command(for: action, commandId: commandId, state: state) {
            case .success(let command):
                return try self.apply(db, state: state, command: command, now: now)
            case .failure(let refusal):
                return try self.reject(db, commandId: commandId, kind: kind, code: refusal.code, state: state, now: now)
            }
        }
    }

    /// Derives `countdownElapsed` / `targetDeadlineReached` / `restExpired` from persisted deadlines. Call it
    /// from executable callbacks only (foreground tick, scene active, intent run) — never from a notification
    /// delivery callback (AGENTS safety rules). Returns `nil` when there is no active session.
    @discardableResult
    public func reconcile(
        previousNow: Date?, monotonicElapsed: TimeInterval?, acknowledgeClockJump: Bool = false, policy: ReconcilePolicy = .standard
    ) throws -> ReconcileResult? {
        try writer.immediateTransaction { db in
            guard let state = try Self.loadActive(db) else { return nil }
            let result = WorkoutReducer.reconcile(
                state, now: self.clock.now(), previousNow: previousNow, monotonicElapsed: monotonicElapsed,
                acknowledgeClockJump: acknowledgeClockJump, policy: policy
            )
            if result.changed {
                try Self.checkInvariants(result.state)
                try Self.update(db, from: state, to: result.state)
            }
            return result
        }
    }

    // MARK: Queries

    public func activeState() throws -> SessionState? {
        try writer.read { db in try Self.loadActive(db) }
    }

    public func state(sessionId: UUID) throws -> SessionState? {
        try writer.read { db in try Self.load(db, sessionId: sessionId) }
    }

    public func processedOutcome(commandId: UUID) throws -> CommandOutcome? {
        try writer.read { db in try Self.outcome(db, commandId: commandId) }
    }

    /// Most recent `processed_commands` outcomes, newest first (device-gate evidence screen).
    public func recentOutcomes(limit: Int = 20) throws -> [CommandOutcome] {
        try writer.read { db in
            try String.fetchAll(
                db, sql: "SELECT response_json FROM processed_commands ORDER BY processed_at DESC, rowid DESC LIMIT ?",
                arguments: [max(0, limit)]
            ).map { try Self.decode(CommandOutcome.self, $0) }
        }
    }

    public func counts() throws -> StoreCounts {
        try writer.read { db in
            StoreCounts(
                sessions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM local_session_state") ?? 0,
                setResults: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM set_results WHERE deleted_at IS NULL") ?? 0,
                outbox: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox") ?? 0,
                processedCommands: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM processed_commands") ?? 0
            )
        }
    }

    public func setResults(sessionId: UUID) throws -> [SetRecord] {
        try writer.read { db in
            let rows = try String.fetchAll(
                db, sql: "SELECT record_json FROM set_results WHERE session_id = ? AND deleted_at IS NULL ORDER BY revision, rowid",
                arguments: [DBText.id(sessionId)]
            )
            return try rows.map { try Self.decode(SetRecord.self, $0) }
        }
    }

    public func outboxEntries() throws -> [OutboxEntry] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sync_outbox ORDER BY seq").map { row in
                let mutationId: String = row["mutation_id"]
                let entityId: String = row["entity_id"]
                return OutboxEntry(
                    seq: row["seq"],
                    mutationId: UUID(uuidString: mutationId) ?? UUID(),
                    entityType: row["entity_type"],
                    entityId: UUID(uuidString: entityId) ?? UUID(),
                    action: row["action"],
                    baseVersion: row["base_version"],
                    state: row["state"]
                )
            }
        }
    }

    // MARK: Transaction pipeline

    private func replay(_ db: Database, commandId: UUID) throws -> HandleResult? {
        guard let outcome = try Self.outcome(db, commandId: commandId) else { return nil }
        let state = try outcome.sessionId.flatMap { try Self.load(db, sessionId: $0) }
        return HandleResult(outcome: outcome, replayed: true, state: state, events: [])
    }

    private func apply(_ db: Database, state: SessionState?, command: Command, now: Date, sessionTitle: String? = nil) throws -> HandleResult {
        let transition: Transition
        switch WorkoutReducer.reduce(state, command, now: now) {
        case .failure(let error):
            var outcome = Self.outcome(for: command.commandId, kind: command.kind, status: .rejected, state: state, code: error.code, now: now)
            if case .duplicateSetResolution(let existing) = error {
                outcome.status = .alreadyResolved
                outcome.setResultIds = [existing.setResultId]
            }
            if case .nothingToReopen = error {
                // IOS-023: the skipped sets were already reopened (double tap / second "Hoàn tác"): idempotent no-op.
                outcome.status = .alreadyResolved
            }
            try Self.record(db, outcome)
            return HandleResult(outcome: outcome, replayed: false, state: state, events: [], error: error)
        case .success(let t):
            transition = t
        }

        let next = transition.state
        try Self.checkInvariants(next)
        let creating = state == nil || state?.sessionId != next.sessionId
        if creating {
            try Self.insert(db, next, title: sessionTitle ?? "")
            let zone = TimeZone.current
            let localDate = SyncPayloads.localDate(next.startedAt, timeZone: zone)
            try db.execute(sql: "UPDATE local_session_state SET local_date = ?, timezone = ? WHERE session_id = ?",
                           arguments: [localDate, zone.identifier, DBText.id(next.sessionId)])
            try Self.appendOutbox(db, commandId: command.commandId, entityType: "workout_session", entityId: next.sessionId,
                                  baseVersion: 0, changedAt: now, payload: SyncPayloads.WorkoutSession(next, localDate: localDate, timezone: zone.identifier))
            for (index, spec) in next.executions.enumerated() {
                try Self.appendOutbox(db, commandId: command.commandId, entityType: "exercise_execution", entityId: spec.id,
                                      baseVersion: 0, changedAt: now, payload: SyncPayloads.ExerciseExecution(sessionId: next.sessionId, spec: spec, orderIndex: index))
            }
        } else if let state {
            try Self.update(db, from: state, to: next)
        }

        // IOS-023: tombstone retracted results BEFORE inserting new ones (a reopened set may be redone later in another
        // transaction; the partial unique index only covers live rows). The delete mutation uses this command's id,
        // so its mutationId differs from the original skip's upsert (no `mutation_id_reused`); baseVersion nil lets
        // the sync engine rebase it on the acknowledged server version, and per-entity ordering sends it after the
        // upsert if that is still queued (docs/08 §7, ADR-025).
        for id in transition.retractedSetResultIds {
            try db.execute(sql: "UPDATE set_results SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL",
                           arguments: [DBText.time(now), DBText.id(id)])
            guard db.changesCount == 1 else { throw CoordinatorError.invariantViolation(["retracted set result \(id) not live"]) }
            try Self.appendOutbox(db, commandId: command.commandId, entityType: "set_result", entityId: id, action: "delete",
                                  baseVersion: nil, changedAt: now, payload: SyncPayloads.Tombstone(id: id, deletedAt: now))
        }

        for record in transition.setRecords {
            try db.execute(
                sql: """
                    INSERT INTO set_results (id, session_id, execution_id, set_index, status, record_json, confirmed_at, revision)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    DBText.id(record.setResultId), DBText.id(record.sessionId), DBText.id(record.key.executionId),
                    record.key.setIndex, record.status.rawValue, try Self.encode(record), DBText.time(record.confirmedAt), record.revision,
                ]
            )
            try Self.appendOutbox(db, commandId: command.commandId, entityType: "set_result", entityId: record.setResultId,
                                  baseVersion: 0, changedAt: now, payload: SyncPayloads.SetResult(record))
        }

        if !creating, next.phase.isTerminal, state?.phase.isTerminal == false {
            // baseVersion is nil here: the sync engine rebases it to the server version it acknowledged (docs/08 §3).
            let stored = try Row.fetchOne(db, sql: "SELECT local_date, timezone FROM local_session_state WHERE session_id = ?", arguments: [DBText.id(next.sessionId)])
            let zone = (stored?["timezone"] as String?).flatMap(TimeZone.init(identifier:)) ?? TimeZone.current
            let localDate = (stored?["local_date"] as String?) ?? SyncPayloads.localDate(next.startedAt, timeZone: zone)
            try Self.appendOutbox(db, commandId: command.commandId, entityType: "workout_session", entityId: next.sessionId,
                                  baseVersion: nil, changedAt: now, payload: SyncPayloads.WorkoutSession(next, localDate: localDate, timezone: zone.identifier))
        }
        if next.phase.isTerminal, state?.phase.isTerminal != true {
            try Self.insertHistory(db, finished: next)
        }

        var outcome = Self.outcome(for: command.commandId, kind: command.kind, status: .applied, state: next, code: nil, now: now)
        outcome.setResultIds = transition.setRecords.map(\.setResultId)
        try Self.record(db, outcome)
        return HandleResult(outcome: outcome, replayed: false, state: next, events: transition.events)
    }

    private func reject(_ db: Database, commandId: UUID, kind: CommandKind, code: String, state: SessionState?, now: Date) throws -> HandleResult {
        let outcome = Self.outcome(for: commandId, kind: kind, status: .rejected, state: state, code: code, now: now)
        try Self.record(db, outcome)
        return HandleResult(outcome: outcome, replayed: false, state: state, events: [])
    }

    // MARK: Live Activity command mapping

    struct Refusal: Error {
        var code: String
    }

    static func command(for action: LiveActivityAction, commandId: UUID, state: SessionState) -> Result<Command, Refusal> {
        switch action {
        case .extendRest30:
            // Phase is checked by the reducer (`invalid_transition` outside resting).
            return .success(.extendRest(ExtendRest(commandId: commandId, seconds: 30)))
        case .confirmCurrentSet:
            // Never infer completion: only confirm a draft the app already produced while executing, with a
            // domain-suggested duration, for targets whose only actual is a duration.
            guard state.phase == .awaitingResult, let draft = state.pendingResult, let suggested = draft.suggestedActualMs,
                  let spec = state.currentExecution, spec.id == draft.key.executionId else {
                return .failure(Refusal(code: "needs_app"))
            }
            var confirm = ConfirmSet(
                commandId: commandId,
                setResultId: CommandIdentity.setResultId(sessionId: state.sessionId, executionId: draft.key.executionId, setIndex: draft.key.setIndex),
                executionId: draft.key.executionId,
                setIndex: draft.key.setIndex
            )
            switch spec.target {
            case .staticHold: confirm.actualHoldMs = suggested
            case .interval: confirm.actualWorkMs = suggested
            // Load (CON-006) needs the user's reps and kg: never filled in from the Lock Screen.
            // Running (CON-004) is entered by hand in the app: distance and time are never inferred.
            case .reps, .timedReps, .skillAttempt, .load, .distance, .duration: return .failure(Refusal(code: "needs_app"))
            }
            return .success(.confirmSet(confirm))
        }
    }

    // MARK: Row helpers

    private static func loadActive(_ db: Database) throws -> SessionState? {
        try String.fetchOne(db, sql: "SELECT state_json FROM local_session_state WHERE status = 'active'")
            .map { try decode(SessionState.self, $0) }
    }

    private static func load(_ db: Database, sessionId: UUID) throws -> SessionState? {
        try String.fetchOne(db, sql: "SELECT state_json FROM local_session_state WHERE session_id = ?", arguments: [DBText.id(sessionId)])
            .map { try decode(SessionState.self, $0) }
    }

    static func insert(_ db: Database, _ s: SessionState, title: String) throws {
        try db.execute(
            sql: """
                INSERT INTO local_session_state (session_id, status, phase, revision, phase_deadline_at, state_json, updated_at, title)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [DBText.id(s.sessionId), s.status.rawValue, s.phase.rawValue, s.revision,
                        s.phaseDeadlineAt.map(DBText.time), try encode(s), DBText.time(s.updatedAt), title]
        )
    }

    /// History row for a session that just became terminal, written in the same transaction.
    private static func insertHistory(_ db: Database, finished s: SessionState) throws {
        let title = try String.fetchOne(db, sql: "SELECT title FROM local_session_state WHERE session_id = ?", arguments: [DBText.id(s.sessionId)]) ?? ""
        let records = try String.fetchAll(
            db, sql: "SELECT record_json FROM set_results WHERE session_id = ? AND deleted_at IS NULL ORDER BY revision, rowid", arguments: [DBText.id(s.sessionId)]
        ).map { try decode(SetRecord.self, $0) }
        let session = CompletedSession(
            id: s.sessionId, title: title, plannedWorkoutId: s.plannedWorkoutId, startedAt: s.startedAt,
            finishedAt: s.finishedAt ?? s.abandonedAt ?? s.updatedAt, status: s.status,
            exerciseIds: s.executions.map(\.exerciseId), plannedSetCount: s.totalPlannedSets,
            sets: records.map(LoggedSet.init(record:)), isSample: false,
            planLineageId: try s.plannedWorkoutId.flatMap { workoutId in
                try String.fetchOne(db, sql: """
                    SELECT p.lineage_id FROM planned_workouts w JOIN training_plans p ON p.id = w.plan_id WHERE w.id = ?
                    """, arguments: [DBText.id(workoutId)]).flatMap(DBText.uuid)
            }
        )
        try ContentStore.insertHistory(db, session, source: "live")
    }

    /// Title stored with the active session (empty when it was created without one).
    public func activeSessionTitle() throws -> String? {
        try writer.read { db in try String.fetchOne(db, sql: "SELECT title FROM local_session_state WHERE status = 'active'") }
    }

    private static func update(_ db: Database, from old: SessionState, to s: SessionState) throws {
        try db.execute(
            sql: """
                UPDATE local_session_state
                SET status = ?, phase = ?, revision = ?, phase_deadline_at = ?, state_json = ?, updated_at = ?
                WHERE session_id = ? AND revision = ?
                """,
            arguments: [s.status.rawValue, s.phase.rawValue, s.revision, s.phaseDeadlineAt.map(DBText.time),
                        try encode(s), DBText.time(s.updatedAt), DBText.id(s.sessionId), old.revision]
        )
        guard db.changesCount == 1 else {
            throw CoordinatorError.revisionConflict(sessionId: s.sessionId, expectedRevision: old.revision)
        }
    }

    private static func appendOutbox<P: Encodable>(
        _ db: Database, commandId: UUID, entityType: String, entityId: UUID, action: String = "upsert", baseVersion: Int?, changedAt: Date, payload: P
    ) throws {
        let mutationId = CommandIdentity.mutationId(commandId: commandId, entityType: entityType, entityId: entityId)
        let envelope = OutboxEnvelope(mutationId: mutationId, entityType: entityType, entityId: entityId, action: action,
                                      baseVersion: baseVersion, clientChangedAt: changedAt, payload: payload)
        try db.execute(
            sql: """
                INSERT INTO sync_outbox (mutation_id, entity_type, entity_id, action, base_version, json, created_at, payload_version)
                VALUES (?, ?, ?, ?, ?, ?, ?, 2)
                """,
            arguments: [DBText.id(mutationId), entityType, DBText.id(entityId), action, baseVersion, try encode(envelope), DBText.time(changedAt)]
        )
    }

    private static func outcome(_ db: Database, commandId: UUID) throws -> CommandOutcome? {
        try String.fetchOne(db, sql: "SELECT response_json FROM processed_commands WHERE command_id = ?", arguments: [DBText.id(commandId)])
            .map { try decode(CommandOutcome.self, $0) }
    }

    private static func record(_ db: Database, _ outcome: CommandOutcome) throws {
        try db.execute(
            sql: "INSERT INTO processed_commands (command_id, kind, response_json, processed_at) VALUES (?, ?, ?, ?)",
            arguments: [DBText.id(outcome.commandId), outcome.kind, try encode(outcome), DBText.time(outcome.processedAt)]
        )
    }

    private static func outcome(for commandId: UUID, kind: CommandKind, status: CommandOutcome.Status, state: SessionState?, code: String?, now: Date) -> CommandOutcome {
        CommandOutcome(
            commandId: commandId, kind: kind.rawValue, status: status, sessionId: state?.sessionId, revision: state?.revision,
            phase: state?.phase.rawValue, phaseDeadlineAt: state?.phaseDeadlineAt, errorCode: code, setResultIds: [], processedAt: now
        )
    }

    private static func checkInvariants(_ s: SessionState) throws {
        let violations = s.invariantViolations
        guard violations.isEmpty else { throw CoordinatorError.invariantViolation(violations) }
    }

    static func encode<T: Encodable>(_ value: T) throws -> String { try DBJSON.encode(value) }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try DBJSON.decode(type, text) }
}

private struct OutboxEnvelope<Payload: Encodable>: Encodable {
    var mutationId: UUID
    var entityType: String
    var entityId: UUID
    var action: String
    var baseVersion: Int?
    var clientChangedAt: Date
    var payload: Payload
}

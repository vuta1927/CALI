import Foundation

/// Discriminator of a user command. Raw value is the JSON `type` used in CON-002 fixtures and
/// suitable for `processed_commands`.
public enum CommandKind: String, Codable, Sendable, CaseIterable {
    case createSession = "create_session"
    case startSet = "start_set"
    case pause
    case resume
    case stopSet = "stop_set"
    case confirmSet = "confirm_set"
    case extendRest = "extend_rest"
    case readyNext = "ready_next"
    case skipSet = "skip_set"
    case finishSession = "finish_session"
    case abandonSession = "abandon_session"
}

// MARK: - Payloads (one per row of the docs/03 §4 transition table that is a user command)

public struct CreateSession: Codable, Equatable, Sendable {
    public var commandId: UUID
    public var sessionId: UUID
    public var plannedWorkoutId: UUID?
    public var executions: [ExecutionSpec]

    public init(commandId: UUID, sessionId: UUID, plannedWorkoutId: UUID? = nil, executions: [ExecutionSpec]) {
        self.commandId = commandId
        self.sessionId = sessionId
        self.plannedWorkoutId = plannedWorkoutId
        self.executions = executions
    }
}

public struct StartSet: Codable, Equatable, Sendable {
    public var commandId: UUID
    /// Pre-countdown length from Settings (default 3, `0` = countdown disabled ⇒ straight to exercising).
    public var countdownSeconds: Int

    public init(commandId: UUID, countdownSeconds: Int = 3) {
        self.commandId = commandId
        self.countdownSeconds = countdownSeconds
    }
}

/// Payload-less commands (`Pause`, `Resume`, `StopSet`, `ReadyNext`, `FinishSession`).
public struct SimpleCommand: Codable, Equatable, Sendable {
    public var commandId: UUID
    public init(commandId: UUID) { self.commandId = commandId }
}

public struct ConfirmSet: Codable, Equatable, Sendable {
    public var commandId: UUID
    /// Client-generated `set_results.id`.
    public var setResultId: UUID
    /// Which set the UI is confirming; must equal the current set (guards against stale UI / double tap).
    public var executionId: UUID
    public var setIndex: Int
    /// `.completed` or `.failed` (skill attempt success/fail). `.skipped` must use `SkipSet`.
    public var status: SetStatus
    public var actualReps: Int?
    public var actualHoldMs: Int64?
    public var actualWorkMs: Int64?
    public var actualRestMs: Int64?
    public var rpe: Int?
    public var note: String?
    /// CON-006 (ADR-062): kilograms lifted; only for a load target, required when it is one.
    public var actualLoadKg: Decimal?
    /// CON-004: running segment values entered by hand (pace is derived, never sent).
    public var actualDistanceMeters: Int?
    public var actualDurationSeconds: Int?
    /// CON-008 (ADR-045): the `pain` criterion; only recorded, never interpreted.
    public var painReported: Bool?
    /// CON-008 (ADR-067): the config version the form was built from and the extra values by criterion id;
    /// both or neither.
    public var criteriaVersion: Int?
    public var criteria: [String: CriteriaValue]?

    public init(
        commandId: UUID, setResultId: UUID, executionId: UUID, setIndex: Int, status: SetStatus = .completed,
        actualReps: Int? = nil, actualHoldMs: Int64? = nil, actualWorkMs: Int64? = nil, actualRestMs: Int64? = nil,
        rpe: Int? = nil, note: String? = nil, actualLoadKg: Decimal? = nil,
        actualDistanceMeters: Int? = nil, actualDurationSeconds: Int? = nil,
        painReported: Bool? = nil, criteriaVersion: Int? = nil, criteria: [String: CriteriaValue]? = nil
    ) {
        self.painReported = painReported
        self.criteriaVersion = criteriaVersion
        self.criteria = criteria
        self.commandId = commandId
        self.setResultId = setResultId
        self.executionId = executionId
        self.setIndex = setIndex
        self.status = status
        self.actualReps = actualReps
        self.actualHoldMs = actualHoldMs
        self.actualWorkMs = actualWorkMs
        self.actualRestMs = actualRestMs
        self.rpe = rpe
        self.note = note
        self.actualLoadKg = actualLoadKg
        self.actualDistanceMeters = actualDistanceMeters
        self.actualDurationSeconds = actualDurationSeconds
    }

    public var key: SetKey { SetKey(executionId: executionId, setIndex: setIndex) }
}

public struct ExtendRest: Codable, Equatable, Sendable {
    public var commandId: UUID
    public var seconds: Int

    public init(commandId: UUID, seconds: Int = 30) {
        self.commandId = commandId
        self.seconds = seconds
    }
}

public struct SkipSet: Codable, Equatable, Sendable {
    public var commandId: UUID
    public var setResultId: UUID
    public var executionId: UUID
    public var setIndex: Int
    public var reason: String?

    public init(commandId: UUID, setResultId: UUID, executionId: UUID, setIndex: Int, reason: String? = nil) {
        self.commandId = commandId
        self.setResultId = setResultId
        self.executionId = executionId
        self.setIndex = setIndex
        self.reason = reason
    }

    public var key: SetKey { SetKey(executionId: executionId, setIndex: setIndex) }
}

public struct AbandonSession: Codable, Equatable, Sendable {
    public var commandId: UUID
    public var reason: String?

    public init(commandId: UUID, reason: String? = nil) {
        self.commandId = commandId
        self.reason = reason
    }
}

// MARK: - Command

/// Every user command of the docs/03 §4 transition table. `CountdownElapsed` and `restExpired` /
/// `targetDeadlineReached` are *not* commands: they are derived by `WorkoutReducer.reconcile` when the app
/// is executing, never by timers or notification callbacks.
///
/// Each command carries a `commandId`; deduplication by `commandId` (`processed_commands`) is the
/// coordinator's job (CaliCore). The reducer additionally rejects a second result for the same set.
public enum Command: Equatable, Sendable {
    case createSession(CreateSession)
    case startSet(StartSet)
    case pause(SimpleCommand)
    case resume(SimpleCommand)
    case stopSet(SimpleCommand)
    case confirmSet(ConfirmSet)
    case extendRest(ExtendRest)
    case readyNext(SimpleCommand)
    case skipSet(SkipSet)
    case finishSession(SimpleCommand)
    case abandonSession(AbandonSession)

    public var kind: CommandKind {
        switch self {
        case .createSession: .createSession
        case .startSet: .startSet
        case .pause: .pause
        case .resume: .resume
        case .stopSet: .stopSet
        case .confirmSet: .confirmSet
        case .extendRest: .extendRest
        case .readyNext: .readyNext
        case .skipSet: .skipSet
        case .finishSession: .finishSession
        case .abandonSession: .abandonSession
        }
    }

    public var commandId: UUID {
        switch self {
        case .createSession(let c): c.commandId
        case .startSet(let c): c.commandId
        case .pause(let c), .resume(let c), .stopSet(let c), .readyNext(let c), .finishSession(let c): c.commandId
        case .confirmSet(let c): c.commandId
        case .extendRest(let c): c.commandId
        case .skipSet(let c): c.commandId
        case .abandonSession(let c): c.commandId
        }
    }
}

/// Flat JSON: `{ "type": "start_set", "commandId": "…", "countdownSeconds": 3 }`.
extension Command: Codable {
    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: TypeKey.self).decode(CommandKind.self, forKey: .type)
        switch kind {
        case .createSession: self = .createSession(try CreateSession(from: decoder))
        case .startSet: self = .startSet(try StartSet(from: decoder))
        case .pause: self = .pause(try SimpleCommand(from: decoder))
        case .resume: self = .resume(try SimpleCommand(from: decoder))
        case .stopSet: self = .stopSet(try SimpleCommand(from: decoder))
        case .confirmSet: self = .confirmSet(try ConfirmSet(from: decoder))
        case .extendRest: self = .extendRest(try ExtendRest(from: decoder))
        case .readyNext: self = .readyNext(try SimpleCommand(from: decoder))
        case .skipSet: self = .skipSet(try SkipSet(from: decoder))
        case .finishSession: self = .finishSession(try SimpleCommand(from: decoder))
        case .abandonSession: self = .abandonSession(try AbandonSession(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .createSession(let c): try c.encode(to: encoder)
        case .startSet(let c): try c.encode(to: encoder)
        case .pause(let c), .resume(let c), .stopSet(let c), .readyNext(let c), .finishSession(let c): try c.encode(to: encoder)
        case .confirmSet(let c): try c.encode(to: encoder)
        case .extendRest(let c): try c.encode(to: encoder)
        case .skipSet(let c): try c.encode(to: encoder)
        case .abandonSession(let c): try c.encode(to: encoder)
        }
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(kind, forKey: .type)
    }
}

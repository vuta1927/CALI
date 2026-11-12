import Foundation

/// Prescribed target snapshot stored with every set result (docs/03 §4: "snapshots prescribed target,
/// actual metrics and catalog version").
public struct PrescribedSnapshot: Codable, Equatable, Hashable, Sendable {
    public var plannedExerciseId: UUID?
    public var exerciseId: UUID
    public var catalogVersion: Int
    public var target: Prescription
    public var restSeconds: Int
    public var setCount: Int

    public init(_ spec: ExecutionSpec) {
        plannedExerciseId = spec.plannedExerciseId
        exerciseId = spec.exerciseId
        catalogVersion = spec.catalogVersion
        target = spec.target
        restSeconds = spec.restSeconds
        setCount = spec.setCount
    }
}

/// Actual metrics as entered/confirmed by the user. Never inferred from a deadline.
public struct SetActuals: Codable, Equatable, Hashable, Sendable {
    public var reps: Int?
    public var holdMs: Int64?
    public var workMs: Int64?
    public var restMs: Int64?
    public var rpe: Int?
    public var note: String?
    /// CON-006: `set_results.actual_load_kg` (kg).
    public var loadKg: Decimal?
    /// CON-004: `set_results.distance_meters` / `duration_seconds`, entered by hand.
    public var distanceMeters: Int?
    public var durationSeconds: Int?
    /// CON-004: where running values came from; only `manual` until Apple Health (ADR-043).
    public var source: ResultSource?
    /// CON-008: `set_results.pain_reported`, and the criteria config version + values the set was entered with.
    public var painReported: Bool?
    public var criteriaVersion: Int?
    public var criteria: [String: CriteriaValue]?

    public init(reps: Int? = nil, holdMs: Int64? = nil, workMs: Int64? = nil, restMs: Int64? = nil, rpe: Int? = nil, note: String? = nil,
                loadKg: Decimal? = nil, distanceMeters: Int? = nil, durationSeconds: Int? = nil, source: ResultSource? = nil,
                painReported: Bool? = nil, criteriaVersion: Int? = nil, criteria: [String: CriteriaValue]? = nil) {
        self.painReported = painReported
        self.criteriaVersion = criteriaVersion
        self.criteria = criteria
        self.reps = reps
        self.holdMs = holdMs
        self.workMs = workMs
        self.restMs = restMs
        self.rpe = rpe
        self.note = note
        self.loadKg = loadKg
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.source = source
    }

    public static let none = SetActuals()

    /// Pace of a running result, when both values allow one (CON-004: derived, never stored).
    public var pace: Pace? {
        guard let distanceMeters, let durationSeconds else { return nil }
        return try? Pace.derive(distanceMeters: distanceMeters, durationSeconds: durationSeconds).get()
    }
}

/// `set_result.source` (CON-004). Omitted in a payload means `manual`.
public enum ResultSource: String, Codable, Sendable {
    case manual
}

/// Everything the coordinator needs to insert one `set_results` row + outbox mutation.
public struct SetRecord: Codable, Equatable, Hashable, Sendable {
    public var setResultId: UUID
    public var sessionId: UUID
    public var key: SetKey
    public var status: SetStatus
    public var prescribed: PrescribedSnapshot
    public var actual: SetActuals
    /// How the exercising phase ended (nil for sets skipped before they started).
    public var endReason: SetEndReason?
    public var skipReason: String?
    /// UTC instant of the user's confirmation (`set_result.confirmedAt`).
    public var confirmedAt: Date
    /// New canonical result ⇒ 1. Edits (out of scope for I1a) bump it.
    public var revision: Int
}

/// Facts the coordinator must persist / react to after the transaction commits.
public enum DomainEvent: Equatable, Sendable {
    case sessionCreated(sessionId: UUID, startedAt: Date)
    case phaseChanged(from: Phase, to: Phase)
    /// `phaseDeadlineAt` changed (including to `nil`): cancel previous reminders, schedule new ones.
    case deadlineChanged(phase: Phase, deadline: Date?)
    case setConfirmed(SetRecord)
    case setSkipped(SetRecord)
    /// A pre-countdown was found elapsed (or implausible) without the app executing; back to `ready`,
    /// the user must start again (UX §5 "do not auto-start if app is inactive").
    case countdownLapsed(lateMs: Int64)
    /// IOS-021: auto-advance was on but the rest was found over too late (app not executing); back to `ready`,
    /// the user starts the set.
    case restLapsed(lateMs: Int64)
    case sessionFinished(finishedAt: Date)
    case sessionAbandoned(at: Date, reason: String?)

    /// Stable code used in CON-002 fixtures.
    public var code: String {
        switch self {
        case .sessionCreated: "session_created"
        case .phaseChanged: "phase_changed"
        case .deadlineChanged: "deadline_changed"
        case .setConfirmed: "set_confirmed"
        case .setSkipped: "set_skipped"
        case .countdownLapsed: "countdown_lapsed"
        case .restLapsed: "rest_lapsed"
        case .sessionFinished: "session_finished"
        case .sessionAbandoned: "session_abandoned"
        }
    }
}

/// Result of an accepted transition.
public struct Transition: Equatable, Sendable {
    public var state: SessionState
    public var events: [DomainEvent]

    public init(state: SessionState, events: [DomainEvent]) {
        self.state = state
        self.events = events
    }

    /// Set records to insert in the same transaction.
    public var setRecords: [SetRecord] {
        events.compactMap {
            switch $0 {
            case .setConfirmed(let r), .setSkipped(let r): r
            default: nil
            }
        }
    }
}

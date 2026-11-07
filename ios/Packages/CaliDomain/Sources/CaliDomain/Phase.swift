import Foundation

/// Persistent phase of a `WorkoutSession` (docs/03 §4). Raw values match
/// `contracts/entity-payloads.schema.json` (`workout_session_payload.phase`) and `db/001_initial.sql`.
public enum Phase: String, Codable, Sendable, CaseIterable {
    case ready
    case preCountdown = "pre_countdown"
    case exercising
    case paused
    case awaitingResult = "awaiting_result"
    case resting
    case reviewingSummary = "reviewing_summary"
    case completed
    case abandoned

    /// `completed` and `abandoned` accept no further commands.
    public var isTerminal: Bool { self == .completed || self == .abandoned }
}

/// Session lifecycle status (`workout_session_payload.status`).
/// `reviewing_summary` keeps `status == .active`; only `FinishSession` sets `.completed`.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case active
    case completed
    case abandoned
}

/// Status of a canonical set result (`set_result_payload.status`).
public enum SetStatus: String, Codable, Sendable, CaseIterable {
    case completed
    case failed
    case skipped
}

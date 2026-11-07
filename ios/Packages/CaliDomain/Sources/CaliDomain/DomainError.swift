import Foundation

/// Why a command was rejected. A rejected command leaves the state untouched (no revision bump).
public enum DomainError: Error, Equatable, Sendable {
    /// The command is not allowed in the current phase (docs/03 §4 precondition column).
    case invalidTransition(from: Phase, command: CommandKind)
    /// Session is completed/abandoned.
    case sessionNotActive(SessionStatus)
    /// `CreateSession` while another session is active.
    case activeSessionExists(sessionId: UUID)
    /// Non-create command without a loaded session.
    case noSession
    /// The set already has a canonical result. The coordinator should return the prior result
    /// (idempotent double-tap, docs/03 §7 #1) — never insert or count a second row.
    case duplicateSetResolution(existing: ResolvedSet)
    /// Command targets a set other than the current one (stale UI / widget).
    case setMismatch(expected: SetKey, received: SetKey)
    case validationFailed([ValidationIssue])
    /// `FinishSession` with `now < startedAt` (wall clock went backwards): would violate
    /// `finished_at >= started_at`; coordinator must run clock reconciliation first.
    case timestampBeforeSessionStart

    /// Stable code used in CON-002 fixtures.
    public var code: String {
        switch self {
        case .invalidTransition: "invalid_transition"
        case .sessionNotActive: "session_not_active"
        case .activeSessionExists: "active_session_exists"
        case .noSession: "no_session"
        case .duplicateSetResolution: "duplicate_set_resolution"
        case .setMismatch: "set_mismatch"
        case .validationFailed: "validation_failed"
        case .timestampBeforeSessionStart: "timestamp_before_session_start"
        }
    }
}

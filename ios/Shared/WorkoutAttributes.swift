import ActivityKit
import Foundation

/// Live Activity payload for an active workout session.
///
/// Compiled into BOTH the app (which will start/update the Activity, POC-001) and the
/// widget extension (which only renders it, ADR-013). Keep the two copies identical by
/// keeping this file the single source.
///
/// `ContentState` is a small display snapshot only (docs/05 §2). It is never the source
/// of truth for workout state: the app's durable session state is.
struct WorkoutAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var sessionId: UUID
        var exerciseShortName: String
        var phase: Phase
        /// 1-based set number as displayed ("Set 2/4").
        var setIndex: Int
        var setCount: Int
        var targetSeconds: Int
        var phaseStartUtc: Date
        var phaseEndUtc: Date
        /// Set while the phase timer is frozen (PAUSED); the countdown renders as of this instant.
        var pausedTimeUtc: Date?
        /// Session revision this snapshot was rendered from; lets stale updates be ignored.
        var revision: Int
    }

    /// Mirrors the session `phase` enum in contracts/entity-payloads.schema.json.
    enum Phase: String, Codable, Hashable, Sendable, CaseIterable {
        case ready
        case preCountdown = "pre_countdown"
        case exercising
        case awaitingResult = "awaiting_result"
        case resting
        case paused
        case reviewingSummary = "reviewing_summary"
        case completed
        case abandoned

        /// Phases whose Lock Screen / Dynamic Island view shows a system-rendered countdown.
        var showsCountdown: Bool {
            switch self {
            case .preCountdown, .exercising, .resting, .paused:
                return true
            case .ready, .awaitingResult, .reviewingSummary, .completed, .abandoned:
                return false
            }
        }
    }
}

extension WorkoutAttributes.ContentState {
    /// Range for `Text(timerInterval:pauseTime:countsDown:showsHours:)`, or `nil` when the
    /// current phase has no countdown. Never inverted: `a...b` traps at runtime when `a > b`,
    /// and a clock change or bad snapshot must not crash the widget.
    /// Reps / skill sets have no target duration (`targetSeconds == 0`): nothing to count down.
    var isOpenEndedSet: Bool {
        targetSeconds == 0 && (phase == .exercising || phase == .paused)
    }

    var countdownInterval: ClosedRange<Date>? {
        guard phase.showsCountdown, !isOpenEndedSet else { return nil }
        let end = max(phaseStartUtc, phaseEndUtc)
        return phaseStartUtc...end
    }
}

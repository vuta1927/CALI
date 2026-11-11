import CaliDomain
import Foundation

/// The cues of CON-010 this build plays (docs/02 §5.1).
public enum VoiceCueKey: String, CaseIterable, Sendable, Codable {
    case countdownStart = "countdown.start"
    case holdDone = "hold.done"
    case timedHalfway = "timed.halfway"
    case timedDone = "timed.done"
    case restEnding10s = "rest.ending_10s"
    case restDone = "rest.done"
    case restDoneNextExercise = "rest.done_next_exercise"
    case sessionDone = "session.done"

    /// Fallback sentence when no pack has been downloaded yet (same as fixtures/voice_cues.vi-VN.json v1); used only as
    /// notification text, never as audio.
    public var defaultText: String {
        switch self {
        case .countdownStart: "Ba, hai, một, bắt đầu."
        case .holdDone: "Đủ thời gian. Có thể thả."
        case .timedHalfway: "Đã được một nửa."
        case .timedDone: "Hết giờ. Dừng lại."
        case .restEnding10s: "Còn mười giây nghỉ."
        case .restDone: "Hết giờ nghỉ. Vào set tiếp theo."
        case .restDoneNextExercise: "Hết giờ nghỉ. Chuyển sang bài mới."
        case .sessionDone: "Xong buổi tập. Làm tốt lắm."
        }
    }
}

/// One cue due at a UTC instant.
public struct PlannedVoiceCue: Equatable, Hashable, Sendable {
    public var key: VoiceCueKey
    public var at: Date
    /// True for the cue at the phase deadline: it replaces the sound of the deadline reminder instead of adding one.
    public var isPhaseDeadline: Bool

    public init(key: VoiceCueKey, at: Date, isPhaseDeadline: Bool = false) {
        self.key = key
        self.at = at
        self.isPhaseDeadline = isPhaseDeadline
    }
}

/// When each cue is due for a session state (docs/02 §5.1). Pure: derived from the persisted UTC deadlines only, so a
/// changed deadline (+30 s, pause, resume, skip) gives a new plan and the caller replaces the old one. A cue never changes
/// workout state (ADR-078).
public enum VoiceCuePlan {
    /// Halfway and "10 s left" only for phases long enough for them to help.
    public static let minimumSecondsForMidCue = 20

    public static func cues(for s: SessionState) -> [PlannedVoiceCue] {
        guard let execution = s.currentExecution else { return [] }
        switch s.phase {
        case .preCountdown:
            guard let start = s.phaseStartedAt else { return [] }
            return [PlannedVoiceCue(key: .countdownStart, at: start)]
        case .exercising:
            guard let deadline = s.phaseDeadlineAt, let target = execution.target.targetDurationSeconds else { return [] }
            var cues: [PlannedVoiceCue] = []
            if target >= minimumSecondsForMidCue {
                cues.append(PlannedVoiceCue(key: .timedHalfway, at: deadline.addingTimeInterval(-Double(target) / 2)))
            }
            let done: VoiceCueKey = if case .staticHold = execution.target { .holdDone } else { .timedDone }
            cues.append(PlannedVoiceCue(key: done, at: deadline, isPhaseDeadline: true))
            return cues
        case .resting:
            guard let deadline = s.phaseDeadlineAt else { return [] }
            var cues: [PlannedVoiceCue] = []
            if execution.restSeconds >= minimumSecondsForMidCue {
                cues.append(PlannedVoiceCue(key: .restEnding10s, at: deadline.addingTimeInterval(-10)))
            }
            // The rest leads to the set that `currentSetIndex` already names; set 1 means a new exercise.
            let next: VoiceCueKey = s.currentSetIndex == 1 && s.currentExecutionIndex > 0 ? .restDoneNextExercise : .restDone
            cues.append(PlannedVoiceCue(key: next, at: deadline, isPhaseDeadline: true))
            return cues
        case .completed:
            guard let finished = s.finishedAt else { return [] }
            return [PlannedVoiceCue(key: .sessionDone, at: finished)]
        default:
            return []
        }
    }
}

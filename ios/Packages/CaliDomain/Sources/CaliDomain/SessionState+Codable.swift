import Foundation

// Codable tolerant of states persisted by older builds (local `state_json`, never on the wire).
extension SessionState {
    enum CodingKeys: String, CodingKey {
        case sessionId, plannedWorkoutId, status, phase, revision, executions, currentExecutionIndex, currentSetIndex
        case startedAt, updatedAt, finishedAt, abandonedAt, abandonReason, phaseStartedAt, phaseDeadlineAt, countdownSeconds
        case accumulatedExerciseMs, pausedAt, pausedRemainingMs, pendingResult, resolvedSets, transitionRestSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionId: try c.decode(UUID.self, forKey: .sessionId),
            plannedWorkoutId: try c.decodeIfPresent(UUID.self, forKey: .plannedWorkoutId),
            status: try c.decode(SessionStatus.self, forKey: .status),
            phase: try c.decode(Phase.self, forKey: .phase),
            revision: try c.decode(Int.self, forKey: .revision),
            executions: try c.decode([ExecutionSpec].self, forKey: .executions),
            currentExecutionIndex: try c.decode(Int.self, forKey: .currentExecutionIndex),
            currentSetIndex: try c.decode(Int.self, forKey: .currentSetIndex),
            startedAt: try c.decode(Date.self, forKey: .startedAt),
            updatedAt: try c.decode(Date.self, forKey: .updatedAt),
            finishedAt: try c.decodeIfPresent(Date.self, forKey: .finishedAt),
            abandonedAt: try c.decodeIfPresent(Date.self, forKey: .abandonedAt),
            abandonReason: try c.decodeIfPresent(String.self, forKey: .abandonReason),
            phaseStartedAt: try c.decodeIfPresent(Date.self, forKey: .phaseStartedAt),
            phaseDeadlineAt: try c.decodeIfPresent(Date.self, forKey: .phaseDeadlineAt),
            countdownSeconds: try c.decodeIfPresent(Int.self, forKey: .countdownSeconds),
            accumulatedExerciseMs: try c.decodeIfPresent(Int64.self, forKey: .accumulatedExerciseMs) ?? 0,
            pausedAt: try c.decodeIfPresent(Date.self, forKey: .pausedAt),
            pausedRemainingMs: try c.decodeIfPresent(Int64.self, forKey: .pausedRemainingMs),
            pendingResult: try c.decodeIfPresent(ResultDraft.self, forKey: .pendingResult),
            resolvedSets: try c.decodeIfPresent([ResolvedSet].self, forKey: .resolvedSets) ?? [],
            // IOS-022: absent in states written before the transition rest existed.
            transitionRestSeconds: try c.decodeIfPresent(Int.self, forKey: .transitionRestSeconds) ?? DomainLimits.defaultTransitionRestSeconds
        )
    }
}

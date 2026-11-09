import Foundation

/// Exercise type (docs/03 §3). Raw values match the contract `target.kind`.
public enum ExerciseType: String, Codable, Sendable, CaseIterable {
    case staticHold = "static_hold"
    case reps
    case timedReps = "timed_reps"
    case interval
    case skillAttempt = "skill_attempt"
    /// CON-006 (ADR-062): weight x reps, kilograms only (ADR-046).
    case load
}

/// Planned target of one set. JSON shape matches `contracts/entity-payloads.schema.json#/$defs/target`,
/// e.g. `{ "kind": "static_hold", "holdSeconds": 12 }`.
public enum Prescription: Equatable, Hashable, Sendable {
    case staticHold(holdSeconds: Int)
    case reps(repMin: Int, repMax: Int)
    case timedReps(timeSeconds: Int)
    /// One work bout per set; `restSeconds` is the intra-interval rest carried for display/snapshot only.
    /// Rest *between sets* always comes from `ExecutionSpec.restSeconds` (CON-002 question Q8).
    case interval(workSeconds: Int, restSeconds: Int)
    case skillAttempt(attempts: Int)
    /// CON-006 (ADR-062): one set = `reps` at `loadKg` (kg, at most 2 decimals). Volume is derived, never stored.
    case load(reps: Int, loadKg: Decimal)

    public var type: ExerciseType {
        switch self {
        case .staticHold: .staticHold
        case .reps: .reps
        case .timedReps: .timedReps
        case .interval: .interval
        case .skillAttempt: .skillAttempt
        case .load: .load
        }
    }

    /// Duration of the exercising phase that gets a UTC deadline, or `nil` when the set is open-ended
    /// (reps / skill attempts end only by explicit user stop). A deadline is a *prompt*, never proof (ADR-009).
    public var targetDurationSeconds: Int? {
        switch self {
        case .staticHold(let s): s
        case .timedReps(let s): s
        case .interval(let work, _): work
        case .reps, .skillAttempt, .load: nil
        }
    }

    /// Validation per docs/03 §3 and the contract schema.
    public func validate() -> [ValidationIssue] {
        switch self {
        case .staticHold(let hold):
            return [ValidationIssue.range("target.holdSeconds", hold, DomainLimits.holdSeconds)].compactMap { $0 }
        case .reps(let lo, let hi):
            var issues = [ValidationIssue.min("target.repMin", lo, 1), ValidationIssue.min("target.repMax", hi, 1)].compactMap { $0 }
            if issues.isEmpty, lo > hi {
                issues.append(ValidationIssue(field: "target.repMax", reason: .inconsistent, detail: "repMax \(hi) < repMin \(lo)"))
            }
            return issues
        case .timedReps(let s):
            return [ValidationIssue.min("target.timeSeconds", s, 1)].compactMap { $0 }
        case .interval(let work, let rest):
            // ADR-019: workSeconds >= 1 and restSeconds >= 1 (docs/03 §3, JSON Schema and OpenAPI agree).
            return [ValidationIssue.min("target.workSeconds", work, 1), ValidationIssue.min("target.restSeconds", rest, 1)].compactMap { $0 }
        case .skillAttempt(let attempts):
            return [ValidationIssue.min("target.attempts", attempts, 1)].compactMap { $0 }
        case .load(let reps, let kg):
            return [ValidationIssue.range("target.reps", reps, DomainLimits.loadReps), ValidationIssue.loadKg("target.loadKg", kg)].compactMap { $0 }
        }
    }
}

extension Prescription: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, holdSeconds, repMin, repMax, timeSeconds, workSeconds, restSeconds, attempts, reps, loadKg
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(ExerciseType.self, forKey: .kind) {
        case .staticHold: self = .staticHold(holdSeconds: try c.decode(Int.self, forKey: .holdSeconds))
        case .reps: self = .reps(repMin: try c.decode(Int.self, forKey: .repMin), repMax: try c.decode(Int.self, forKey: .repMax))
        case .timedReps: self = .timedReps(timeSeconds: try c.decode(Int.self, forKey: .timeSeconds))
        case .interval: self = .interval(workSeconds: try c.decode(Int.self, forKey: .workSeconds), restSeconds: try c.decode(Int.self, forKey: .restSeconds))
        case .skillAttempt: self = .skillAttempt(attempts: try c.decode(Int.self, forKey: .attempts))
        case .load: self = .load(reps: try c.decode(Int.self, forKey: .reps), loadKg: try c.decode(Decimal.self, forKey: .loadKg))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .kind)
        switch self {
        case .staticHold(let s): try c.encode(s, forKey: .holdSeconds)
        case .reps(let lo, let hi):
            try c.encode(lo, forKey: .repMin)
            try c.encode(hi, forKey: .repMax)
        case .timedReps(let s): try c.encode(s, forKey: .timeSeconds)
        case .interval(let work, let rest):
            try c.encode(work, forKey: .workSeconds)
            try c.encode(rest, forKey: .restSeconds)
        case .skillAttempt(let a): try c.encode(a, forKey: .attempts)
        case .load(let reps, let kg):
            try c.encode(reps, forKey: .reps)
            try c.encode(kg, forKey: .loadKg)
        }
    }
}

/// One exercise of the session as executed (snapshot of the planned exercise at session creation).
/// Mirrors `planned_exercise_payload` + catalog version so every confirmed set can snapshot it (docs/03 §4 invariants).
public struct ExecutionSpec: Codable, Equatable, Hashable, Sendable {
    /// `exercise_executions.id`.
    public var id: UUID
    public var plannedExerciseId: UUID?
    /// Catalog exercise id.
    public var exerciseId: UUID
    public var catalogVersion: Int
    public var setCount: Int
    public var target: Prescription
    /// Rest between sets of this exercise (0..3600).
    public var restSeconds: Int

    public init(id: UUID, plannedExerciseId: UUID? = nil, exerciseId: UUID, catalogVersion: Int, setCount: Int, target: Prescription, restSeconds: Int) {
        self.id = id
        self.plannedExerciseId = plannedExerciseId
        self.exerciseId = exerciseId
        self.catalogVersion = catalogVersion
        self.setCount = setCount
        self.target = target
        self.restSeconds = restSeconds
    }

    public func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if let i = ValidationIssue.range("setCount", setCount, DomainLimits.setCount) { issues.append(i) }
        if let i = ValidationIssue.range("restSeconds", restSeconds, DomainLimits.restSeconds) { issues.append(i) }
        if let i = ValidationIssue.min("catalogVersion", catalogVersion, 1) { issues.append(i) }
        issues.append(contentsOf: target.validate())
        return issues
    }
}

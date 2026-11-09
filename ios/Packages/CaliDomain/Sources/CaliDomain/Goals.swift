import Foundation

// CON-005 (docs/18 §6, docs/03 §2.3): goals, phases and indicator definitions, plus the pure rules that
// compute progress from saved sets. `current` is always computed here, never stored or sent.

/// ADR-060: derived from `ExerciseType`, never stored.
public enum MeasurementType: String, Codable, Sendable, CaseIterable {
    case hold, reps, distance, duration, load
}

extension ExerciseType {
    public var measurementType: MeasurementType {
        switch self {
        case .staticHold: .hold
        case .reps, .timedReps, .skillAttempt: .reps
        case .interval, .duration: .duration
        case .distance: .distance
        case .load: .load
        }
    }
}

public enum IndicatorKind: String, Codable, Sendable, CaseIterable {
    case performance, adherence, volume, milestone, body
}

public enum IndicatorAggregation: String, Codable, Sendable {
    /// Best of the week / best so far.
    case max
    /// Total of the week; "current" is the latest week with data.
    case sum
}

/// `indicator_definition` (server / portal owned, ADR-051). The app bundles the db/005 defaults so goals
/// work offline; the downloaded config replaces them once CON-008 is fetched.
public struct IndicatorDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var version: Int
    public var kind: IndicatorKind
    public var label: String
    public var unit: String
    public var step: Decimal
    public var aggregation: IndicatorAggregation
    public var measurementTypes: [MeasurementType]
    public var enabled: Bool

    public init(id: String, version: Int = 1, kind: IndicatorKind, label: String, unit: String, step: Decimal,
                aggregation: IndicatorAggregation, measurementTypes: [MeasurementType], enabled: Bool = true) {
        self.id = id
        self.version = version
        self.kind = kind
        self.label = label
        self.unit = unit
        self.step = step
        self.aggregation = aggregation
        self.measurementTypes = measurementTypes
        self.enabled = enabled
    }

    /// Same rows as `db/005_plan_goals_phases.sql`.
    public static let bundled: [IndicatorDefinition] = [
        IndicatorDefinition(id: "best_hold_seconds", kind: .performance, label: "Giữ lâu nhất", unit: "giây", step: 1, aggregation: .max, measurementTypes: [.hold]),
        IndicatorDefinition(id: "best_set_reps", kind: .performance, label: "Set tốt nhất", unit: "lần", step: 1, aggregation: .max, measurementTypes: [.reps]),
        IndicatorDefinition(id: "milestone_hold_seconds", kind: .milestone, label: "Lần đầu giữ được", unit: "giây", step: 1, aggregation: .max, measurementTypes: [.hold]),
        IndicatorDefinition(id: "milestone_reps", kind: .milestone, label: "Lần đầu làm được", unit: "lần", step: 1, aggregation: .max, measurementTypes: [.reps]),
        IndicatorDefinition(id: "weekly_total_reps", kind: .volume, label: "Tổng lần / tuần", unit: "lần", step: 1, aggregation: .sum, measurementTypes: [.reps]),
        IndicatorDefinition(id: "weekly_total_hold_seconds", kind: .volume, label: "Tổng thời gian giữ / tuần", unit: "giây", step: 1, aggregation: .sum, measurementTypes: [.hold]),
    ]

    public func applies(to type: ExerciseType) -> Bool { measurementTypes.contains(type.measurementType) }
}

public enum GoalStatus: String, Codable, Sendable, CaseIterable {
    case active, reached, achieved, missed, archived
}

/// `goal_target`: one value, or a `{min,max}` range (body goals).
public enum GoalTarget: Hashable, Sendable, Codable {
    case value(Decimal)
    case range(min: Decimal, max: Decimal)

    private enum CodingKeys: String, CodingKey { case value, min, max }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Decimal.self, forKey: .value) { self = .value(v); return }
        self = .range(min: try c.decode(Decimal.self, forKey: .min), max: try c.decode(Decimal.self, forKey: .max))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .value(let v): try c.encode(v, forKey: .value)
        case .range(let lo, let hi):
            try c.encode(lo, forKey: .min)
            try c.encode(hi, forKey: .max)
        }
    }

    /// Whether `current` meets the target (≥ value, or inside the range).
    public func isMet(by current: Decimal?) -> Bool {
        guard let current else { return false }
        switch self {
        case .value(let v): return current >= v
        case .range(let lo, let hi): return current >= lo && current <= hi
        }
    }
}

/// `plan_goal_payload`. Belongs to the plan lineage; `scopePhaseId == nil` = whole plan.
public struct PlanGoal: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var planLineageId: UUID
    public var title: String
    /// Immutable after creation (ADR-047).
    public var indicatorId: String
    /// Immutable after creation (ADR-047).
    public var exerciseId: UUID?
    /// Client snapshot at creation (ADR-044).
    public var baseline: Decimal?
    public var target: GoalTarget
    public var scopePhaseId: UUID?
    public var unlockAfterGoalId: UUID?
    public var status: GoalStatus
    /// Set only by the user's "Xác nhận đạt" (AGENTS rules 3, 5); kept when archived.
    public var achievedAt: Date?
    public var pinned: Bool
    public var note: String?
    public var createdAt: Date?
    public var deletedAt: Date?

    public init(id: UUID, planLineageId: UUID, title: String, indicatorId: String, exerciseId: UUID? = nil, baseline: Decimal? = nil,
                target: GoalTarget, scopePhaseId: UUID? = nil, unlockAfterGoalId: UUID? = nil, status: GoalStatus = .active,
                achievedAt: Date? = nil, pinned: Bool = false, note: String? = nil, createdAt: Date? = nil, deletedAt: Date? = nil) {
        self.id = id
        self.planLineageId = planLineageId
        self.title = title
        self.indicatorId = indicatorId
        self.exerciseId = exerciseId
        self.baseline = baseline
        self.target = target
        self.scopePhaseId = scopePhaseId
        self.unlockAfterGoalId = unlockAfterGoalId
        self.status = status
        self.achievedAt = achievedAt
        self.pinned = pinned
        self.note = note
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    /// Active or waiting for confirmation: counts as "đang theo đuổi" unless locked.
    public var isLive: Bool { status == .active || status == .reached }
}

/// `plan_phase_payload`: an ordered phase of one plan revision.
public struct PlanPhase: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// 1...52.
    public var weeks: Int
    public var description: String?

    public init(id: UUID, name: String, weeks: Int, description: String? = nil) {
        self.id = id
        self.name = name
        self.weeks = weeks
        self.description = description
    }
}

// MARK: - Phases (docs/18 §6.5)

public struct PhaseSpan: Equatable, Sendable {
    public enum State: String, Sendable { case done, current, upcoming }
    public var phase: PlanPhase
    public var index: Int
    /// 1-based, inclusive.
    public var firstWeek: Int
    public var lastWeek: Int
    public var state: State

    public var label: String { firstWeek == lastWeek ? "Tuần \(firstWeek)" : "Tuần \(firstWeek)–\(lastWeek)" }
    public func contains(week: Int) -> Bool { (firstWeek...lastWeek).contains(week) }
}

public enum PhaseTimeline {
    public static func totalWeeks(_ phases: [PlanPhase]) -> Int { phases.reduce(0) { $0 + $1.weeks } }

    /// Week ranges and states, computed from order and lengths (never stored). `currentWeek == 0` means the
    /// plan has not started: every phase is upcoming. Past the last week every phase is done.
    public static func spans(_ phases: [PlanPhase], currentWeek: Int) -> [PhaseSpan] {
        var first = 1
        return phases.enumerated().map { index, phase in
            let last = first + phase.weeks - 1
            defer { first = last + 1 }
            let state: PhaseSpan.State = currentWeek <= 0 || currentWeek < first ? .upcoming : currentWeek > last ? .done : .current
            return PhaseSpan(phase: phase, index: index, firstWeek: first, lastWeek: last, state: state)
        }
    }

    public static func validate(_ phases: [PlanPhase]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        for (i, p) in phases.enumerated() {
            let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > 120 { issues.append(ValidationIssue(field: "phases[\(i)].name", reason: .outOfRange, detail: "1–120 ký tự")) }
            if !(1...52).contains(p.weeks) { issues.append(ValidationIssue(field: "phases[\(i)].weeks", reason: .outOfRange, detail: "1–52 tuần")) }
            if (p.description?.count ?? 0) > 500 { issues.append(ValidationIssue(field: "phases[\(i)].description", reason: .outOfRange, detail: "tối đa 500 ký tự")) }
        }
        return issues
    }
}

// MARK: - Goal rules (docs/18 §6.2–6.4)

public enum GoalRules {
    public static let pinnedLimit = 3
    public static let focusHintThreshold = 6

    /// A goal whose `unlockAfterGoalId` points to a goal not yet achieved (archived keeps its achievedAt).
    public static func isLocked(_ goal: PlanGoal, in goals: [PlanGoal]) -> Bool {
        guard let after = goal.unlockAfterGoalId else { return false }
        guard let previous = goals.first(where: { $0.id == after && $0.deletedAt == nil }) else { return false }
        return previous.achievedAt == nil
    }

    /// `goal_unlock_cycle`: following `unlockAfterGoalId` from `goal` comes back to it.
    public static func createsCycle(_ goal: PlanGoal, in goals: [PlanGoal]) -> Bool {
        var byId = Dictionary(goals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        byId[goal.id] = goal
        var seen: Set<UUID> = [goal.id]
        var next = goal.unlockAfterGoalId
        while let id = next {
            if !seen.insert(id).inserted { return true }
            next = byId[id]?.unlockAfterGoalId
        }
        return false
    }

    /// Field-level checks matching the contract and db/005 (validation_failed).
    public static func validate(_ goal: PlanGoal, indicator: IndicatorDefinition?, exerciseType: ExerciseType?,
                                others: [PlanGoal]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let title = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.count > 120 { issues.append(ValidationIssue(field: "title", reason: .outOfRange, detail: "1–120 ký tự")) }
        if (goal.note?.count ?? 0) > 500 { issues.append(ValidationIssue(field: "note", reason: .outOfRange, detail: "tối đa 500 ký tự")) }
        guard let indicator, indicator.enabled else {
            return issues + [ValidationIssue(field: "indicatorId", reason: .outOfRange, detail: "chỉ số không có")]
        }
        if indicator.kind != .adherence && indicator.kind != .body {
            if let type = exerciseType {
                if !indicator.applies(to: type) { issues.append(ValidationIssue(field: "exerciseId", reason: .outOfRange, detail: "bài không hợp với chỉ số")) }
            } else {
                issues.append(ValidationIssue(field: "exerciseId", reason: .outOfRange, detail: "cần chọn bài"))
            }
        }
        switch goal.target {
        case .value(let v):
            if v < 0 || v > 999_999_999 { issues.append(ValidationIssue(field: "target.value", reason: .outOfRange, detail: "ngoài khoảng")) }
        case .range(let lo, let hi):
            if lo < 0 || hi > 999_999_999 || lo > hi { issues.append(ValidationIssue(field: "target.max", reason: .outOfRange, detail: "khoảng không hợp lệ")) }
        }
        if let b = goal.baseline, b < 0 { issues.append(ValidationIssue(field: "baseline", reason: .outOfRange, detail: "phải ≥ 0")) }
        if goal.status == .achieved && goal.achievedAt == nil { issues.append(ValidationIssue(field: "achievedAt", reason: .outOfRange, detail: "cần thời điểm xác nhận")) }
        if goal.achievedAt != nil && goal.status != .achieved && goal.status != .archived {
            issues.append(ValidationIssue(field: "achievedAt", reason: .outOfRange, detail: "chỉ có khi đã đạt"))
        }
        if goal.unlockAfterGoalId == goal.id || createsCycle(goal, in: others) {
            issues.append(ValidationIssue(field: "unlockAfterGoalId", reason: .outOfRange, detail: "goal_unlock_cycle"))
        }
        if goal.pinned && goal.deletedAt == nil {
            let pinned = others.filter { $0.id != goal.id && $0.planLineageId == goal.planLineageId && $0.pinned && $0.deletedAt == nil }.count
            if pinned >= pinnedLimit { issues.append(ValidationIssue(field: "pinned", reason: .outOfRange, detail: "pinned_goal_limit")) }
        }
        return issues
    }
}

// MARK: - Progress (docs/18 §6.1, §6.6)

/// One measured value of a completed set, already placed in its plan week (1-based).
public struct MetricSample: Equatable, Sendable {
    public var week: Int
    public var exerciseId: UUID
    public var measurement: MeasurementType
    public var value: Decimal

    public init(week: Int, exerciseId: UUID, measurement: MeasurementType, value: Decimal) {
        self.week = week
        self.exerciseId = exerciseId
        self.measurement = measurement
        self.value = value
    }
}

public struct WeekPoint: Equatable, Sendable {
    public var week: Int
    /// `nil` = no data that week (never interpolated).
    public var value: Decimal?
}

public struct ProgressSummary: Equatable, Sendable {
    public var points: [WeekPoint]
    /// Best so far (max) or latest week with data (sum).
    public var current: Decimal?
    public var currentWeek: Int?
    /// First week with data; only set when at least two weeks have data ("chưa đủ dữ liệu để so").
    public var reference: Decimal?
    public var referenceWeek: Int?

    public var delta: Decimal? { current.flatMap { c in reference.map { c - $0 } } }
    /// Whole percent, nil when the reference is 0 or missing.
    public var percent: Int? {
        guard let delta, let reference, reference > 0 else { return nil }
        let p = NSDecimalNumber(decimal: delta / reference * 100).doubleValue
        return Int(p.rounded())
    }
}

public enum GoalProgress {
    /// The measured value of a completed set for `measurement` (hold → seconds, one decimal; reps → reps).
    public static func value(of measurement: MeasurementType, holdMs: Int64?, reps: Int?) -> Decimal? {
        switch measurement {
        case .hold:
            guard let ms = holdMs, ms > 0 else { return nil }
            return Decimal((ms + 50) / 100) / 10
        case .reps:
            guard let reps, reps > 0 else { return nil }
            return Decimal(reps)
        case .distance, .duration, .load:
            return nil
        }
    }

    /// Weekly points 1...`totalWeeks` (or through the last week with data) for one exercise.
    public static func summary(samples: [MetricSample], exerciseId: UUID, measurement: MeasurementType,
                               aggregation: IndicatorAggregation, weeks: ClosedRange<Int>? = nil) -> ProgressSummary {
        let mine = samples.filter { $0.exerciseId == exerciseId && $0.measurement == measurement }
        var byWeek: [Int: Decimal] = [:]
        for s in mine {
            if let range = weeks, !range.contains(s.week) { continue }
            switch aggregation {
            case .max: byWeek[s.week] = max(byWeek[s.week] ?? s.value, s.value)
            case .sum: byWeek[s.week, default: 0] += s.value
            }
        }
        let lastWeek = max(weeks?.upperBound ?? 0, byWeek.keys.max() ?? 0)
        let firstWeek = weeks?.lowerBound ?? 1
        let points = lastWeek >= firstWeek ? (firstWeek...lastWeek).map { WeekPoint(week: $0, value: byWeek[$0]) } : []
        let withData = points.filter { $0.value != nil }
        var summary = ProgressSummary(points: points, current: nil, currentWeek: nil, reference: nil, referenceWeek: nil)
        guard let first = withData.first, let last = withData.last else { return summary }
        switch aggregation {
        case .max:
            let best = withData.max { $0.value! < $1.value! }!
            summary.current = best.value
            summary.currentWeek = withData.first { $0.value == best.value }?.week
        case .sum:
            summary.current = last.value
            summary.currentWeek = last.week
        }
        if withData.count >= 2 {
            summary.reference = first.value
            summary.referenceWeek = first.week
        }
        return summary
    }

    /// `current` of a goal: best in scope (performance, milestone) or total of `currentWeek` (volume).
    /// Adherence and body goals are computed elsewhere and return nil here.
    public static func current(of goal: PlanGoal, indicator: IndicatorDefinition, exerciseType: ExerciseType?,
                               samples: [MetricSample], scopeWeeks: ClosedRange<Int>?, currentWeek: Int) -> Decimal? {
        guard let exerciseId = goal.exerciseId, let type = exerciseType else { return nil }
        let measurement = type.measurementType
        let inScope = samples.filter { s in
            s.exerciseId == exerciseId && s.measurement == measurement && (scopeWeeks?.contains(s.week) ?? true)
        }
        switch indicator.kind {
        case .performance, .milestone:
            return inScope.map(\.value).max()
        case .volume:
            let week = inScope.filter { $0.week == currentWeek }
            return week.isEmpty ? nil : week.reduce(0) { $0 + $1.value }
        case .adherence, .body:
            return nil
        }
    }

    /// 0...1 progress from baseline to target, for the bar.
    public static func fraction(current: Decimal?, baseline: Decimal?, target: GoalTarget) -> Double {
        guard let current else { return 0 }
        switch target {
        case .value(let t):
            let b = baseline ?? 0
            guard t > b else { return current >= t ? 1 : 0 }
            let f = NSDecimalNumber(decimal: (current - b) / (t - b)).doubleValue
            return min(1, max(0, f))
        case .range(let lo, let hi):
            return current >= lo && current <= hi ? 1 : 0.5
        }
    }
}

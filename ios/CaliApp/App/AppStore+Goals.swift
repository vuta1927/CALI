import CaliCore
import CaliDomain
import Foundation

/// IOS-015 (docs/18 §6, CON-005): goals, phases and progress of a plan. Every value shown as "hiện tại"
/// is computed here from saved sets; nothing is typed in. "Đã đạt" is only ever the user's confirmation.
extension AppStore {
    // MARK: Lookups

    /// db/005 defaults until the downloaded indicator config exists (CON-008).
    // TODO(CON-008): replace with the indicator definitions served with `GET /v1/criteria-config`.
    var indicators: [IndicatorDefinition] { IndicatorDefinition.bundled.filter(\.enabled) }

    func indicator(_ id: String) -> IndicatorDefinition? { IndicatorDefinition.bundled.first { $0.id == id } }

    func goal(_ id: UUID) -> PlanGoal? { goals.first { $0.id == id } }

    func goals(of lineageId: UUID) -> [PlanGoal] { goals.filter { $0.planLineageId == lineageId } }

    func isLocked(_ goal: PlanGoal) -> Bool { GoalRules.isLocked(goal, in: goals(of: goal.planLineageId)) }

    func currentWeek(of plan: WorkoutPlan, now: Date = Date()) -> CurrentWeek {
        PlanSchedule.currentWeek(program: plan.program, activations: plan.activations, today: today(now))
    }

    func phaseSpans(of plan: WorkoutPlan, phases: [PlanPhase]? = nil, now: Date = Date()) -> [PhaseSpan] {
        let week = currentWeek(of: plan, now: now)
        let current = week.state == .finished ? Int.max : week.week
        return PhaseTimeline.spans(phases ?? plan.phases, currentWeek: current)
    }

    /// "Tuần x/y · giai đoạn" for a running weekly plan with phases; nil otherwise.
    func phaseCaption(_ plan: WorkoutPlan, now: Date = Date()) -> String? {
        let week = currentWeek(of: plan, now: now)
        guard plan.kind == .weekly, !plan.phases.isEmpty, week.state == .inProgress else { return nil }
        let total = PhaseTimeline.totalWeeks(plan.phases)
        let phase = phaseSpans(of: plan, now: now).first { $0.state == .current }?.phase.name
        return (["Tuần \(week.week)/\(total)"] + [phase].compactMap { $0 }).joined(separator: " · ")
    }

    func scopeLabel(_ goal: PlanGoal, in plan: WorkoutPlan) -> String {
        guard let phaseId = goal.scopePhaseId else { return "Cả giáo án" }
        guard let span = phaseSpans(of: plan).first(where: { $0.phase.id == phaseId }) else { return "Cả giáo án (giai đoạn đã xoá)" }
        return "\(span.phase.name) · \(span.label)"
    }

    /// Plan week (1-based) of a day, counted the same way as "Tuần x/y" (D7).
    func week(of day: LocalDate, in plan: WorkoutPlan) -> Int {
        max(1, PlanSchedule.currentWeek(program: .weekly(totalWeeks: nil), activations: plan.activations, today: day).week)
    }

    /// Completed sets of this plan's sessions, placed in their plan week. Only this plan counts (I4).
    func samples(for plan: WorkoutPlan) -> [MetricSample] {
        var result: [MetricSample] = []
        for session in history where session.planLineageId == plan.lineageId && !session.isSample {
            let week = week(of: LocalDate.today(at: session.startedAt, in: calendar.timeZone), in: plan)
            for set in session.sets where set.status == .completed {
                let measurement = set.target.type.measurementType
                if let value = GoalProgress.value(of: measurement, holdMs: set.holdMs, reps: set.reps) {
                    result.append(MetricSample(week: week, exerciseId: set.exerciseId, measurement: measurement, value: value))
                }
            }
        }
        return result
    }

    func scopeWeeks(of goal: PlanGoal, in plan: WorkoutPlan) -> ClosedRange<Int>? {
        guard let phaseId = goal.scopePhaseId, let span = phaseSpans(of: plan).first(where: { $0.phase.id == phaseId }) else { return nil }
        return span.firstWeek...span.lastWeek
    }

    func current(of goal: PlanGoal, now: Date = Date()) -> Decimal? {
        guard let plan = plan(goal.planLineageId), let indicator = indicator(goal.indicatorId) else { return nil }
        return GoalProgress.current(of: goal, indicator: indicator, exerciseType: goal.exerciseId.flatMap(exercise)?.type,
                                    samples: samples(for: plan), scopeWeeks: scopeWeeks(of: goal, in: plan),
                                    currentWeek: currentWeek(of: plan, now: now).week)
    }

    /// Baseline snapshot for a new goal (ADR-044): the first plan week with data; none for milestones.
    func suggestedBaseline(indicator: IndicatorDefinition, exerciseId: UUID, in plan: WorkoutPlan) -> Decimal? {
        guard indicator.kind == .performance || indicator.kind == .volume, let type = exercise(exerciseId)?.type else { return nil }
        let summary = GoalProgress.summary(samples: samples(for: plan), exerciseId: exerciseId, measurement: type.measurementType,
                                           aggregation: indicator.aggregation)
        return summary.points.first { $0.value != nil }?.value
    }

    // MARK: Goal commands (each with a commandId and one audit row)

    @discardableResult
    func saveGoal(_ goal: PlanGoal, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard let plan = plan(goal.planLineageId), plan.deletedAt == nil else { return refuse("Không tìm thấy giáo án.") }
        var goal = goal
        goal.title = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = self.goal(goal.id)
        if let existing {
            // ADR-047: indicator and exercise never change; a different one is a new goal.
            guard existing.indicatorId == goal.indicatorId, existing.exerciseId == goal.exerciseId else {
                return refuse("Không đổi được bài hoặc chỉ số của mục tiêu đã có. Hãy lưu trữ và tạo mục tiêu mới.")
            }
            goal.createdAt = existing.createdAt
        } else {
            goal.createdAt = now
        }
        let issues = GoalRules.validate(goal, indicator: indicator(goal.indicatorId), exerciseType: goal.exerciseId.flatMap(exercise)?.type,
                                        others: goals(of: goal.planLineageId))
        if let issue = issues.first { return refuse(Self.describe(issue)) }
        return commitContent(ContentChange(goals: [goal]), action: existing == nil ? "Thêm mục tiêu" : "Sửa mục tiêu",
                             detail: "\(plan.title) · \(goal.title)", commandId: commandId, now: now)
    }

    @discardableResult
    func setPinned(_ goalId: UUID, _ pinned: Bool, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        change(goalId, action: pinned ? "Ghim mục tiêu" : "Bỏ ghim mục tiêu", now: now, commandId: commandId) { goal in
            guard goal.isLive || !pinned else { return "Chỉ ghim được mục tiêu đang theo đuổi." }
            goal.pinned = pinned
            return nil
        }
    }

    /// "Xác nhận đạt": the only way a goal becomes achieved (AGENTS rules 3, 5).
    @discardableResult
    func confirmGoal(_ goalId: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        change(goalId, action: "Xác nhận đạt mục tiêu", now: now, commandId: commandId) { goal in
            guard goal.isLive else { return "Mục tiêu này không còn đang theo đuổi." }
            goal.status = .achieved
            goal.achievedAt = now
            goal.pinned = false
            return nil
        }
    }

    /// "Chưa, giữ tiếp".
    @discardableResult
    func keepGoal(_ goalId: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        change(goalId, action: "Giữ tiếp mục tiêu", now: now, commandId: commandId) { goal in
            guard goal.status == .reached else { return "Mục tiêu này không chờ xác nhận." }
            goal.status = .active
            return nil
        }
    }

    /// "Gia hạn": a missed goal moves to the current phase (or the whole plan) and is pursued again.
    @discardableResult
    func extendGoal(_ goalId: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        let current = goal(goalId).flatMap { plan($0.planLineageId) }.flatMap { plan in
            phaseSpans(of: plan, now: now).first { $0.state == .current }?.phase.id
        }
        return change(goalId, action: "Gia hạn mục tiêu", now: now, commandId: commandId) { goal in
            guard goal.status == .missed else { return "Chỉ gia hạn được mục tiêu chưa đạt." }
            goal.scopePhaseId = current
            goal.status = .active
            return nil
        }
    }

    @discardableResult
    func archiveGoal(_ goalId: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        change(goalId, action: "Lưu trữ mục tiêu", now: now, commandId: commandId) { goal in
            goal.status = .archived
            goal.pinned = false
            return nil
        }
    }

    /// An archived goal comes back as achieved when it had been confirmed, else as pursued.
    @discardableResult
    func restoreGoal(_ goalId: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        change(goalId, action: "Khôi phục mục tiêu", now: now, commandId: commandId) { goal in
            guard goal.status == .archived else { return "Mục tiêu này chưa được lưu trữ." }
            goal.status = goal.achievedAt == nil ? .active : .achieved
            return nil
        }
    }

    private func change(_ goalId: UUID, action: String, now: Date, commandId: UUID, _ edit: (inout PlanGoal) -> String?) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard var goal = goal(goalId), let plan = plan(goal.planLineageId) else { return refuse("Không tìm thấy mục tiêu.") }
        if let refusal = edit(&goal) { return refuse(refusal) }
        let issues = GoalRules.validate(goal, indicator: indicator(goal.indicatorId), exerciseType: goal.exerciseId.flatMap(exercise)?.type,
                                        others: goals(of: goal.planLineageId))
        if let issue = issues.first { return refuse(Self.describe(issue)) }
        return commitContent(ContentChange(goals: [goal]), action: action, detail: "\(plan.title) · \(goal.title)",
                             commandId: commandId, now: now)
    }

    static func describe(_ issue: ValidationIssue) -> String {
        switch issue.field {
        case "title": "Tên mục tiêu cần từ 1 đến 120 ký tự."
        case "note": "Ghi chú tối đa 500 ký tự."
        case "exerciseId": "Chọn một bài phù hợp với chỉ số."
        case "indicatorId": "Chỉ số này không còn dùng được."
        case "target.value", "target.max": "Mức đích chưa hợp lệ."
        case "unlockAfterGoalId": "Thứ tự mở khoá tạo thành vòng lặp."
        case "pinned": "Đã ghim \(GoalRules.pinnedLimit) mục tiêu. Bỏ ghim một mục tiêu khác trước."
        default: "Dữ liệu chưa hợp lệ (\(issue.field))."
        }
    }

    // MARK: Roadmap (docs/18 §6.5)

    /// Saves the edited phase list in one step with an audit row. Goals scoped to a removed phase move to
    /// the whole plan. Sets are never touched.
    @discardableResult
    func savePhases(_ lineageId: UUID, _ phases: [PlanPhase], now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard var plan = plan(lineageId), isEditable(plan, now: now) else { return refuse("Giáo án này chỉ xem được.") }
        let phases = phases.map { PlanPhase(id: $0.id, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                            weeks: $0.weeks, description: $0.description) }
        if let issue = PhaseTimeline.validate(phases).first {
            return refuse(issue.field.hasSuffix("weeks") ? "Mỗi giai đoạn từ 1 đến 52 tuần." : "Tên giai đoạn cần từ 1 đến 120 ký tự.")
        }
        let kept = Set(phases.map(\.id))
        let rescoped = goals(of: lineageId).filter { $0.scopePhaseId.map { !kept.contains($0) } ?? false }.map { goal -> PlanGoal in
            var copy = goal
            copy.scopePhaseId = nil
            return copy
        }
        let before = PhaseTimeline.totalWeeks(plan.phases)
        plan.phases = phases
        let detail = "\(plan.title) · \(phases.count) giai đoạn, \(before) → \(PhaseTimeline.totalWeeks(phases)) tuần"
        return commitContent(ContentChange(plans: [plan], goals: rescoped), action: "Sửa lộ trình", detail: detail,
                             commandId: commandId, now: now)
    }

    // MARK: Status suggestions

    /// docs/18 §6.2: after a completed session, pursued goals of its exercises whose current value now meets
    /// the target wait for the user's confirmation ("Chờ xác nhận"). Never "achieved".
    func flagReachedGoals(after sessionId: UUID, now: Date = Date()) {
        guard let session = history.first(where: { $0.id == sessionId }), let lineage = session.planLineageId else { return }
        let exercises = Set(session.sets.filter { $0.status == .completed }.map(\.exerciseId))
        let reached = goals(of: lineage).filter { goal in
            goal.status == .active && !isLocked(goal) && goal.exerciseId.map(exercises.contains) == true
                && goal.target.isMet(by: current(of: goal, now: now))
        }.map { goal -> PlanGoal in
            var copy = goal
            copy.status = .reached
            return copy
        }
        guard !reached.isEmpty else { return }
        commit(ContentChange(goals: reached, audit: AuditEntry(id: UUID(), at: now, action: "Mục tiêu chạm mức đích",
                                                               detail: reached.map(\.title).joined(separator: ", "))), now: now)
    }

    /// docs/18 §6.2: a pursued goal whose phase is over becomes "Chưa đạt"; the user extends or archives it.
    func closeEndedGoalScopes(now: Date = Date()) {
        var missed: [PlanGoal] = []
        for goal in goals where goal.isLive && goal.scopePhaseId != nil {
            guard let plan = plan(goal.planLineageId),
                  let span = phaseSpans(of: plan, now: now).first(where: { $0.phase.id == goal.scopePhaseId }),
                  span.state == .done, !goal.target.isMet(by: current(of: goal, now: now)) else { continue }
            var copy = goal
            copy.status = .missed
            missed.append(copy)
        }
        guard !missed.isEmpty else { return }
        commit(ContentChange(goals: missed, audit: AuditEntry(id: UUID(), at: now, action: "Mục tiêu hết phạm vi",
                                                              detail: missed.map(\.title).joined(separator: ", "))), now: now)
    }
}

// MARK: - Progress screen (docs/18 §6.6)

struct WeekAdherence: Equatable, Identifiable {
    var week: Int
    var done: Int
    var planned: Int
    var id: Int { week }
}

struct ExerciseProgress: Identifiable {
    var exercise: Exercise
    var indicator: IndicatorDefinition
    var summary: ProgressSummary
    var id: UUID { exercise.id }
}

extension AppStore {
    /// One column per plan week from week 1: completed / planned. Today and later are not counted yet;
    /// missed sessions are only the difference (never red).
    func weeklyAdherence(of plan: WorkoutPlan, now: Date = Date()) -> [WeekAdherence] {
        let today = today(now)
        let adherence = PlanSchedule.adherence(lineageId: plan.lineageId, program: plan.program, activations: plan.activations,
                                               slots: plan.slots, sessions: completedRefs(), today: today)
        var byWeek: [Int: WeekAdherence] = [:]
        for occurrence in adherence.occurrences where occurrence.date < today || occurrence.outcome == .completed {
            let week = week(of: occurrence.date, in: plan)
            var entry = byWeek[week] ?? WeekAdherence(week: week, done: 0, planned: 0)
            entry.planned += 1
            if occurrence.outcome == .completed { entry.done += 1 }
            byWeek[week] = entry
        }
        guard let last = byWeek.keys.max() else { return [] }
        return (1...last).map { byWeek[$0] ?? WeekAdherence(week: $0, done: 0, planned: 0) }
    }

    /// One row per plan exercise with data: best hold or best set, by plan week.
    func exerciseProgress(of plan: WorkoutPlan) -> [ExerciseProgress] {
        let samples = samples(for: plan)
        var seen: Set<UUID> = []
        let ids = plan.workouts.flatMap(\.exercises).map(\.exerciseId).filter { seen.insert($0).inserted }
        return ids.compactMap { id in
            guard let exercise = exercise(id) else { return nil }
            let measurement = exercise.type.measurementType
            guard let indicator = IndicatorDefinition.bundled.first(where: {
                $0.kind == .performance && $0.measurementTypes.contains(measurement)
            }) else { return nil }
            let summary = GoalProgress.summary(samples: samples, exerciseId: id, measurement: measurement, aggregation: .max)
            return summary.current == nil ? nil : ExerciseProgress(exercise: exercise, indicator: indicator, summary: summary)
        }
    }
}

// MARK: - Criteria on saved sets (IOS-016)

extension AppStore {
    /// "Kỹ thuật: Chuẩn · Điều kiện: Có trợ lực · Có ghi nhận đau" for a saved set, labelled from the config
    /// version it was entered with. Values of a criterion this build does not know are left out.
    func criteriaSummary(of set: LoggedSet) -> String? {
        var parts: [String] = []
        if let config = [criteriaConfig].first(where: { $0.version == set.criteriaVersion }), let values = set.criteria {
            for criterion in config.criteria {
                guard let value = values[criterion.id] else { continue }
                let labels = Dictionary(uniqueKeysWithValues: (criterion.options ?? []).map { ($0.v, $0.label) })
                let text: String? = switch value {
                case .token(let v): labels[v]
                case .tokens(let list): list.compactMap { labels[$0] }.joined(separator: ", ")
                case .number(let n): Fmt.number(n)
                case .bool(let b): b ? "Có" : nil
                }
                if let text, !text.isEmpty { parts.append("\(criterion.label): \(text)") }
            }
        }
        if set.painReported == true { parts.append("Có ghi nhận đau") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

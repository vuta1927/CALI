import CaliCore
import CaliDomain
import Foundation

/// One planned workout of one plan on one day (MP-06, MP-09).
struct ScheduledItem: Identifiable, Hashable {
    let plan: WorkoutPlan
    let workout: PlannedWorkout
    let date: LocalDate
    let outcome: PlannedOccurrence.Outcome

    var id: String { "\(plan.lineageId)|\(workout.id)|\(date)" }
    var isDone: Bool { outcome == .completed }
}

/// What to do with another followed plan so a new one fits under the limit (MP-04, docs/19 §4.3).
struct LimitResolution: Hashable {
    enum Action: String { case pause, end }
    let lineageId: UUID
    let action: Action
}

/// Input of MP-02 "Tạo giáo án".
struct PlanDraft: Identifiable {
    let id = UUID()
    enum Method: Hashable {
        case blank
        /// MP-03: copy another plan (also "Lặp lại" and "Nhân bản để sửa").
        case clone(UUID)
        /// The starter plan bundled with the app.
        case template
    }

    var method: Method = .blank
    var title = ""
    var discipline: PlanDiscipline = .calisthenics
    var kind: PlanKind = .weekly
    var eventName = ""
    var eventDate: LocalDate?
}

/// Multi-plan (IOS-013, docs/19): lookups, the merged schedule and lifecycle commands. Every command takes a
/// `commandId`, checks its preconditions, and writes the plan rows plus one audit row in one transaction
/// (I5); a repeated `commandId` is a no-op that reports success.
extension AppStore {
    /// docs/19 D9 / BR-8.
    static let planCountLimit = 50
    static let titleRange = 1...120
    static let endNoteLimit = 500

    // MARK: Lookups

    var calendar: Calendar { .current }

    func today(_ now: Date = Date()) -> LocalDate {
        LocalDate.today(at: now, in: calendar.timeZone)
    }

    /// Local midnight of a local date, for formatting.
    func date(of day: LocalDate) -> Date {
        calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
    }

    /// Plans that are not deleted, in creation order.
    var visiblePlans: [WorkoutPlan] { plans.filter { $0.deletedAt == nil } }

    func plan(_ lineageId: UUID) -> WorkoutPlan? {
        plans.first { $0.lineageId == lineageId }
    }

    func plan(containing workoutId: UUID) -> WorkoutPlan? {
        plans.first { plan in plan.workouts.contains { $0.id == workoutId } }
    }

    func status(of plan: WorkoutPlan, now: Date = Date()) -> PlanStatus {
        plan.status(today: today(now))
    }

    /// `active` plans first, then `scheduled` (both take a slot of the D1 limit).
    func followedPlans(now: Date = Date()) -> [WorkoutPlan] {
        let today = today(now)
        return visiblePlans.filter { $0.status(today: today) == .active } + visiblePlans.filter { $0.status(today: today) == .scheduled }
    }

    /// Ended, archived and deleted plans are read-only (MP-08: "Nhân bản để sửa").
    func isEditable(_ plan: WorkoutPlan, now: Date = Date()) -> Bool {
        ![.ended, .archived, .deleted].contains(status(of: plan, now: now))
    }

    /// The plan whose workout the active session is running (docs/19 §4.3 "Chặn").
    func hasActiveSession(_ plan: WorkoutPlan) -> Bool {
        guard let player, player.state.isActive, let workoutId = player.state.plannedWorkoutId else { return false }
        return plan.workouts.contains { $0.id == workoutId }
    }

    /// The display name history uses for a session's plan: "X (đã xoá)" once deleted (MP-10).
    func planLabel(for session: CompletedSession) -> String? {
        guard let lineage = session.planLineageId, let plan = plan(lineage) else { return nil }
        return plan.deletedAt == nil ? plan.title : "\(plan.title) (đã xoá)"
    }

    /// Event plans: whole days from today to the event (negative after it).
    func daysUntilEvent(_ plan: WorkoutPlan, now: Date = Date()) -> Int? {
        guard plan.kind == .event, let eventDate = plan.eventDate else { return nil }
        return today(now).days(until: eventDate)
    }

    /// MP-07: the program is over (weekly finished or event day passed) and the user has not chosen yet.
    func isFinished(_ plan: WorkoutPlan, now: Date = Date()) -> Bool {
        guard [.active, .paused].contains(status(of: plan, now: now)) else { return false }
        return PlanSchedule.currentWeek(program: plan.program, activations: plan.activations, today: today(now)).state == .finished
    }

    // MARK: Schedule across plans

    /// Planned workouts of every plan on `from...through`, I4 outcomes included, sorted by day then plan order.
    func scheduledItems(from: LocalDate, through: LocalDate, now: Date = Date()) -> [ScheduledItem] {
        let today = today(now)
        let refs = completedRefs()
        var ranked: [(rank: Int, item: ScheduledItem)] = []
        for (rank, plan) in visiblePlans.enumerated() where plan.endedAt == nil && plan.archivedAt == nil {
            var days: [(workoutId: UUID, date: LocalDate, outcome: PlannedOccurrence.Outcome)] = []
            if from <= today {
                let adherence = PlanSchedule.adherence(lineageId: plan.lineageId, program: plan.program, activations: plan.activations,
                                                       slots: plan.slots, sessions: refs, today: today)
                for occurrence in adherence.occurrences where from <= occurrence.date && occurrence.date <= through {
                    days.append((occurrence.plannedWorkoutId, occurrence.date, occurrence.outcome))
                }
            }
            let futureFrom = max(from, today.adding(days: 1))
            if futureFrom <= through {
                let future = PlanSchedule.occurrences(program: plan.program, activations: plan.activations, slots: plan.slots,
                                                      from: futureFrom, through: through)
                for occurrence in future { days.append((occurrence.plannedWorkoutId, occurrence.date, .pending)) }
            }
            for day in days {
                guard let workout = plan.workouts.first(where: { $0.id == day.workoutId }) else { continue }
                ranked.append((rank, ScheduledItem(plan: plan, workout: workout, date: day.date, outcome: day.outcome)))
            }
        }
        ranked.sort { lhs, rhs in
            if lhs.item.date != rhs.item.date { return lhs.item.date < rhs.item.date }
            return lhs.rank < rhs.rank
        }
        return ranked.map(\.item)
    }

    func scheduledItems(on day: LocalDate, now: Date = Date()) -> [ScheduledItem] {
        scheduledItems(from: day, through: day, now: now)
    }

    /// The first day after today that has planned workouts, within two weeks (MP-09 empty state).
    func nextScheduledDay(now: Date = Date()) -> (day: LocalDate, items: [ScheduledItem])? {
        let today = today(now)
        let items = scheduledItems(from: today.adding(days: 1), through: today.adding(days: 14), now: now)
        guard let first = items.first?.date else { return nil }
        return (first, items.filter { $0.date == first })
    }

    /// Monday of the week containing `day`.
    func monday(of day: LocalDate) -> LocalDate {
        day.adding(days: 1 - day.isoWeekday)
    }

    /// Completed sessions in I4 form: the local day they started and the plan they belong to.
    func completedRefs() -> [CompletedSessionRef] {
        history.filter { $0.status == .completed && !$0.isSample }.map {
            CompletedSessionRef(sessionId: $0.id, lineageId: $0.planLineageId, plannedWorkoutId: $0.plannedWorkoutId,
                                date: LocalDate.today(at: $0.startedAt, in: calendar.timeZone))
        }
    }

    /// MP-04: other followed plans that would push `lineageId` over the D1 limit when started on `from`.
    func limitConflicts(starting lineageId: UUID, from: LocalDate) -> [WorkoutPlan] {
        let candidate = PlanActivation(id: UUID(), fromDate: from, timezone: calendar.timeZone.identifier)
        let others = plans.filter { $0.lineageId != lineageId }.map(\.lineageState)
        guard case .exceedsLimit(_, _, _, let ids) = PlanLifecycle.checkActivePlanLimit(
            candidate: candidate, candidateLineageId: lineageId, plans: others) else { return [] }
        return ids.filter { $0 != lineageId }.compactMap { id in plan(id) }
    }

    /// D5: followed plans that also train on a weekday of `lineageId` (information only, never blocks).
    func overlappingPlans(with lineageId: UUID, now: Date = Date()) -> [(plan: WorkoutPlan, weekdays: [Int])] {
        guard let target = plan(lineageId) else { return [] }
        let days = Set(target.slots.map(\.weekday))
        return followedPlans(now: now).filter { $0.lineageId != lineageId }.compactMap { other in
            let shared = Set(other.slots.map(\.weekday)).intersection(days).sorted()
            return shared.isEmpty ? nil : (other, shared)
        }
    }

    // MARK: Lifecycle commands

    /// MP-02 / MP-03. Saves a draft (never starts it) and returns its id.
    @discardableResult
    func createPlan(_ draft: PlanDraft, now: Date = Date(), commandId: UUID = UUID()) -> UUID? {
        // The plan id is the commandId, so a repeated command finds the plan it created.
        if audit.contains(where: { $0.id == commandId }) { return plan(commandId)?.lineageId }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let eventName = draft.eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.titleRange.contains(title.count) else { refuse("Tên giáo án cần từ 1 đến 120 ký tự."); return nil }
        guard visiblePlans.count < Self.planCountLimit else {
            refuse("Đã có \(Self.planCountLimit) giáo án. Hãy xoá bớt giáo án cũ trước khi tạo mới.")
            return nil
        }
        if draft.kind == .event {
            guard let eventDate = draft.eventDate, eventDate >= today(now) else { refuse("Chọn ngày sự kiện từ hôm nay trở đi."); return nil }
            guard eventName.count <= Self.titleRange.upperBound else { refuse("Tên sự kiện tối đa 120 ký tự."); return nil }
        }

        var workouts: [PlannedWorkout] = []
        var phases: [PlanPhase] = []
        var action = "Tạo giáo án"
        switch draft.method {
        case .blank: break
        case .template: workouts = MockData.plan.workouts
        case .clone(let source):
            guard let original = plan(source) else { refuse("Không tìm thấy giáo án để nhân bản."); return nil }
            workouts = original.workouts
            // Phases belong to one revision, so the copy gets new ids (ADR-057); goals stay with their lineage.
            phases = original.phases.map { PlanPhase(id: UUID(), name: $0.name, weeks: $0.weeks, description: $0.description) }
            action = "Nhân bản giáo án"
        }
        // New ids: the copy is a separate plan; sessions, activations and AI decisions are never copied (MP-03).
        workouts = workouts.map { workout in
            var copy = workout
            copy.id = UUID()
            copy.exercises = workout.exercises.map { var e = $0; e.id = UUID(); return e }
            return copy
        }
        let id = commandId
        let plan = WorkoutPlan(
            id: id, title: title, workouts: workouts, kind: draft.kind,
            eventDate: draft.kind == .event ? draft.eventDate : nil,
            eventName: draft.kind == .event && !eventName.isEmpty ? eventName : nil,
            primaryDiscipline: draft.discipline, createdAt: now, phases: phases
        )
        return commitContent(ContentChange(plans: [plan]), action: action, detail: title, commandId: commandId, now: now) ? id : nil
    }

    /// MP-04 / MP-05: opens an activation from `from` (today or later). When the plan would exceed the D1
    /// limit, `resolution` pauses or ends one other followed plan in the same transaction; without it the
    /// command is refused and the UI asks which plan to free (I2).
    @discardableResult
    func startPlan(_ lineageId: UUID, from: LocalDate, resolving resolution: LimitResolution? = nil, now: Date = Date(),
                   commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard var plan = plan(lineageId) else { return refuse("Không tìm thấy giáo án.") }
        let status = plan.status(today: today(now))
        guard status == .draft || status == .paused else { return refuse("Giáo án này không ở trạng thái Nháp hoặc Tạm dừng.") }
        guard !plan.slots.isEmpty else { return refuse("Thêm ít nhất một buổi tập trước khi bắt đầu theo.") }
        if let eventDate = plan.eventDate, plan.kind == .event, from > eventDate {
            return refuse("Ngày bắt đầu phải trước ngày sự kiện.")
        }
        let activation = PlanActivation(id: UUID(), fromDate: from, timezone: calendar.timeZone.identifier)
        guard PlanLifecycle.validateNewActivation(activation, existing: plan.activations, now: now).isEmpty else {
            return refuse("Không chọn được ngày đã qua.")
        }

        var change = ContentChange()
        var others = plans.filter { $0.lineageId != lineageId }
        var detail = plan.title
        if let resolution {
            guard let index = others.firstIndex(where: { $0.lineageId == resolution.lineageId }),
                  let freed = closing(others[index], action: resolution.action == .pause ? .paused : .stopped, now: now) else {
                return false
            }
            others[index] = freed.plan
            change.plans.append(freed.plan)
            change.activationEndReasons.merge(freed.reasons) { $1 }
            detail += " · \(resolution.action == .pause ? "tạm dừng" : "kết thúc") \(freed.plan.title)"
        }
        let check = PlanLifecycle.checkActivePlanLimit(candidate: activation, candidateLineageId: lineageId, plans: others.map(\.lineageState))
        if case .exceedsLimit(_, _, let limit, _) = check {
            return refuse("Đã đủ \(limit) giáo án đang theo. Chọn giáo án cần tạm dừng hoặc kết thúc.")
        }
        plan.activations.append(activation)
        change.plans.insert(plan, at: 0)
        return commitContent(change, action: status == .paused ? "Tiếp tục giáo án" : "Bắt đầu theo giáo án",
                             detail: "\(detail) · từ \(Fmt.dayMonthShort(date(of: from)))", commandId: commandId, now: now)
    }

    @discardableResult
    func pausePlan(_ lineageId: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard let plan = plan(lineageId), let closed = closing(plan, action: .paused, now: now) else { return false }
        return commitContent(ContentChange(plans: [closed.plan], activationEndReasons: closed.reasons),
                             action: "Tạm dừng giáo án", detail: plan.title, commandId: commandId, now: now)
    }

    /// docs/19 §4.3 "Kết thúc": optional reason and note (≤ 500 characters).
    @discardableResult
    func endPlan(_ lineageId: UUID, reason: PlanEndReason, note: String = "", now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= Self.endNoteLimit else { return refuse("Ghi chú tối đa \(Self.endNoteLimit) ký tự.") }
        guard let plan = plan(lineageId),
              let closed = closing(plan, action: reason == .completed ? .completed : .stopped, now: now) else { return false }
        var ended = closed.plan
        ended.endedAt = now
        ended.endReason = reason
        ended.endNote = note.isEmpty ? nil : note
        // ADR-053: goals still pursued become "Chưa đạt"; nothing is marked achieved for the user.
        let missed = goals(of: lineageId).filter(\.isLive).map { goal -> PlanGoal in
            var copy = goal
            copy.status = .missed
            return copy
        }
        return commitContent(ContentChange(plans: [ended], activationEndReasons: closed.reasons, goals: missed),
                             action: "Kết thúc giáo án", detail: "\(plan.title) · \(reason == .completed ? "Hoàn thành" : "Dừng sớm")",
                             commandId: commandId, now: now)
    }

    /// MP-07 "Kéo dài" for an event plan past its event day: it becomes a weekly plan in a new revision.
    // TODO(IOS-013): "Kéo dài" for a finished weekly plan (append a phase; length now comes from phases, IOS-015).
    // Until then the user extends it by adding a phase in Lộ trình while the plan is still running.
    @discardableResult
    func extendPlan(_ lineageId: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard var plan = plan(lineageId), isFinished(plan, now: now), plan.kind == .event else {
            return refuse("Chỉ kéo dài được giáo án đã qua ngày sự kiện.")
        }
        plan.kind = .weekly
        plan.eventDate = nil
        plan.revision += 1
        return commitContent(ContentChange(plans: [plan]), action: "Kéo dài giáo án", detail: "\(plan.title) · chuyển sang Theo tuần",
                             commandId: commandId, now: now)
    }

    @discardableResult
    func setArchived(_ lineageId: UUID, _ archived: Bool, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard var plan = plan(lineageId), plan.deletedAt == nil else { return refuse("Không tìm thấy giáo án.") }
        if archived {
            guard !status(of: plan, now: now).countsTowardActiveLimit else {
                return refuse("Tạm dừng hoặc kết thúc giáo án trước khi lưu trữ.")
            }
            plan.archivedAt = now
        } else {
            plan.archivedAt = nil
        }
        return commitContent(ContentChange(plans: [plan]), action: archived ? "Lưu trữ giáo án" : "Khôi phục giáo án",
                             detail: plan.title, commandId: commandId, now: now)
    }

    /// Soft delete (ADR-040): workouts stay so history keeps naming the plan; sessions are never touched (I3).
    @discardableResult
    func deletePlan(_ lineageId: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard let plan = plan(lineageId), plan.deletedAt == nil else { return refuse("Không tìm thấy giáo án.") }
        guard !hasActiveSession(plan) else { return refuse("Giáo án đang có buổi tập dở. Hãy kết thúc buổi đó trước.") }
        var deleted = plan
        var reasons: [UUID: ActivationEndReason] = [:]
        if let closed = close(plan, reason: .deleted, now: now) {
            deleted = closed.plan
            reasons = closed.reasons
        }
        deleted.deletedAt = now
        return commitContent(ContentChange(plans: [deleted], activationEndReasons: reasons), action: "Xóa giáo án",
                             detail: plan.title, commandId: commandId, now: now)
    }

    @discardableResult
    func renamePlan(_ lineageId: UUID, title: String, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.titleRange.contains(title.count) else { return refuse("Tên giáo án cần từ 1 đến 120 ký tự.") }
        guard var plan = plan(lineageId), isEditable(plan, now: now) else { return refuse("Giáo án này chỉ xem được.") }
        plan.title = title
        return commitContent(ContentChange(plans: [plan]), action: "Sửa giáo án", detail: title, commandId: commandId, now: now)
    }

    // MARK: Race result (IOS-014, MP-07)

    /// "Ghi kết quả thi" is offered from the event day on, while the plan is followed or paused.
    func canRecordRaceResult(_ plan: WorkoutPlan, now: Date = Date()) -> Bool {
        guard plan.kind == .event, let days = daysUntilEvent(plan, now: now), days <= 0 else { return false }
        return [.active, .paused].contains(status(of: plan, now: now))
    }

    /// The running workout planned on the event day, which the result is attached to (docs/19 MP-07).
    func raceWorkout(of plan: WorkoutPlan) -> (workout: PlannedWorkout, item: PlannedExercise)? {
        guard let eventDate = plan.eventDate,
              let workout = plan.workouts.first(where: { $0.weekday == eventDate.isoWeekday && $0.exercises.contains { $0.target.type == .distance } }),
              let item = workout.exercises.first(where: { $0.target.type == .distance }) else { return nil }
        return (workout, item)
    }

    /// Saves the official result as one completed `distance` session entered by hand (`source = manual`):
    /// the session, its set and the audit row are written in one transaction. Nothing else changes; the
    /// plan stays as it is until the user ends, extends or repeats it (D6).
    // TODO(CON-008): offer the user to confirm a running milestone goal; db/005 seeds no distance/duration
    // indicator yet, so no running goal can exist until the indicator config adds one.
    @discardableResult
    func recordRaceResult(_ lineageId: UUID, distanceMeters: Int, durationSeconds: Int, now: Date = Date(),
                          commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard let plan = plan(lineageId), canRecordRaceResult(plan, now: now) else {
            return refuse("Chỉ ghi kết quả thi từ ngày sự kiện, khi giáo án chưa kết thúc.")
        }
        if case .failure(let issue) = Pace.derive(distanceMeters: distanceMeters, durationSeconds: durationSeconds) {
            return refuse(issue.field == "durationSeconds" ? "Thời gian phải lớn hơn 0 và tối đa 24 giờ." : "Quãng đường phải lớn hơn 0 và tối đa 1000 km.")
        }
        if let player, player.state.isActive {
            return refuse("Bạn đang có buổi \"\(player.title)\" chưa kết thúc. Hãy kết thúc buổi đó trước.")
        }
        let linked = raceWorkout(of: plan)
        let exerciseId = linked?.item.exerciseId ?? MockData.easyRun
        let target = linked?.item.target ?? .distance(distanceMeters: distanceMeters, durationSeconds: nil)
        let sessionId = UUID()
        let execution = ExecutionSpec(id: UUID(), plannedExerciseId: linked?.item.id, exerciseId: exerciseId,
                                      catalogVersion: exercise(exerciseId)?.catalogVersion ?? MockData.catalogVersion,
                                      setCount: 1, target: target, restSeconds: 0)
        let commands: [Command] = [
            .createSession(CreateSession(commandId: commandId, sessionId: sessionId, plannedWorkoutId: linked?.workout.id, executions: [execution])),
            .startSet(StartSet(commandId: UUID(), countdownSeconds: 0)),
            .stopSet(SimpleCommand(commandId: UUID())),
            .confirmSet(ConfirmSet(commandId: UUID(), setResultId: UUID(), executionId: execution.id, setIndex: 1,
                                   actualDistanceMeters: distanceMeters, actualDurationSeconds: durationSeconds)),
            .finishSession(SimpleCommand(commandId: UUID())),
        ]
        let title = "Kết quả thi · \(plan.eventName ?? plan.title)"
        let entry = AuditEntry(id: commandId, at: now, action: "Ghi kết quả thi",
                               detail: "\(plan.title) · \(Fmt.km(distanceMeters)) · \(Fmt.duration(durationSeconds))")
        do {
            let result = try recordSession(commands, sessionTitle: title, audit: entry)
            guard result.outcome.status == .applied || result.replayed else {
                return refuse("Không ghi được kết quả thi: \(result.error.map(WorkoutPlayerModel.message(for:)) ?? (result.outcome.errorCode ?? "-"))")
            }
        } catch {
            return refuse("Không lưu được kết quả thi trên máy. Hãy thử lại. (\(error.localizedDescription))")
        }
        reloadContent()
        return true
    }

    /// Race results already saved for this plan, newest first. A result is linked through the event-day
    /// workout; without one the session has no plan link, so it is matched by the title it was saved with.
    func raceResults(of plan: WorkoutPlan) -> [CompletedSession] {
        let prefix = "Kết quả thi · "
        return history.filter { session in
            session.status == .completed && session.title.hasPrefix(prefix)
                && (session.planLineageId == plan.lineageId || session.title == prefix + (plan.eventName ?? plan.title))
        }
    }

    // MARK: Helpers

    /// Pause / end preconditions plus the activation change (docs/19 §4.3).
    private func closing(_ plan: WorkoutPlan, action: ActivationEndReason, now: Date) -> (plan: WorkoutPlan, reasons: [UUID: ActivationEndReason])? {
        let status = status(of: plan, now: now)
        switch action {
        case .paused:
            guard status == .active || status == .scheduled else { refuse("Chỉ tạm dừng được giáo án đang theo."); return nil }
        default:
            guard [.active, .scheduled, .paused].contains(status) else { refuse("Giáo án này không kết thúc được."); return nil }
        }
        guard !hasActiveSession(plan) else {
            refuse("\"\(plan.title)\" đang có buổi tập dở. Hãy kết thúc buổi đó trước.")
            return nil
        }
        return close(plan, reason: action, now: now) ?? (plan, [:])
    }

    /// Closes the open activation the day before `now` (a pause or end takes effect from today), or cancels it
    /// when it had not started before today. `nil` when nothing is open.
    private func close(_ plan: WorkoutPlan, reason: ActivationEndReason, now: Date) -> (plan: WorkoutPlan, reasons: [UUID: ActivationEndReason])? {
        let today = today(now)
        guard let open = plan.openActivation(today: today), let index = plan.activations.firstIndex(of: open) else { return nil }
        var copy = plan
        if open.fromDate >= today {
            copy.activations.remove(at: index)
            return (copy, [:])
        }
        copy.activations[index].toDate = today.adding(days: -1)
        return (copy, [open.id: reason])
    }

    @discardableResult
    func refuse(_ message: String) -> Bool {
        alertMessage = message
        return false
    }
}

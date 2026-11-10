#if DEBUG
import CaliCore
import CaliDomain
import Foundation

/// DEBUG only: `-uiScenario run|race|overview|goals|roadmap|progress` opens a screen that needs several steps to reach, for simulator
/// screenshots. It runs on an in-memory store (nothing reaches the local database) through the normal
/// store commands; the event plan it creates is the user's own kind of data, not a sample.
enum DebugScenario: String {
    /// P6 result form of a 5 km running segment.
    case run
    /// MP-07 race result sheet of an event plan whose event day is today.
    case race
    /// IOS-015 screens of the starter plan with a roadmap, goals and one recorded session.
    case overview, goals, roadmap, progress
    /// IOS-016 set result form of a gym load set / a calisthenics hold, with the criteria of the bundled config.
    case gym, hold
    /// IOS-017 History across two plans: missed days, today's open session, a run session with kilometres.
    case history
    /// IOS-018 body weight screen with eight entries over five weeks.
    case body
    /// IOS-012 dev Diagnostics screen.
    case diagnostics

    /// The store starts 10 days ago for `history`, so the plans have days that passed without a session.
    var seedNow: Date { self == .history ? Date().addingTimeInterval(-10 * 86_400) : Date() }

    static var launch: DebugScenario? { UserDefaults.standard.string(forKey: "uiScenario").flatMap(Self.init(rawValue:)) }

    /// Returns the plan whose race result sheet should open.
    @MainActor
    func apply(to store: AppStore) -> UUID? {
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        let run = PlannedExercise(id: UUID(), exerciseId: MockData.easyRun, setCount: 1,
                                  target: .distance(distanceMeters: self == .run ? 5_000 : 10_000, durationSeconds: self == .run ? nil : 3_000),
                                  restSeconds: 0)
        switch self {
        case .overview, .goals, .roadmap, .progress:
            return seedGoals(store)
        case .history:
            return seedHistory(store)
        case .diagnostics:
            return store.plans.first?.lineageId
        case .body:
            let now = Date()
            for (days, kg) in [(35, "74.2"), (28, "73.8"), (21, "73.5"), (14, "73.1"), (9, "72.9"), (4, "72.6"), (1, "72.4"), (0, "72.1")] {
                _ = store.saveBodyMeasurement(BodyMeasurement(value: Decimal(string: kg)!, measuredAt: now.addingTimeInterval(-Double(days) * 86_400 - 900)), now: now)
            }
            return store.plans.first?.lineageId
        case .gym, .hold:
            let load = self == .gym
            let exerciseId = load ? MockData.backSquat : MockData.tuckPlanche
            let item = PlannedExercise(id: UUID(), exerciseId: exerciseId, setCount: 3,
                                       target: load ? .load(reps: 5, loadKg: 60) : .staticHold(holdSeconds: 12), restSeconds: 90)
            store.startWorkout(PlannedWorkout(id: UUID(), weekday: store.today().isoWeekday, title: load ? "Chân" : "Planche", focus: "", exercises: [item]))
            store.player?.startSet()
            store.player?.stopSet()
            return nil
        case .run:
            store.startWorkout(PlannedWorkout(id: UUID(), weekday: store.today().isoWeekday, title: "Chạy nhẹ 5 km", focus: "", exercises: [run]))
            store.player?.startSet()
            store.player?.stopSet()
            return nil
        case .race:
            let today = store.today()
            guard let id = store.createPlan(PlanDraft(title: "Chuẩn bị 10 km", kind: .event, eventName: "Giải chạy 10 km", eventDate: today)) else { return nil }
            _ = store.updateWorkout(PlannedWorkout(id: UUID(), weekday: today.isoWeekday, title: "Ngày thi", focus: "", exercises: [run]), in: id)
            _ = store.startPlan(id, from: today)
            return id
        }
    }

    /// A second plan "Chạy bán marathon" followed since the store's start, plus one completed run session today.
    @MainActor
    private func seedHistory(_ store: AppStore) -> UUID? {
        let past = seedNow
        guard let run = store.createPlan(PlanDraft(title: "Chạy bán marathon", discipline: .running), now: past) else { return nil }
        let workouts = [1, 3, 5, 7].map { weekday in
            PlannedWorkout(id: UUID(), weekday: weekday, title: weekday == 7 ? "Chạy dài 12 km" : "Chạy nhẹ 8 km", focus: "",
                           exercises: [PlannedExercise(id: UUID(), exerciseId: MockData.easyRun, setCount: 1,
                                                       target: .distance(distanceMeters: weekday == 7 ? 12_000 : 8_000, durationSeconds: nil), restSeconds: 0)])
        }
        for workout in workouts { _ = store.updateWorkout(workout, in: run) }
        _ = store.startPlan(run, from: store.today(past), now: past)
        // One run today: linked to the plan's workout when it is scheduled today, otherwise a free run.
        let linked = workouts.first { $0.weekday == store.today().isoWeekday }
        let item = (linked ?? workouts[0]).exercises[0]
        let sessionId = UUID()
        let spec = ExecutionSpec(id: UUID(), plannedExerciseId: item.id, exerciseId: item.exerciseId, catalogVersion: MockData.catalogVersion,
                                 setCount: 1, target: item.target, restSeconds: 0)
        let commands: [Command] = [
            .createSession(CreateSession(commandId: UUID(), sessionId: sessionId, plannedWorkoutId: linked?.id, executions: [spec])),
            .startSet(StartSet(commandId: UUID(), countdownSeconds: 0)), .stopSet(SimpleCommand(commandId: UUID())),
            .confirmSet(ConfirmSet(commandId: UUID(), setResultId: UUID(), executionId: spec.id, setIndex: 1, status: .completed,
                                   actualDistanceMeters: 8_250, actualDurationSeconds: 2_538)),
            .finishSession(SimpleCommand(commandId: UUID())),
        ]
        _ = try? store.recordSession(commands, sessionTitle: linked?.title ?? "Chạy nhẹ 8 km",
                                     audit: AuditEntry(id: UUID(), at: Date(), action: "Ghi buổi tập", detail: "Chạy nhẹ"))
        store.reloadContent()
        return nil
    }

    /// Phases, three goals (a pinned one that the recorded session reaches, a pinned one still pursued, a
    /// locked milestone) and one completed session, all through the normal store commands.
    @MainActor
    private func seedGoals(_ store: AppStore) -> UUID? {
        guard let plan = store.plans.first else { return nil }
        let base = PlanPhase(id: UUID(), name: "Nền tảng", weeks: 4, description: "Giữ form, tăng dần thời gian giữ.")
        _ = store.savePhases(plan.lineageId, [base, PlanPhase(id: UUID(), name: "Tăng sức", weeks: 3), PlanPhase(id: UUID(), name: "Kiểm tra", weeks: 1)])
        let pairs = plan.workouts.flatMap { w in w.exercises.map { (workout: w, item: $0) } }
        guard let reps = pairs.first(where: { store.exercise($0.item.exerciseId)?.type == .reps }),
              let hold = pairs.first(where: { store.exercise($0.item.exerciseId)?.type == .staticHold }) else { return plan.lineageId }
        func name(_ id: UUID) -> String { store.exercise(id)?.name ?? "" }
        let first = PlanGoal(id: UUID(), planLineageId: plan.lineageId, title: "\(name(reps.item.exerciseId)) 10 lần một set",
                             indicatorId: "best_set_reps", exerciseId: reps.item.exerciseId, baseline: 6, target: .value(10), pinned: true)
        let second = PlanGoal(id: UUID(), planLineageId: plan.lineageId, title: "Giữ \(name(hold.item.exerciseId)) 30 giây",
                              indicatorId: "best_hold_seconds", exerciseId: hold.item.exerciseId, baseline: 12, target: .value(30),
                              scopePhaseId: base.id, pinned: true)
        let milestone = PlanGoal(id: UUID(), planLineageId: plan.lineageId, title: "\(name(hold.item.exerciseId)) giữ 45 giây",
                                 indicatorId: "milestone_hold_seconds", exerciseId: hold.item.exerciseId, target: .value(45))
        var locked = PlanGoal(id: UUID(), planLineageId: plan.lineageId, title: "\(name(hold.item.exerciseId)) giữ 60 giây",
                              indicatorId: "milestone_hold_seconds", exerciseId: hold.item.exerciseId, target: .value(60))
        locked.unlockAfterGoalId = milestone.id
        for goal in [first, second, milestone, locked] { _ = store.saveGoal(goal) }

        let sessionId = UUID()
        let specs = [(reps, 11, nil as Int64?), (hold, nil, 21_400 as Int64?)].map { pair, reps, holdMs in
            (ExecutionSpec(id: UUID(), plannedExerciseId: pair.item.id, exerciseId: pair.item.exerciseId,
                           catalogVersion: store.exercise(pair.item.exerciseId)?.catalogVersion ?? MockData.catalogVersion,
                           setCount: 1, target: pair.item.target, restSeconds: 0), reps, holdMs)
        }
        var commands: [Command] = [.createSession(CreateSession(commandId: UUID(), sessionId: sessionId, plannedWorkoutId: reps.workout.id,
                                                                executions: specs.map { $0.0 }))]
        for (spec, reps, holdMs) in specs {
            commands += [.startSet(StartSet(commandId: UUID(), countdownSeconds: 0)), .stopSet(SimpleCommand(commandId: UUID())),
                         .confirmSet(ConfirmSet(commandId: UUID(), setResultId: UUID(), executionId: spec.id, setIndex: 1, status: .completed,
                                                actualReps: reps, actualHoldMs: holdMs))]
        }
        commands.append(.finishSession(SimpleCommand(commandId: UUID())))
        _ = try? store.recordSession(commands, sessionTitle: reps.workout.title,
                                     audit: AuditEntry(id: UUID(), at: Date(), action: "Ghi buổi tập", detail: reps.workout.title))
        store.reloadContent()
        store.flagReachedGoals(after: sessionId)
        return plan.lineageId
    }
}
#endif

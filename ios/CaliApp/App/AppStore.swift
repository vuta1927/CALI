import CaliDomain
import Foundation
import Observation

/// App-wide state for the POC. Owns the plan, history, recommendations and the active workout,
/// and persists everything locally after each change (offline-first; no backend in the POC).
@Observable
@MainActor
final class AppStore {
    // MARK: State

    let catalog: [Exercise] = MockData.catalog
    private(set) var plan: WorkoutPlan
    private(set) var history: [CompletedSession]
    private(set) var recommendations: [Recommendation]
    private(set) var audit: [AuditEntry]
    private(set) var settings: AppSettings

    /// The in-flight (or just finished) workout. Kept after completion so the summary screen can
    /// render; removed when the player is closed.
    private(set) var player: WorkoutPlayerModel?
    var isPlayerPresented = false

    /// Shown when a start request is refused (e.g. another workout is active).
    var alertMessage: String?

    @ObservationIgnored private let createdAt: Date
    @ObservationIgnored private let persists: Bool
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private let exerciseIndex: [UUID: Exercise] =
        Dictionary(uniqueKeysWithValues: MockData.catalog.map { ($0.id, $0) })

    init(persists: Bool = true, now: Date = Date()) {
        self.persists = persists
        if persists, let snapshot = LocalStore.load() {
            plan = snapshot.plan
            history = snapshot.history
            recommendations = snapshot.recommendations
            audit = snapshot.audit
            settings = snapshot.settings
            createdAt = snapshot.createdAt
            if let active = snapshot.active {
                player = WorkoutPlayerModel(active: active)
            }
        } else {
            plan = MockData.plan
            history = MockData.sampleHistory(now: now)
            recommendations = MockData.sampleRecommendations()
            audit = []
            settings = AppSettings()
            createdAt = now
        }
        player?.store = self
    }

    // MARK: Lookups

    func exercise(_ id: UUID) -> Exercise? { exerciseIndex[id] }

    func workout(_ id: UUID) -> PlannedWorkout? {
        if id == MockData.quickTestId { return MockData.quickTest }
        return plan.workouts.first { $0.id == id }
    }

    /// Workout scheduled for the given day (ISO weekday), if any.
    func workout(on date: Date) -> PlannedWorkout? {
        let weekday = Fmt.isoWeekday(date)
        return plan.workouts.first { $0.weekday == weekday }
    }

    /// Next scheduled workout strictly after `date` (within the coming week).
    func nextWorkout(after date: Date) -> (workout: PlannedWorkout, date: Date)? {
        let calendar = Calendar.current
        for offset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            if let workout = workout(on: day) { return (workout, day) }
        }
        return nil
    }

    var activeSessionInProgress: Bool {
        player?.state.isActive == true
    }

    /// Sessions finished in the current calendar week (Mon–Sun).
    func sessionsThisWeek(now: Date = Date()) -> [CompletedSession] {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return [] }
        return history.filter { $0.status == .completed && week.contains($0.startedAt) }
    }

    var pendingRecommendationCount: Int {
        recommendations.filter { $0.decision == nil }.count
    }

    // MARK: Workout lifecycle

    func startWorkout(_ workout: PlannedWorkout) {
        if let player, player.state.isActive {
            if player.state.plannedWorkoutId == workout.id {
                isPlayerPresented = true
            } else {
                alertMessage = "Bạn đang có buổi \"\(player.title)\" chưa kết thúc. Hãy tiếp tục hoặc dừng buổi đó trước."
            }
            return
        }
        let executions = workout.exercises.map { item in
            ExecutionSpec(
                id: UUID(),
                plannedExerciseId: item.id,
                exerciseId: item.exerciseId,
                catalogVersion: exercise(item.exerciseId)?.catalogVersion ?? MockData.catalogVersion,
                setCount: item.setCount,
                target: item.target,
                restSeconds: item.restSeconds
            )
        }
        let command = CreateSession(commandId: UUID(), sessionId: UUID(), plannedWorkoutId: workout.id, executions: executions)
        switch WorkoutReducer.reduce(nil, .createSession(command), now: Date()) {
        case .success(let transition):
            let model = WorkoutPlayerModel(active: ActiveSession(state: transition.state, title: workout.title, records: []))
            model.store = self
            player = model
            isPlayerPresented = true
            if settings.notificationsEnabled { notifications.requestAuthorizationIfNeeded() }
            persist()
            syncSideEffects()
        case .failure(let error):
            alertMessage = "Không bắt đầu được buổi tập: \(WorkoutPlayerModel.message(for: error))"
        }
    }

    func resumeWorkout() {
        guard player != nil else { return }
        isPlayerPresented = true
    }

    /// Called by the player after every accepted transition (command or reconcile).
    func playerDidChange(_ model: WorkoutPlayerModel) {
        guard model === player else { return }
        if model.state.phase.isTerminal {
            archive(model)
        }
        persist()
        syncSideEffects()
    }

    /// Dismisses the player; a finished workout is released, an active one keeps running.
    func closePlayer() {
        isPlayerPresented = false
        if let player, !player.state.isActive {
            self.player = nil
            persist()
        }
    }

    private func archive(_ model: WorkoutPlayerModel) {
        let s = model.state
        guard !history.contains(where: { $0.id == s.sessionId }) else { return }
        let session = CompletedSession(
            id: s.sessionId,
            title: model.title,
            plannedWorkoutId: s.plannedWorkoutId,
            startedAt: s.startedAt,
            finishedAt: s.finishedAt ?? s.abandonedAt ?? s.updatedAt,
            status: s.status,
            exerciseIds: s.executions.map(\.exerciseId),
            plannedSetCount: s.totalPlannedSets,
            sets: model.records.map(LoggedSet.init(record:)),
            isSample: false
        )
        history.insert(session, at: 0)
    }

    private func syncSideEffects() {
        guard let player, player.state.isActive || player.state.phase.isTerminal else {
            notifications.cancelAll()
            liveActivity.sync(nil, enabled: false)
            return
        }
        let name = player.currentExercise?.name ?? player.title
        notifications.sync(state: player.state, exerciseName: name, enabled: settings.notificationsEnabled)
        let content = LiveActivityController.contentState(for: player.state, exerciseName: name)
        liveActivity.sync(content, enabled: settings.liveActivityEnabled)
    }

    // MARK: Plan editing

    func updateWorkout(_ workout: PlannedWorkout) {
        guard let index = plan.workouts.firstIndex(where: { $0.id == workout.id }) else { return }
        guard plan.workouts[index] != workout else { return }
        plan.workouts[index] = workout
        log("Sửa giáo án", "\(workout.title): \(workout.exercises.count) bài, \(workout.totalSets) set")
        persist()
    }

    // MARK: Recommendations (approval workflow + audit trail, AGENTS rule 5)

    func decide(_ recommendation: Recommendation, accept: Bool, now: Date = Date()) {
        guard let index = recommendations.firstIndex(where: { $0.id == recommendation.id }),
              recommendations[index].decision == nil else { return }
        recommendations[index].decision = accept ? .accepted : .rejected
        recommendations[index].decidedAt = now

        let summary = "\(recommendation.title) (\(recommendation.fromLabel) → \(recommendation.toLabel))"
        guard accept else {
            log("Từ chối đề xuất", summary, at: now)
            persist()
            return
        }
        if let change = recommendation.change, apply(change) {
            log("Chấp nhận đề xuất", "\(summary) — đã cập nhật giáo án", at: now)
        } else {
            log("Chấp nhận đề xuất", "\(summary) — không áp dụng được: bài tập không còn trong giáo án", at: now)
        }
        persist()
    }

    private func apply(_ change: PlanChange) -> Bool {
        guard let w = plan.workouts.firstIndex(where: { $0.id == change.plannedWorkoutId }),
              let e = plan.workouts[w].exercises.firstIndex(where: { $0.id == change.plannedExerciseId }) else { return false }
        if let sets = change.newSetCount { plan.workouts[w].exercises[e].setCount = sets }
        if let target = change.newTarget { plan.workouts[w].exercises[e].target = target }
        if let rest = change.newRestSeconds { plan.workouts[w].exercises[e].restSeconds = rest }
        return true
    }

    // MARK: Settings & data

    func updateSettings(_ body: (inout AppSettings) -> Void) {
        var copy = settings
        body(&copy)
        guard copy != settings else { return }
        let notificationsTurnedOn = copy.notificationsEnabled && !settings.notificationsEnabled
        settings = copy
        if notificationsTurnedOn { notifications.requestAuthorizationIfNeeded() }
        persist()
        syncSideEffects()
    }

    /// Wipes local data and restores the sample plan/history. Ends any active workout first.
    func resetDemoData(now: Date = Date()) {
        isPlayerPresented = false
        player = nil
        notifications.cancelAll()
        liveActivity.sync(nil, enabled: false)
        plan = MockData.plan
        history = MockData.sampleHistory(now: now)
        recommendations = MockData.sampleRecommendations()
        audit = []
        let welcomeSeen = settings.hasSeenWelcome
        settings = AppSettings()
        settings.hasSeenWelcome = welcomeSeen
        if persists { LocalStore.delete() }
        persist()
    }

    private func log(_ action: String, _ detail: String, at date: Date = Date()) {
        audit.insert(AuditEntry(id: UUID(), at: date, action: action, detail: detail), at: 0)
    }

    private func persist() {
        guard persists else { return }
        let active: ActiveSession? = player.flatMap { $0.state.isActive ? $0.activeSnapshot : nil }
        LocalStore.save(PersistedSnapshot(
            plan: plan,
            history: history,
            recommendations: recommendations,
            audit: audit,
            settings: settings,
            active: active,
            createdAt: createdAt
        ))
    }
}

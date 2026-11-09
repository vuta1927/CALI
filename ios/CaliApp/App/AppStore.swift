import CaliCore
import CaliDomain
import Foundation
import Observation

/// App-wide state. Owns the plan, history, recommendations and the active workout. Every change is
/// committed to the local GRDB database first (`AppDatabase`, offline-first) and only then published to
/// the UI; workout commands go through the single-writer `WorkoutCoordinator`.
@Observable
@MainActor
final class AppStore {
    // MARK: State

    private(set) var catalog: [Exercise]
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

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private let liveActivity = LiveActivityController()

    /// - Parameters:
    ///   - persists: `false` uses a fresh in-memory database (unit tests hosted in the app).
    ///   - database: an explicit database (tests that simulate a relaunch share one).
    init(persists: Bool = true, now: Date = Date(), database: AppDatabase? = nil) {
        var openError: String?
        if let database {
            self.database = database
        } else if persists, let onDisk = Self.open(now: now, error: &openError) {
            self.database = onDisk
        } else {
            // Never touch the file we could not open; the session runs in memory and says so.
            self.database = try! AppDatabase.inMemory()
        }
        let loaded: LocalContent
        do {
            try self.database.content.seedIfEmpty(AppDatabase.seed(now: now), now: now)
            loaded = try self.database.content.load()
        } catch {
            openError = "Không đọc được dữ liệu trên máy (\(error.localizedDescription))."
            loaded = LocalContent(catalog: MockData.catalog, plan: MockData.plan, history: [], recommendations: [], audit: [], settings: AppSettings())
        }
        catalog = loaded.catalog
        plan = loaded.plan ?? MockData.plan
        history = loaded.history
        recommendations = loaded.recommendations
        audit = loaded.audit
        settings = loaded.settings
        alertMessage = openError
        restoreActiveSession()
    }

    private static func open(now: Date, error: inout String?) -> AppDatabase? {
        do {
            return try AppDatabase.openOnDisk(now: now)
        } catch let failure {
            error = "Không mở được dữ liệu trên máy; thay đổi lần này sẽ không được lưu. (\(failure.localizedDescription))"
            return nil
        }
    }

    /// Rebuilds the player for a session that was active when the app was last terminated.
    private func restoreActiveSession() {
        let coordinator = database.coordinator
        guard let state = try? coordinator.activeState() else { return }
        let records = (try? coordinator.setResults(sessionId: state.sessionId)) ?? []
        let title = (try? coordinator.activeSessionTitle()) ?? ""
        let model = WorkoutPlayerModel(active: ActiveSession(state: state, title: title, records: records))
        model.store = self
        player = model
    }

    // MARK: Lookups

    func exercise(_ id: UUID) -> Exercise? { catalog.first { $0.id == id } }

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

    /// True while sample history or undecided sample recommendations are visible; screens then show
    /// the "Dữ liệu mẫu" badge (AGENTS: no mock data masquerading as production data).
    var showsSampleData: Bool {
        history.contains(where: \.isSample) || recommendations.contains { $0.isSample && $0.decision == nil }
    }

    func exercises(of workout: PlannedWorkout) -> [Exercise?] {
        workout.exercises.map { exercise($0.exerciseId) }
    }

    func discipline(of workout: PlannedWorkout) -> Discipline {
        Discipline(types: workout.exercises.map(\.target.type))
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
        guard let result = execute(.createSession(command), sessionTitle: workout.title) else { return }
        guard result.outcome.status == .applied, let state = result.state else {
            let reason = result.error.map(WorkoutPlayerModel.message(for:)) ?? (result.outcome.errorCode ?? "-")
            alertMessage = "Không bắt đầu được buổi tập: \(reason)"
            return
        }
        let model = WorkoutPlayerModel(active: ActiveSession(state: state, title: workout.title, records: []))
        model.store = self
        player = model
        isPlayerPresented = true
        if settings.notificationsEnabled { notifications.requestAuthorizationIfNeeded() }
        syncSideEffects()
    }

    /// Runs one workout command through the coordinator (transactional, deduplicated by `commandId`).
    /// Returns `nil` and shows an alert when the database write failed; nothing changed then.
    func execute(_ command: Command, sessionTitle: String? = nil) -> HandleResult? {
        do {
            return try database.coordinator.handle(command, sessionTitle: sessionTitle)
        } catch {
            alertMessage = "Không lưu được thao tác trên máy. Hãy thử lại. (\(error.localizedDescription))"
            return nil
        }
    }

    /// Persists deadline-derived transitions (countdown over, target reached, rest over). Called from the
    /// player's foreground tick only when the pure reducer already sees a change.
    func reconcile(previousNow: Date?, monotonicElapsed: TimeInterval?, acknowledgeClockJump: Bool) -> ReconcileResult? {
        do {
            return try database.coordinator.reconcile(
                previousNow: previousNow, monotonicElapsed: monotonicElapsed, acknowledgeClockJump: acknowledgeClockJump
            )
        } catch {
            alertMessage = "Không lưu được trạng thái buổi tập trên máy. (\(error.localizedDescription))"
            return nil
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
            // The coordinator wrote the history row in the same transaction as the terminal state.
            reloadContent()
        }
        syncSideEffects()
    }

    /// Dismisses the player; a finished workout is released, an active one keeps running.
    func closePlayer() {
        isPlayerPresented = false
        if let player, !player.state.isActive {
            self.player = nil
        }
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

    @discardableResult
    func saveExercise(_ exercise: Exercise, commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [exercise.poster, exercise.video].compactMap({ $0 }).allSatisfy({ $0.url != nil }) else {
            alertMessage = "Tên bài tập hoặc đường dẫn media không hợp lệ."
            return false
        }
        if let previous = self.exercise(exercise.id), previous.type != exercise.type {
            let referenced = plan.workouts.contains { $0.exercises.contains { $0.exerciseId == exercise.id } }
                || MockData.quickTest.exercises.contains { $0.exerciseId == exercise.id }
                || history.contains { $0.exerciseIds.contains(exercise.id) }
                || (player?.state.executions.contains { $0.exerciseId == exercise.id } ?? false)
            guard !referenced else {
                alertMessage = "Bài đã được sử dụng. Hãy tạo bài mới nếu muốn đổi kiểu tập."
                return false
            }
        }
        return commitContent(ContentChange(exercises: [exercise]), action: "Lưu bài tập", detail: exercise.name, commandId: commandId)
    }

    @discardableResult
    func updateWorkout(_ workout: PlannedWorkout, commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard !workout.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...7).contains(workout.weekday), !workout.exercises.isEmpty,
              workout.exercises.allSatisfy({ item in
                  (1...10).contains(item.setCount) && (0...300).contains(item.restSeconds)
                      && item.target.validate().isEmpty && exercise(item.exerciseId)?.type == item.target.type
              }),
              !plan.workouts.contains(where: { $0.id != workout.id && $0.weekday == workout.weekday }) else {
            alertMessage = "Kiểm tra tên, ngày tập, bài tập và mục tiêu; mỗi ngày chỉ có một buổi."
            return false
        }
        var copy = plan
        copy.deletedAt = nil
        if let index = copy.workouts.firstIndex(where: { $0.id == workout.id }) { copy.workouts[index] = workout }
        else { copy.workouts.append(workout) }
        return commitContent(ContentChange(plan: copy), action: "Lưu buổi tập", detail: workout.title, commandId: commandId)
    }

    @discardableResult
    func renamePlan(_ title: String, commandId: UUID = UUID()) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        var copy = plan
        if copy.deletedAt != nil { copy.id = UUID() }
        copy.title = title
        copy.deletedAt = nil
        return commitContent(ContentChange(plan: copy), action: "Sửa giáo án", detail: title, commandId: commandId)
    }

    @discardableResult
    func deleteWorkout(_ id: UUID, commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard let workout = plan.workouts.first(where: { $0.id == id }) else {
            alertMessage = "Buổi tập này không còn trong giáo án."
            return false
        }
        var copy = plan
        copy.workouts.removeAll { $0.id == id }
        return commitContent(ContentChange(plan: copy), action: "Xóa buổi tập", detail: workout.title, commandId: commandId)
    }

    @discardableResult
    func deletePlan(commandId: UUID = UUID()) -> Bool {
        var copy = plan
        copy.workouts = []
        copy.deletedAt = Date()
        return commitContent(ContentChange(plan: copy), action: "Xóa giáo án", detail: plan.title, commandId: commandId)
    }

    /// Commits the change and its audit row in one transaction before publishing it; a failed write leaves
    /// state untouched. A repeated `commandId` is a no-op that reports success.
    private func commitContent(_ change: ContentChange, action: String, detail: String, commandId: UUID) -> Bool {
        var change = change
        change.audit = AuditEntry(id: commandId, at: Date(), action: action, detail: detail)
        return commit(change)
    }

    @discardableResult
    private func commit(_ change: ContentChange) -> Bool {
        do {
            try database.content.apply(change)
            reloadContent()
            return true
        } catch {
            alertMessage = "Không lưu được thay đổi trên máy. Hãy kiểm tra dung lượng và thử lại."
            return false
        }
    }

    private func reloadContent() {
        guard let loaded = try? database.content.load() else { return }
        catalog = loaded.catalog
        if let loadedPlan = loaded.plan { plan = loadedPlan }
        history = loaded.history
        recommendations = loaded.recommendations
        audit = loaded.audit
        settings = loaded.settings
    }

    // MARK: Recommendations (approval workflow + audit trail, AGENTS rule 5)

    /// The decision, the plan edit it approves and the audit row are written in one transaction.
    func decide(_ recommendation: Recommendation, accept: Bool, now: Date = Date(), commandId: UUID = UUID()) {
        guard var decided = recommendations.first(where: { $0.id == recommendation.id }), decided.decision == nil else { return }
        decided.decision = accept ? .accepted : .rejected
        decided.decidedAt = now

        let summary = "\(recommendation.title) (\(recommendation.fromLabel) → \(recommendation.toLabel))"
        var change = ContentChange(recommendations: [decided])
        if !accept {
            change.audit = AuditEntry(id: commandId, at: now, action: "Từ chối đề xuất", detail: summary)
        } else if let planChange = recommendation.change, let edited = applying(planChange, to: plan) {
            change.plan = edited
            change.audit = AuditEntry(id: commandId, at: now, action: "Chấp nhận đề xuất", detail: "\(summary) — đã cập nhật giáo án")
        } else {
            change.audit = AuditEntry(id: commandId, at: now, action: "Chấp nhận đề xuất",
                                      detail: "\(summary) — không áp dụng được: bài tập không còn trong giáo án")
        }
        commit(change)
    }

    private func applying(_ change: PlanChange, to plan: WorkoutPlan) -> WorkoutPlan? {
        var plan = plan
        guard let w = plan.workouts.firstIndex(where: { $0.id == change.plannedWorkoutId }),
              let e = plan.workouts[w].exercises.firstIndex(where: { $0.id == change.plannedExerciseId }) else { return nil }
        if let sets = change.newSetCount { plan.workouts[w].exercises[e].setCount = sets }
        if let target = change.newTarget { plan.workouts[w].exercises[e].target = target }
        if let rest = change.newRestSeconds { plan.workouts[w].exercises[e].restSeconds = rest }
        return plan
    }

    // MARK: Settings & data

    func updateSettings(_ body: (inout AppSettings) -> Void) {
        var copy = settings
        body(&copy)
        guard copy != settings else { return }
        let notificationsTurnedOn = copy.notificationsEnabled && !settings.notificationsEnabled
        guard commit(ContentChange(settings: copy)) else { return }
        if notificationsTurnedOn { notifications.requestAuthorizationIfNeeded() }
        syncSideEffects()
    }

    /// Wipes local data and restores the sample plan/history. Ends any active workout first.
    func resetDemoData(now: Date = Date()) {
        isPlayerPresented = false
        player = nil
        notifications.cancelAll()
        liveActivity.sync(nil, enabled: false)
        var fresh = AppSettings()
        fresh.hasSeenWelcome = settings.hasSeenWelcome
        do {
            try database.content.resetAll(to: AppDatabase.seed(now: now, settings: fresh), now: now)
            reloadContent()
            if let seededPlan = try database.content.load().plan { plan = seededPlan }
        } catch {
            alertMessage = "Không đặt lại được dữ liệu trên máy. (\(error.localizedDescription))"
        }
    }
}

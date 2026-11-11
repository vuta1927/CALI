import CaliCore
import CaliDomain
import Foundation
import Observation

/// App-wide state. Owns the plans, history, recommendations and the active workout. Every change is
/// committed to the local GRDB database first (`AppDatabase`, offline-first) and only then published to
/// the UI; workout commands go through the single-writer `WorkoutCoordinator`.
@Observable
@MainActor
final class AppStore {
    // MARK: State

    private(set) var catalog: [Exercise]
    /// Current revision of every plan lineage, oldest first, soft-deleted ones included (history labels).
    /// Multi-plan lookups and lifecycle commands live in `AppStore+Plans.swift`.
    private(set) var plans: [WorkoutPlan]
    private(set) var history: [CompletedSession]
    private(set) var recommendations: [Recommendation]
    private(set) var audit: [AuditEntry]
    private(set) var settings: AppSettings
    /// CON-005 goals of every plan lineage.
    private(set) var goals: [PlanGoal] = []
    /// CON-007, sensitive (ADR-064): only the app process reads these; nothing here reaches the widget or the AI.
    private(set) var bodyMeasurements: [BodyMeasurement] = []
    /// CON-008: the criteria config the set form is built from and the indicators of the goal pickers. The bundled
    /// version 1 until `GET /v1/criteria-config` has been downloaded; then the cached copy, also offline.
    private(set) var published = PublishedConfig.bundled
    var criteriaConfig: CriteriaConfig { published.criteria }

    /// The in-flight (or just finished) workout. Kept after completion so the summary screen can
    /// render; removed when the player is closed.
    private(set) var player: WorkoutPlayerModel?
    var isPlayerPresented = false

    /// Shown when a start request is refused (e.g. another workout is active).
    var alertMessage: String?

    @ObservationIgnored private let database: AppDatabase
    #if DEBUG
    /// Counts and states for the dev-only Diagnostics screen (IOS-012).
    func databaseDiagnostics() throws -> DatabaseDiagnostics { try DatabaseDiagnostics.read(database.coordinator.writer) }
    #endif
    /// IOS-007: outbox sync and its status (Profile "Đồng bộ").
    /// IOS-008: Sign in with Apple and the account this device's data belongs to.
    @ObservationIgnored private(set) lazy var auth: AuthService = {
        let service = AuthService(coordinator: database.coordinator)
        service.onSessionChanged = { [weak self] in
            self?.sync.reconfigure()
            self?.sync.syncSoon()
        }
        return service
    }()
    @ObservationIgnored private(set) lazy var sync: SyncService = {
        let service = SyncService(coordinator: database.coordinator, auth: auth)
        service.onContentChanged = { [weak self] in self?.reloadContent() }
        service.onConfigChanged = { [weak self] in self?.published = $0 }
        return service
    }()
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private let voiceCues = VoiceCueService()
    @ObservationIgnored private let liveActivity = LiveActivityController()

    /// - Parameters:
    ///   - persists: `false` uses a fresh in-memory database (unit tests hosted in the app).
    ///   - database: an explicit database (tests that simulate a relaunch share one).
    ///   - starterContent: the bundled starter plan, sample history and catalog. Default: only for in-memory stores and tests that
    ///     pass a database; the real app starts empty and takes its catalog from the server.
    init(persists: Bool = true, now: Date = Date(), database: AppDatabase? = nil, starterContent: Bool? = nil) {
        let starter = starterContent ?? (database != nil || !persists)
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
            if starter {
                try self.database.content.seedIfEmpty(AppDatabase.seed(now: now), now: now)
                try self.database.content.insertMissingExercises(MockData.catalog, now: now)
            } else {
                try self.database.content.seedIfEmpty(AppDatabase.emptySeed(), now: now)
            }
            loaded = try self.database.content.load()
        } catch {
            openError = "Không đọc được dữ liệu trên máy (\(error.localizedDescription))."
            loaded = LocalContent(catalog: starter ? MockData.catalog : [], plans: starter ? [MockData.plan] : [], history: [], recommendations: [], audit: [], settings: AppSettings())
        }
        catalog = loaded.catalog
        plans = loaded.plans
        history = loaded.history
        recommendations = loaded.recommendations
        audit = loaded.audit
        settings = loaded.settings
        goals = loaded.goals
        bodyMeasurements = loaded.bodyMeasurements
        alertMessage = openError
        Fmt.weightUnit = loaded.settings.weightUnit
        restoreActiveSession()
        closeEndedGoalScopes(now: now)
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
        model.criteriaConfig = criteriaConfig
        player = model
    }

    // MARK: Lookups

    func exercise(_ id: UUID) -> Exercise? { catalog.first { $0.id == id } }

    func workout(_ id: UUID) -> PlannedWorkout? {
        return plan(containing: id)?.workouts.first { $0.id == id }
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
        model.criteriaConfig = criteriaConfig
        player = model
        isPlayerPresented = true
        if settings.notificationsEnabled { notifications.requestAuthorizationIfNeeded() }
        syncSideEffects()
    }

    /// Runs one workout command through the coordinator (transactional, deduplicated by `commandId`).
    /// Returns `nil` and shows an alert when the database write failed; nothing changed then.
    func execute(_ command: Command, sessionTitle: String? = nil) -> HandleResult? {
        do {
            let result = try database.coordinator.handle(command, sessionTitle: sessionTitle)
            // Not while a workout runs: the network stays out of the player; rows go out after the session or on foreground.
            if !result.replayed, result.state?.isActive != true { sync.syncSoon() }
            return result
        } catch {
            alertMessage = "Không lưu được thao tác trên máy. Hãy thử lại. (\(error.localizedDescription))"
            return nil
        }
    }

    /// A whole session entered by hand, written in one transaction with its audit row (race result).
    func recordSession(_ commands: [Command], sessionTitle: String, audit: AuditEntry) throws -> HandleResult {
        try database.coordinator.recordSession(commands, sessionTitle: sessionTitle, audit: audit)
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
            if model.state.status == .completed { flagReachedGoals(after: model.state.sessionId) }
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
            voiceCues.cancelAll()
            liveActivity.sync(nil, enabled: false)
            return
        }
        let name = player.currentExercise?.name ?? player.title
        voiceCues.library = sync.voiceLibrary
        let deadlineCue = VoiceCuePlan.cues(for: player.state).first(where: \.isPhaseDeadline)?.key
        let voice = deadlineCue.map { (sound: voiceCues.notificationSound(for: $0, enabled: settings.voiceCuesEnabled), text: voiceCues.text(for: $0)) }
        notifications.sync(state: player.state, exerciseName: name, enabled: settings.notificationsEnabled,
                           voice: settings.voiceCuesEnabled ? voice : nil)
        voiceCues.sync(state: player.state, enabled: settings.voiceCuesEnabled, notificationsAllowed: settings.notificationsEnabled)
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
            let referenced = plans.contains { $0.workouts.contains { $0.exercises.contains { $0.exerciseId == exercise.id } } }
                || history.contains { $0.exerciseIds.contains(exercise.id) }
                || (player?.state.executions.contains { $0.exerciseId == exercise.id } ?? false)
            guard !referenced else {
                alertMessage = "Bài đã được sử dụng. Hãy tạo bài mới nếu muốn đổi kiểu tập."
                return false
            }
        }
        return commitContent(ContentChange(exercises: [exercise]), action: "Lưu bài tập", detail: exercise.name, commandId: commandId)
    }

    /// Adds or replaces a workout of plan `lineageId` (one workout per weekday per plan).
    @discardableResult
    func updateWorkout(_ workout: PlannedWorkout, in lineageId: UUID, commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard var plan = plan(lineageId), isEditable(plan) else { return refuse("Giáo án này chỉ xem được.") }
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
        if let index = plan.workouts.firstIndex(where: { $0.id == workout.id }) { plan.workouts[index] = workout }
        else { plan.workouts.append(workout) }
        return commitContent(ContentChange(plans: [plan]), action: "Lưu buổi tập", detail: "\(workout.title) · \(plan.title)", commandId: commandId)
    }

    @discardableResult
    func deleteWorkout(_ id: UUID, commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard var plan = plan(containing: id), let workout = plan.workouts.first(where: { $0.id == id }) else {
            alertMessage = "Buổi tập này không còn trong giáo án."
            return false
        }
        guard isEditable(plan) else { return refuse("Giáo án này chỉ xem được.") }
        plan.workouts.removeAll { $0.id == id }
        return commitContent(ContentChange(plans: [plan]), action: "Xóa buổi tập", detail: "\(workout.title) · \(plan.title)", commandId: commandId)
    }

    /// Commits the change and its audit row in one transaction before publishing it; a failed write leaves
    /// state untouched. A repeated `commandId` is a no-op that reports success.
    func commitContent(_ change: ContentChange, action: String, detail: String, commandId: UUID, now: Date = Date()) -> Bool {
        var change = change
        change.audit = AuditEntry(id: commandId, at: now, action: action, detail: detail)
        return commit(change, now: now)
    }

    @discardableResult
    func commit(_ change: ContentChange, now: Date = Date()) -> Bool {
        do {
            try database.content.apply(change, now: now)
            reloadContent()
            return true
        } catch {
            alertMessage = "Không lưu được thay đổi trên máy. Hãy kiểm tra dung lượng và thử lại."
            return false
        }
    }

    func reloadContent() {
        guard let loaded = try? database.content.load() else { return }
        catalog = loaded.catalog
        plans = loaded.plans
        history = loaded.history
        recommendations = loaded.recommendations
        audit = loaded.audit
        settings = loaded.settings
        goals = loaded.goals
        bodyMeasurements = loaded.bodyMeasurements
        Fmt.weightUnit = loaded.settings.weightUnit
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
        } else if let planChange = recommendation.change, let target = plan(containing: planChange.plannedWorkoutId),
                  isEditable(target, now: now), let edited = applying(planChange, to: target) {
            change.plans = [edited]
            change.audit = AuditEntry(id: commandId, at: now, action: "Chấp nhận đề xuất", detail: "\(summary) — đã cập nhật giáo án")
        } else {
            change.audit = AuditEntry(id: commandId, at: now, action: "Chấp nhận đề xuất",
                                      detail: "\(summary) — không áp dụng được: bài tập không còn trong giáo án đang sửa được")
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

    /// Sign-out (docs/08 §6): the tokens go first and the sync in flight finishes, then the user's choice about local data
    /// is applied. Deleting also ends an active workout, like a reset.
    func signOut(deleteLocalData: Bool, now: Date = Date()) async {
        await auth.endSession()
        await sync.stopAndWait()
        if deleteLocalData {
            isPlayerPresented = false
            player = nil
            notifications.cancelAll()
            voiceCues.cancelAll()
            liveActivity.sync(nil, enabled: false)
            var fresh = AppSettings()
            fresh.hasSeenWelcome = settings.hasSeenWelcome
            do {
                try auth.wipeLocalData(seed: AppDatabase.seed(now: now, settings: fresh), now: now)
                reloadContent()
            } catch {
                alertMessage = "Không xoá được dữ liệu trên máy. (\(error.localizedDescription))"
            }
        }
        sync.reconfigure()
    }

    /// Wipes everything on this phone and starts empty: the catalog and the plans then come from the server (the next sync
    /// pulls from the beginning). Changes not yet sent are lost, so the caller says so first. Ends any active workout.
    func clearLocalData(now: Date = Date()) {
        isPlayerPresented = false
        player = nil
        notifications.cancelAll()
        voiceCues.cancelAll()
        liveActivity.sync(nil, enabled: false)
        var fresh = AppSettings()
        fresh.hasSeenWelcome = settings.hasSeenWelcome
        do {
            try database.content.resetAll(to: AppDatabase.emptySeed(settings: fresh), now: now)
            reloadContent()
            sync.refresh()
            Task {
                await sync.refreshCatalog()
                sync.syncSoon()
            }
        } catch {
            alertMessage = "Không xoá được dữ liệu trên máy. (\(error.localizedDescription))"
        }
    }

    /// Wipes local data and restores the sample plan/history. Ends any active workout first.
    func resetDemoData(now: Date = Date()) {
        isPlayerPresented = false
        player = nil
        notifications.cancelAll()
        voiceCues.cancelAll()
        liveActivity.sync(nil, enabled: false)
        var fresh = AppSettings()
        fresh.hasSeenWelcome = settings.hasSeenWelcome
        do {
            try database.content.resetAll(to: AppDatabase.seed(now: now, settings: fresh), now: now)
            reloadContent()
        } catch {
            alertMessage = "Không đặt lại được dữ liệu trên máy. (\(error.localizedDescription))"
        }
    }
}

import CaliDomain
import Foundation
import Observation

/// Drives one workout session through the pure `WorkoutReducer`.
///
/// - Every user action becomes a domain `Command` with a fresh `commandId`; only accepted transitions
///   change state, and each one is persisted by `AppStore` before side effects run.
/// - Time-based transitions (countdown → exercising, target reached → awaiting result, rest over →
///   ready) are derived by `reconcile` only while the app is executing (tick / foreground). A set is
///   never confirmed because a countdown hit zero (AGENTS safety rules).
@Observable
@MainActor
final class WorkoutPlayerModel {
    enum Banner: Equatable {
        case info(String)
        case error(String)
    }

    private(set) var state: SessionState
    private(set) var records: [SetRecord]
    let title: String

    /// Wall-clock instant the UI renders against; refreshed by `tick()`.
    private(set) var now = Date()
    var banner: Banner?
    /// Increments on every phase change; drives `.sensoryFeedback`.
    private(set) var feedbackTick = 0
    /// Non-nil while a clock change is waiting for the user's confirmation.
    var clockAnomaly: ClockAnomaly?
    var showRecoveryPrompt = false

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var lastTickWall: Date?
    @ObservationIgnored private var lastTickMono: UInt64?
    @ObservationIgnored private var recoveryPromptShown = false
    /// The user confirmed the current time is correct; stays on until the next accepted command
    /// moves `updatedAt` to the new timeline (otherwise the backward check would fire every tick).
    @ObservationIgnored private var clockAcknowledged = false
    /// One client-generated `setResultId` per set, so a double tap re-sends the same id (idempotent).
    @ObservationIgnored private var setResultIds: [SetKey: UUID] = [:]

    init(active: ActiveSession) {
        state = active.state
        records = active.records
        title = active.title
    }

    var activeSnapshot: ActiveSession {
        ActiveSession(state: state, title: title, records: records)
    }

    // MARK: Derived

    var currentExecution: ExecutionSpec? { state.currentExecution }

    var currentExercise: Exercise? {
        currentExecution.flatMap { store?.exercise($0.exerciseId) }
    }

    func exercise(for execution: ExecutionSpec) -> Exercise? {
        store?.exercise(execution.exerciseId)
    }

    var nextUp: (execution: ExecutionSpec, setIndex: Int)? {
        guard let execution = currentExecution else { return nil }
        return (execution, state.currentSetIndex)
    }

    /// Fraction of planned sets that are resolved.
    var progress: Double {
        let total = state.totalPlannedSets
        return total == 0 ? 0 : Double(state.resolvedSets.count) / Double(total)
    }

    var remainingMs: Int64? { state.remainingMs(at: now) }
    var elapsedMs: Int64 { state.exerciseElapsedMs(at: now) }

    var sessionElapsedSeconds: Int {
        let end = state.finishedAt ?? state.abandonedAt ?? now
        return max(0, Int(end.timeIntervalSince(state.startedAt)))
    }

    /// Phase progress for the ring (0...1), counting down for timed phases.
    var phaseProgress: Double {
        guard let start = state.phaseStartedAt, let deadline = state.phaseDeadlineAt else { return 0 }
        let total = deadline.timeIntervalSince(start)
        guard total > 0 else { return 1 }
        return min(max(now.timeIntervalSince(start) / total, 0), 1)
    }

    func records(for execution: ExecutionSpec) -> [SetRecord] {
        records.filter { $0.key.executionId == execution.id }.sorted { $0.key.setIndex < $1.key.setIndex }
    }

    // MARK: Commands

    func startSet() {
        let countdown = store?.settings.countdownSeconds ?? 3
        send(.startSet(StartSet(commandId: UUID(), countdownSeconds: countdown)))
    }

    /// From the rest screen: end rest early (or after it expired) and start the next set.
    func startNextSet() {
        if state.phase == .resting {
            guard send(.readyNext(SimpleCommand(commandId: UUID()))) else { return }
        }
        if state.phase == .ready { startSet() }
    }

    func skipRest() {
        send(.readyNext(SimpleCommand(commandId: UUID())))
    }

    func pause() { send(.pause(SimpleCommand(commandId: UUID()))) }
    func resume() { send(.resume(SimpleCommand(commandId: UUID()))) }
    func stopSet() { send(.stopSet(SimpleCommand(commandId: UUID()))) }
    func extendRest(_ seconds: Int = 30) { send(.extendRest(ExtendRest(commandId: UUID(), seconds: seconds))) }
    func finish() { send(.finishSession(SimpleCommand(commandId: UUID()))) }

    func abandon(reason: String?) {
        send(.abandonSession(AbandonSession(commandId: UUID(), reason: reason)))
    }

    func confirm(status: SetStatus, reps: Int?, holdMs: Int64?, workMs: Int64?, rpe: Int?, note: String?, loadKg: Decimal? = nil) {
        guard let key = state.pendingResult?.key else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        send(.confirmSet(ConfirmSet(
            commandId: UUID(),
            setResultId: resultId(for: key),
            executionId: key.executionId,
            setIndex: key.setIndex,
            status: status,
            actualReps: reps,
            actualHoldMs: holdMs,
            actualWorkMs: workMs,
            rpe: rpe,
            note: (trimmed?.isEmpty ?? true) ? nil : trimmed,
            actualLoadKg: loadKg
        )))
    }

    func skipCurrentSet(reason: String?) {
        guard let key = state.pendingResult?.key ?? state.currentSetKey else { return }
        send(.skipSet(SkipSet(
            commandId: UUID(),
            setResultId: resultId(for: key),
            executionId: key.executionId,
            setIndex: key.setIndex,
            reason: reason
        )))
    }

    private func resultId(for key: SetKey) -> UUID {
        if let id = setResultIds[key] { return id }
        let id = UUID()
        setResultIds[key] = id
        return id
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        let at = Date()
        switch WorkoutReducer.reduce(state, command, now: at) {
        case .success(let transition):
            clockAcknowledged = false
            banner = nil
            apply(transition.state, events: transition.events, at: at)
            return true
        case .failure(.duplicateSetResolution):
            // Idempotent double tap: the set already has its canonical result.
            return true
        case .failure(let error):
            banner = .error(Self.message(for: error))
            return false
        }
    }

    // MARK: Time reconciliation

    /// Called ~4×/s while the player is visible and on every scene-phase change.
    func tick() {
        let wall = Date()
        let mono = MonotonicClock.nowNanos()
        now = wall
        guard state.isActive, clockAnomaly == nil else { return }

        let monoElapsed = lastTickMono.map { MonotonicClock.seconds(from: $0, to: mono) }
        let result = WorkoutReducer.reconcile(
            state,
            now: wall,
            previousNow: lastTickWall,
            monotonicElapsed: monoElapsed,
            acknowledgeClockJump: clockAcknowledged
        )
        for signal in result.signals {
            switch signal {
            case .clockJumpDetected(let anomaly):
                clockAnomaly = anomaly
            case .recoveryPromptRequired:
                if !recoveryPromptShown {
                    recoveryPromptShown = true
                    showRecoveryPrompt = true
                }
            }
        }
        if result.requiresUserReconciliation { return }
        lastTickWall = wall
        lastTickMono = mono
        if result.changed {
            apply(result.state, events: result.events, at: wall)
        }
    }

    /// The user confirmed the device time is correct. Recorded durations are left untouched.
    func acknowledgeClockChange() {
        clockAnomaly = nil
        clockAcknowledged = true
        lastTickWall = nil
        lastTickMono = nil
        tick()
    }

    /// Scene went to background: forget the in-process monotonic baseline is NOT needed (it keeps
    /// counting through sleep), but drop the wall baseline if the process may be killed.
    func sceneDidBecomeActive() {
        tick()
    }

    private func apply(_ newState: SessionState, events: [DomainEvent], at: Date) {
        let previousPhase = state.phase
        state = newState
        now = at
        for event in events {
            switch event {
            case .setConfirmed(let record), .setSkipped(let record):
                if !records.contains(where: { $0.setResultId == record.setResultId }) {
                    records.append(record)
                }
            case .countdownLapsed:
                banner = .info("Đếm ngược đã hết khi app không mở. Set chưa bắt đầu — bấm Bắt đầu khi sẵn sàng.")
            default:
                break
            }
        }
        if case .awaitingResult = newState.phase,
           case .targetDeadlineReached(let lateMs)? = newState.pendingResult?.endReason,
           lateMs > 2_000 {
            banner = .info("Hết thời gian mục tiêu khi app ở nền. Hãy nhập kết quả thực tế của bạn.")
        }
        if state.phase != previousPhase { feedbackTick += 1 }
        store?.playerDidChange(self)
    }

    // MARK: Messages

    static func message(for error: DomainError) -> String {
        switch error {
        case .invalidTransition(let from, _):
            "Thao tác không hợp lệ ở bước \"\(from.label)\"."
        case .sessionNotActive:
            "Buổi tập đã kết thúc."
        case .activeSessionExists:
            "Đang có một buổi tập khác chưa kết thúc."
        case .noSession:
            "Không tìm thấy buổi tập."
        case .duplicateSetResolution:
            "Set này đã được ghi nhận."
        case .setMismatch:
            "Màn hình đã cũ — set hiện tại đã thay đổi."
        case .validationFailed(let issues):
            "Dữ liệu chưa hợp lệ: " + issues.map(Self.describe).joined(separator: "; ")
        case .timestampBeforeSessionStart:
            "Giờ thiết bị sớm hơn lúc bắt đầu buổi tập. Hãy kiểm tra lại giờ hệ thống."
        }
    }

    private static func describe(_ issue: ValidationIssue) -> String {
        switch issue.field {
        case "actualReps": "cần nhập số lần"
        case "actualHoldMs": "cần nhập thời gian giữ"
        case "actualWorkMs": "cần nhập thời gian tập"
        case "actualLoadKg": "cần nhập mức tạ từ 0 đến 1000 kg, tối đa 2 chữ số thập phân"
        case "rpe": "RPE phải từ 1 đến 10"
        case "note": "ghi chú quá dài"
        case "seconds": "thời gian nghỉ vượt giới hạn"
        default: issue.description
        }
    }

    static func describe(_ anomaly: ClockAnomaly) -> String {
        switch anomaly {
        case .backward(let seconds):
            "Giờ thiết bị vừa lùi khoảng \(Int(seconds.rounded())) giây."
        case .monotonicMismatch(let wall, let mono):
            "Giờ thiết bị thay đổi bất thường (đồng hồ: \(Int(wall))s, thực tế: \(Int(mono))s)."
        case .forwardGapExceeded(let seconds):
            "Giờ thiết bị nhảy tới khoảng \(Int(seconds / 3600)) giờ."
        }
    }
}

import ActivityKit
import CaliCore
import CaliDomain
import SwiftUI
import UIKit
import UserNotifications

/// Dev/POC screen for the POC-001/002 device gate (docs/20 phase 0, checklists in `evidence/POC-00x`).
/// Reached from "Cá nhân → POC thiết bị"; it drives its own database and Live Activity and never touches
/// `AppStore` / `AppDatabase`. TODO(POC-002): remove after the GO/NO-GO decision.
struct POCDeviceGateView: View {
    @State private var model = POCDeviceGateModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            environmentSection
            sessionSection
            doubleTapSection
            if let signal = model.clockSignal {
                Section("Đồng hồ") {
                    Text("Phát hiện: \(signal). Thời lượng đã ghi không bị sửa; xác nhận để tiếp tục tính hạn.")
                        .font(.footnote)
                    Button("Xác nhận đổi giờ và đối soát") { model.acknowledgeClockJump() }
                }
            }
            storeSection
            eventSection
        }
        .navigationTitle("POC thiết bị")
        .toolbarTitleDisplayMode(.inline)
        .task {
            await model.prepare()
            while !Task.isCancelled {
                model.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.tick()
                Task { await model.refreshEnvironment() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pocStoreDidChange)) { _ in model.reload() }
    }

    private var environmentSection: some View {
        Section {
            LabeledContent("Build", value: "\(BuildInfo.current.version) (\(BuildInfo.current.build)) · \(String(BuildInfo.current.sha.prefix(7)))")
            LabeledContent("iOS", value: UIDevice.current.systemVersion)
            LabeledContent("DB POC-002", value: model.databaseDescription)
            LabeledContent("App Group", value: POCRuntime.shared.appGroup.summary)
            LabeledContent("Thông báo", value: model.notificationStatus)
            LabeledContent("Live Activities", value: model.activitiesEnabled ? "bật" : "tắt")
            LabeledContent("Protected data", value: model.protectedDataAvailable ? "available" : "unavailable")
            Toggle("Chặn chạm khi máy khoá (guard)", isOn: Binding(get: { model.guardEnabled }, set: { model.setGuard($0) }))
        } header: {
            Text("Môi trường")
        } footer: {
            Text("Nút trên màn khoá dùng authenticationPolicy = requiresAuthentication; guard là lớp phòng thủ thứ hai trong app (mặc định bật). Thông báo chỉ để nhắc, không bao giờ tự ghi kết quả. Không chạy buổi tập thường cùng lúc với POC.")
        }
    }

    private var sessionSection: some View {
        Section {
            if let s = model.state, s.isActive {
                LabeledContent("Phase", value: s.phase.rawValue)
                LabeledContent("Revision", value: String(s.revision))
                LabeledContent("Set", value: "\(s.currentSetIndex)/\(s.currentExecution?.setCount ?? 0)")
                if let deadline = s.phaseDeadlineAt {
                    LabeledContent("Hạn (UTC)", value: deadline.formatted(.iso8601))
                    if deadline > Date() {
                        LabeledContent("Còn lại") { Text(deadline, style: .timer).monospacedDigit() }
                    }
                }
                if let draft = s.pendingResult {
                    LabeledContent("Gợi ý (ms)", value: draft.suggestedActualMs.map(String.init) ?? "– (màn khoá sẽ trả needs_app)")
                    LabeledContent("Đo được (ms)", value: String(draft.measuredElapsedMs))
                }
                actionButtons(for: s)
            } else {
                Button("Bắt đầu phiên POC (Plank giữ 15s × 3, nghỉ 60s)") { model.startSession() }
            }
            if !model.lastMessage.isEmpty {
                Text(model.lastMessage).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Phiên POC")
        } footer: {
            Text("Để thử \"Xong set\" trên màn khoá: giữ app mở tới khi hết 15s (phase awaiting_result có gợi ý), rồi khoá máy và bấm nút trên Live Activity.")
        }
    }

    @ViewBuilder
    private func actionButtons(for s: SessionState) -> some View {
        switch s.phase {
        case .ready:
            Button("Bắt đầu set") { model.send(.startSet(StartSet(commandId: UUID()))) }
        case .preCountdown, .exercising:
            Button("Dừng set") { model.send(.stopSet(SimpleCommand(commandId: UUID()))) }
        case .awaitingResult:
            Button("Xác nhận set (trong app)") { model.confirmInApp() }
        case .resting:
            Button("+30s nghỉ (trong app)") { model.send(.extendRest(ExtendRest(commandId: UUID()))) }
            Button("Sẵn sàng set tiếp") { model.send(.readyNext(SimpleCommand(commandId: UUID()))) }
        case .reviewingSummary:
            Button("Hoàn thành buổi") { model.send(.finishSession(SimpleCommand(commandId: UUID()))) }
        default:
            EmptyView()
        }
        Button("Huỷ phiên POC", role: .destructive) {
            model.send(.abandonSession(AbandonSession(commandId: UUID(), reason: "poc_device_gate_end")))
        }
    }

    private var doubleTapSection: some View {
        Section {
            Button("Chạm đôi, cùng commandId (mô phỏng nút màn khoá)") { Task { await model.doubleTapSameCommandId() } }
            Button("Chạm đôi xác nhận, khác commandId") { Task { await model.doubleConfirmDifferentCommandIds() } }
        } header: {
            Text("Kiểm thử chạm đôi (T-04)")
        } footer: {
            Text("Hai lệnh chạy song song trên coordinator. Kỳ vọng: cùng commandId → 1 applied + 1 replayed; khác commandId → 1 applied + 1 already_resolved; luôn chỉ 1 set_result.")
        }
    }

    private var storeSection: some View {
        Section("Cơ sở dữ liệu") {
            if let c = model.counts {
                LabeledContent("local_session_state", value: String(c.sessions))
                LabeledContent("set_results", value: String(c.setResults))
                LabeledContent("sync_outbox", value: String(c.outbox))
                LabeledContent("processed_commands", value: String(c.processedCommands))
            }
            ForEach(Array(model.outcomes.enumerated()), id: \.offset) { _, o in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(o.kind) · \(o.status.rawValue)\(o.errorCode.map { " · \($0)" } ?? "")")
                        .font(.footnote.weight(.semibold))
                    Text("rev \(o.revision.map(String.init) ?? "–") · \(o.commandId.uuidString.lowercased().prefix(8)) · \(o.processedAt.formatted(.iso8601))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var eventSection: some View {
        Section {
            if let url = POCRuntime.shared.events.url {
                ShareLink(item: url) { Label("Xuất nhật ký (poc-events.jsonl)", systemImage: "square.and.arrow.up") }
            }
            Button("Xoá nhật ký", role: .destructive) { model.clearEvents() }
            ForEach(Array(model.eventLines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2.monospaced()).textSelection(.enabled)
            }
        } header: {
            Text("Nhật ký sự kiện (mới nhất trước)")
        }
    }
}

@Observable
@MainActor
final class POCDeviceGateModel {
    private(set) var state: SessionState?
    private(set) var counts: StoreCounts?
    private(set) var outcomes: [CommandOutcome] = []
    private(set) var eventLines: [String] = []
    private(set) var lastMessage = ""
    private(set) var clockSignal: String?
    private(set) var notificationStatus = "?"
    private(set) var activitiesEnabled = false
    private(set) var protectedDataAvailable = true
    private(set) var guardEnabled = POCRuntime.lockedTapGuardEnabled

    /// Baseline for clock-jump detection; kept unchanged while a jump awaits acknowledgement so the prompt
    /// persists instead of being absorbed by the next tick.
    private var lastWall: Date?
    private var lastMono: UInt64?

    private var runtime: POCRuntime { POCRuntime.shared }

    var databaseDescription: String {
        switch runtime.coordinator {
        case .success: runtime.databasePath ?? "?"
        case .failure(let error): "LỖI: \(error)"
        }
    }

    private var coordinator: WorkoutCoordinator? { try? runtime.coordinator.get() }

    func prepare() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshEnvironment()
        runtime.events.log("poc_screen_opened", [
            "notifications": notificationStatus, "activitiesEnabled": String(activitiesEnabled),
            "appGroup": runtime.appGroup.summary, "guard": String(guardEnabled),
        ])
        // Re-assert the Lock Screen / notification side effects from durable state (e.g. after force-quit).
        POCSideEffects.shared.sync(try? coordinator?.activeState())
        reload()
    }

    func refreshEnvironment() async {
        notificationStatus = switch await Self.notificationAuthorizationStatus() {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
        activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    }

    /// `UNNotificationSettings` is not Sendable (Swift 6): read it off the main actor and return only the enum.
    nonisolated private static func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func setGuard(_ on: Bool) {
        guardEnabled = on
        POCRuntime.lockedTapGuardEnabled = on
        runtime.events.log("guard_changed", ["guard": String(on)])
    }

    func reload() {
        guard let coordinator else { return }
        state = try? coordinator.activeState()
        counts = try? coordinator.counts()
        outcomes = (try? coordinator.recentOutcomes(limit: 20)) ?? []
        eventLines = runtime.events.recentLines(40)
        protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    }

    /// Foreground tick (executable callback): derives timing transitions from persisted deadlines.
    func tick() {
        guard let coordinator else { return }
        let wall = Date()
        let mono = MonotonicClock.nowNanos()
        let elapsed = lastMono.map { MonotonicClock.seconds(from: $0, to: mono) }
        do {
            if let r = try coordinator.reconcile(previousNow: lastWall, monotonicElapsed: elapsed) {
                if r.requiresUserReconciliation {
                    let codes = r.signals.map(\.code).joined(separator: ",")
                    if clockSignal != codes {
                        runtime.events.log("clock_jump_detected", ["signals": codes, "revision": String(r.state.revision)])
                    }
                    clockSignal = codes
                    reload()
                    return
                }
                clockSignal = nil
                if r.changed {
                    runtime.events.log("reconciled", [
                        "phase": r.state.phase.rawValue, "revision": String(r.state.revision),
                        "suggestedActualMs": r.state.pendingResult?.suggestedActualMs.map(String.init) ?? "-",
                    ])
                    POCSideEffects.shared.sync(r.state)
                }
            }
            lastWall = wall
            lastMono = mono
        } catch {
            lastMessage = "reconcile lỗi: \(error)"
        }
        reload()
    }

    func acknowledgeClockJump() {
        guard let coordinator else { return }
        let elapsed = lastMono.map { MonotonicClock.seconds(from: $0, to: MonotonicClock.nowNanos()) }
        do {
            let r = try coordinator.reconcile(previousNow: lastWall, monotonicElapsed: elapsed, acknowledgeClockJump: true)
            runtime.events.log("clock_jump_acknowledged", ["revision": r.map { String($0.state.revision) } ?? "-"])
            clockSignal = nil
            lastWall = Date()
            lastMono = MonotonicClock.nowNanos()
            POCSideEffects.shared.sync(r?.state)
        } catch {
            lastMessage = "acknowledge lỗi: \(error)"
        }
        reload()
    }

    func startSession() {
        let sessionId = UUID()
        let spec = ExecutionSpec(
            id: UUID(), exerciseId: UUID(), catalogVersion: 1, setCount: 3,
            target: .staticHold(holdSeconds: 15), restSeconds: 60
        )
        guard send(.createSession(CreateSession(commandId: UUID(), sessionId: sessionId, executions: [spec]))) else { return }
        send(.startSet(StartSet(commandId: UUID())))
    }

    /// In-app confirmation of the pending draft (user's explicit action; the value is the draft's suggestion
    /// or measured elapsed time, as the real result form would prefill).
    func confirmInApp() {
        guard let s = state, let key = s.currentSetKey, let draft = s.pendingResult else { return }
        let ms = draft.suggestedActualMs ?? draft.measuredElapsedMs
        let setResultId = CommandIdentity.setResultId(sessionId: s.sessionId, executionId: key.executionId, setIndex: key.setIndex)
        send(.confirmSet(ConfirmSet(commandId: UUID(), setResultId: setResultId, executionId: key.executionId,
                                    setIndex: key.setIndex, actualHoldMs: ms)))
    }

    @discardableResult
    func send(_ command: Command) -> Bool {
        guard let coordinator else {
            lastMessage = "DB POC chưa mở được"
            return false
        }
        do {
            let r = try coordinator.handle(command)
            var fields = r.outcome.pocFields(replayed: r.replayed)
            fields["source"] = "app"
            runtime.events.log("command_handled", fields)
            lastMessage = "\(r.outcome.kind): \(r.outcome.status.rawValue)\(r.outcome.errorCode.map { " (\($0))" } ?? "")"
            POCSideEffects.shared.sync(r.state)
            reload()
            return r.outcome.status == .applied
        } catch {
            runtime.events.log("command_failed", ["error": String(describing: error), "source": "app"])
            lastMessage = "Lỗi: \(error)"
            reload()
            return false
        }
    }

    /// Same deterministic commandId twice, concurrently, through the Live Activity entry point.
    func doubleTapSameCommandId() async {
        guard let coordinator, let s = state else { return }
        let action: LiveActivityAction
        switch s.phase {
        case .resting: action = .extendRest30
        case .awaitingResult: action = .confirmCurrentSet
        default:
            lastMessage = "Cần phase resting hoặc awaiting_result"
            return
        }
        let sessionId = s.sessionId
        let revision = s.revision
        let results = await Self.race(2) {
            try coordinator.handleLiveActivityAction(sessionId: sessionId, renderedRevision: revision, action: action)
        }
        report(results, test: "double_tap_same_command_id")
    }

    /// Two confirmations with different commandIds and setResultIds (two stale screens), concurrently.
    func doubleConfirmDifferentCommandIds() async {
        guard let coordinator, let s = state, s.phase == .awaitingResult, let key = s.currentSetKey, let draft = s.pendingResult else {
            lastMessage = "Cần phase awaiting_result"
            return
        }
        let ms = draft.suggestedActualMs ?? draft.measuredElapsedMs
        let results = await Self.race(2) {
            try coordinator.handle(.confirmSet(ConfirmSet(commandId: UUID(), setResultId: UUID(), executionId: key.executionId,
                                                          setIndex: key.setIndex, actualHoldMs: ms)))
        }
        report(results, test: "double_confirm_different_command_ids")
    }

    func clearEvents() {
        runtime.events.clear()
        reload()
    }

    private func report(_ results: [Result<HandleResult, any Error>], test: String) {
        let summary = results.map { r -> String in
            switch r {
            case .success(let h): "\(h.outcome.status.rawValue)\(h.replayed ? "+replayed" : "")\(h.outcome.errorCode.map { "(\($0))" } ?? "")"
            case .failure(let e): "error(\(e))"
            }
        }.joined(separator: " | ")
        let total: Int? = try? coordinator?.counts().setResults
        let setResults = total.map(String.init) ?? "?"
        runtime.events.log(test, ["results": summary, "setResultsTotal": setResults])
        lastMessage = "\(test): \(summary)"
        if case .success(let h)? = results.first { POCSideEffects.shared.sync(h.state) }
        reload()
    }

    private nonisolated static func race(
        _ count: Int, _ work: @escaping @Sendable () throws -> HandleResult
    ) async -> [Result<HandleResult, any Error>] {
        await withTaskGroup(of: Result<HandleResult, any Error>.self) { group in
            for _ in 0..<count {
                group.addTask { Result { try work() } }
            }
            var all: [Result<HandleResult, any Error>] = []
            for await r in group { all.append(r) }
            return all
        }
    }
}

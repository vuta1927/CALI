import ActivityKit
import CaliCore
import CaliDomain
import Foundation
import os
import UIKit
import UserNotifications

/// POC-001/002 device gate (docs/20 phase 0): one GRDB database in the app container, one
/// `WorkoutCoordinator`, reached both from the POC screen and from `POCLiveActivityIntent` (which iOS
/// runs inside the app process). ADR-013: the widget extension never opens this database.
///
/// Isolated from the normal workout: separate file (`Application Support/POC/poc-002.sqlite`), separate
/// notification id, Live Activity flagged `deviceGatePOC`. `LocalStore` stays the app's store until
/// IOS-001 (after a GO). TODO(IOS-001): delete this POC runtime once the coordinator backs the real player.
final class POCRuntime: Sendable {
    static let shared = POCRuntime()

    /// Exercise label rendered on the Lock Screen for the POC session.
    static let exerciseName = "Plank (POC)"
    static let lockedTapGuardKey = "cali.poc.lockedTapGuard"

    let databasePath: String?
    let coordinator: Result<WorkoutCoordinator, any Error>
    let appGroup: AppGroupStatus
    let events = POCEventLog()

    private init() {
        appGroup = AppGroupStatus.check()
        let url = try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("POC", isDirectory: true)
            .appendingPathComponent("poc-002.sqlite")
        databasePath = url?.path
        coordinator = Result {
            guard let url else { throw CocoaError(.fileNoSuchFile) }
            return WorkoutCoordinator(writer: try CaliDatabase.openPool(at: url, label: "POC-002"))
        }
        events.log("runtime_opened", [
            "db": databasePath ?? "-",
            "dbOpen": coordinator.isSuccess ? "true" : "false",
            "appGroup": appGroup.summary,
        ])
    }

    /// App-level guard for Lock Screen taps (defence in depth next to `authenticationPolicy`).
    /// Default ON. When ON and protected data is unavailable, the tap is refused WITHOUT any database
    /// write, so the same deterministic `commandId` still works after the user unlocks.
    static var lockedTapGuardEnabled: Bool {
        get { UserDefaults.standard.object(forKey: lockedTapGuardKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: lockedTapGuardKey) }
    }

    /// Entry point of `POCLiveActivityIntent.perform()` (app process only). Never infers completion from
    /// a countdown: `confirm_current_set` is only accepted for a draft the app already produced
    /// (`WorkoutCoordinator.handleLiveActivityAction`).
    func handleLiveActivityTap(sessionId: String, revision: Int, action: String) async {
        let probe = await MainActor.run {
            (protected: UIApplication.shared.isProtectedDataAvailable, appState: UIApplication.shared.applicationState.pocLabel)
        }
        let guardOn = Self.lockedTapGuardEnabled
        var fields = [
            "sessionId": sessionId, "renderedRevision": String(revision), "action": action,
            "protectedDataAvailable": String(probe.protected), "appState": probe.appState, "guard": String(guardOn),
        ]
        events.log("intent_received", fields)

        guard let id = UUID(uuidString: sessionId), let liveAction = LiveActivityAction(rawValue: action) else {
            events.log("intent_invalid_parameters", fields)
            return
        }
        if guardOn && !probe.protected {
            events.log("intent_refused_locked", fields)
            return
        }
        let coordinator: WorkoutCoordinator
        switch self.coordinator {
        case .success(let c): coordinator = c
        case .failure(let error):
            fields["error"] = String(describing: error)
            events.log("intent_db_unavailable", fields)
            return
        }
        do {
            let result = try coordinator.handleLiveActivityAction(sessionId: id, renderedRevision: revision, action: liveAction)
            fields.merge(result.outcome.pocFields(replayed: result.replayed)) { _, new in new }
            events.log("intent_handled", fields)
            await POCSideEffects.shared.sync(result.state)
            await MainActor.run { NotificationCenter.default.post(name: .pocStoreDidChange, object: nil) }
        } catch {
            fields["error"] = String(describing: error)
            events.log("intent_failed", fields)
        }
    }
}

extension Notification.Name {
    /// Posted on the main actor after a Live Activity intent changed the POC database.
    static let pocStoreDidChange = Notification.Name("cali.poc.storeDidChange")
}

/// App Group availability. ADR-013 does not need one (single writer in the app process); the POC only
/// records whether the signed build has it, so a NO-GO that reopens ADR-013 knows the starting point.
struct AppGroupStatus: Sendable {
    let identifier: String
    let containerPath: String?

    static func check() -> AppGroupStatus {
        let identifier = "group." + (Bundle.main.bundleIdentifier ?? "unknown")
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        return AppGroupStatus(identifier: identifier, containerPath: url?.path)
    }

    var summary: String {
        containerPath.map { "available(\(identifier))" } ?? "unavailable(\(identifier))"
    }
}

/// Append-only JSON-lines evidence log in `Application Support/POC/poc-events.jsonl` (survives relaunch
/// and force-quit, exportable from the POC screen) mirrored to the unified log (subsystem `cali.poc`).
final class POCEventLog: Sendable {
    private static let logger = Logger(subsystem: "cali.poc", category: "device-gate")
    private let queue = DispatchQueue(label: "cali.poc.event-log")
    let url: URL?

    init() {
        let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        url = support?.appendingPathComponent("POC", isDirectory: true).appendingPathComponent("poc-events.jsonl")
    }

    func log(_ event: String, _ fields: [String: String] = [:]) {
        let at = Self.timestamp(Date())
        var line = fields
        line["event"] = event
        line["at"] = at
        line["monotonicNs"] = String(MonotonicClock.nowNanos())
        line["timeZone"] = TimeZone.current.identifier
        let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        Self.logger.notice("\(event, privacy: .public) \(text, privacy: .public)")
        guard let url else { return }
        queue.sync {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }

    func recentLines(_ limit: Int = 40) -> [String] {
        guard let url else { return [] }
        let text = queue.sync { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return Array(text.split(separator: "\n").suffix(limit).reversed()).map(String.init)
    }

    func clear() {
        guard let url else { return }
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    private static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// Live Activity + advisory notification for the POC session only. Notifications are reminders: nothing
/// in their delivery path changes state (AGENTS safety rules). The countdown is system-rendered from the
/// persisted UTC deadline; the activity is updated on transitions only.
@MainActor
final class POCSideEffects {
    static let shared = POCSideEffects()
    static let notificationId = "cali.poc.phase-deadline"

    private var tail: Task<Void, Never>?

    func sync(_ state: SessionState?) {
        syncNotification(state)
        let content = state.flatMap { LiveActivityController.contentState(for: $0, exerciseName: POCRuntime.exerciseName) }
        let previous = tail
        tail = Task {
            await previous?.value
            await Self.apply(content)
        }
    }

    func endAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
        let previous = tail
        tail = Task {
            await previous?.value
            await Self.apply(nil)
        }
    }

    private func syncNotification(_ state: SessionState?) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationId])
        guard let state, state.isActive, let deadline = state.phaseDeadlineAt else { return }
        let interval = deadline.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default
        switch state.phase {
        case .exercising:
            content.title = "POC: hết thời gian mục tiêu"
            content.body = "Mở COAMI để xác nhận set \(state.currentSetIndex). Thông báo chỉ để nhắc, không tự ghi kết quả."
        case .resting:
            content.title = "POC: hết giờ nghỉ"
            content.body = "Sẵn sàng cho set \(state.currentSetIndex)."
        default:
            return
        }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.notificationId, content: content, trigger: trigger))
        POCRuntime.shared.events.log("notification_scheduled", [
            "phase": state.phase.rawValue, "revision": String(state.revision),
            "deadlineUtc": deadline.formatted(.iso8601), "inSeconds": String(Int(interval.rounded())),
        ])
    }

    private nonisolated static func apply(_ content: WorkoutAttributes.ContentState?) async {
        let mine = Activity<WorkoutAttributes>.activities.filter { $0.attributes.deviceGatePOC == true }
        guard let content, content.phase != .completed, content.phase != .abandoned else {
            for activity in mine {
                await activity.end(content.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: .immediate)
            }
            POCRuntime.shared.events.log("live_activity_ended", ["count": String(mine.count)])
            return
        }
        let activityContent = ActivityContent(state: content, staleDate: nil)
        var found = false
        for activity in mine {
            if activity.content.state.sessionId == content.sessionId {
                found = true
                // Never roll the Lock Screen back to an older snapshot (app tick and intent may race).
                guard activity.content.state.revision <= content.revision else { continue }
                await activity.update(activityContent)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        if found {
            POCRuntime.shared.events.log("live_activity_updated", ["revision": String(content.revision), "phase": content.phase.rawValue])
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            POCRuntime.shared.events.log("live_activity_disabled")
            return
        }
        do {
            _ = try Activity<WorkoutAttributes>.request(
                attributes: WorkoutAttributes(deviceGatePOC: true), content: activityContent, pushType: nil
            )
            POCRuntime.shared.events.log("live_activity_requested", ["revision": String(content.revision), "phase": content.phase.rawValue])
        } catch {
            POCRuntime.shared.events.log("live_activity_request_failed", ["error": String(describing: error)])
        }
    }
}

extension CommandOutcome {
    func pocFields(replayed: Bool) -> [String: String] {
        [
            "commandId": commandId.uuidString.lowercased(),
            "kind": kind,
            "status": status.rawValue,
            "replayed": String(replayed),
            "errorCode": errorCode ?? "-",
            "revision": revision.map(String.init) ?? "-",
            "phase": phase ?? "-",
            "setResultIds": setResultIds.map { $0.uuidString.lowercased() }.joined(separator: ","),
        ]
    }
}

extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

extension UIApplication.State {
    var pocLabel: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

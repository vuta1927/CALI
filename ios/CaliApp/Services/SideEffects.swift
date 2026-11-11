import ActivityKit
import CaliDomain
import Foundation
import UserNotifications

/// Monotonic time source for clock-jump detection (AGENTS: "use monotonic clock in-process").
///
/// `CLOCK_MONOTONIC` on Darwin keeps counting while the device sleeps and is not affected by
/// wall-clock or time-zone changes, so `wall elapsed - monotonic elapsed` exposes a manual clock
/// change. (`ProcessInfo.systemUptime` stops during sleep and would raise false alarms.)
enum MonotonicClock {
    static func nowNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        end >= start ? TimeInterval(end - start) / 1_000_000_000 : 0
    }
}

/// Local reminders at phase deadlines. A notification is advisory only: it may be late or never
/// delivered, and nothing in its delivery path changes workout state (AGENTS safety rules).
@MainActor
final class NotificationService {
    static let requestId = "cali.phase-deadline"

    private var authorizationRequested = false

    func requestAuthorizationIfNeeded() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Replaces any pending reminder with one for the current deadline (if any).
    /// - Parameter voice: the spoken cue of this deadline (IOS-019): its sound replaces the default one and its sentence
    ///   leads the body; `sound == nil` (voice off) leaves the default sound.
    func sync(state: SessionState?, exerciseName: String, enabled: Bool, voice: (sound: UNNotificationSound?, text: String)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestId])
        guard enabled, let state, state.isActive, let deadline = state.phaseDeadlineAt else { return }
        let interval = deadline.timeIntervalSinceNow
        guard interval > 1 else { return }

        let content = UNMutableNotificationContent()
        content.sound = voice?.sound ?? .default
        switch state.phase {
        case .exercising:
            content.title = "Hết thời gian mục tiêu"
            content.body = "\(exerciseName) — mở COAMI để xác nhận kết quả set \(state.currentSetIndex)."
        case .resting:
            content.title = "Hết giờ nghỉ"
            content.body = "Sẵn sàng cho \(exerciseName), set \(state.currentSetIndex)."
        default:
            return // pre-countdown is too short to be worth a reminder
        }
        if let text = voice?.text { content.body = "\(text) \(content.body)" }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.requestId, content: content, trigger: trigger))
    }

    func cancelAll() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.requestId])
    }
}

/// Starts/updates/ends the workout Live Activity. Updates happen only on state transitions; the
/// countdown itself is rendered by the system from UTC dates (docs/05 §2: no per-second updates).
@MainActor
final class LiveActivityController {
    /// Serialises ActivityKit calls so a quick "update then end" cannot arrive out of order.
    private var tail: Task<Void, Never>?
    private var lastRevision: Int?

    func sync(_ content: WorkoutAttributes.ContentState?, enabled: Bool) {
        guard let content, enabled else {
            lastRevision = nil
            enqueue { await Self.endAll() }
            return
        }
        guard content.revision != lastRevision else { return }
        lastRevision = content.revision
        let terminal = content.phase == .completed || content.phase == .abandoned
        enqueue {
            if terminal {
                await Self.endAll(final: content)
            } else {
                await Self.upsert(content)
            }
        }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    private nonisolated static func upsert(_ content: WorkoutAttributes.ContentState) async {
        let activityContent = ActivityContent(state: content, staleDate: nil)
        let existing = workoutActivities
        if existing.isEmpty {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            _ = try? Activity<WorkoutAttributes>.request(
                attributes: WorkoutAttributes(),
                content: activityContent,
                pushType: nil
            )
            return
        }
        for activity in existing {
            if activity.content.state.sessionId == content.sessionId {
                await activity.update(activityContent)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        if !existing.contains(where: { $0.content.state.sessionId == content.sessionId }),
           ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity<WorkoutAttributes>.request(attributes: WorkoutAttributes(), content: activityContent, pushType: nil)
        }
    }

    private nonisolated static func endAll(final content: WorkoutAttributes.ContentState? = nil) async {
        for activity in workoutActivities {
            let finalContent = content.map { ActivityContent(state: $0, staleDate: nil) }
            await activity.end(finalContent, dismissalPolicy: content == nil ? .immediate : .after(.now.addingTimeInterval(15 * 60)))
        }
    }

    /// Activities of the normal workout; the POC device-gate activity (`WorkoutAttributes/deviceGatePOC`)
    /// is owned by `POCSideEffects` and never ended or updated from here.
    private nonisolated static var workoutActivities: [Activity<WorkoutAttributes>] {
        Activity<WorkoutAttributes>.activities.filter { $0.attributes.deviceGatePOC != true }
    }

    /// Display snapshot for a session state; `nil` when there is nothing to show.
    static func contentState(for s: SessionState, exerciseName: String, now: Date = Date()) -> WorkoutAttributes.ContentState? {
        guard let phase = WorkoutAttributes.Phase(rawValue: s.phase.rawValue),
              let execution = s.currentExecution ?? s.executions.last else { return nil }
        var start = s.phaseStartedAt ?? now
        var end = s.phaseDeadlineAt ?? start
        var pausedAt: Date?
        if s.phase == .paused, let paused = s.pausedAt {
            start = paused
            end = TimeMath.date(paused, plusMs: s.pausedRemainingMs ?? 0)
            pausedAt = paused
        }
        return WorkoutAttributes.ContentState(
            sessionId: s.sessionId,
            exerciseShortName: exerciseName,
            phase: phase,
            setIndex: s.currentSetIndex,
            setCount: execution.setCount,
            targetSeconds: execution.target.targetDurationSeconds ?? 0,
            phaseStartUtc: start,
            phaseEndUtc: end,
            pausedTimeUtc: pausedAt,
            revision: s.revision
        )
    }
}

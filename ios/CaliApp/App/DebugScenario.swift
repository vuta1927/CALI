#if DEBUG
import CaliCore
import CaliDomain
import Foundation

/// DEBUG only: `-uiScenario run|race` opens a screen that needs several steps to reach, for simulator
/// screenshots. It runs on an in-memory store (nothing reaches the local database) through the normal
/// store commands; the event plan it creates is the user's own kind of data, not a sample.
enum DebugScenario: String {
    /// P6 result form of a 5 km running segment.
    case run
    /// MP-07 race result sheet of an event plan whose event day is today.
    case race

    static var launch: DebugScenario? { UserDefaults.standard.string(forKey: "uiScenario").flatMap(Self.init(rawValue:)) }

    /// Returns the plan whose race result sheet should open.
    @MainActor
    func apply(to store: AppStore) -> UUID? {
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        let run = PlannedExercise(id: UUID(), exerciseId: MockData.easyRun, setCount: 1,
                                  target: .distance(distanceMeters: self == .run ? 5_000 : 10_000, durationSeconds: self == .run ? nil : 3_000),
                                  restSeconds: 0)
        switch self {
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
}
#endif

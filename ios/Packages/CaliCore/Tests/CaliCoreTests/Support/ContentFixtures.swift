import CaliCore
import CaliDomain
import Foundation

/// Small catalog + plan matching the `Specs` exercise ids (7001 hold, 7002 reps, 7003 load).
enum Content {
    static func exercise(_ n: Int, type: ExerciseType, name: String? = nil) -> Exercise {
        Exercise(id: uuid(n), slug: "ex-\(n)", name: name ?? "Bài \(n)", type: type, level: .beginner, equipment: [],
                 muscles: ["core"], cues: [], mistakes: [], catalogVersion: 1, symbol: "figure.core.training", paletteIndex: 0)
    }

    static let catalog = [
        exercise(7001, type: .staticHold, name: "Plank"),
        exercise(7002, type: .reps, name: "Push-up"),
        exercise(7003, type: .load, name: "Squat tạ"),
    ]

    static func plan(id: UUID = uuid(100), exerciseIds: [UUID] = [uuid(7001), uuid(7002)], deletedAt: Date? = nil) -> WorkoutPlan {
        WorkoutPlan(deletedAt: deletedAt, id: id, title: "Kế hoạch tuần", workouts: [
            PlannedWorkout(id: uuid(200), weekday: 1, title: "Thứ 2", focus: "Toàn thân", exercises: exerciseIds.enumerated().map { i, ex in
                PlannedExercise(id: uuid(300 + i), exerciseId: ex, setCount: 3, target: .reps(repMin: 8, repMax: 10), restSeconds: 90)
            }),
        ])
    }

    static func session(_ n: Int, startedAt: Date, sample: Bool = false) -> CompletedSession {
        CompletedSession(id: uuid(n), title: "Buổi \(n)", plannedWorkoutId: uuid(200), startedAt: startedAt,
                         finishedAt: startedAt.addingTimeInterval(1_800), status: .completed, exerciseIds: [uuid(7001)],
                         plannedSetCount: 3, sets: [], isSample: sample)
    }

    static func recommendation(_ n: Int) -> Recommendation {
        Recommendation(id: uuid(n), title: "Tăng set", rationale: "r", uncertainty: "u", confidence: 0.6, exerciseId: uuid(7001),
                       fromLabel: "3 set", toLabel: "4 set",
                       change: PlanChange(plannedWorkoutId: uuid(200), plannedExerciseId: uuid(300), newSetCount: 4), isSample: true)
    }

    static func seed() -> ContentSeed {
        ContentSeed(catalog: catalog, plan: plan(), sampleHistory: [session(400, startedAt: t0.addingTimeInterval(-86_400), sample: true)],
                    sampleRecommendations: [recommendation(500)])
    }
}

extension WorkoutPlan {
    /// The plan without the fields the store fills in on write (activations, creation time, derived
    /// discipline), for comparing a loaded plan with the fixture that was written.
    func stripped() -> WorkoutPlan {
        var copy = self
        copy.activations = []
        copy.createdAt = nil
        copy.primaryDiscipline = nil
        return copy
    }
}

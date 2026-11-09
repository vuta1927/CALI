import CaliDomain
import Foundation

// POC MOCK DATA — TODO(POC-001): remove once the catalog bundle (contracts/catalog-bundle.schema.json)
// and plan/history sync from the backend are wired in. Expiry: first build that talks to the real API.
//
// - The first six exercises and the Monday/Wednesday/Friday plan keep the UUIDs from
//   fixtures/exercise_catalog.json and fixtures/workout_plan.json (development fixtures).
// - Everything else is invented for the POC and is shown with a "Dữ liệu mẫu" badge in the UI.
// - Cues are technique reminders only, not medical advice.
enum MockData {
    private static func id(_ text: String) -> UUID {
        guard let value = UUID(uuidString: text) else { preconditionFailure("bad mock UUID \(text)") }
        return value
    }

    static let catalogVersion = 1

    // MARK: Catalog

    static let tuckPlanche = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")
    static let pullUp = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2")
    static let dips = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3")
    static let lSit = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4")
    static let squat = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5")
    static let ringSupport = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6")
    static let pushUp = id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1")
    static let hollowHold = id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2")
    static let pikePushUp = id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb3")
    static let wallHandstand = id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb4")
    static let burpee = id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb5")
    static let mountainClimber = id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb6")
    static let plank = id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb7")
    static let australianRow = id("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb8")
    // IOS-014 running (ids and slugs from fixtures/exercise_catalog.json).
    static let easyRun = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa7")
    static let timedRun = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa8")
    // IOS-016 gym (id and slug from fixtures/exercise_catalog.json).
    static let backSquat = id("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa9")

    static let catalog: [Exercise] = [
        Exercise(
            id: tuckPlanche, slug: "tuck-planche", name: "Tuck Planche", type: .staticHold, level: .intermediate,
            equipment: [], muscles: ["Vai trước", "Core", "Cổ tay"],
            cues: ["Duỗi thẳng khuỷu tay", "Đẩy vai ra trước", "Giữ thân ổn định"],
            mistakes: ["Gập khuỷu tay", "Vai không đẩy ra trước", "Nín thở"],
            catalogVersion: catalogVersion, symbol: "figure.gymnastics", paletteIndex: 0
        ),
        Exercise(
            id: pullUp, slug: "pull-up", name: "Pull-up", type: .reps, level: .intermediate,
            equipment: ["Xà đơn"], muscles: ["Lưng xô", "Tay trước", "Cẳng tay"],
            cues: ["Kiểm soát thân", "Kéo không giật mạnh"],
            mistakes: ["Đung đưa người", "Không duỗi hết tay ở điểm thấp"],
            catalogVersion: catalogVersion, symbol: "figure.climbing", paletteIndex: 1
        ),
        Exercise(
            id: dips, slug: "dips", name: "Dips", type: .reps, level: .intermediate,
            equipment: ["Xà kép"], muscles: ["Ngực dưới", "Tay sau", "Vai trước"],
            cues: ["Kiểm soát vai", "Không đẩy qua đau khớp"],
            mistakes: ["Nhún vai lên tai", "Xuống quá sâu khi chưa đủ linh hoạt"],
            catalogVersion: catalogVersion, symbol: "figure.strengthtraining.functional", paletteIndex: 2
        ),
        Exercise(
            id: lSit, slug: "l-sit", name: "L-sit", type: .staticHold, level: .intermediate,
            equipment: ["Sàn hoặc parallettes"], muscles: ["Core", "Gập hông", "Tay sau"],
            cues: ["Đẩy vai xuống", "Giữ gối duỗi theo khả năng"],
            mistakes: ["Võng vai", "Gập gối quá nhiều"],
            catalogVersion: catalogVersion, symbol: "figure.core.training", paletteIndex: 3
        ),
        Exercise(
            id: squat, slug: "squat", name: "Squat", type: .reps, level: .beginner,
            equipment: [], muscles: ["Đùi trước", "Mông", "Đùi sau"],
            cues: ["Giữ gót chân ổn định", "Kiểm soát xuống và lên"],
            mistakes: ["Gối đổ vào trong", "Nhấc gót"],
            catalogVersion: catalogVersion, symbol: "figure.strengthtraining.traditional", paletteIndex: 4
        ),
        Exercise(
            id: ringSupport, slug: "ring-support", name: "Ring Support", type: .staticHold, level: .intermediate,
            equipment: ["Vòng treo"], muscles: ["Vai", "Ngực", "Tay sau"],
            cues: ["Ổn định vai", "Dừng nếu đau khớp"],
            mistakes: ["Vòng rung mạnh", "Gập khuỷu tay"],
            catalogVersion: catalogVersion, symbol: "figure.gymnastics", paletteIndex: 5
        ),
        Exercise(
            id: pushUp, slug: "push-up", name: "Push-up", type: .reps, level: .beginner,
            equipment: [], muscles: ["Ngực", "Tay sau", "Core"],
            cues: ["Thân thẳng một đường", "Khuỷu tay khoảng 45°"],
            mistakes: ["Võng hông", "Chỉ xuống nửa biên độ"],
            catalogVersion: catalogVersion, symbol: "figure.strengthtraining.functional", paletteIndex: 6
        ),
        Exercise(
            id: hollowHold, slug: "hollow-body-hold", name: "Hollow Body Hold", type: .staticHold, level: .beginner,
            equipment: [], muscles: ["Core", "Gập hông"],
            cues: ["Ép thắt lưng xuống sàn", "Thở đều"],
            mistakes: ["Thắt lưng nhấc khỏi sàn", "Kéo cổ"],
            catalogVersion: catalogVersion, symbol: "figure.core.training", paletteIndex: 1
        ),
        Exercise(
            id: pikePushUp, slug: "pike-push-up", name: "Pike Push-up", type: .reps, level: .beginner,
            equipment: [], muscles: ["Vai", "Tay sau"],
            cues: ["Hông cao", "Đầu đi về phía trước tay"],
            mistakes: ["Khuỷu tay bè rộng", "Hông thấp dần"],
            catalogVersion: catalogVersion, symbol: "figure.flexibility", paletteIndex: 2
        ),
        Exercise(
            id: wallHandstand, slug: "wall-handstand", name: "Handstand dựa tường", type: .skillAttempt, level: .advanced,
            equipment: ["Tường"], muscles: ["Vai", "Core", "Cổ tay"],
            cues: ["Đẩy sàn, vai lên tai", "Siết mông và bụng"],
            mistakes: ["Lưng cong chuối", "Khuỷu tay mềm"],
            catalogVersion: catalogVersion, symbol: "figure.gymnastics", paletteIndex: 3
        ),
        Exercise(
            id: burpee, slug: "burpee", name: "Burpee", type: .timedReps, level: .beginner,
            equipment: [], muscles: ["Toàn thân"],
            cues: ["Tiếp đất nhẹ", "Giữ nhịp đều"],
            mistakes: ["Võng lưng khi chống đẩy", "Nín thở"],
            catalogVersion: catalogVersion, symbol: "figure.highintensity.intervaltraining", paletteIndex: 4
        ),
        Exercise(
            id: mountainClimber, slug: "mountain-climber", name: "Mountain Climber", type: .interval, level: .beginner,
            equipment: [], muscles: ["Core", "Vai", "Gập hông"],
            cues: ["Vai thẳng trên cổ tay", "Hông thấp"],
            mistakes: ["Hông nhô cao", "Bước chân quá ngắn"],
            catalogVersion: catalogVersion, symbol: "figure.mixed.cardio", paletteIndex: 5
        ),
        Exercise(
            id: plank, slug: "plank", name: "Plank", type: .staticHold, level: .beginner,
            equipment: [], muscles: ["Core", "Vai"],
            cues: ["Siết bụng và mông", "Không võng hông"],
            mistakes: ["Hông quá cao", "Cúi đầu"],
            catalogVersion: catalogVersion, symbol: "figure.pilates", paletteIndex: 6
        ),
        Exercise(
            id: australianRow, slug: "australian-row", name: "Australian Row", type: .reps, level: .beginner,
            equipment: ["Xà thấp hoặc vòng treo"], muscles: ["Lưng giữa", "Tay trước"],
            cues: ["Ngực chạm xà", "Thân thẳng"],
            mistakes: ["Hông chảy xuống", "Kéo bằng cổ"],
            catalogVersion: catalogVersion, symbol: "figure.rower", paletteIndex: 0
        ),
        Exercise(
            id: easyRun, slug: "easy-run", name: "Chạy nhẹ", type: .distance, level: .beginner,
            equipment: [], muscles: ["Tim mạch", "Bắp chân", "Đùi"],
            cues: ["Giữ nhịp thở đều", "Bước ngắn, tiếp đất nhẹ"],
            mistakes: ["Chạy quá nhanh ngay từ đầu", "Sải bước quá dài"],
            catalogVersion: catalogVersion, symbol: "figure.run", paletteIndex: 1
        ),
        Exercise(
            id: timedRun, slug: "timed-run", name: "Chạy theo thời gian", type: .duration, level: .beginner,
            equipment: [], muscles: ["Tim mạch", "Bắp chân", "Đùi"],
            cues: ["Chạy ở mức nói chuyện được", "Thả lỏng vai"],
            mistakes: ["Gồng vai", "Nín thở khi tăng tốc"],
            catalogVersion: catalogVersion, symbol: "figure.run.circle", paletteIndex: 4
        ),
        Exercise(
            id: backSquat, slug: "barbell-back-squat", name: "Barbell Back Squat", type: .load, level: .intermediate,
            equipment: ["Tạ đòn", "Giá squat"], muscles: ["Đùi trước", "Mông", "Core"],
            cues: ["Giữ lưng trung tính", "Gối theo hướng mũi chân"],
            mistakes: ["Gối cụp vào trong", "Lưng tròn ở đáy"],
            catalogVersion: catalogVersion, symbol: "dumbbell", paletteIndex: 2
        ),
    ]

    // MARK: Plan

    static let planId = id("11111111-1111-4111-8111-111111111111")
    static let mondayId = id("22222222-2222-4222-8222-222222222222")
    static let wednesdayId = id("22222222-2222-4222-8222-222222222224")
    static let fridayId = id("22222222-2222-4222-8222-222222222226")
    static let saturdayId = id("22222222-2222-4222-8222-22222222222f")
    static let quickTestId = id("22222222-2222-4222-8222-2222222222aa")

    static let mondayPlanche = id("33333333-3333-4333-8333-333333333331")
    static let mondayPullUp = id("33333333-3333-4333-8333-333333333332")
    static let mondayDips = id("33333333-3333-4333-8333-333333333333")

    private static func item(_ pid: String, _ exercise: UUID, _ sets: Int, _ target: Prescription, rest: Int) -> PlannedExercise {
        PlannedExercise(id: id(pid), exerciseId: exercise, setCount: sets, target: target, restSeconds: rest)
    }

    static let plan = WorkoutPlan(
        id: planId,
        title: "Planche Foundation / Pull / Legs — Demo",
        workouts: [
            PlannedWorkout(id: mondayId, weekday: 1, title: "Planche / Pull / Legs", focus: "Sức mạnh đẩy & kéo", exercises: [
                item("33333333-3333-4333-8333-333333333331", tuckPlanche, 4, .staticHold(holdSeconds: 12), rest: 90),
                item("33333333-3333-4333-8333-333333333332", pullUp, 4, .reps(repMin: 8, repMax: 10), rest: 120),
                item("33333333-3333-4333-8333-333333333333", dips, 3, .reps(repMin: 10, repMax: 15), rest: 90),
                item("44444444-4444-4444-8444-444444444441", squat, 3, .reps(repMin: 15, repMax: 20), rest: 60),
            ]),
            PlannedWorkout(id: wednesdayId, weekday: 3, title: "Static Hold / Legs", focus: "Giữ tĩnh & chân", exercises: [
                item("33333333-3333-4333-8333-333333333334", lSit, 3, .staticHold(holdSeconds: 15), rest: 90),
                item("44444444-4444-4444-8444-444444444442", ringSupport, 3, .staticHold(holdSeconds: 20), rest: 90),
                item("44444444-4444-4444-8444-444444444443", squat, 4, .reps(repMin: 15, repMax: 20), rest: 60),
                item("44444444-4444-4444-8444-444444444444", plank, 3, .staticHold(holdSeconds: 45), rest: 45),
            ]),
            PlannedWorkout(id: fridayId, weekday: 5, title: "Pull / Legs", focus: "Kéo & chân", exercises: [
                item("33333333-3333-4333-8333-333333333335", pullUp, 3, .reps(repMin: 8, repMax: 10), rest: 120),
                item("44444444-4444-4444-8444-444444444445", australianRow, 3, .reps(repMin: 10, repMax: 12), rest: 90),
                item("44444444-4444-4444-8444-444444444446", squat, 3, .reps(repMin: 15, repMax: 20), rest: 60),
                item("44444444-4444-4444-8444-444444444447", burpee, 3, .timedReps(timeSeconds: 30), rest: 60),
            ]),
            PlannedWorkout(id: saturdayId, weekday: 6, title: "Skill & Core", focus: "Kỹ năng & core", exercises: [
                item("44444444-4444-4444-8444-444444444448", wallHandstand, 3, .skillAttempt(attempts: 3), rest: 90),
                item("44444444-4444-4444-8444-444444444449", pikePushUp, 3, .reps(repMin: 6, repMax: 10), rest: 90),
                item("44444444-4444-4444-8444-44444444444a", hollowHold, 3, .staticHold(holdSeconds: 30), rest: 45),
                item("44444444-4444-4444-8444-44444444444b", mountainClimber, 3, .interval(workSeconds: 30, restSeconds: 15), rest: 30),
            ]),
        ]
    )

    /// Short session covering all five exercise types, so the whole player flow can be tried in ~3 minutes.
    static let quickTest = PlannedWorkout(id: quickTestId, weekday: 0, title: "Buổi thử nhanh", focus: "Đủ 5 loại bài · ~3 phút", exercises: [
        item("55555555-5555-4555-8555-555555555551", hollowHold, 2, .staticHold(holdSeconds: 10), rest: 15),
        item("55555555-5555-4555-8555-555555555552", pushUp, 2, .reps(repMin: 5, repMax: 8), rest: 15),
        item("55555555-5555-4555-8555-555555555553", burpee, 1, .timedReps(timeSeconds: 15), rest: 15),
        item("55555555-5555-4555-8555-555555555554", mountainClimber, 1, .interval(workSeconds: 15, restSeconds: 10), rest: 10),
        item("55555555-5555-4555-8555-555555555555", wallHandstand, 1, .skillAttempt(attempts: 2), rest: 0),
    ])

    // MARK: Sample history (relative to `now`, always flagged isSample)

    static func sampleHistory(now: Date = Date(), calendar: Calendar = .current) -> [CompletedSession] {
        let specs: [(daysAgo: Int, workout: PlannedWorkout, variant: Int)] = [
            (2, plan.workouts[2], 0),
            (4, plan.workouts[1], 1),
            (6, plan.workouts[0], 2),
            (9, plan.workouts[2], 3),
            (11, plan.workouts[1], 4),
            (13, plan.workouts[0], 5),
        ]
        return specs.enumerated().map { index, spec in
            let day = calendar.date(byAdding: .day, value: -spec.daysAgo, to: now) ?? now
            let start = calendar.date(bySettingHour: 18, minute: 30, second: 0, of: day) ?? day
            let sets = sampleSets(for: spec.workout, variant: spec.variant, sessionIndex: index)
            let minutes = spec.workout.estimatedMinutes + (spec.variant % 3) * 2
            return CompletedSession(
                id: UUID(),
                title: spec.workout.title,
                plannedWorkoutId: spec.workout.id,
                startedAt: start,
                finishedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                status: .completed,
                exerciseIds: spec.workout.exercises.map(\.exerciseId),
                plannedSetCount: spec.workout.totalSets,
                sets: sets,
                isSample: true
            )
        }
    }

    /// Deterministic, plausible numbers. Older sessions (higher variant) are slightly weaker, so the
    /// history reads as progress.
    private static func sampleSets(for workout: PlannedWorkout, variant: Int, sessionIndex: Int) -> [LoggedSet] {
        var result: [LoggedSet] = []
        for (exerciseIndex, item) in workout.exercises.enumerated() {
            for setIndex in 1...item.setCount {
                let fatigue = setIndex - 1
                let seed = (exerciseIndex * 7 + setIndex * 3 + variant * 5 + sessionIndex) % 10
                var set = LoggedSet(
                    id: UUID(), exerciseId: item.exerciseId, setIndex: setIndex, status: .completed,
                    target: item.target, reps: nil, holdMs: nil, workMs: nil,
                    rpe: min(10, 6 + fatigue + (seed % 2)), note: nil, skipReason: nil
                )
                switch item.target {
                case .staticHold(let s):
                    let actual = max(3, s - fatigue - variant / 2 + (seed % 3 == 0 ? 1 : 0))
                    set.holdMs = Int64(actual) * 1000 + Int64(seed % 2) * 500
                case .reps(let lo, let hi):
                    set.reps = max(1, min(hi, hi - fatigue - variant / 2))
                    if set.reps! < lo { set.status = .failed }
                case .timedReps(let s):
                    set.reps = max(5, 14 - fatigue - variant / 2)
                    set.workMs = Int64(s) * 1000
                case .interval(let work, _):
                    set.workMs = Int64(work) * 1000
                case .skillAttempt:
                    set.status = seed % 3 == 0 ? .failed : .completed
                case .load(let r, let kg):
                    // Exhaustiveness only: the sample plan has no load exercise, so no load history is generated.
                    set.reps = r
                    set.loadKg = kg
                case .distance(let meters, let seconds):
                    // Exhaustiveness only: the sample plan has no running exercise.
                    set.distanceMeters = meters
                    set.durationSeconds = seconds ?? 1800
                case .duration(let seconds):
                    set.durationSeconds = seconds
                }
                if variant == 1, exerciseIndex == 0, setIndex == item.setCount {
                    set.status = .skipped
                    set.holdMs = nil
                    set.reps = nil
                    set.rpe = nil
                    set.skipReason = "Mệt"
                }
                if sessionIndex == 0, exerciseIndex == 0, setIndex == 1 {
                    set.note = "Cảm thấy khỏe, kéo dứt khoát."
                }
                result.append(set)
            }
        }
        return result
    }

    // MARK: Sample AI recommendations (no LLM involved)

    static func sampleRecommendations() -> [Recommendation] {
        [
            Recommendation(
                id: id("66666666-6666-4666-8666-666666666661"),
                title: "Tăng thời gian giữ Tuck Planche",
                rationale: "3 buổi gần nhất bạn hoàn thành 4/4 set, RPE trung bình 7. Tăng nhẹ thời gian giữ để tiếp tục tiến bộ.",
                uncertainty: "Dựa trên 3 buổi dữ liệu mẫu. Đây là gợi ý tập luyện, không phải lời khuyên y tế.",
                confidence: 0.72,
                exerciseId: tuckPlanche,
                fromLabel: "4 × giữ 12s", toLabel: "4 × giữ 15s",
                change: PlanChange(plannedWorkoutId: mondayId, plannedExerciseId: mondayPlanche, newSetCount: nil,
                                   newTarget: .staticHold(holdSeconds: 15), newRestSeconds: nil),
                decision: nil, decidedAt: nil, isSample: true
            ),
            Recommendation(
                id: id("66666666-6666-4666-8666-666666666662"),
                title: "Giảm khối lượng Dips",
                rationale: "Set cuối của Dips thường dưới mức tối thiểu và RPE 9. Giảm biên độ số lần để giữ kỹ thuật tốt.",
                uncertainty: "Có thể do mệt từ bài trước. Nếu đau khớp vai, hãy dừng và hỏi chuyên gia.",
                confidence: 0.58,
                exerciseId: dips,
                fromLabel: "3 × 10–15 lần", toLabel: "3 × 8–12 lần",
                change: PlanChange(plannedWorkoutId: mondayId, plannedExerciseId: mondayDips, newSetCount: nil,
                                   newTarget: .reps(repMin: 8, repMax: 12), newRestSeconds: nil),
                decision: nil, decidedAt: nil, isSample: true
            ),
            Recommendation(
                id: id("66666666-6666-4666-8666-666666666663"),
                title: "Nghỉ lâu hơn giữa các set Pull-up",
                rationale: "Số lần giảm mạnh từ set 1 đến set 4. Thêm 30 giây nghỉ có thể giữ số lần ổn định hơn.",
                uncertainty: "Độ tin cậy thấp: ít dữ liệu về thời gian nghỉ thực tế.",
                confidence: 0.45,
                exerciseId: pullUp,
                fromLabel: "nghỉ 2 phút", toLabel: "nghỉ 2p30s",
                change: PlanChange(plannedWorkoutId: mondayId, plannedExerciseId: mondayPullUp, newSetCount: nil,
                                   newTarget: nil, newRestSeconds: 150),
                decision: nil, decidedAt: nil, isSample: true
            ),
        ]
    }
}

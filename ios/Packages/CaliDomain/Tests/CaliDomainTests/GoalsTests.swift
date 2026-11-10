import CaliDomain
import XCTest

/// IOS-015 / CON-005: goal rules, phase timeline and progress, all pure.
final class GoalsTests: XCTestCase {
    private let lineage = UUID()
    private let plank = UUID()
    private let pushUp = UUID()
    private var hold: IndicatorDefinition { IndicatorDefinition.bundled.first { $0.id == "best_hold_seconds" }! }
    private var weeklyReps: IndicatorDefinition { IndicatorDefinition.bundled.first { $0.id == "weekly_total_reps" }! }

    private func goal(_ id: UUID = UUID(), indicator: String = "best_hold_seconds", exercise: UUID? = nil, target: GoalTarget = .value(15),
                      after: UUID? = nil, status: GoalStatus = .active, achievedAt: Date? = nil, pinned: Bool = false) -> PlanGoal {
        PlanGoal(id: id, planLineageId: lineage, title: "Giữ 15 giây", indicatorId: indicator, exerciseId: exercise ?? plank,
                 target: target, unlockAfterGoalId: after, status: status, achievedAt: achievedAt, pinned: pinned)
    }

    func testBundledIndicatorsMatchDb005AndMeasurementTypes() {
        XCTAssertEqual(IndicatorDefinition.bundled.map(\.id), ["best_hold_seconds", "best_set_reps", "milestone_hold_seconds",
                                                              "milestone_reps", "weekly_total_reps", "weekly_total_hold_seconds"])
        XCTAssertEqual(ExerciseType.staticHold.measurementType, .hold)
        XCTAssertEqual(ExerciseType.skillAttempt.measurementType, .reps)
        XCTAssertEqual(ExerciseType.interval.measurementType, .duration)
        XCTAssertTrue(hold.applies(to: .staticHold))
        XCTAssertFalse(hold.applies(to: .reps))
    }

    func testValidationCoversContractRules() {
        XCTAssertEqual(GoalRules.validate(goal(), indicator: hold, exerciseType: .staticHold, others: []), [])
        XCTAssertEqual(GoalRules.validate(goal(), indicator: hold, exerciseType: .reps, others: []).map(\.field), ["exerciseId"])
        var untitled = goal()
        untitled.title = "  "
        XCTAssertEqual(GoalRules.validate(untitled, indicator: hold, exerciseType: .staticHold, others: []).map(\.field), ["title"])
        XCTAssertEqual(GoalRules.validate(goal(target: .range(min: 5, max: 4)), indicator: hold, exerciseType: .staticHold, others: []).map(\.field), ["target.max"])
        XCTAssertEqual(GoalRules.validate(goal(status: .achieved), indicator: hold, exerciseType: .staticHold, others: []).map(\.field), ["achievedAt"])
        XCTAssertEqual(GoalRules.validate(goal(status: .active, achievedAt: Date()), indicator: hold, exerciseType: .staticHold, others: []).map(\.field), ["achievedAt"])
        XCTAssertEqual(GoalRules.validate(goal(status: .archived, achievedAt: Date()), indicator: hold, exerciseType: .staticHold, others: []), [])
        XCTAssertEqual(GoalRules.validate(goal(), indicator: nil, exerciseType: .staticHold, others: []).map(\.field), ["indicatorId"])
    }

    func testPinnedLimitIsThreePerLineage() {
        let pinned = (0..<3).map { _ in goal(pinned: true) }
        XCTAssertEqual(GoalRules.validate(goal(pinned: true), indicator: hold, exerciseType: .staticHold, others: pinned).map(\.field), ["pinned"])
        XCTAssertEqual(GoalRules.validate(pinned[0], indicator: hold, exerciseType: .staticHold, others: pinned), [], "re-saving a pinned goal")
        var other = goal(pinned: true)
        other.planLineageId = UUID()
        XCTAssertEqual(GoalRules.validate(other, indicator: hold, exerciseType: .staticHold, others: pinned), [])
    }

    func testUnlockChainLocksUntilConfirmedAndRejectsCycles() {
        let a = UUID(), b = UUID()
        let first = goal(a)
        let second = goal(b, after: a)
        XCTAssertTrue(GoalRules.isLocked(second, in: [first, second]))
        XCTAssertTrue(GoalRules.isLocked(second, in: [goal(a, status: .reached), second]), "reached is not confirmed")
        XCTAssertFalse(GoalRules.isLocked(second, in: [goal(a, status: .achieved, achievedAt: Date()), second]))
        XCTAssertFalse(GoalRules.isLocked(second, in: [goal(a, status: .archived, achievedAt: Date()), second]))
        XCTAssertTrue(GoalRules.createsCycle(goal(a, after: b), in: [first, second]))
        XCTAssertFalse(GoalRules.createsCycle(second, in: [first, second]))
        XCTAssertEqual(GoalRules.validate(goal(a, after: a), indicator: hold, exerciseType: .staticHold, others: []).map(\.field), ["unlockAfterGoalId"])
    }

    func testPhaseSpansAreComputedFromOrderAndLength() {
        let phases = [PlanPhase(id: UUID(), name: "Nền tảng", weeks: 4), PlanPhase(id: UUID(), name: "Tăng", weeks: 1), PlanPhase(id: UUID(), name: "Đỉnh", weeks: 3)]
        XCTAssertEqual(PhaseTimeline.totalWeeks(phases), 8)
        let spans = PhaseTimeline.spans(phases, currentWeek: 5)
        XCTAssertEqual(spans.map(\.label), ["Tuần 1–4", "Tuần 5", "Tuần 6–8"])
        XCTAssertEqual(spans.map(\.state), [.done, .current, .upcoming])
        XCTAssertEqual(PhaseTimeline.spans(phases, currentWeek: 0).map(\.state), [.upcoming, .upcoming, .upcoming])
        XCTAssertEqual(PhaseTimeline.spans(phases, currentWeek: 9).map(\.state), [.done, .done, .done])
        XCTAssertEqual(PhaseTimeline.validate([PlanPhase(id: UUID(), name: "", weeks: 53)]).map(\.field), ["phases[0].name", "phases[0].weeks"])
    }

    func testProgressUsesFirstWeekAsReferenceAndNeedsTwoWeeks() {
        let samples = [
            MetricSample(week: 1, exerciseId: plank, measurement: .hold, value: 10),
            MetricSample(week: 1, exerciseId: plank, measurement: .hold, value: 12),
            MetricSample(week: 3, exerciseId: plank, measurement: .hold, value: 15),
            MetricSample(week: 4, exerciseId: plank, measurement: .hold, value: 14),
            MetricSample(week: 2, exerciseId: pushUp, measurement: .reps, value: 9),
        ]
        let best = GoalProgress.summary(samples: samples, exerciseId: plank, measurement: .hold, aggregation: .max, weeks: 1...6)
        XCTAssertEqual(best.points.map(\.value), [12, nil, 15, 14, nil, nil], "empty weeks stay empty")
        XCTAssertEqual(best.current, 15)
        XCTAssertEqual(best.currentWeek, 3)
        XCTAssertEqual(best.reference, 12)
        XCTAssertEqual(best.referenceWeek, 1)
        XCTAssertEqual(best.delta, 3)
        XCTAssertEqual(best.percent, 25)

        let total = GoalProgress.summary(samples: samples, exerciseId: plank, measurement: .hold, aggregation: .sum)
        XCTAssertEqual(total.current, 14, "sum: latest week with data")
        XCTAssertEqual(total.reference, 22)

        let single = GoalProgress.summary(samples: samples, exerciseId: pushUp, measurement: .reps, aggregation: .max)
        XCTAssertEqual(single.current, 9)
        XCTAssertNil(single.reference, "one week is not enough to compare")
        XCTAssertNil(single.percent)
    }

    func testGoalCurrentByKindAndScope() {
        let samples = [
            MetricSample(week: 1, exerciseId: plank, measurement: .hold, value: 20),
            MetricSample(week: 2, exerciseId: pushUp, measurement: .reps, value: 8),
            MetricSample(week: 2, exerciseId: pushUp, measurement: .reps, value: 7),
            MetricSample(week: 3, exerciseId: plank, measurement: .hold, value: 12),
        ]
        XCTAssertEqual(GoalProgress.current(of: goal(), indicator: hold, exerciseType: .staticHold, samples: samples, scopeWeeks: nil, currentWeek: 3), 20)
        XCTAssertEqual(GoalProgress.current(of: goal(), indicator: hold, exerciseType: .staticHold, samples: samples, scopeWeeks: 2...4, currentWeek: 3), 12)
        let volume = goal(indicator: "weekly_total_reps", exercise: pushUp)
        XCTAssertEqual(GoalProgress.current(of: volume, indicator: weeklyReps, exerciseType: .reps, samples: samples, scopeWeeks: nil, currentWeek: 2), 15)
        XCTAssertNil(GoalProgress.current(of: volume, indicator: weeklyReps, exerciseType: .reps, samples: samples, scopeWeeks: nil, currentWeek: 3))
    }

    func testValuesTargetsAndFraction() {
        XCTAssertEqual(GoalProgress.value(of: .hold, holdMs: 12_340, reps: nil), Decimal(string: "12.3"))
        XCTAssertNil(GoalProgress.value(of: .hold, holdMs: 0, reps: nil))
        XCTAssertEqual(GoalProgress.value(of: .reps, holdMs: nil, reps: 9), 9)
        XCTAssertTrue(GoalTarget.value(15).isMet(by: 15))
        XCTAssertFalse(GoalTarget.value(15).isMet(by: nil))
        XCTAssertTrue(GoalTarget.range(min: 67, max: 69).isMet(by: 68))
        XCTAssertEqual(GoalProgress.fraction(current: 12, baseline: 10, target: .value(14)), 0.5)
        XCTAssertEqual(GoalProgress.fraction(current: 20, baseline: nil, target: .value(15)), 1)
    }

    func testGoalRoundTripsWithContractTargetShape() throws {
        let g = goal(target: .range(min: 67, max: 69))
        let data = try DomainJSON.makeEncoder().encode(g)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["target"] as? [String: Any])?.keys.sorted(), ["max", "min"])
        XCTAssertEqual(try DomainJSON.makeDecoder().decode(PlanGoal.self, from: data), g)
    }
}

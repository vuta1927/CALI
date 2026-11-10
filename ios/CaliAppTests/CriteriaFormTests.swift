import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-016: the set form is built from the criteria config; values are saved with their config version.
final class CriteriaFormTests: XCTestCase {
    override func tearDown() {
        Fmt.weightUnit = .kg
        super.tearDown()
    }

    @MainActor
    private func makeStore() throws -> AppStore {
        let store = AppStore(now: Date().addingTimeInterval(-10 * 86_400), database: try AppDatabase.inMemory())
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        return store
    }

    /// Starts a one-set workout of the first catalog exercise of `type` and stops the set (waiting for a result).
    @MainActor
    private func awaitingResult(_ store: AppStore, type: ExerciseType, target: Prescription) throws -> (WorkoutPlayerModel, Exercise) {
        let exercise = try XCTUnwrap(store.catalog.first { $0.type == type })
        let item = PlannedExercise(id: UUID(), exerciseId: exercise.id, setCount: 1, target: target, restSeconds: 60)
        store.startWorkout(PlannedWorkout(id: UUID(), weekday: 1, title: "Test", focus: "", exercises: [item]))
        let model = try XCTUnwrap(store.player)
        model.startSet()
        model.stopSet()
        XCTAssertEqual(model.state.phase, .awaitingResult)
        return (model, exercise)
    }

    @MainActor
    func testFormFieldsFollowTheConfigAndTheExerciseDiscipline() throws {
        let store = try makeStore()
        let cali = try XCTUnwrap(store.catalog.first { $0.type == .staticHold })
        let gym = try XCTUnwrap(store.catalog.first { $0.type == .load })
        func ids(_ e: Exercise) -> [String] { store.criteriaConfig.applicable(exerciseId: e.id, type: e.type).map(\.id) }
        XCTAssertEqual(ids(cali), ["technique", "condition", "pain"])
        XCTAssertEqual(ids(gym), ["technique", "rpe", "equipment", "pain"])
    }

    @MainActor
    func testConfirmSavesCriteriaPainAndLoadWithTheConfigVersion() throws {
        let store = try makeStore()
        let (model, exercise) = try awaitingResult(store, type: .load, target: .load(reps: 5, loadKg: 60))
        model.confirm(status: .completed, reps: 5, holdMs: nil, workMs: nil, rpe: 8, note: nil, loadKg: Decimal(string: "62.5"),
                      painReported: true, criteria: ["technique": .token("good"), "equipment": .tokens(["barbell", "smith"])])
        let record = try XCTUnwrap(model.records.first)
        XCTAssertEqual(record.actual.loadKg, Decimal(string: "62.5"))
        XCTAssertEqual(record.actual.rpe, 8)
        XCTAssertEqual(record.actual.painReported, true)
        XCTAssertEqual(record.actual.criteriaVersion, store.criteriaConfig.version)
        XCTAssertEqual(record.actual.criteria?["technique"], .token("good"))
        model.finish()
        let set = try XCTUnwrap(store.history.first?.sets.first)
        XCTAssertEqual(set.exerciseId, exercise.id)
        XCTAssertEqual(store.criteriaSummary(of: set), "Kỹ thuật (tự đánh giá): Chuẩn · Dụng cụ: Tạ đòn, Smith · Có ghi nhận đau")
    }

    @MainActor
    func testUnknownOptionIsRefusedAndNothingIsSaved() throws {
        let store = try makeStore()
        let (model, _) = try awaitingResult(store, type: .staticHold, target: .staticHold(holdSeconds: 10))
        model.confirm(status: .completed, reps: nil, holdMs: 10_000, workMs: nil, rpe: nil, note: nil, criteria: ["technique": .token("perfect")])
        XCTAssertTrue(model.records.isEmpty)
        if case .error? = model.banner {} else { XCTFail("expected an error banner") }
        model.confirm(status: .completed, reps: nil, holdMs: 10_000, workMs: nil, rpe: nil, note: nil)
        XCTAssertEqual(model.records.count, 1)
        XCTAssertNil(model.records.first?.actual.criteriaVersion, "no values: no version either")
    }

    @MainActor
    func testPreviousSetPrefillsOnlyCriteriaThatAskForIt() throws {
        let store = try makeStore()
        let exercise = try XCTUnwrap(store.catalog.first { $0.type == .staticHold })
        let applicable = store.criteriaConfig.applicable(exerciseId: exercise.id, type: exercise.type)
        let previous = SetActuals(painReported: true, criteriaVersion: 1,
                                  criteria: ["technique": .token("ok"), "condition": .tokens(["assist"])])
        XCTAssertEqual(CriteriaFields.prefill(applicable, from: previous), ["condition": .tokens(["assist"])])
        XCTAssertEqual(CriteriaFields.prefill(applicable, from: nil), [:])
    }

    @MainActor
    func testWeightUnitSettingChangesDisplayOnly() throws {
        let store = try makeStore()
        XCTAssertEqual(Fmt.loadKg(Decimal(string: "57.5")!), "57,5 kg")
        store.updateSettings { $0.weightUnit = .lb }
        XCTAssertEqual(Fmt.weightUnit, .lb)
        XCTAssertEqual(Fmt.loadKg(60), "132,3 lb")
        XCTAssertEqual(Fmt.target(.load(reps: 5, loadKg: 60)), "5 lần @ 132,3 lb")
        store.updateSettings { $0.weightUnit = .kg }
        XCTAssertEqual(Fmt.loadKg(60), "60 kg")
    }
}

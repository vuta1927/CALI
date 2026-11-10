import XCTest
import CaliDomain
@testable import CaliApp

final class ContentEditingTests: XCTestCase {
    @MainActor
    func testExerciseEditAndRepeatedCommandKeepStableIdentity() throws {
        let store = AppStore(persists: false)
        var exercise = store.catalog[0]
        exercise.name = "Tên riêng"
        let command = UUID()
        XCTAssertTrue(store.saveExercise(exercise, commandId: command))
        XCTAssertTrue(store.saveExercise(exercise, commandId: command))
        XCTAssertEqual(store.exercise(exercise.id)?.name, "Tên riêng")
        XCTAssertEqual(store.audit.filter { $0.id == command }.count, 1)
        XCTAssertEqual(store.starterPlan.workouts[0].exercises[0].exerciseId, exercise.id)
    }

    @MainActor
    func testDeletePlanIsBlockedDuringItsWorkoutThenKeepsHistoryAndWorkouts() throws {
        let store = AppStore(persists: false)
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false }
        store.startWorkout(store.starterPlan.workouts[0])
        let session = try XCTUnwrap(store.player?.state.sessionId)
        XCTAssertFalse(store.deleteStarterPlan())
        XCTAssertNil(store.starterPlan.deletedAt)
        XCTAssertEqual(store.player?.state.sessionId, session)

        store.player?.abandon(reason: "test")
        let history = store.history
        let workouts = store.starterPlan.workouts
        XCTAssertTrue(store.deleteStarterPlan())
        XCTAssertNotNil(store.starterPlan.deletedAt)
        XCTAssertEqual(store.starterPlan.workouts, workouts)
        XCTAssertEqual(store.history, history)
        XCTAssertEqual(store.planLabel(for: try XCTUnwrap(store.history.first { $0.id == session })), "\(store.starterPlan.title) (đã xoá)")
        XCTAssertTrue(store.followedPlans().isEmpty)
    }

    @MainActor
    func testCannotChangeTypeOfReferencedExercise() {
        let store = AppStore(persists: false)
        var exercise = store.catalog[0]
        exercise.type = exercise.type == .reps ? .staticHold : .reps
        XCTAssertFalse(store.saveExercise(exercise))
    }

    @MainActor
    func testInvalidMediaIsRejected() {
        XCTAssertNil(ExerciseMediaReference.remote("file:///private/data"))
        XCTAssertNil(ExerciseMediaReference.remote("javascript:alert(1)"))
        XCTAssertNil(ExerciseMediaReference.remote("http://example.com/image.jpg"))
        XCTAssertNotNil(ExerciseMediaReference.remote("https://example.com/image.jpg"))
        XCTAssertNil(ExerciseMediaReference(source: .local, value: "../secret").url)
    }

    @MainActor
    func testOldCatalogAndPlanDecodeWithoutNewFields() throws {
        let encoder = DomainJSON.makeEncoder()
        let decoder = DomainJSON.makeDecoder()
        let exercise = MockData.catalog[0]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(exercise)) as? [String: Any])
        object.removeValue(forKey: "poster")
        object.removeValue(forKey: "video")
        let decoded = try decoder.decode(Exercise.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.id, exercise.id)
        XCTAssertNil(decoded.poster)
        XCTAssertNil(decoded.video)
        let store = AppStore(persists: false, now: Date(timeIntervalSince1970: 1_800_000_000))
        let old = PersistedSnapshot(plan: store.starterPlan, history: store.history,
            recommendations: [], audit: [], settings: AppSettings(), createdAt: Date())
        let oldData = try encoder.encode(old)
        let restored = try decoder.decode(PersistedSnapshot.self, from: oldData)
        XCTAssertNil(restored.catalog)
        XCTAssertNil(restored.plan.deletedAt)
        XCTAssertEqual(restored.history, store.history)
    }

    @MainActor
    func testSnapshotRoundTripKeepsPersonalCatalogAndDeletion() throws {
        let store = AppStore(persists: false)
        var exercise = store.catalog[0]
        exercise.id = UUID()
        exercise.name = "Bài cá nhân"
        exercise.poster = .remote("https://example.com/poster.jpg")
        XCTAssertTrue(store.saveExercise(exercise))
        XCTAssertTrue(store.deleteStarterPlan())
        let snapshot = PersistedSnapshot(catalog: store.catalog, plan: store.starterPlan, history: store.history,
            recommendations: [], audit: store.audit, settings: AppSettings(), createdAt: Date())
        let restored = try DomainJSON.makeDecoder().decode(PersistedSnapshot.self, from: DomainJSON.makeEncoder().encode(snapshot))
        XCTAssertEqual(restored.catalog?.last, exercise)
        XCTAssertNotNil(restored.plan.deletedAt)
        XCTAssertEqual(restored.audit.map(\.id), store.audit.map(\.id))
        XCTAssertEqual(restored.audit.map(\.detail), store.audit.map(\.detail))
        for (decoded, original) in zip(restored.audit, store.audit) {
            XCTAssertEqual(decoded.at.timeIntervalSince1970, original.at.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    @MainActor
    func testDuplicateWeekdayIsRejectedWithoutChangingPlan() {
        let store = AppStore(persists: false)
        let before = store.starterPlan
        var duplicate = before.workouts[0]
        duplicate.id = UUID()
        XCTAssertFalse(store.updateWorkout(duplicate, in: before.lineageId))
        XCTAssertEqual(store.starterPlan, before)
        XCTAssertTrue(store.audit.isEmpty)
    }

    @MainActor
    func testImportedFileSurvivesSourceRemoval() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        // A valid one-pixel PNG; media bytes are not stored in the JSON snapshot.
        let bytes = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let reference = try LocalMedia.importFile(source, isVideo: false)
        defer { LocalMedia.discard(reference) }
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(reference.url)), bytes)
    }
}

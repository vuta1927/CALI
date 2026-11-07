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
        XCTAssertEqual(store.plan.workouts[0].exercises[0].exerciseId, exercise.id)
    }

    @MainActor
    func testDeletePlanPreservesHistoryAndActiveSession() {
        let store = AppStore(persists: false)
        store.startWorkout(store.plan.workouts[0])
        let session = store.player?.state.sessionId
        let history = store.history
        XCTAssertTrue(store.deletePlan())
        XCTAssertTrue(store.plan.workouts.isEmpty)
        XCTAssertNotNil(store.plan.deletedAt)
        XCTAssertEqual(store.history, history)
        XCTAssertEqual(store.player?.state.sessionId, session)
        XCTAssertTrue(store.activeSessionInProgress)
    }

    @MainActor
    func testCannotChangeTypeOfReferencedExercise() {
        let store = AppStore(persists: false)
        var exercise = store.catalog[0]
        exercise.type = exercise.type == .reps ? .staticHold : .reps
        XCTAssertFalse(store.saveExercise(exercise))
    }

    @MainActor
    func testCannotInvalidateBundledQuickTestPrescription() throws {
        let store = AppStore(persists: false)
        let item = try XCTUnwrap(MockData.quickTest.exercises.first { $0.exerciseId == MockData.pushUp })
        XCTAssertFalse(store.plan.workouts.contains { $0.exercises.contains { $0.exerciseId == item.exerciseId } })
        XCTAssertFalse(store.history.contains { $0.exerciseIds.contains(item.exerciseId) })
        XCTAssertNil(store.player)
        var exercise = try XCTUnwrap(store.exercise(item.exerciseId))
        let previous = exercise
        exercise.type = exercise.type == .reps ? .staticHold : .reps
        XCTAssertFalse(store.saveExercise(exercise))
        XCTAssertEqual(store.exercise(item.exerciseId), previous)
        XCTAssertEqual(store.exercise(item.exerciseId)?.type, item.target.type)
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
        let store = AppStore(persists: false)
        let old = PersistedSnapshot(plan: store.plan, history: store.history,
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
        XCTAssertTrue(store.deletePlan())
        let snapshot = PersistedSnapshot(catalog: store.catalog, plan: store.plan, history: store.history,
            recommendations: [], audit: store.audit, settings: AppSettings(), createdAt: Date())
        let restored = try DomainJSON.makeDecoder().decode(PersistedSnapshot.self, from: DomainJSON.makeEncoder().encode(snapshot))
        XCTAssertEqual(restored.catalog?.last, exercise)
        XCTAssertNotNil(restored.plan.deletedAt)
        XCTAssertEqual(restored.audit, store.audit)
    }

    @MainActor
    func testDuplicateWeekdayIsRejectedWithoutChangingPlan() {
        let store = AppStore(persists: false)
        let before = store.plan
        var duplicate = before.workouts[0]
        duplicate.id = UUID()
        XCTAssertFalse(store.updateWorkout(duplicate))
        XCTAssertEqual(store.plan, before)
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

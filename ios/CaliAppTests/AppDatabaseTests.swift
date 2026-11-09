import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-001: the app reads and writes through `AppDatabase` (GRDB) instead of the JSON snapshot.
final class AppDatabaseTests: XCTestCase {
    @MainActor
    private func makeStore(_ database: AppDatabase) -> AppStore {
        let store = AppStore(database: database)
        store.updateSettings { $0.notificationsEnabled = false; $0.liveActivityEnabled = false; $0.countdownSeconds = 0 }
        return store
    }

    @MainActor
    func testRelaunchRestoresActiveSessionAndContentEdits() throws {
        let database = try AppDatabase.inMemory()
        let first = makeStore(database)
        XCTAssertTrue(first.renameStarterPlan("Giáo án của tôi"))
        first.startWorkout(first.starterPlan.workouts[0])
        let player = try XCTUnwrap(first.player)
        player.startSet()
        XCTAssertEqual(player.state.phase, .exercising)

        let relaunched = AppStore(database: database)
        XCTAssertEqual(relaunched.starterPlan.title, "Giáo án của tôi")
        XCTAssertEqual(relaunched.settings.countdownSeconds, 0)
        let restored = try XCTUnwrap(relaunched.player)
        // The database keeps instants to the millisecond; compare the stored (JSON) form.
        let encoder = DomainJSON.makeEncoder()
        XCTAssertEqual(try encoder.encode(restored.state), try encoder.encode(player.state))
        XCTAssertEqual(restored.title, first.starterPlan.workouts[0].title)
        XCTAssertTrue(relaunched.activeSessionInProgress)
    }

    @MainActor
    func testAbandonedSessionIsInHistoryAfterRelaunch() throws {
        let database = try AppDatabase.inMemory()
        let store = makeStore(database)
        let samples = store.history.count
        store.startWorkout(store.starterPlan.workouts[0])
        let player = try XCTUnwrap(store.player)
        player.abandon(reason: "test")
        XCTAssertEqual(store.history.count, samples + 1)
        XCTAssertEqual(store.history.first { $0.id == player.state.sessionId }?.status, .abandoned)

        let relaunched = AppStore(database: database)
        XCTAssertNil(relaunched.player)
        XCTAssertEqual(relaunched.history.count, samples + 1)
    }

    @MainActor
    func testSecondWorkoutIsRefusedWhileOneIsActive() throws {
        let store = makeStore(try AppDatabase.inMemory())
        store.startWorkout(store.starterPlan.workouts[0])
        let session = store.player?.state.sessionId
        store.startWorkout(store.starterPlan.workouts[1])
        XCTAssertNotNil(store.alertMessage)
        XCTAssertEqual(store.player?.state.sessionId, session)
    }

    @MainActor
    func testAcceptingRecommendationUpdatesPlanAndAuditTogether() throws {
        let database = try AppDatabase.inMemory()
        let store = makeStore(database)
        let recommendation = try XCTUnwrap(store.recommendations.first { $0.change != nil && $0.decision == nil })
        store.decide(recommendation, accept: true)
        XCTAssertEqual(store.recommendations.first { $0.id == recommendation.id }?.decision, .accepted)
        XCTAssertEqual(store.audit.first?.action, "Chấp nhận đề xuất")

        let relaunched = AppStore(database: database)
        XCTAssertEqual(relaunched.starterPlan, store.starterPlan)
        XCTAssertEqual(relaunched.recommendations.first { $0.id == recommendation.id }?.decision, .accepted)
        // A second decision on the same recommendation is ignored.
        relaunched.decide(recommendation, accept: false)
        XCTAssertEqual(relaunched.audit.count, store.audit.count)
    }

    @MainActor
    func testResetKeepsWelcomeFlagAndEndsWorkout() throws {
        let store = makeStore(try AppDatabase.inMemory())
        store.updateSettings { $0.hasSeenWelcome = true }
        XCTAssertTrue(store.renameStarterPlan("Khác"))
        store.startWorkout(store.starterPlan.workouts[0])
        store.resetDemoData()
        XCTAssertNil(store.player)
        XCTAssertEqual(store.starterPlan.title, MockData.plan.title)
        XCTAssertTrue(store.settings.hasSeenWelcome)
        XCTAssertTrue(store.audit.isEmpty)
    }
}

import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-007 slice 1 in the app: status wording and the no-credentials case (Release has none until IOS-008).
@MainActor
final class SyncServiceTests: XCTestCase {
    func testWithoutCredentialsStatusSaysLocalOnlyAndNothingIsSent() async throws {
        let store = AppStore(persists: false)
        #if DEBUG
        guard DevCredentialStore.read(.baseURL) == nil else { throw XCTSkip("dev credentials present on this device") }
        #endif
        XCTAssertFalse(store.sync.isConfigured)
        XCTAssertEqual(SyncStatusView.summary(store.sync), "Chỉ lưu trên máy")
        await store.sync.syncNow()
        XCTAssertNil(store.sync.lastOutcome)
    }

    func testFinishingASessionLeavesContractRowsWaitingAndNeverCallsItSynced() throws {
        let store = AppStore(persists: false)
        let workout = try XCTUnwrap(store.plans.first?.workouts.first)
        store.startWorkout(workout)
        XCTAssertTrue(store.activeSessionInProgress)
        store.sync.refresh()
        XCTAssertEqual(store.sync.status.pending, 1 + workout.exercises.count, "session + one execution per exercise")
        XCTAssertEqual(store.sync.status.badge, .waiting)
    }

    func testReasonTextNeverEchoesServerMessages() {
        XCTAssertEqual(SyncStatusView.reason("version_conflict"), "Dữ liệu này đã thay đổi ở nơi khác.")
        XCTAssertEqual(SyncStatusView.reason("anything_else"), "Máy chủ không nhận thay đổi này.")
        XCTAssertEqual(SyncStatusView.entityName("set_result"), "Kết quả set")
        XCTAssertEqual(SyncStatusView.entityName("body_measurement"), "Số đo cơ thể")
        XCTAssertTrue(SyncStatusView.reason("active_plan_limit").contains("Gửi lại"))
        XCTAssertFalse(SyncStatusView.reason("body_measurement").contains("kg"), "no value in any sentence")
    }
}

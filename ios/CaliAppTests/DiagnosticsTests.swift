import CaliCore
import CaliDomain
import XCTest
@testable import CaliApp

/// IOS-012: dev credentials stay in the Keychain; the store reports counts only.
final class DiagnosticsFlowTests: XCTestCase {
    override func tearDown() {
        DevCredentialStore.clear(.token)
        DevCredentialStore.clear(.baseURL)
        super.tearDown()
    }

    func testTokenRoundTripsThroughTheKeychainAndClears() throws {
        // The unsigned simulator build (CODE_SIGNING_ALLOWED=NO) has no keychain entitlement; this runs on a signed device build.
        try XCTSkipUnless(DevCredentialStore.write(.token, "  eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln \n"), "Keychain unavailable in an unsigned build")
        XCTAssertEqual(DevCredentialStore.read(.token), "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2ln", "trimmed")
        XCTAssertTrue(DevCredentialStore.write(.token, "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIyIn0.c2ln"), "overwrite")
        XCTAssertTrue(DevCredentialStore.read(.token)?.contains("IyIn0") == true)
        XCTAssertTrue(DevCredentialStore.write(.token, "   "), "an empty value clears")
        XCTAssertNil(DevCredentialStore.read(.token))
        XCTAssertNil(UserDefaults.standard.string(forKey: "api-jwt"), "never in UserDefaults")
    }

    @MainActor
    func testStoreDiagnosticsCarryNoWeightOrAuditText() throws {
        let store = AppStore(database: try AppDatabase.inMemory())
        XCTAssertTrue(store.saveBodyMeasurement(BodyMeasurement(value: Decimal(string: "72.45")!, measuredAt: Date().addingTimeInterval(-60))))
        let text = DiagnosticsReport.render(DiagnosticsReport.lines(for: try store.databaseDiagnostics()), generatedAt: Date())
        XCTAssertTrue(text.contains("body_measurements: 1, dirty 1"))
        XCTAssertFalse(text.contains("72.45"))
        XCTAssertFalse(text.contains("Cân nặng"))
    }
}

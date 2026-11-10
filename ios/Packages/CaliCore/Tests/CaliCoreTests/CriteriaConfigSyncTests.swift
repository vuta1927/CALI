import CaliDomain
import Foundation
import XCTest
@testable import CaliCore

/// CON-008 client: cache the published config, revalidate with the ETag, never lose the last good copy.
final class CriteriaConfigSyncTests: XCTestCase {
    /// Version 2 of the config: `technique` has gone, one criterion has a type this build does not know, one indicator has a
    /// kind it does not know, and `best_set_reps` is disabled.
    private let v2 = """
    {"version": 2, "publishedAt": "2026-11-10T00:00:00Z", "supportedTypes": ["number", "choice", "scale", "chips", "toggle"],
     "criteria": [
       {"id": "rpe", "type": "scale", "label": "RPE", "appliesTo": {"disciplines": ["gym"]}, "min": 6, "max": 10, "step": 1, "required": false, "enabled": true},
       {"id": "mood", "type": "emoji", "label": "Mood", "appliesTo": {"disciplines": ["*"]}, "required": false, "enabled": true}],
     "indicators": {"version": 8, "publishedAt": "2026-11-10T00:00:00Z", "indicators": [
       {"id": "best_hold_seconds", "version": 1, "kind": "performance", "label": "Giữ lâu nhất", "unit": "giây", "step": 1, "aggregation": "max", "measurementTypes": ["hold"], "enabled": true},
       {"id": "best_set_reps", "version": 2, "kind": "performance", "label": "Set tốt nhất", "unit": "lần", "step": 1, "aggregation": "max", "measurementTypes": ["reps"], "enabled": false},
       {"id": "future", "version": 1, "kind": "telepathy", "label": "?", "unit": "", "step": 1, "aggregation": "max", "measurementTypes": [], "enabled": true}]}}
    """

    private final class FakeAPI: CriteriaConfigAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<CriteriaConfigResponse?, SyncTransportError>]
        private(set) var etagsSent: [String?] = []

        init(_ results: [Result<CriteriaConfigResponse?, SyncTransportError>]) { self.results = results }

        func fetch(ifNoneMatch: String?) async throws -> CriteriaConfigResponse? {
            try lock.withLock {
                etagsSent.append(ifNoneMatch)
                return try results.removeFirst().get()
            }
        }
    }

    private func store() throws -> CriteriaConfigStore { CriteriaConfigStore(writer: try CaliDatabase.openInMemory()) }

    func testNothingCachedMeansTheBundledVersionOne() async throws {
        let cached = await (try store()).load(); XCTAssertEqual(cached, .bundled)
    }

    func testDecodeKeepsWhatItKnowsAndSkipsWhatItDoesNot() throws {
        let config = try XCTUnwrap(PublishedConfig.decode(Data(v2.utf8)))
        XCTAssertEqual(config.criteria.version, 2)
        XCTAssertEqual(config.criteria.applicable(exerciseId: UUID(), type: .reps).map(\.id), [], "rpe is gym only, mood has an unknown type")
        XCTAssertEqual(config.criteria.criteria.map(\.id), ["rpe", "mood"])
        XCTAssertEqual(config.indicators.map(\.id), ["best_hold_seconds", "best_set_reps"], "the unknown kind is skipped")
        XCTAssertEqual(config.indicators.last?.enabled, false)
    }

    func testAnOlderThanBundledOrUnreadableBodyIsRefused() {
        XCTAssertNil(PublishedConfig.decode(Data("{\"version\": 0}".utf8)))
        XCTAssertNil(PublishedConfig.decode(Data("not json".utf8)))
    }

    func testRefreshStoresTheBodyAndRevalidatesWithItsEtag() async throws {
        let store = try store()
        let api = FakeAPI([.success(.init(body: Data(v2.utf8), etag: "\"c2.i8\"")), .success(nil), .success(.init(body: Data(v2.utf8), etag: "\"c2.i8\""))])
        let refresher = CriteriaConfigRefresher(api: api, store: store)

        let first = try await refresher.refresh()
        XCTAssertTrue(first)
        let loaded = await store.load(); XCTAssertEqual(loaded.criteria.version, 2)
        let second = try await refresher.refresh()
        XCTAssertFalse(second, "304")
        let third = try await refresher.refresh()
        XCTAssertFalse(third, "same body again is not a change")
        XCTAssertEqual(api.etagsSent, [nil, "\"c2.i8\"", "\"c2.i8\""])
    }

    func testAFailedOrUnreadableFetchKeepsTheLastGoodCopy() async throws {
        let store = try store()
        let api = FakeAPI([.success(.init(body: Data(v2.utf8), etag: "\"a\"")), .failure(.offline),
                           .success(.init(body: Data("{\"version\": 3}".utf8), etag: "\"b\"")), .failure(.server(status: 503))])
        let refresher = CriteriaConfigRefresher(api: api, store: store)
        try await refresher.refresh()
        for _ in 0..<3 { _ = try? await refresher.refresh() }
        let loaded = await store.load(); XCTAssertEqual(loaded.criteria.version, 2)
        let etag = await store.etag(); XCTAssertEqual(etag, "\"a\"")
    }

    func testDeletingLocalDataClearsTheCacheBackToBundled() async throws {
        let coordinator = WorkoutCoordinator(writer: try CaliDatabase.openInMemory(), clock: SystemClock())
        let store = CriteriaConfigStore(coordinator: coordinator)
        try await CriteriaConfigRefresher(api: FakeAPI([.success(.init(body: Data(v2.utf8), etag: nil))]), store: store).refresh()
        let loaded = await store.load(); XCTAssertEqual(loaded.criteria.version, 2)
        try await AccountScope(coordinator: coordinator).signOut(deleteLocalData: true, seed: .empty())
        let after = await store.load(); XCTAssertEqual(after, PublishedConfig.bundled)
    }
}

import CaliDomain
import CaliDomainTestSupport
import Foundation
import XCTest
@testable import CaliCore

/// Catalog from the server and a database that starts with no bundled content.
final class ExerciseCatalogTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func serverJSON(_ items: [String], next: String? = nil, more: Bool = false) -> Data {
        Data(#"{"items":[\#(items.joined(separator: ","))],"nextCursor":\#(next.map { "\"\($0)\"" } ?? "null"),"hasMore":\#(more)}"#.utf8)
    }

    private func item(_ n: Int, type: String = "reps", name: String = "Bài") -> String {
        #"{"id":"\#(uuid(n).uuidString.lowercased())","slug":"ex-\#(n)","name":"\#(name) \#(n)","type":"\#(type)","discipline":"calisthenics","measurementType":"reps","focusTags":["push"],"equipment":[],"cues":["Giữ thân thẳng"],"catalogVersion":2,"media":[]}"#
    }

    private func api(_ responses: [Data]) -> URLSessionExerciseCatalogAPI {
        final class Box: @unchecked Sendable { var pages: [Data] = []; var seen: [URL] = [] }
        let box = Box()
        box.pages = responses
        URLSessionSyncAPITests.Stub.seen = []
        URLSessionSyncAPITests.Stub.handler = { request in
            let page = box.pages.isEmpty ? Data() : box.pages.removeFirst()
            return (200, [:], page)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLSessionSyncAPITests.Stub.self]
        return URLSessionExerciseCatalogAPI(baseURL: URL(string: "https://example.invalid/")!, session: URLSession(configuration: config))
    }

    func testEmptySeedWritesNoPlanAndNoSamples() throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(.empty(), now: t0, timeZone: utc)
        let content = try store.load()
        XCTAssertTrue(content.plans.isEmpty)
        XCTAssertTrue(content.catalog.isEmpty)
        XCTAssertTrue(content.history.isEmpty)
        XCTAssertTrue(content.recommendations.isEmpty)
        XCTAssertFalse(try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc), "initialized: a later seed never refills it")
    }

    func testRefreshReadsEveryPageSkipsUnknownTypesAndStoresTheCatalog() async throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(.empty(), now: t0, timeZone: utc)
        let client = api([serverJSON([item(1), item(2, type: "teleport")], next: "c1", more: true), serverJSON([item(3, type: "load")])])
        let changed = try await ExerciseCatalogRefresher(api: client, store: store).refresh(now: t0)
        XCTAssertEqual(changed, 2, "the exercise of an unknown type is skipped, not a failed page")
        let catalog = try store.load().catalog
        XCTAssertEqual(Set(catalog.map(\.id)), [uuid(1), uuid(3)])
        XCTAssertEqual(catalog.first { $0.id == uuid(3) }?.type, .load)
        XCTAssertEqual(catalog.first { $0.id == uuid(1) }?.cues, ["Giữ thân thẳng"])
    }

    func testRefreshKeepsLocalOnlyFieldsAndIsQuietWhenNothingChanged() async throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(.empty(), now: t0, timeZone: utc)
        var mine = Content.exercise(1, type: .reps, name: "Của tôi")
        mine.level = .advanced
        mine.mistakes = ["Võng lưng"]
        try store.apply(ContentChange(exercises: [mine]), now: t0)

        let first = try await ExerciseCatalogRefresher(api: api([serverJSON([item(1)])]), store: store).refresh(now: t0)
        XCTAssertEqual(first, 1)
        let merged = try XCTUnwrap(try store.load().catalog.first)
        XCTAssertEqual(merged.name, "Bài 1", "server name")
        XCTAssertEqual(merged.level, .advanced, "local-only fields stay")
        XCTAssertEqual(merged.mistakes, ["Võng lưng"])

        let again = try await ExerciseCatalogRefresher(api: api([serverJSON([item(1)])]), store: store).refresh(now: t0)
        XCTAssertEqual(again, 0)
    }

    func testAnEmptyServerCatalogChangesNothing() async throws {
        let db = try CaliDatabase.openInMemory()
        let store = ContentStore(writer: db)
        try store.seedIfEmpty(Content.seed(), now: t0, timeZone: utc)
        let before = try store.load().catalog
        let changed = try await ExerciseCatalogRefresher(api: api([serverJSON([])]), store: store).refresh(now: t0)
        XCTAssertEqual(changed, 0)
        XCTAssertEqual(try store.load().catalog, before, "an empty or unreachable server never empties the phone")
    }
}

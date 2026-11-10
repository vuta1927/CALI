import CaliDomain
import CaliDomainTestSupport
import CryptoKit
import Foundation
import XCTest
@testable import CaliCore

/// BE-006 client: posters of server exercises are downloaded once, verified by hash, and never replace the user's own photo.
final class ExerciseMediaTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4])
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private final class Downloader: MediaDownloading, @unchecked Sendable {
        private let lock = NSLock()
        var data: Data
        private(set) var calls: [URL] = []
        init(_ data: Data) { self.data = data }
        func download(_ url: URL) async throws -> Data { lock.withLock { calls.append(url); return data } }
    }

    private func media(_ kind: String = "poster", sha: String, url: String? = "https://files.example/p.png?sig=x", expires: String? = nil, mime: String = "image/png") -> ServerMedia {
        ServerMedia(id: UUID(), kind: kind, url: url.flatMap(URL.init(string:)), urlExpiresAt: expires, mimeType: mime, sha256: sha)
    }

    func testDownloadsOnceVerifiesAndNamesTheFileAfterItsHash() async throws {
        let downloader = Downloader(png)
        let cache = ExerciseMediaCache(directory: dir, downloader: downloader)
        let item = media(sha: sha(png))
        let first = await cache.poster(from: [item])
        let reference = try XCTUnwrap(first)
        XCTAssertEqual(reference.value, "srv-\(sha(png)).png")
        XCTAssertTrue(ExerciseMediaCache.isServerCached(reference))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(reference.value)), png)
        let second = await cache.poster(from: [item])
        XCTAssertEqual(second, reference)
        XCTAssertEqual(downloader.calls.count, 1, "the second call finds the file")
    }

    func testRefusesWrongHashExpiredUrlPlainHttpAndOtherTypes() async throws {
        let downloader = Downloader(png)
        let cache = ExerciseMediaCache(directory: dir, downloader: downloader)
        let wrongHash = await cache.poster(from: [media(sha: String(repeating: "a", count: 64))])
        XCTAssertNil(wrongHash)
        let expired = await cache.poster(from: [media(sha: sha(png), expires: "2020-01-01T00:00:00Z")])
        XCTAssertNil(expired)
        let http = await cache.poster(from: [media(sha: sha(png), url: "http://files.example/p.png")])
        XCTAssertNil(http)
        let noUrl = await cache.poster(from: [media(sha: sha(png), url: nil)])
        XCTAssertNil(noUrl)
        let video = await cache.poster(from: [media(sha: sha(png), mime: "video/mp4")])
        XCTAssertNil(video)
        let badHash = await cache.poster(from: [media(sha: "XYZ")])
        XCTAssertNil(badHash)
        XCTAssertEqual(downloader.calls.count, 1, "only the wrong-hash item reached the network")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "nothing was written")
    }

    func testPosterBeatsThumbnailAndThumbnailIsTheFallback() async throws {
        let cache = ExerciseMediaCache(directory: dir, downloader: Downloader(png))
        let thumb = media("thumbnail", sha: sha(png))
        let poster = Data([0x89, 0x50, 0x4E, 0x47, 9])
        let both = await cache.poster(from: [thumb, media("poster", sha: sha(poster))])
        XCTAssertEqual(both?.value, "srv-\(sha(png)).png", "the poster's bytes do not match its hash, so the thumbnail is used")
        let fallback = await cache.poster(from: [thumb])
        XCTAssertEqual(fallback?.value, "srv-\(sha(png)).png")
    }

    func testRefreshAttachesPostersAndKeepsTheUsersOwnPhoto() async throws {
        let store = ContentStore(writer: try CaliDatabase.openInMemory())
        try store.seedIfEmpty(.empty(), now: t0, timeZone: utc)
        let a = ServerExercise.fixture(1), b = ServerExercise.fixture(2)
        let page = ExerciseCatalogPage(items: [a, b].map(ExerciseCatalog.local),
                                       media: [a.id: [media(sha: sha(png))], b.id: [media(sha: sha(png))]], nextCursor: nil, hasMore: false)
        let cache = ExerciseMediaCache(directory: dir, downloader: Downloader(png))
        // B already has the user's own photo.
        var own = ExerciseCatalog.local(b)
        own.poster = ExerciseMediaReference(source: .local, value: "mine.jpg")
        try store.apply(ContentChange(exercises: [own]), now: t0)

        let changed = try await ExerciseCatalogRefresher(api: FixedAPI(page), store: store, media: cache).refresh(now: t0)
        XCTAssertEqual(changed, 1, "B keeps its own photo, so it does not change")
        let catalog = Dictionary(uniqueKeysWithValues: try store.load().catalog.map { ($0.id, $0) })
        XCTAssertEqual(catalog[a.id]?.poster?.value, "srv-\(sha(png)).png")
        XCTAssertEqual(catalog[b.id]?.poster?.value, "mine.jpg")
    }

    private struct FixedAPI: ExerciseCatalogAPI {
        let page: ExerciseCatalogPage
        init(_ page: ExerciseCatalogPage) { self.page = page }
        func page(cursor: String?, limit: Int) async throws -> ExerciseCatalogPage { page }
    }
}

extension ServerExercise {
    static func fixture(_ n: Int) -> ServerExercise {
        let json = #"{"id":"\#(uuid(n).uuidString.lowercased())","slug":"ex-\#(n)","name":"Bài \#(n)","type":"reps","equipment":[],"cues":[],"catalogVersion":1,"media":[]}"#
        return try! JSONDecoder().decode(ServerExercise.self, from: Data(json.utf8))
    }
}

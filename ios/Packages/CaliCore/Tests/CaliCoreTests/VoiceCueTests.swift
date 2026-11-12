import CaliDomain
import CryptoKit
import Foundation
import XCTest
@testable import CaliCore

/// IOS-019 (CON-010, ADR-077/078): voice pack download into the sounds folder, and when each cue is due.
final class VoiceCueTests: XCTestCase {
    // MARK: Pack sync

    private final class FakeAPI: VoicePackAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<VoicePackResponse?, SyncTransportError>]
        private(set) var etagsSent: [String?] = []

        init(_ results: [Result<VoicePackResponse?, SyncTransportError>]) { self.results = results }

        func fetch(locale: String, ifNoneMatch: String?) async throws -> VoicePackResponse? {
            try lock.withLock {
                etagsSent.append(ifNoneMatch)
                return try results.removeFirst().get()
            }
        }
    }

    private final class FakeDownloader: MediaDownloading, @unchecked Sendable {
        private let lock = NSLock()
        var files: [URL: Data]
        private(set) var downloaded: [URL] = []

        init(_ files: [URL: Data]) { self.files = files }

        func download(_ url: URL) async throws -> Data {
            try lock.withLock {
                downloaded.append(url)
                guard let data = files[url] else { throw SyncTransportError.server(status: 403) }
                return data
            }
        }
    }

    private let restAudio = Data("caff-rest".utf8), holdAudio = Data("caff-hold".utf8)

    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func url(_ name: String) -> URL { URL(string: "https://media.example/\(name)?X-Amz-Signature=x")! }

    private func pack(version: Int, restHash: String? = nil, audioURLs: Bool = true) -> Data {
        func audio(_ name: String, _ hash: String) -> String {
            let u = audioURLs ? "\"\(url(name))\"" : "null"
            return #"{"url": \#(u), "expiresAt": null, "format": "caf_ima4", "sha256": "\#(hash)", "byteSize": 9, "durationMs": 1500}"#
        }
        return Data("""
        {"locale": "vi-VN", "version": \(version), "publishedAt": "2026-11-11T00:00:00Z", "voice": "vbee test", "cues": [
          {"key": "rest.done", "text": "Hết giờ nghỉ. Vào set tiếp theo.", "audio": \(audio("rest", restHash ?? hex(restAudio)))},
          {"key": "hold.done", "text": "Đủ thời gian. Có thể thả.", "audio": \(audio("hold", hex(holdAudio)))},
          {"key": "future.cue", "text": "Sau này.", "audio": \(audio("hold", hex(holdAudio)))}]}
        """.utf8)
    }

    private func makeStore() throws -> VoicePackStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return VoicePackStore(writer: try CaliDatabase.openInMemory(), soundsDirectory: dir)
    }

    private func files(_ store: VoicePackStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.soundsDirectory.path)) ?? []).sorted()
    }

    func testDownloadsVerifiedFilesUnderVersionedNamesAndRevalidatesWithTheEtag() async throws {
        let store = try makeStore()
        let downloader = FakeDownloader([url("rest"): restAudio, url("hold"): holdAudio])
        let api = FakeAPI([.success(.init(body: pack(version: 1), etag: "\"vi-VN.v1\"")), .success(nil)])
        let refresher = VoicePackRefresher(api: api, store: store, downloader: downloader)

        let changed = try await refresher.refresh()
        XCTAssertTrue(changed)
        let library = await store.load()
        XCTAssertEqual(library.version, 1)
        XCTAssertEqual(library[.restDone], .init(text: "Hết giờ nghỉ. Vào set tiếp theo.", soundFile: "cali-voice-vi-VN-v1-rest.done.caf"))
        XCTAssertEqual(try Data(contentsOf: store.soundsDirectory.appendingPathComponent("cali-voice-vi-VN-v1-rest.done.caf")), restAudio)
        XCTAssertNotNil(library.cues["future.cue"], "a key this build does not play is kept for a later build")

        let again = try await refresher.refresh()
        XCTAssertFalse(again)
        XCTAssertEqual(api.etagsSent, [nil, "\"vi-VN.v1\""])
    }

    func testABadHashKeepsThePreviousPackAndItsFiles() async throws {
        let store = try makeStore()
        let downloader = FakeDownloader([url("rest"): restAudio, url("hold"): holdAudio])
        let api = FakeAPI([
            .success(.init(body: pack(version: 1), etag: "\"vi-VN.v1\"")),
            .success(.init(body: pack(version: 2, restHash: String(repeating: "a", count: 64)), etag: "\"vi-VN.v2\"")),
        ])
        let refresher = VoicePackRefresher(api: api, store: store, downloader: downloader)
        _ = try await refresher.refresh()

        let changed = try await refresher.refresh()
        XCTAssertFalse(changed)
        let library = await store.load()
        XCTAssertEqual(library.version, 1, "v2 is incomplete, v1 stays in use")
        XCTAssertTrue(files(store).contains("cali-voice-vi-VN-v1-rest.done.caf"))
        let etag = await store.etag()
        XCTAssertEqual(etag, "\"vi-VN.v1\"", "the v2 ETag is not saved, so the next refresh retries")
    }

    func testANewVersionReplacesTheOldFilesOnlyWhenComplete() async throws {
        let store = try makeStore()
        let downloader = FakeDownloader([url("rest"): restAudio, url("hold"): holdAudio])
        let api = FakeAPI([.success(.init(body: pack(version: 1), etag: "a")), .success(.init(body: pack(version: 2), etag: "b"))])
        let refresher = VoicePackRefresher(api: api, store: store, downloader: downloader)
        _ = try await refresher.refresh()
        try Data("other".utf8).write(to: store.soundsDirectory.appendingPathComponent("someone-else.caf"))

        _ = try await refresher.refresh()

        XCTAssertEqual(files(store), ["cali-voice-vi-VN-v2-future.cue.caf", "cali-voice-vi-VN-v2-hold.done.caf",
                                      "cali-voice-vi-VN-v2-rest.done.caf", "someone-else.caf"])
    }

    func testWithoutStorageTheTextIsKeptAndTheDefaultSoundUsed() async throws {
        let store = try makeStore()
        let refresher = VoicePackRefresher(api: FakeAPI([.success(.init(body: pack(version: 1, audioURLs: false), etag: "a"))]),
                                           store: store, downloader: FakeDownloader([:]))
        _ = try await refresher.refresh()
        let library = await store.load()
        XCTAssertEqual(library[.holdDone], .init(text: "Đủ thời gian. Có thể thả.", soundFile: nil))
    }

    func testAMissingFileFallsBackToTheDefaultSound() async throws {
        let store = try makeStore()
        let refresher = VoicePackRefresher(api: FakeAPI([.success(.init(body: pack(version: 1), etag: "a"))]), store: store,
                                           downloader: FakeDownloader([url("rest"): restAudio, url("hold"): holdAudio]))
        _ = try await refresher.refresh()
        try FileManager.default.removeItem(at: store.soundsDirectory.appendingPathComponent("cali-voice-vi-VN-v1-rest.done.caf"))
        let library = await store.load()
        XCTAssertNil(library[.restDone]?.soundFile)
    }

    func testOfflineChangesNothing() async throws {
        let store = try makeStore()
        let refresher = VoicePackRefresher(api: FakeAPI([.failure(.offline)]), store: store, downloader: FakeDownloader([:]))
        do {
            _ = try await refresher.refresh()
            XCTFail("expected offline")
        } catch {}
        let library = await store.load()
        XCTAssertEqual(library, .empty)
    }

    // MARK: Plan

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(_ phase: Phase, target: Prescription = .staticHold(holdSeconds: 30), rest: Int = 60,
                       executionIndex: Int = 0, setIndex: Int = 2, deadline: TimeInterval? = 30) -> SessionState {
        let executions = (0..<2).map { _ in
            ExecutionSpec(id: UUID(), exerciseId: UUID(), catalogVersion: 1, setCount: 3, target: target, restSeconds: rest)
        }
        return SessionState(sessionId: UUID(), plannedWorkoutId: nil, status: phase == .completed ? .completed : .active, phase: phase,
                            revision: 3, executions: executions, currentExecutionIndex: executionIndex, currentSetIndex: setIndex,
                            startedAt: t0, updatedAt: t0, finishedAt: phase == .completed ? t0 : nil, phaseStartedAt: t0,
                            phaseDeadlineAt: deadline.map { t0.addingTimeInterval($0) })
    }

    func testHoldGetsHalfwayAndDoneAtTheDeadline() {
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.exercising)), [
            PlannedVoiceCue(key: .timedHalfway, at: t0.addingTimeInterval(15)),
            PlannedVoiceCue(key: .holdDone, at: t0.addingTimeInterval(30), isPhaseDeadline: true),
        ])
    }

    func testShortTimedSetHasNoHalfwayAndOpenEndedSetsHaveNoCue() {
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.exercising, target: .timedReps(timeSeconds: 15), deadline: 15)),
                       [PlannedVoiceCue(key: .timedDone, at: t0.addingTimeInterval(15), isPhaseDeadline: true)])
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.exercising, target: .reps(repMin: 8, repMax: 12), deadline: nil)), [])
    }

    func testRestGetsTenSecondsLeftAndDone() {
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.resting, deadline: 60)), [
            PlannedVoiceCue(key: .restEnding10s, at: t0.addingTimeInterval(50)),
            PlannedVoiceCue(key: .restDone, at: t0.addingTimeInterval(60), isPhaseDeadline: true),
        ])
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.resting, rest: 15, deadline: 15)),
                       [PlannedVoiceCue(key: .restDone, at: t0.addingTimeInterval(15), isPhaseDeadline: true)])
    }

    func testAutoAdvanceRestCountsDownInForegroundOnly() {
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.resting, deadline: 60), autoAdvance: true), [
            PlannedVoiceCue(key: .restEnding10s, at: t0.addingTimeInterval(50)),
            PlannedVoiceCue(key: .countdownStart, at: t0.addingTimeInterval(57), delivery: .foregroundOnly),
            PlannedVoiceCue(key: .restDone, at: t0.addingTimeInterval(60), isPhaseDeadline: true, delivery: .backgroundOnly),
        ])
        // Too short a rest for a 3-second count: unchanged plan.
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.resting, rest: 3, deadline: 3), autoAdvance: true),
                       [PlannedVoiceCue(key: .restDone, at: t0.addingTimeInterval(3), isPhaseDeadline: true)])
    }

    func testRestBeforeTheFirstSetOfANewExerciseSaysSo() {
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.resting, rest: 10, executionIndex: 1, setIndex: 1, deadline: 10)).map(\.key),
                       [.restDoneNextExercise])
    }

    func testCountdownFinishAndPhasesWithoutCues() {
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.preCountdown, deadline: 3)), [PlannedVoiceCue(key: .countdownStart, at: t0)])
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.completed, deadline: nil)), [PlannedVoiceCue(key: .sessionDone, at: t0)])
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.paused, deadline: nil)), [], "a paused set has no moving deadline")
        XCTAssertEqual(VoiceCuePlan.cues(for: state(.awaitingResult, deadline: nil)), [])
    }

    func testDefaultTextsMatchTheCommittedScript() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../../fixtures/voice_cues.vi-VN.json").standardized
        struct Script: Decodable { struct Cue: Decodable { var key: String; var text: String }; var cues: [Cue] }
        let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: url))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: script.cues.map { ($0.key, $0.text) }),
                       Dictionary(uniqueKeysWithValues: VoiceCueKey.allCases.map { ($0.rawValue, $0.defaultText) }))
    }
}

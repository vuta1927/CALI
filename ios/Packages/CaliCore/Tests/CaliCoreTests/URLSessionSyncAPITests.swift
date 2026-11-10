import Foundation
import XCTest
@testable import CaliCore

/// IOS-007: the HTTP layer against a `URLProtocol` stub (no network). Covers the status mapping of docs/08 §8 and the
/// single refresh-and-retry on 401.
final class URLSessionSyncAPITests: XCTestCase {
    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
        nonisolated(unsafe) static var seen: [URLRequest] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var request = request
            if request.httpBody == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                request.httpBody = data
            }
            Self.seen.append(request)
            do {
                let (status, headers, body) = try Self.handler!(request)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    final class Tokens: SyncTokenProvider, @unchecked Sendable {
        var access = "old"
        var refreshes = 0
        var refreshFails = false
        func accessToken() async throws -> String { access }
        func refreshAccessToken() async throws {
            refreshes += 1
            if refreshFails { throw SyncTransportError.unauthorized }
            access = "new"
        }
    }

    private func api(_ tokens: Tokens) -> URLSessionSyncAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        Stub.seen = []
        return URLSessionSyncAPI(baseURL: URL(string: "https://example.invalid/")!, session: URLSession(configuration: config), tokens: tokens)
    }

    private var request: SyncPushRequest {
        SyncPushRequest(deviceId: UUID(), mutations: [SyncMutation(mutationId: UUID(), entityType: "set_result", entityId: UUID(), action: "upsert", baseVersion: 0,
                                                                  clientChangedAt: Date(timeIntervalSince1970: 1_800_000_000), payload: .object(["weight": .number(Decimal(string: "62.5")!)]))])
    }

    func testPushSendsBearerJSONAndDecodesReceipts() async throws {
        let req = request
        Stub.handler = { r in
            let id = req.mutations[0].mutationId.uuidString.lowercased()
            return (200, [:], Data(#"{"results":[{"mutationId":"\#(id)","status":"applied","serverVersion":1}]}"#.utf8))
        }
        let response = try await api(Tokens()).push(req)
        XCTAssertEqual(response.results.first?.status, .applied)
        let seen = try XCTUnwrap(Stub.seen.first)
        XCTAssertEqual(seen.url?.path, "/v1/sync/push")
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Authorization"), "Bearer old")
        let body = String(decoding: try XCTUnwrap(seen.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("\"weight\":62.5"), "decimal payload numbers keep their value")
        XCTAssertTrue(body.contains("\"clientChangedAt\":\"2027-01-15T08:00:00.000Z\""))
    }

    func testA401RefreshesOnceAndRetriesWithTheNewToken() async throws {
        let req = request
        let tokens = Tokens()
        Stub.handler = { r in
            if r.value(forHTTPHeaderField: "Authorization") == "Bearer old" { return (401, [:], Data()) }
            return (200, [:], Data(#"{"results":[]}"#.utf8))
        }
        _ = try await api(tokens).push(req)
        XCTAssertEqual(tokens.refreshes, 1)
        XCTAssertEqual(Stub.seen.count, 2)
        XCTAssertEqual(Stub.seen[0].httpBody, Stub.seen[1].httpBody, "the retry carries the identical mutations")
    }

    func testAStillRejectedTokenAfterRefreshIsUnauthorizedWithoutAThirdTry() async throws {
        let tokens = Tokens()
        Stub.handler = { _ in (401, [:], Data()) }
        do { _ = try await api(tokens).push(request); XCTFail() } catch { XCTAssertEqual(error as? SyncTransportError, .unauthorized) }
        XCTAssertEqual(Stub.seen.count, 2)
        XCTAssertEqual(tokens.refreshes, 1)
    }

    func testFailedRefreshIsUnauthorized() async throws {
        let tokens = Tokens()
        tokens.refreshFails = true
        Stub.handler = { _ in (401, [:], Data()) }
        do { _ = try await api(tokens).push(request); XCTFail() } catch { XCTAssertEqual(error as? SyncTransportError, .unauthorized) }
    }

    func testStatusMapping() async throws {
        let cases: [(Int, [String: String], String, SyncTransportError)] = [
            (429, ["Retry-After": "90"], "", .rateLimited(retryAfter: 90)),
            (409, [:], #"{"code":"device_owner_mismatch"}"#, .deviceOwnerMismatch),
            (400, [:], #"{"code":"validation_failed"}"#, .batchRefused(status: 400, code: "validation_failed")),
            (413, [:], "", .batchRefused(status: 413, code: nil)),
            (503, [:], "", .server(status: 503)),
        ]
        for (status, headers, body, expected) in cases {
            Stub.handler = { _ in (status, headers, Data(body.utf8)) }
            do { _ = try await api(Tokens()).push(request); XCTFail("\(status)") } catch { XCTAssertEqual(error as? SyncTransportError, expected, "\(status)") }
        }
    }

    func testPullIsAGetWithCursorAndLimitAndNoBody() async throws {
        let id = UUID().uuidString.lowercased()
        Stub.handler = { _ in
            (200, [:], Data(#"{"changes":[{"changeId":"c9","entityType":"training_plan","entityId":"\#(id)","operation":"upsert","serverVersion":2,"payload":{"title":"A","weeks":4}}],"nextCursor":"c9","hasMore":true}"#.utf8))
        }
        let page = try await api(Tokens()).pull(cursor: "c8", limit: 500)
        let seen = try XCTUnwrap(Stub.seen.first)
        XCTAssertEqual(seen.httpMethod, "GET")
        XCTAssertNil(seen.httpBody)
        XCTAssertEqual(seen.url?.path, "/v1/sync/pull")
        let items = URLComponents(url: try XCTUnwrap(seen.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "cursor" }?.value, "c8")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "100", "clamped to the contract maximum")
        XCTAssertEqual(page.nextCursor, "c9")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.changes.first?.payload["title"]?.stringValue, "A")
    }

    func testInitialPullOmitsTheCursorAndStatusesMap() async throws {
        Stub.handler = { _ in (410, [:], Data(#"{"code":"cursor_expired"}"#.utf8)) }
        do { _ = try await api(Tokens()).pull(cursor: nil, limit: 100); XCTFail() } catch { XCTAssertEqual(error as? SyncTransportError, .cursorExpired) }
        let items = URLComponents(url: try XCTUnwrap(Stub.seen.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertNil(items.first { $0.name == "cursor" })
        Stub.handler = { _ in (401, [:], Data()) }
        do { _ = try await api(Tokens()).pull(cursor: "x", limit: 10); XCTFail() } catch { XCTAssertEqual(error as? SyncTransportError, .unauthorized) }
    }

    func testNetworkFailureIsOffline() async throws {
        Stub.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await api(Tokens()).push(request); XCTFail() } catch { XCTAssertEqual(error as? SyncTransportError, .offline) }
    }
}

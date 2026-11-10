import CaliDomain
import Foundation

/// Any JSON value. Used for payloads and server entities the client does not interpret; numbers are `Decimal`
/// so integers stay integers and 62.5 stays 62.5 through a decode and encode.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Decimal)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Decimal.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// `SyncMutation` of contracts/openapi.yaml. The envelope is a closed object (ADR-030): no extra field here.
public struct SyncMutation: Codable, Equatable, Sendable {
    public var mutationId: UUID
    public var entityType: String
    public var entityId: UUID
    public var action: String
    public var baseVersion: Int
    public var clientChangedAt: Date
    public var payload: JSONValue

    public init(mutationId: UUID, entityType: String, entityId: UUID, action: String, baseVersion: Int, clientChangedAt: Date, payload: JSONValue) {
        self.mutationId = mutationId
        self.entityType = entityType
        self.entityId = entityId
        self.action = action
        self.baseVersion = baseVersion
        self.clientChangedAt = clientChangedAt
        self.payload = payload
    }
}

public struct SyncPushRequest: Codable, Equatable, Sendable {
    public var deviceId: UUID
    public var mutations: [SyncMutation]

    public init(deviceId: UUID, mutations: [SyncMutation]) {
        self.deviceId = deviceId
        self.mutations = mutations
    }
}

/// `MutationError` (ADR-021). `message` is server text: shown to the user only after redaction.
public struct MutationError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var retryable: Bool
    public var details: JSONValue?
}

public struct SyncMutationResult: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case applied, duplicate, conflict, rejected }

    public var mutationId: UUID
    public var status: Status
    public var serverVersion: Int64?
    public var serverEntity: JSONValue?
    public var error: MutationError?
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
    public var results: [SyncMutationResult]
}

/// One entry of the server's change feed (`SyncChange`). The payload is kept as JSON: the schema depends on
/// `entityType` and a delete carries `{id, deletedAt}` only.
public struct SyncChange: Codable, Equatable, Sendable {
    public var changeId: String
    public var entityType: String
    public var entityId: UUID
    public var operation: String
    public var serverVersion: Int64
    public var payload: JSONValue
}

public struct SyncPullResponse: Codable, Equatable, Sendable {
    public var changes: [SyncChange]
    public var nextCursor: String
    public var hasMore: Bool
}

/// How a request failed, as far as the engine needs to tell apart (docs/08 §8).
public enum SyncTransportError: Error, Equatable, Sendable {
    /// 401 that a token refresh did not fix, or no credentials at all: the user has to sign in.
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    /// 409 `device_owner_mismatch` (ADR-033): nothing was applied; use a new device id.
    case deviceOwnerMismatch
    /// 400 or 413: the batch itself is refused, nothing was applied.
    case batchRefused(status: Int, code: String?)
    /// 410 `cursor_expired` on pull: reset the cursor and pull again from the start (docs/08 §7).
    case cursorExpired
    case server(status: Int)
    /// No answer from the network (offline, timeout, DNS, TLS).
    case offline
}

public protocol SyncAPI: Sendable {
    func push(_ request: SyncPushRequest) async throws -> SyncPushResponse
    /// `cursor == nil` is the initial sync.
    func pull(cursor: String?, limit: Int) async throws -> SyncPullResponse
}

/// Bearer tokens for the sync API. `refreshAccessToken` is called at most once per 401.
public protocol SyncTokenProvider: Sendable {
    func accessToken() async throws -> String
    func refreshAccessToken() async throws
}

public enum SyncWireCoding {
    public static func encoder() -> JSONEncoder { DomainJSON.makeEncoder() }
    public static func decoder() -> JSONDecoder { DomainJSON.makeDecoder() }
}

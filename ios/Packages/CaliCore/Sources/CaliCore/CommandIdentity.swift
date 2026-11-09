import Foundation

/// Deterministic identifiers for commands issued from a rendered snapshot (Live Activity buttons).
///
/// A Lock Screen / Dynamic Island button is rendered from a `ContentState` carrying the session
/// `revision`. Every tap on the same rendered state must produce the SAME `commandId`, so a double tap
/// (or the system re-running the intent) is deduplicated by `processed_commands` (docs/03 §7 #1, T-04).
/// A deliberate second tap after the activity re-rendered with a new revision gets a new id.
///
/// Hash: two FNV-1a 64-bit passes with different offset bases → 128 bits, then RFC 9562 version 8
/// (custom) and variant bits. Not cryptographic; inputs are local and non-adversarial.
public enum CommandIdentity {
    public static func uuid(namespace: String, _ components: [String]) -> UUID {
        let text = ([namespace] + components).joined(separator: "|")
        let bytes = Array(text.utf8)
        let high = fnv1a64(bytes, offset: 0xcbf2_9ce4_8422_2325)
        let low = fnv1a64(bytes, offset: 0x84222325_cbf29ce4)
        var b = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 {
            b[i] = UInt8(truncatingIfNeeded: high >> (56 - 8 * UInt64(i)))
            b[8 + i] = UInt8(truncatingIfNeeded: low >> (56 - 8 * UInt64(i)))
        }
        b[6] = (b[6] & 0x0f) | 0x80 // version 8
        b[8] = (b[8] & 0x3f) | 0x80 // RFC 9562 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Command id for a Live Activity action rendered at `revision` of `sessionId`.
    public static func liveActivityCommandId(sessionId: UUID, revision: Int, action: LiveActivityAction) -> UUID {
        uuid(namespace: "cali.live-activity.command.v1", [sessionId.uuidString.lowercased(), String(revision), action.rawValue])
    }

    /// `set_results.id` for a set confirmed from a Live Activity: stable per (session, execution, set).
    public static func setResultId(sessionId: UUID, executionId: UUID, setIndex: Int) -> UUID {
        uuid(namespace: "cali.set-result.v1", [sessionId.uuidString.lowercased(), executionId.uuidString.lowercased(), String(setIndex)])
    }

    /// Outbox `mutationId` derived from the command that produced it (stable if a write is retried).
    static func mutationId(commandId: UUID, entityType: String, entityId: UUID) -> UUID {
        uuid(namespace: "cali.outbox.mutation.v1", [commandId.uuidString.lowercased(), entityType, entityId.uuidString.lowercased()])
    }

    private static func fnv1a64(_ bytes: [UInt8], offset: UInt64) -> UInt64 {
        var hash = offset
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// Actions exposed as Live Activity buttons (POC-001). Both are explicit user input; neither infers
/// that a set was completed from a countdown reaching zero (AGENTS safety rule 3).
public enum LiveActivityAction: String, Codable, Sendable, CaseIterable {
    /// `ExtendRest(+30s)` while resting.
    case extendRest30 = "extend_rest_30"
    /// `ConfirmSet` of the pending set using the domain's suggested actual duration. Only allowed when
    /// the app already produced a draft with `suggestedActualMs` for a duration-only target
    /// (static hold / interval); everything else returns `needs_app`.
    case confirmCurrentSet = "confirm_current_set"
}

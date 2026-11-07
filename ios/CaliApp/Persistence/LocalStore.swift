import CaliDomain
import Foundation
import os

/// Everything the POC persists. One JSON file in Application Support, written atomically after
/// every accepted command (offline-first: no network involved).
///
/// TODO(POC-003): replace with the GRDB schema (ios local migrations, ADR-012) once the POC is
/// validated. Expiry: first slice that adds the outbox/sync.
struct PersistedSnapshot: Codable, Sendable {
    static let currentSchema = 1

    var schemaVersion = PersistedSnapshot.currentSchema
    var plan: WorkoutPlan
    var history: [CompletedSession]
    var recommendations: [Recommendation]
    var audit: [AuditEntry]
    var settings: AppSettings
    var active: ActiveSession?
    var createdAt: Date
}

/// The in-flight workout: the domain state plus the set records produced so far.
struct ActiveSession: Codable, Sendable {
    var state: SessionState
    var title: String
    var records: [SetRecord]
}

enum LocalStore {
    private static let log = Logger(subsystem: "com.cali.app", category: "LocalStore")

    static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("cali-poc.json")
    }

    static func load() -> PersistedSnapshot? {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try DomainJSON.makeDecoder().decode(PersistedSnapshot.self, from: data)
            guard snapshot.schemaVersion == PersistedSnapshot.currentSchema else {
                log.error("Unsupported schema \(snapshot.schemaVersion, privacy: .public); starting fresh")
                return nil
            }
            return snapshot
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting user data.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            log.error("Failed to decode local store: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static func save(_ snapshot: PersistedSnapshot) {
        do {
            let data = try DomainJSON.makeEncoder().encode(snapshot)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log.error("Failed to save local store: \(String(describing: error), privacy: .public)")
        }
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

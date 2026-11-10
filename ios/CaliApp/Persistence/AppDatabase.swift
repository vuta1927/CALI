import CaliCore
import CaliDomain
import Foundation
import os

/// The app's local store (IOS-001): one GRDB database in `Application Support/cali.sqlite`, one
/// `WorkoutCoordinator` (workout commands) and one `ContentStore` (catalog, plan, history, AI review,
/// settings) sharing the same single writer (ADR-013).
///
/// On first open the pre-IOS-001 JSON snapshot `cali-poc.json` is imported once
/// (`LegacySnapshotImporter`); an empty database is seeded with the bundled catalog, the starter plan and
/// labelled sample data. The POC device gate keeps its own database (`POCRuntime`).
struct AppDatabase {
    private static let log = Logger(subsystem: "com.cali.app", category: "AppDatabase")

    let coordinator: WorkoutCoordinator
    let content: ContentStore

    init(coordinator: WorkoutCoordinator) {
        self.coordinator = coordinator
        content = ContentStore(writer: coordinator.writer)
    }

    static var directory: URL {
        (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
    }

    static var databaseURL: URL { directory.appendingPathComponent("cali.sqlite") }
    static var legacySnapshotURL: URL { directory.appendingPathComponent(LegacySnapshotImporter.source) }

    /// Opens (and migrates) the on-disk database, then imports the legacy snapshot if one is present.
    static func openOnDisk(now: Date = Date()) throws -> AppDatabase {
        let database = AppDatabase(coordinator: WorkoutCoordinator(writer: try CaliDatabase.openPool(at: databaseURL, label: "AppDatabase")))
        let outcome = try LegacySnapshotImporter.importIfNeeded(
            fileURL: legacySnapshotURL, writer: database.coordinator.writer, fallbackCatalog: MockData.catalog, now: now
        )
        switch outcome {
        case .imported(let summary):
            log.notice("Imported legacy snapshot: \(String(describing: summary), privacy: .public)")
        case .unreadable(let movedTo):
            log.error("Legacy snapshot unreadable; kept as \(movedTo ?? "-", privacy: .public)")
        case .noFile, .alreadyImported:
            break
        }
        return database
    }

    /// Fresh in-memory database (unit tests, and the fallback when the file cannot be opened).
    static func inMemory() throws -> AppDatabase {
        AppDatabase(coordinator: WorkoutCoordinator(writer: try CaliDatabase.openInMemory()))
    }

    /// No bundled plan, history or catalog: what the app shows comes from the server (catalog) and from the user.
    static func emptySeed(settings: AppSettings = AppSettings()) -> ContentSeed { .empty(settings: settings) }

    static func seed(now: Date, settings: AppSettings = AppSettings()) -> ContentSeed {
        ContentSeed(catalog: MockData.catalog, plan: MockData.plan, sampleHistory: MockData.sampleHistory(now: now),
                    sampleRecommendations: MockData.sampleRecommendations(), settings: settings)
    }
}

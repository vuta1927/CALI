import Foundation

/// The app-facing sync surface: send the outbox (when an API is configured) and read what to show. Keeps GRDB out of
/// the app target. Without an API (no account, Release build before IOS-008) the status is still readable.
public struct SyncClient: Sendable {
    private let coordinator: WorkoutCoordinator
    private let engine: OutboxSyncEngine?

    public init(coordinator: WorkoutCoordinator, api: (any SyncAPI)?) {
        self.coordinator = coordinator
        engine = api.map { OutboxSyncEngine(writer: coordinator.writer, api: $0) }
    }

    public var canSync: Bool { engine != nil }

    public func syncOnce() async -> SyncRunSummary? { await engine?.syncOnce() }
    public func status() throws -> SyncStatus { try SyncStatus.read(coordinator.writer) }
    public func issues() throws -> [SyncIssue] { try SyncIssue.read(coordinator.writer) }

    private var resolver: SyncConflictResolver { SyncConflictResolver(writer: coordinator.writer) }
    public func keepLocal(_ issue: SyncIssue) throws { try resolver.keepLocal(seq: issue.id) }
    public func useServer(_ issue: SyncIssue, now: Date = Date()) throws { try resolver.useServer(seq: issue.id, now: now) }
    public func retry(_ issue: SyncIssue) throws { try resolver.retry(seq: issue.id) }
    public func dismiss(_ issue: SyncIssue) throws { try resolver.dismiss(seq: issue.id) }
}

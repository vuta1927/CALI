import CaliCore
import Foundation
import Observation

/// IOS-007: runs the outbox sync and publishes the state the Profile row shows. Sync is a background courtesy
/// (AGENTS: no BE dependency during a workout): it never blocks a command, and a failure only leaves rows pending.
@Observable
@MainActor
final class SyncService {
    private(set) var status = SyncStatus(pending: 0, conflicted: 0, rejected: 0)
    private(set) var issues: [SyncIssue] = []
    private(set) var isSyncing = false
    private(set) var lastOutcome: SyncRunSummary.Outcome?

    @ObservationIgnored private var client: SyncClient
    @ObservationIgnored private let coordinator: WorkoutCoordinator
    @ObservationIgnored private var debounce: Task<Void, Never>?
    /// Called after pulled changes or a "use the server's version" decision changed local content.
    @ObservationIgnored var onContentChanged: (() -> Void)?

    init(coordinator: WorkoutCoordinator) {
        self.coordinator = coordinator
        client = SyncClient(coordinator: coordinator, api: Self.makeAPI())
        refresh()
    }

    /// False in Release until Sign in with Apple (IOS-008) provides tokens.
    var isConfigured: Bool { client.canSync }

    /// Re-reads the credentials, e.g. after they were pasted in Diagnostics.
    func reconfigure() {
        client = SyncClient(coordinator: coordinator, api: Self.makeAPI())
        refresh()
    }

    func refresh() {
        status = (try? client.status()) ?? status
        issues = (try? client.issues()) ?? []
    }

    /// After a local write: waits a moment so a burst of commands becomes one request.
    func syncSoon() {
        guard isConfigured else { refresh(); return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard isConfigured, !isSyncing else { refresh(); return }
        isSyncing = true
        defer { isSyncing = false }
        let summary = await client.syncOnce()
        lastOutcome = summary?.outcome
        refresh()
        if (summary?.applied ?? 0) > 0 { onContentChanged?() }
    }

    // MARK: Decisions on changes the server did not take

    enum Decision { case keepLocal, useServer, retry, dismiss }

    func decide(_ decision: Decision, on issue: SyncIssue) {
        do {
            switch decision {
            case .keepLocal: try client.keepLocal(issue)
            case .useServer: try client.useServer(issue); onContentChanged?()
            case .retry: try client.retry(issue)
            case .dismiss: try client.dismiss(issue)
            }
            refresh()
            if decision == .keepLocal || decision == .retry { syncSoon() }
        } catch {
            refresh() // the row was already settled elsewhere
        }
    }

    private static func makeAPI() -> (any SyncAPI)? {
        #if DEBUG
        guard let base = DevCredentialStore.read(.baseURL), let url = URL(string: base), url.scheme == "https" || url.scheme == "http",
              DevCredentialStore.read(.token) != nil else { return nil }
        return URLSessionSyncAPI(baseURL: url, tokens: DevTokenProvider())
        #else
        // TODO(IOS-008): tokens from Sign in with Apple; until then Release builds do not sync.
        return nil
        #endif
    }
}

#if DEBUG
/// Dev auth (docs/16): the JWT pasted in Diagnostics. It cannot be refreshed, so a 401 means "paste a new one".
struct DevTokenProvider: SyncTokenProvider {
    func accessToken() async throws -> String {
        guard let token = DevCredentialStore.read(.token) else { throw SyncTransportError.unauthorized }
        return token
    }

    func refreshAccessToken() async throws { throw SyncTransportError.unauthorized }
}
#endif

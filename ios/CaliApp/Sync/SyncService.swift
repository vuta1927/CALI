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
    @ObservationIgnored private let auth: AuthService?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var isRefreshingCatalog = false
    /// Called after pulled changes or a "use the server's version" decision changed local content.
    @ObservationIgnored var onContentChanged: (() -> Void)?
    /// Called with the cached or newly downloaded criteria and indicators (CON-008).
    @ObservationIgnored var onConfigChanged: ((PublishedConfig) -> Void)?

    init(coordinator: WorkoutCoordinator, auth: AuthService? = nil) {
        self.coordinator = coordinator
        self.auth = auth
        client = SyncClient(coordinator: coordinator, api: Self.makeAPI(auth))
        refresh()
    }

    /// False until the user is signed in (Sign in with Apple, IOS-008) and the account owns this device's data.
    var isConfigured: Bool { client.canSync }

    /// Re-reads the credentials, e.g. after they were pasted in Diagnostics.
    func reconfigure() {
        client = SyncClient(coordinator: coordinator, api: Self.makeAPI(auth))
        refresh()
    }

    /// Sign-out: no new run starts and the one in flight is awaited, so nothing from the account lands after local data is wiped.
    func stopAndWait() async {
        debounce?.cancel()
        client = SyncClient(coordinator: coordinator, api: nil)
        await running?.value
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

    /// The published exercise catalog (anonymous). Offline or failing it changes nothing; new exercises also unblock pulled
    /// plans that were waiting for them, so a sync follows.
    func refreshCatalog() async {
        guard let base = auth?.baseURL, !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        await refreshConfig(base)
        let refresher = ExerciseCatalogRefresher(api: URLSessionExerciseCatalogAPI(baseURL: base), coordinator: coordinator,
                                                media: ExerciseMediaCache(directory: LocalMedia.directory))
        guard let changed = try? await refresher.refresh(), changed > 0 else { return }
        onContentChanged?()
        syncSoon()
    }

    /// At launch, before any network: the last downloaded config, or the bundled one.
    func loadCachedConfig() async {
        onConfigChanged?(await CriteriaConfigStore(coordinator: coordinator).load())
    }

    /// `GET /v1/criteria-config` with the cached ETag. Offline, 304 or a body this build cannot read keep the copy in use.
    private func refreshConfig(_ base: URL) async {
        let store = CriteriaConfigStore(coordinator: coordinator)
        let refresher = CriteriaConfigRefresher(api: URLSessionCriteriaConfigAPI(baseURL: base), store: store)
        guard (try? await refresher.refresh()) == true else { return }
        onConfigChanged?(await store.load())
    }

    func syncNow() async {
        await refreshCatalog()
        guard isConfigured, !isSyncing else { refresh(); return }
        isSyncing = true
        let client = self.client
        let run = Task { [weak self] in
            let summary = await client.syncOnce()
            guard let self else { return }
            lastOutcome = summary?.outcome
            refresh()
            if (summary?.applied ?? 0) > 0 { onContentChanged?() }
            if summary?.outcome == .needsSignIn { await auth?.sessionMayHaveEnded() }
        }
        running = run
        await run.value
        running = nil
        isSyncing = false
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

    private static func makeAPI(_ auth: AuthService?) -> (any SyncAPI)? {
        if let auth, auth.allowsSync, let base = auth.baseURL {
            return URLSessionSyncAPI(baseURL: base, tokens: auth.manager)
        }
        #if DEBUG
        guard let base = DevCredentialStore.read(.baseURL), let url = URL(string: base), url.scheme == "https" || url.scheme == "http",
              DevCredentialStore.read(.token) != nil else { return nil }
        return URLSessionSyncAPI(baseURL: url, tokens: DevTokenProvider())
        #else
        return nil // signed out: the app works fully on this device
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

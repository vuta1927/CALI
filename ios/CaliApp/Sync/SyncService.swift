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
    /// How the last attempt to read the published catalog ended, so the Catalog tab can say why it still shows old data.
    private(set) var catalogState: CatalogState = .idle

    enum CatalogState: Equatable { case idle, noServer, offline, failed }

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
    /// The cached or newly downloaded voice cues (CON-010, IOS-019); read when cues are scheduled.
    @ObservationIgnored private(set) var voiceLibrary: VoiceCueLibrary = .empty

    /// A test replaces this to answer without a network.
    @ObservationIgnored var makeCatalogAPI: (URL) -> any ExerciseCatalogAPI = { URLSessionExerciseCatalogAPI(baseURL: $0) }

    /// DEBUG only: the pasted dev credentials in the Keychain, used while nobody is signed in.
    @ObservationIgnored private let usesDevCredentials: Bool

    /// `usesDevCredentials: false` keeps a test independent of what an earlier run left in the device Keychain.
    init(coordinator: WorkoutCoordinator, auth: AuthService? = nil, usesDevCredentials: Bool = true) {
        self.coordinator = coordinator
        self.auth = auth
        self.usesDevCredentials = usesDevCredentials
        client = SyncClient(coordinator: coordinator, api: Self.makeAPI(auth, devCredentials: usesDevCredentials))
        refresh()
    }

    /// False until the user is signed in (Sign in with Apple, IOS-008) and the account owns this device's data.
    var isConfigured: Bool { client.canSync }

    /// Re-reads the credentials, e.g. after they were pasted in Diagnostics.
    func reconfigure() {
        client = SyncClient(coordinator: coordinator, api: Self.makeAPI(auth, devCredentials: usesDevCredentials))
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
        guard !isRefreshingCatalog else { return }
        guard let base = auth?.baseURL else { catalogState = .noServer; return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        await refreshConfig(base)
        await refreshVoicePack(base)
        let refresher = ExerciseCatalogRefresher(api: makeCatalogAPI(base), coordinator: coordinator,
                                                media: ExerciseMediaCache(directory: LocalMedia.directory))
        do {
            let changed = try await refresher.refresh()
            catalogState = .idle
            guard changed > 0 else { return }
            onContentChanged?()
            syncSoon()
        } catch let error as SyncTransportError where error == .offline {
            catalogState = .offline
        } catch {
            catalogState = .failed
        }
    }

    /// At launch, before any network: the last downloaded config, or the bundled one.
    func loadCachedConfig() async {
        onConfigChanged?(await CriteriaConfigStore(coordinator: coordinator).load())
        voiceLibrary = await voicePackStore.load()
    }

    private var voicePackStore: VoicePackStore {
        VoicePackStore(coordinator: coordinator, soundsDirectory: VoicePackStore.defaultSoundsDirectory)
    }

    /// `GET /v1/voice-pack` with the cached ETag; the files go to `Library/Sounds`. Failing, the pack in use stays.
    private func refreshVoicePack(_ base: URL) async {
        let store = voicePackStore
        guard (try? await VoicePackRefresher(api: URLSessionVoicePackAPI(baseURL: base), store: store).refresh()) == true else { return }
        voiceLibrary = await store.load()
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

    private static func makeAPI(_ auth: AuthService?, devCredentials: Bool) -> (any SyncAPI)? {
        if let auth, auth.allowsSync, let base = auth.baseURL {
            return URLSessionSyncAPI(baseURL: base, tokens: auth.manager)
        }
        #if DEBUG
        guard devCredentials, let base = DevCredentialStore.read(.baseURL), let url = URL(string: base), url.scheme == "https" || url.scheme == "http",
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

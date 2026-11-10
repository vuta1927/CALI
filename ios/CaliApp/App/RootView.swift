import SwiftUI

enum AppTab: String, Hashable {
    case today, plan, catalog, history, profile

    /// DEBUG only: `-uiTab history` opens a tab directly (simulator screenshots for mockup review).
    static var launchTab: AppTab {
        #if DEBUG
        UserDefaults.standard.string(forKey: "uiTab").flatMap(AppTab.init(rawValue:)) ?? .today
        #else
        .today
        #endif
    }

    /// DEBUG only: `-uiSkipWelcome YES` hides the first-launch sheet without changing stored settings.
    static var skipsWelcome: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "uiSkipWelcome") || DebugScenario.launch != nil
        #else
        false
        #endif
    }
}

/// Five-tab shell (docs/02 §2). The workout player is a full-screen modal on top of any tab.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = AppTab.launchTab
    @State private var debugRacePlan: UUID?
    /// The welcome screen opens on every launch (not once per install); it is dismissed for the rest of the session.
    @State private var showsWelcome = !AppTab.skipsWelcome

    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("Hôm nay", systemImage: "house.fill", value: AppTab.today) {
                NavigationStack { TodayView(tab: $tab) }
            }
            Tab("Giáo án", systemImage: "calendar.badge.clock", value: AppTab.plan) {
                NavigationStack { PlansListView() }
            }
            Tab("Bài tập", systemImage: "figure.strengthtraining.functional", value: AppTab.catalog) {
                NavigationStack { CatalogView() }
            }
            Tab("Lịch sử", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.history) {
                NavigationStack { HistoryView(tab: $tab) }
            }
            Tab("Cá nhân", systemImage: "person.crop.circle", value: AppTab.profile) {
                NavigationStack { ProfileView(tab: $tab) }
            }
            .badge(store.pendingRecommendationCount)
        }
        .tint(.caliAccentInk)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.sync.syncSoon()
                Task { await store.sync.refreshCatalog() }
            }
        }
        .task {
            await store.sync.loadCachedConfig()
            await store.auth.restore()
            await store.sync.refreshCatalog()
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .fullScreenCover(isPresented: $store.isPlayerPresented) {
            if let player = store.player {
                WorkoutPlayerView(model: player)
                    .environment(store)
            }
        }
        #if DEBUG
        .task {
            if let scenario = DebugScenario.launch { debugRacePlan = scenario.apply(to: store) }
        }
        .sheet(isPresented: Binding(get: { debugRacePlan != nil }, set: { if !$0 { debugRacePlan = nil } })) {
            if let id = debugRacePlan, let plan = store.plan(id) {
                switch DebugScenario.launch {
                case .overview: NavigationStack { PlanDetailView(lineageId: id) }.environment(store)
                case .goals: NavigationStack { GoalsView(lineageId: id) }.environment(store)
                case .roadmap: NavigationStack { RoadmapView(lineageId: id) }.environment(store)
                case .progress: NavigationStack { PlanProgressView(lineageId: id) }.environment(store)
                case .diagnostics: NavigationStack { DiagnosticsView() }.environment(store)
                case .body: NavigationStack { BodyMeasurementsView() }.environment(store)
                default: RaceResultSheet(plan: plan, plannedDistance: 10_000).environment(store)
                }
            }
        }
        #endif
        .fullScreenCover(isPresented: $showsWelcome) {
            WelcomeView(showsSignIn: store.auth.isAvailable) {
                store.updateSettings { $0.hasSeenWelcome = true }; showsWelcome = false
            } onSignIn: {
                store.updateSettings { $0.hasSeenWelcome = true }; showsWelcome = false
                tab = .profile
            }
            .interactiveDismissDisabled()
        }
        .alert("Không thể thực hiện", isPresented: alertBinding) {
            Button("Đóng", role: .cancel) { store.alertMessage = nil }
            if store.activeSessionInProgress {
                Button("Mở buổi đang tập") {
                    store.alertMessage = nil
                    store.resumeWorkout()
                }
            }
        } message: {
            Text(store.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })
    }
}

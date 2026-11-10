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
        UserDefaults.standard.bool(forKey: "uiSkipWelcome")
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
            if phase == .active { store.sync.syncSoon() }
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
        .sheet(isPresented: welcomeBinding) {
            WelcomeView { store.updateSettings { $0.hasSeenWelcome = true } }
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

    private var welcomeBinding: Binding<Bool> {
        Binding(get: { !store.settings.hasSeenWelcome && !AppTab.skipsWelcome }, set: { _ in })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { store.alertMessage != nil }, set: { if !$0 { store.alertMessage = nil } })
    }
}

/// First-launch explainer: what the POC is, what is sample data, and the safety disclaimer.
struct WelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HStack(spacing: Spacing.m) {
                    COAMISymbol()
                        .frame(width: 56, height: 56)
                    COAMIWordmark(includesTagline: true)
                }
                .padding(.top, Spacing.xl)
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Text("Tập rõ ràng. Tiến bộ bền vững.")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.caliText)
                    Text("COAMI đồng hành cùng bạn từ giáo án, hướng dẫn trực quan đến từng set và khoảng nghỉ — kể cả khi offline.")
                        .font(.title3)
                        .foregroundStyle(Color.caliSecondary)
                }
                VStack(alignment: .leading, spacing: Spacing.l) {
                    WelcomeRow(systemImage: "wifi.slash", title: "Chạy hoàn toàn offline",
                               text: "Mọi dữ liệu nằm trên iPhone của bạn. Chưa kết nối máy chủ.")
                    WelcomeRow(systemImage: "flask", title: "Có dữ liệu mẫu",
                               text: "Giáo án, lịch sử và đề xuất AI ban đầu là dữ liệu mẫu, được gắn nhãn \"Dữ liệu mẫu\". Ảnh bài tập là ảnh tạm (PLACEHOLDER).")
                    WelcomeRow(systemImage: "clock", title: "Thử nhanh trong 3 phút",
                               text: "Ở tab Hôm nay, chọn \"Buổi thử nhanh\" để đi qua đủ 5 loại bài: giữ tĩnh, số lần, theo thời gian, interval và kỹ năng.")
                    WelcomeRow(systemImage: "cross.case", title: "An toàn là trên hết",
                               text: "COAMI không đưa ra lời khuyên y tế. Dừng tập nếu thấy đau và hỏi chuyên gia khi cần.")
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Bắt đầu", action: onContinue)
                .buttonStyle(.caliPrimary)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .background(LinearGradient(colors: [Color.caliCanvas.opacity(0), Color.caliCanvas], startPoint: .top, endPoint: .center))
        }
        .background(COAMIScreenBackground())
    }
}

private struct WelcomeRow: View {
    let systemImage: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.caliAccentInk)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Color.caliSecondary)
            }
        }
    }
}

import SwiftUI

enum AppTab: Hashable {
    case today, plan, catalog, history, profile
}

/// Five-tab shell (docs/02 §2). The workout player is a full-screen modal on top of any tab.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: AppTab = .today

    var body: some View {
        @Bindable var store = store
        TabView(selection: $tab) {
            Tab("Hôm nay", systemImage: "flame", value: AppTab.today) {
                NavigationStack { TodayView(tab: $tab) }
            }
            Tab("Giáo án", systemImage: "calendar", value: AppTab.plan) {
                NavigationStack { PlanView() }
            }
            Tab("Bài tập", systemImage: "figure.strengthtraining.functional", value: AppTab.catalog) {
                NavigationStack { CatalogView() }
            }
            Tab("Lịch sử", systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                NavigationStack { HistoryView() }
            }
            Tab("Cá nhân", systemImage: "person.crop.circle", value: AppTab.profile) {
                NavigationStack { ProfileView() }
            }
            .badge(store.pendingRecommendationCount)
        }
        .tint(.caliAccent)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $store.isPlayerPresented) {
            if let player = store.player {
                WorkoutPlayerView(model: player)
                    .environment(store)
            }
        }
        .sheet(isPresented: welcomeBinding) {
            WelcomeView { store.updateSettings { $0.hasSeenWelcome = true } }
                .interactiveDismissDisabled()
        }
        .alert("Không thể bắt đầu", isPresented: alertBinding) {
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
        Binding(get: { !store.settings.hasSeenWelcome }, set: { _ in })
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
                Image(systemName: "figure.gymnastics")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.caliAccent)
                    .padding(.top, Spacing.xxl)
                Text("Chào mừng đến CALI")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Color.caliText)
                Text("Bản thử nghiệm (POC) để trải nghiệm giao diện tập luyện calisthenics.")
                    .font(.title3)
                    .foregroundStyle(Color.caliSecondary)
                VStack(alignment: .leading, spacing: Spacing.l) {
                    WelcomeRow(systemImage: "wifi.slash", title: "Chạy hoàn toàn offline",
                               text: "Mọi dữ liệu nằm trên iPhone của bạn. Chưa kết nối máy chủ.")
                    WelcomeRow(systemImage: "tag", title: "Có dữ liệu mẫu",
                               text: "Giáo án, lịch sử và đề xuất AI ban đầu là dữ liệu mẫu, được gắn nhãn \"Dữ liệu mẫu\". Ảnh bài tập là ảnh tạm (PLACEHOLDER).")
                    WelcomeRow(systemImage: "timer", title: "Thử nhanh trong 3 phút",
                               text: "Ở tab Hôm nay, chọn \"Buổi thử nhanh\" để đi qua đủ 5 loại bài: giữ tĩnh, số lần, theo thời gian, interval và kỹ năng.")
                    WelcomeRow(systemImage: "cross.case", title: "An toàn là trên hết",
                               text: "CALI không đưa ra lời khuyên y tế. Dừng tập nếu thấy đau và hỏi chuyên gia khi cần.")
                }
                Button("Bắt đầu", action: onContinue)
                    .buttonStyle(.caliPrimary)
                    .padding(.top, Spacing.l)
            }
            .padding(Spacing.xl)
        }
        .background(Color.caliCanvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
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
                .foregroundStyle(Color.caliAccent)
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

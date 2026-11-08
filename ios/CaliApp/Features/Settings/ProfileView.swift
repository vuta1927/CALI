import SwiftUI

/// "Cá nhân" tab (UX-10): AI recommendations entry, workout settings, data reset, build info.
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                NavigationLink {
                    AIReviewView()
                } label: {
                    HStack {
                        Label("Đề xuất AI", systemImage: "sparkles")
                        Spacer()
                        if store.pendingRecommendationCount > 0 {
                            Text("\(store.pendingRecommendationCount) mới")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, Spacing.s)
                                .padding(.vertical, 2)
                                .foregroundStyle(Color.caliOnAccent)
                                .background(Color.caliAccent, in: Capsule())
                        }
                    }
                }
                NavigationLink {
                    AuditLogView()
                } label: {
                    Label("Nhật ký thay đổi", systemImage: "list.bullet.rectangle")
                }
            }
            .listRowBackground(Color.caliSurface)

            Section {
                Stepper(value: setting(\.countdownSeconds), in: 0...10) {
                    LabeledContent("Đếm ngược trước set", value: store.settings.countdownSeconds == 0 ? "Tắt" : "\(store.settings.countdownSeconds) giây")
                }
                Toggle("Rung phản hồi", isOn: setting(\.hapticsEnabled))
                Toggle("Thông báo nhắc hết giờ", isOn: setting(\.notificationsEnabled))
                Toggle("Live Activity trên màn khoá", isOn: setting(\.liveActivityEnabled))
            } header: {
                Text("Buổi tập")
            } footer: {
                Text("Thông báo chỉ để nhắc và có thể đến trễ. COAMI không bao giờ tự đánh dấu set hoàn thành — bạn luôn xác nhận kết quả.")
            }
            .listRowBackground(Color.caliSurface)

            Section {
                Button("Khôi phục dữ liệu mẫu", role: .destructive) { confirmReset = true }
            } header: {
                Text("Dữ liệu")
            } footer: {
                Text("Dữ liệu chỉ lưu trên iPhone này (chưa đồng bộ máy chủ). Khôi phục sẽ xoá lịch sử, giáo án đã sửa và quyết định đề xuất.")
            }
            .listRowBackground(Color.caliSurface)

            Section {
                LabeledContent("Phiên bản", value: "\(BuildInfo.current.version) (\(BuildInfo.current.build))")
                LabeledContent("Commit", value: String(BuildInfo.current.sha.prefix(7)))
                LabeledContent("Chế độ", value: "POC · offline · dữ liệu mẫu")
            } header: {
                Text("Ứng dụng")
            } footer: {
                Text("COAMI không đưa ra lời khuyên y tế. Hỏi ý kiến chuyên gia trước khi bắt đầu chương trình tập mới.")
            }
            .listRowBackground(Color.caliSurface)
        }
        .caliScreen()
        .navigationTitle("Cá nhân")
        .toolbarTitleDisplayMode(.inlineLarge)
        .confirmationDialog("Khôi phục dữ liệu mẫu?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Xoá và khôi phục", role: .destructive) { store.resetDemoData() }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(store.activeSessionInProgress ? "Buổi tập đang dở cũng sẽ bị huỷ." : "Không thể hoàn tác.")
        }
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

import CaliCore
import CaliDomain
import SwiftUI

/// "Cá nhân" tab (UX-10, mockup `profile`): this week, AI + audit entries, workout settings, data, app.
///
/// The week card sums every followed plan and breaks the schedule down per plan (IOS-017).
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Binding var tab: AppTab
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                weekCard
                VStack(spacing: 0) {
                    NavigationLink { AIReviewView() } label: {
                        CardRow(systemImage: "sparkles", title: "Đề xuất AI") {
                            if store.pendingRecommendationCount > 0 {
                                TagChip(text: "\(store.pendingRecommendationCount) mới", tint: .caliAccent, filled: true)
                            }
                            Image(systemName: "chevron.right").foregroundStyle(Color.caliSecondary)
                        }
                    }
                    CardDivider()
                    NavigationLink { AuditLogView() } label: {
                        CardRow(systemImage: "list.bullet", title: "Nhật ký thay đổi") {
                            Image(systemName: "chevron.right").foregroundStyle(Color.caliSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .caliCard(padding: Spacing.l)
                .padding(.bottom, Spacing.s)

                group("Buổi tập", footer: "Thông báo chỉ để nhắc và có thể đến trễ. COAMI không bao giờ tự đánh dấu set hoàn thành — bạn luôn xác nhận kết quả.") {
                    CardRow(title: "Đếm ngược trước set") {
                        Text(store.settings.countdownSeconds == 0 ? "Tắt" : "\(store.settings.countdownSeconds) giây")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Color.caliSecondary)
                        MiniStepper(label: "Đếm ngược trước set",
                                    canDecrement: store.settings.countdownSeconds > 0,
                                    canIncrement: store.settings.countdownSeconds < 10) { delta in
                            store.updateSettings { $0.countdownSeconds = min(10, max(0, $0.countdownSeconds + delta)) }
                        }
                    }
                    CardDivider()
                    CardRow(title: "Đơn vị mức tạ") {
                        Picker("Đơn vị mức tạ", selection: setting(\.weightUnit)) {
                            ForEach(WeightUnit.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 140)
                    }
                    CardDivider()
                    Toggle("Rung phản hồi", isOn: setting(\.hapticsEnabled)).frame(minHeight: 52)
                    CardDivider()
                    Toggle("Thông báo nhắc hết giờ", isOn: setting(\.notificationsEnabled)).frame(minHeight: 52)
                    CardDivider()
                    Toggle("Live Activity trên màn khoá", isOn: setting(\.liveActivityEnabled)).frame(minHeight: 52)
                }

                group("Dữ liệu", footer: "Dữ liệu chỉ lưu trên iPhone này (chưa đồng bộ máy chủ). Khôi phục sẽ xoá lịch sử, giáo án đã sửa và quyết định đề xuất.") {
                    Button { confirmReset = true } label: {
                        CardRow(title: "Khôi phục dữ liệu mẫu", tint: .caliError) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }

                // TODO(POC-002): remove the device-gate entry after the POC-002 GO/NO-GO decision.
                group("Nhà phát triển", footer: "Màn kiểm thử Lock Screen / Live Activity / cơ sở dữ liệu cho đợt POC. Dùng cơ sở dữ liệu riêng, không ảnh hưởng buổi tập thường.") {
                    NavigationLink { POCDeviceGateView() } label: {
                        CardRow(systemImage: "lock.iphone", title: "POC thiết bị (POC-001/002)") {
                            Image(systemName: "chevron.right").foregroundStyle(Color.caliSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }

                group("Ứng dụng", footer: "COAMI không đưa ra lời khuyên y tế. Hỏi ý kiến chuyên gia trước khi bắt đầu chương trình tập mới.") {
                    CardRow(title: "Phiên bản") { value("\(BuildInfo.current.version) (\(BuildInfo.current.build))") }
                    CardDivider()
                    CardRow(title: "Commit") { value(String(BuildInfo.current.sha.prefix(7))) }
                    CardDivider()
                    CardRow(title: "Chế độ") { value("POC · offline · dữ liệu mẫu") }
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Cá nhân")
        .toolbarTitleDisplayMode(.large)
        .confirmationDialog("Khôi phục dữ liệu mẫu?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Xoá và khôi phục", role: .destructive) { store.resetDemoData() }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(store.activeSessionInProgress ? "Buổi tập đang dở cũng sẽ bị huỷ." : "Không thể hoàn tác.")
        }
    }

    /// "Tuần này" across every followed plan (IOS-017): sessions done / scheduled, minutes, km, adherence and a line per plan.
    /// Sets are not shown here: a set count and a distance are never added together.
    private var weekCard: some View {
        let now = Date()
        let week = store.weekSummary(now: now)
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tuần này").font(.headline).foregroundStyle(Color.caliText)
                Spacer()
                if let interval {
                    Text(Fmt.range(interval.start, interval.end.addingTimeInterval(-1)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.caliSecondary)
                }
            }
            HStack(spacing: Spacing.m) {
                StatTile(value: "\(week.done)/\(week.scheduled)", label: "Buổi xong", systemImage: "checkmark.circle", tint: .caliAccent)
                StatTile(value: "\(week.minutes)", label: "Phút", systemImage: "clock")
                if week.distanceMeters > 0 {
                    StatTile(value: Fmt.km(week.distanceMeters), label: "Quãng đường", systemImage: "figure.run")
                }
            }
            if let percent = week.adherencePercent {
                Text("Chuyên cần chung \(percent)%\(week.extraSessions > 0 ? " · thêm \(week.extraSessions) buổi ngoài lịch" : "")")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
            } else if week.extraSessions > 0 {
                Text("\(week.extraSessions) buổi ngoài lịch").font(.footnote).foregroundStyle(Color.caliSecondary)
            }
            if week.perPlan.count > 1 {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(week.perPlan) { line in
                        HStack {
                            Label(line.title, systemImage: "calendar").lineLimit(1)
                            Spacer()
                            Text("\(line.done)/\(line.scheduled)").monospacedDigit()
                        }
                        .font(.footnote)
                        .foregroundStyle(Color.caliSecondary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Button("Xem trong Lịch sử") { tab = .history }
                .buttonStyle(.caliLink)
        }
        .caliCard()
    }

    private func group<Content: View>(_ title: String, footer: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: title)
            VStack(spacing: 0) { content() }
                .tint(.caliAccent)
                .foregroundStyle(Color.caliText)
                .caliCard(padding: Spacing.l)
            Text(footer)
                .font(.caption)
                .foregroundStyle(Color.caliSecondary)
                .padding(.horizontal, Spacing.xs)
        }
        .padding(.bottom, Spacing.s)
    }

    private func value(_ text: String) -> some View {
        Text(text).font(.subheadline.monospacedDigit()).foregroundStyle(Color.caliSecondary).lineLimit(1)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: keyPath] }, set: { value in store.updateSettings { $0[keyPath: keyPath] = value } })
    }
}

/// Compact − / + pair (mockup segmented stepper), each half a 44pt target.
struct MiniStepper: View {
    let label: String
    var canDecrement = true
    var canIncrement = true
    let step: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            half("minus", "Giảm \(label)", enabled: canDecrement) { step(-1) }
            Rectangle().fill(Color.caliBorder).frame(width: 1, height: 20)
            half("plus", "Tăng \(label)", enabled: canIncrement) { step(1) }
        }
        .background(Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func half(_ image: String, _ a11y: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.caliText)
                .frame(width: minTapTarget, height: minTapTarget)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(a11y)
    }
}

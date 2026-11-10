import CaliCore
import SwiftUI

/// "Đồng bộ" (IOS-007, docs/08 §8): how many changes wait to be sent, the last successful send, and the changes the
/// server did not accept, each with the decisions the user can take (docs/08 §5). Nothing is merged automatically.
/// Sync status lives here and nowhere in the save flows (mockup rule).
struct SyncStatusView: View {
    @Environment(AppStore.self) private var store

    static func summary(_ sync: SyncService) -> String {
        switch sync.status.badge {
        case .needsAttention: "Cần xử lý xung đột"
        case .waiting: sync.isConfigured ? "Đã lưu trên máy · Chờ đồng bộ" : "Chỉ lưu trên máy"
        case .synced: sync.isConfigured ? "Đã đồng bộ" : "Chỉ lưu trên máy"
        }
    }

    static func entityName(_ type: String) -> String {
        switch type {
        case "workout_session": "Buổi tập"
        case "exercise_execution": "Bài tập trong buổi"
        case "set_result": "Kết quả set"
        case "training_plan": "Giáo án"
        case "plan_activation": "Lịch theo giáo án"
        case "plan_phase": "Giai đoạn của giáo án"
        case "planned_workout": "Buổi trong giáo án"
        case "planned_exercise": "Bài trong giáo án"
        case "plan_goal": "Mục tiêu"
        case "body_measurement": "Số đo cơ thể"
        default: "Dữ liệu"
        }
    }

    /// Server text is never shown as is; the code picks the sentence.
    static func reason(_ code: String) -> String {
        switch code {
        case "version_conflict": "Dữ liệu này đã thay đổi ở nơi khác."
        case "validation_failed": "Máy chủ không nhận dạng dữ liệu này."
        case "forbidden_entity", "cross_user_reference": "Dữ liệu này không thuộc tài khoản đang đăng nhập."
        case "active_plan_limit": "Đã đạt số giáo án tối đa được theo cùng lúc. Hãy tạm dừng một giáo án rồi bấm Gửi lại."
        case "plan_count_limit": "Đã đạt số giáo án tối đa của tài khoản."
        case "pinned_goal_limit": "Đã đạt số mục tiêu được ghim tối đa. Hãy bỏ ghim một mục tiêu rồi bấm Gửi lại."
        case "goal_unlock_cycle": "Mục tiêu mở khoá này tạo vòng lặp với mục tiêu khác."
        default: "Máy chủ không nhận thay đổi này."
        }
    }

    var body: some View {
        let sync = store.sync
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(Self.summary(sync)).font(.title3.bold()).foregroundStyle(Color.caliText)
                    if sync.status.pending > 0 {
                        Text("\(sync.status.pending) thay đổi đang chờ gửi.").foregroundStyle(Color.caliSecondary)
                    }
                    if let last = sync.status.lastPushOkAt {
                        Text("Lần gửi gần nhất: \(last.formatted(date: .abbreviated, time: .shortened))").font(.subheadline).foregroundStyle(Color.caliSecondary)
                    }
                    if let last = sync.status.lastPullOkAt {
                        Text("Lần nhận gần nhất: \(last.formatted(date: .abbreviated, time: .shortened))").font(.subheadline).foregroundStyle(Color.caliSecondary)
                    }
                    if sync.status.unappliedChanges > 0 {
                        Text("\(sync.status.unappliedChanges) thay đổi từ máy chủ đã nhận, chưa áp dụng vào dữ liệu trên máy.").font(.subheadline).foregroundStyle(Color.caliSecondary)
                    }
                    if !sync.isConfigured {
                        Text("Chưa đăng nhập nên dữ liệu chỉ nằm trên iPhone này. Mọi buổi tập vẫn được lưu đầy đủ.")
                            .font(.subheadline).foregroundStyle(Color.caliSecondary)
                    }
                    if sync.lastOutcome == .needsSignIn {
                        Text("Phiên đăng nhập đã hết hạn.").font(.subheadline).foregroundStyle(Color.caliSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .caliCard(padding: Spacing.l)

                if sync.isConfigured {
                    Button(sync.isSyncing ? "Đang gửi…" : "Đồng bộ ngay") { Task { await sync.syncNow() } }
                        .buttonStyle(.caliPrimary)
                        .disabled(sync.isSyncing)
                }

                if !sync.issues.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        SectionHeader(title: "Cần xử lý", trailing: "\(sync.issues.count)")
                        ForEach(sync.issues) { issue in
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(Self.entityName(issue.entityType)).font(.headline).foregroundStyle(Color.caliText)
                                Text(Self.reason(issue.code)).font(.subheadline).foregroundStyle(Color.caliSecondary)
                                if issue.entityType == "body_measurement" && issue.kind == .conflicted {
                                    Text("Giá trị chỉ hiện trong màn Số đo cơ thể.").font(.caption).foregroundStyle(Color.caliSecondary)
                                }
                                HStack(spacing: Spacing.m) {
                                    if issue.kind == .conflicted {
                                        Button("Giữ bản trên máy") { sync.decide(.keepLocal, on: issue) }
                                        if issue.canUseServer { Button("Dùng bản máy chủ") { sync.decide(.useServer, on: issue) } }
                                    } else {
                                        Button("Gửi lại") { sync.decide(.retry, on: issue) }
                                        Button("Bỏ qua") { sync.decide(.dismiss, on: issue) }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .padding(.top, Spacing.xs)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .caliCard(padding: Spacing.l)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Đồng bộ")
        .navigationBarTitleDisplayMode(.inline)
        .task { sync.refresh() }
    }
}

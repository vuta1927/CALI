import SwiftUI

/// AI recommendations (UX-09, docs/09). POC: fixed sample recommendations, no LLM call. Every
/// change requires an explicit accept/reject and is written to the audit log (AGENTS rule 5).
struct AIReviewView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let pending = store.recommendations.filter { $0.decision == nil }
        let decided = store.recommendations.filter { $0.decision != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Label("Đề xuất dựa trên lịch sử tập. COAMI không đưa ra lời khuyên y tế; giáo án chỉ thay đổi khi bạn chấp nhận.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
                    .caliCard(padding: Spacing.m)

                SectionHeader(title: "Chờ quyết định", trailing: "\(pending.count)")
                if pending.isEmpty {
                    Text("Không còn đề xuất nào cần xem.")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                        .caliCard()
                }
                ForEach(pending) { rec in
                    RecommendationCard(recommendation: rec)
                }

                if !decided.isEmpty {
                    SectionHeader(title: "Đã quyết định")
                    ForEach(decided) { rec in
                        RecommendationCard(recommendation: rec)
                    }
                }

                NavigationLink {
                    AuditLogView()
                } label: {
                    HStack {
                        Label("Nhật ký thay đổi", systemImage: "list.bullet.rectangle")
                            .foregroundStyle(Color.caliText)
                        Spacer()
                        Text("\(store.audit.count)")
                            .foregroundStyle(Color.caliSecondary)
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Color.caliSecondary)
                    }
                    .frame(minHeight: minTapTarget)
                    .caliCard(padding: Spacing.m)
                }
                .buttonStyle(.plain)
            }
            .padding(Spacing.l)
        }
        .caliScreen()
        .navigationTitle("Đề xuất AI")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RecommendationCard: View {
    @Environment(AppStore.self) private var store
    let recommendation: Recommendation
    @State private var confirmAccept = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.m) {
                PosterThumb(exercise: recommendation.exerciseId.flatMap(store.exercise), size: 52)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(recommendation.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    HStack(spacing: Spacing.s) {
                        Text(recommendation.fromLabel)
                            .strikethrough(recommendation.decision == .accepted)
                            .foregroundStyle(Color.caliSecondary)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(Color.caliSecondary)
                        Text(recommendation.toLabel)
                            .foregroundStyle(Color.caliAccent)
                    }
                    .font(.subheadline.weight(.semibold))
                }
                Spacer()
                if recommendation.isSample { MockBadge() }
            }
            Text(recommendation.rationale)
                .font(.subheadline)
                .foregroundStyle(Color.caliText)
            HStack(spacing: Spacing.s) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text("Độ tin cậy \(Int((recommendation.confidence * 100).rounded()))%")
            }
            .font(.caption)
            .foregroundStyle(Color.caliSecondary)
            Label(recommendation.uncertainty, systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(Color.caliSecondary)

            if let decision = recommendation.decision {
                HStack {
                    TagChip(text: decision == .accepted ? "Đã chấp nhận" : "Đã từ chối",
                            systemImage: decision == .accepted ? "checkmark" : "xmark",
                            tint: decision == .accepted ? .caliAccent : .caliSecondary,
                            filled: decision == .accepted)
                    Spacer()
                    if let at = recommendation.decidedAt {
                        Text("\(Fmt.relativeDay(at)) \(Fmt.time(at))")
                            .font(.caption)
                            .foregroundStyle(Color.caliSecondary)
                    }
                }
            } else {
                HStack(spacing: Spacing.m) {
                    Button("Từ chối") { store.decide(recommendation, accept: false) }
                        .buttonStyle(.caliSecondary)
                    Button("Chấp nhận") { confirmAccept = true }
                        .buttonStyle(.caliPrimary)
                }
            }
        }
        .caliCard()
        .confirmationDialog("Áp dụng thay đổi vào giáo án?", isPresented: $confirmAccept, titleVisibility: .visible) {
            Button("Chấp nhận và cập nhật giáo án") { store.decide(recommendation, accept: true) }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("\(recommendation.fromLabel) → \(recommendation.toLabel)")
        }
    }
}

struct AuditLogView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.audit.isEmpty {
                ContentUnavailableView("Chưa có thay đổi", systemImage: "list.bullet.rectangle",
                                       description: Text("Các lần sửa giáo án và quyết định với đề xuất AI sẽ được ghi ở đây."))
            } else {
                List(store.audit) { entry in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(entry.action)
                                .font(.headline)
                                .foregroundStyle(Color.caliText)
                            Spacer()
                            Text("\(Fmt.dayMonth(entry.at)) \(Fmt.time(entry.at))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.caliSecondary)
                        }
                        Text(entry.detail)
                            .font(.subheadline)
                            .foregroundStyle(Color.caliSecondary)
                    }
                    .padding(.vertical, Spacing.xs)
                    .listRowBackground(Color.caliSurface)
                }
            }
        }
        .caliScreen()
        .navigationTitle("Nhật ký thay đổi")
        .navigationBarTitleDisplayMode(.inline)
    }
}

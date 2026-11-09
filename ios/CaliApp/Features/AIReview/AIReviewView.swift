import SwiftUI

/// AI recommendations (UX-09, docs/09, mockup `aiReview`). POC: fixed sample recommendations, no LLM
/// call. Every change requires an explicit accept/reject and is written to the audit log (AGENTS rule 5).
struct AIReviewView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let pending = store.recommendations.filter { $0.decision == nil }
        let decided = store.recommendations.filter { $0.decision != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text("AI chỉ đề xuất. Giáo án chỉ đổi khi bạn chấp nhận, và mọi quyết định được ghi vào Nhật ký thay đổi.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader(title: "Chờ quyết định", trailing: "\(pending.count)")
                    if pending.isEmpty {
                        HStack(spacing: Spacing.m) {
                            Image(systemName: "checkmark.circle").foregroundStyle(Color.caliAccentInk)
                            Text("Không còn đề xuất nào chờ bạn.").font(.subheadline).foregroundStyle(Color.caliSecondary)
                        }
                        .caliCard(padding: Spacing.m)
                    }
                    ForEach(pending) { RecommendationCard(recommendation: $0) }
                }

                if !decided.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        SectionHeader(title: "Đã quyết định", trailing: "\(decided.count)")
                        ForEach(decided) { DecidedRow(recommendation: $0) }
                    }
                }

                Text("COAMI không đưa ra lời khuyên y tế.")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
            }
            .padding(Spacing.l)
        }
        .caliScreen()
        .navigationTitle("Đề xuất AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.recommendations.contains(where: \.isSample) {
                ToolbarItem(placement: .primaryAction) { MockBadge() }
            }
        }
    }
}

private struct RecommendationCard: View {
    @Environment(AppStore.self) private var store
    let recommendation: Recommendation
    @State private var confirmAccept = false

    var body: some View {
        let confidence = Int((recommendation.confidence * 100).rounded())
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.m) {
                PosterThumb(exercise: recommendation.exerciseId.flatMap(store.exercise), size: 56)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(recommendation.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    TagChip(text: "Độ tin cậy \(confidence)%", systemImage: "info.circle",
                            tint: confidence >= 60 ? .caliAccentInk : .caliSecondary)
                }
            }
            Text(recommendation.rationale)
                .font(.subheadline)
                .foregroundStyle(Color.caliText)
            if !recommendation.uncertainty.isEmpty {
                Label(recommendation.uncertainty, systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
            }
            FromToView(fromCaption: "Hiện tại", from: recommendation.fromLabel, toCaption: "Đề xuất", to: recommendation.toLabel)
            HStack(spacing: Spacing.s) {
                Button("Từ chối") { store.decide(recommendation, accept: false) }
                    .buttonStyle(.caliSecondary)
                Button("Chấp nhận") { confirmAccept = true }
                    .buttonStyle(.caliPrimary)
            }
        }
        .caliCard()
        .confirmationDialog("Áp dụng thay đổi vào giáo án?", isPresented: $confirmAccept, titleVisibility: .visible) {
            Button("Chấp nhận và cập nhật giáo án") { store.decide(recommendation, accept: true) }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("\(recommendation.title): \(recommendation.fromLabel) → \(recommendation.toLabel)")
        }
    }
}

private struct DecidedRow: View {
    @Environment(AppStore.self) private var store
    let recommendation: Recommendation

    var body: some View {
        let accepted = recommendation.decision == .accepted
        HStack(spacing: Spacing.m) {
            PosterThumb(exercise: recommendation.exerciseId.flatMap(store.exercise), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(recommendation.title)
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            TagChip(text: accepted ? "Đã chấp nhận" : "Đã từ chối", systemImage: accepted ? "checkmark.circle" : "xmark",
                    tint: accepted ? .caliAccentInk : .caliSecondary)
        }
        .caliCard(padding: Spacing.m)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let change = "\(recommendation.fromLabel) → \(recommendation.toLabel)"
        guard let at = recommendation.decidedAt else { return change }
        return "\(change) · \(Fmt.dayMonthShort(at)) \(Fmt.time(at))"
    }
}

struct AuditLogView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Chỉ ghi thêm, không sửa hay xoá. Mỗi thay đổi giáo án (bạn sửa hoặc chấp nhận đề xuất AI) đều có một dòng.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
                if store.audit.isEmpty {
                    ContentUnavailableView("Chưa có thay đổi", systemImage: "list.bullet.rectangle",
                                           description: Text("Các lần sửa giáo án và quyết định với đề xuất AI sẽ được ghi ở đây."))
                }
                ForEach(store.audit) { entry in
                    HStack(alignment: .top, spacing: Spacing.m) {
                        Image(systemName: icon(entry.action))
                            .foregroundStyle(Color.caliAccentInk)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.action)
                                .font(.headline)
                                .foregroundStyle(Color.caliText)
                            if !entry.detail.isEmpty {
                                Text(entry.detail)
                                    .font(.footnote)
                                    .foregroundStyle(Color.caliSecondary)
                            }
                            Text("\(Fmt.dayMonthShort(entry.at)) \(Fmt.time(entry.at))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.caliSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .caliCard(padding: Spacing.m)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Spacing.l)
        }
        .caliScreen()
        .navigationTitle("Nhật ký thay đổi")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func icon(_ action: String) -> String {
        let a = action.lowercased()
        if a.contains("từ chối") { return "xmark.circle" }
        if a.contains("chấp nhận") { return "checkmark.circle" }
        if a.contains("xoá") || a.contains("xóa") { return "trash" }
        return "pencil"
    }
}

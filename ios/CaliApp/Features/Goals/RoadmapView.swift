import CaliDomain
import SwiftUI

/// docs/18 §6.5 (mockup `roadmap`): week strip + phase timeline. Edits happen on a draft; Lưu applies them
/// in one step with an audit row, Huỷ discards. Week ranges are always computed, never typed.
struct RoadmapView: View {
    @Environment(AppStore.self) private var store
    let lineageId: UUID
    @State private var draft: [PlanPhase]?
    @State private var commandId = UUID()
    @State private var confirmingShrink = false
    @State private var deleting: PlanPhase?

    var body: some View {
        if let plan = store.plan(lineageId) {
            let phases = draft ?? plan.phases
            let week = store.currentWeek(of: plan)
            let spans = store.phaseSpans(of: plan, phases: phases)
            let total = PhaseTimeline.totalWeeks(phases)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if total > 0 { weekStrip(total: total, current: week.state == .inProgress ? week.week : 0, spans: spans) }
                    if phases.isEmpty && draft == nil {
                        ContentUnavailableView("Chưa có lộ trình", systemImage: "map",
                                               description: Text("Chia giáo án thành các giai đoạn. Tổng số tuần là độ dài giáo án."))
                    }
                    ForEach(spans, id: \.phase.id) { span in
                        if draft != nil { editRow(span, count: phases.count) } else { phaseRow(span) }
                    }
                    if draft != nil {
                        Button("Thêm giai đoạn", systemImage: "plus") {
                            draft?.append(PlanPhase(id: UUID(), name: "Giai đoạn \(phases.count + 1)", weeks: 4))
                        }
                        .buttonStyle(.caliSecondary)
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .safeAreaInset(edge: .bottom) {
                if draft != nil {
                    HStack {
                        Button("Huỷ") { draft = nil }.buttonStyle(.caliSecondary)
                        Button("Lưu") { attemptSave(plan) }.buttonStyle(.caliPrimary)
                    }
                    .padding(Spacing.l)
                    .background(Color.caliCanvas)
                }
            }
            .caliScreen()
            .navigationTitle("Lộ trình")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(draft != nil)
            .toolbar {
                if draft == nil, store.isEditable(plan) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sửa") {
                            commandId = UUID()
                            draft = plan.phases
                        }
                    }
                }
            }
            .confirmationDialog("Rút ngắn qua tuần hiện tại?", isPresented: $confirmingShrink, titleVisibility: .visible) {
                Button("Vẫn lưu") { save(plan) }
                Button("Huỷ", role: .cancel) {}
            } message: {
                Text("Đang ở tuần \(week.week). Lộ trình mới ngắn hơn nên giáo án sẽ được tính là đã xong. Buổi đã tập vẫn giữ nguyên.")
            }
            .confirmationDialog("Xoá giai đoạn hiện tại?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible, presenting: deleting) { phase in
                Button("Xoá", role: .destructive) { draft?.removeAll { $0.id == phase.id } }
                Button("Huỷ", role: .cancel) {}
            } message: { _ in
                Text("Mục tiêu của giai đoạn này sẽ chuyển sang phạm vi cả giáo án.")
            }
        }
    }

    private func weekStrip(total: Int, current: Int, spans: [PhaseSpan]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(current > 0 ? "Tuần \(current)/\(total)" : "\(total) tuần")
                .font(.headline)
                .foregroundStyle(Color.caliText)
            HStack(spacing: 3) {
                ForEach(1...total, id: \.self) { week in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(week < current ? Color.caliAccent : week == current ? Color.caliAccentInk : Color.caliSurfaceRaised)
                        .frame(height: 10)
                }
            }
            .accessibilityHidden(true)
        }
        .caliCard()
    }

    private func phaseRow(_ span: PhaseSpan) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: span.state == .done ? "checkmark.circle.fill" : span.state == .current ? "circle.inset.filled" : "circle")
                .foregroundStyle(span.state == .upcoming ? Color.caliSecondary : Color.caliAccentInk)
                .font(.title3)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(span.phase.name).font(.headline).foregroundStyle(Color.caliText)
                Text("\(span.label) · \(span.phase.weeks) tuần\(span.state == .current ? " · Đang ở đây" : "")")
                    .font(.caption).foregroundStyle(Color.caliSecondary)
                if let description = span.phase.description, !description.isEmpty {
                    Text(description).font(.footnote).foregroundStyle(Color.caliText)
                }
            }
            Spacer(minLength: 0)
        }
        .caliCard()
        .accessibilityElement(children: .combine)
    }

    private func editRow(_ span: PhaseSpan, count: Int) -> some View {
        let index = span.index
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(span.label).font(.caption.weight(.semibold)).foregroundStyle(Color.caliSecondary)
                Spacer()
                Button { move(index, by: -1) } label: { Image(systemName: "arrow.up").frame(width: minTapTarget, height: minTapTarget) }
                    .disabled(index == 0).accessibilityLabel("Lên trên")
                Button { move(index, by: 1) } label: { Image(systemName: "arrow.down").frame(width: minTapTarget, height: minTapTarget) }
                    .disabled(index == count - 1).accessibilityLabel("Xuống dưới")
                Button(role: .destructive) {
                    if span.state == .current { deleting = span.phase } else { draft?.remove(at: index) }
                } label: { Image(systemName: "trash").frame(width: minTapTarget, height: minTapTarget) }
                    .accessibilityLabel("Xoá giai đoạn")
            }
            TextField("Tên giai đoạn", text: Binding(get: { draft?[safe: index]?.name ?? "" }, set: { draft?[index].name = $0 }))
                .textFieldStyle(.roundedBorder)
            Stepper(value: Binding(get: { draft?[safe: index]?.weeks ?? 1 }, set: { draft?[index].weeks = $0 }), in: 1...52) {
                Text("\(draft?[safe: index]?.weeks ?? 1) tuần").monospacedDigit().foregroundStyle(Color.caliText)
            }
        }
        .caliCard()
    }

    private func move(_ index: Int, by offset: Int) {
        guard var phases = draft, phases.indices.contains(index + offset) else { return }
        phases.swapAt(index, index + offset)
        draft = phases
    }

    private func attemptSave(_ plan: WorkoutPlan) {
        guard let draft else { return }
        let week = store.currentWeek(of: plan)
        if week.state == .inProgress, !draft.isEmpty, PhaseTimeline.totalWeeks(draft) < week.week {
            confirmingShrink = true
        } else {
            save(plan)
        }
    }

    private func save(_ plan: WorkoutPlan) {
        guard let phases = draft else { return }
        if store.savePhases(plan.lineageId, phases, commandId: commandId) { draft = nil }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

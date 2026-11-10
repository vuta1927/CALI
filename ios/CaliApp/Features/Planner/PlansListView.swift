import CaliDomain
import SwiftUI

/// "Giáo án" tab root (MP-01, mockup `plansList`): plans grouped by status, "+" to create.
struct PlansListView: View {
    @Environment(AppStore.self) private var store
    @State private var creating = false
    @State private var created: UUID?
    @State private var showsArchived = false

    var body: some View {
        let now = Date()
        let plans = store.visiblePlans
        let followed = store.followedPlans(now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if plans.isEmpty {
                    emptyState
                } else {
                    group("Đang theo", trailing: "\(followed.count)/\(PlanLifecycle.defaultActivePlanLimit)", plans: followed, now: now)
                    group("Nháp", plans: plans.filter { store.status(of: $0, now: now) == .draft }, now: now)
                    group("Tạm dừng", plans: plans.filter { store.status(of: $0, now: now) == .paused }, now: now)
                    group("Đã kết thúc", plans: plans.filter { store.status(of: $0, now: now) == .ended }.reversed(), now: now)
                    archived(plans.filter { store.status(of: $0, now: now) == .archived }, now: now)
                }
                Text("Theo tối đa \(PlanLifecycle.defaultActivePlanLimit) giáo án cùng lúc. Giáo án không tự kết thúc; bạn chọn khi nào dừng.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
                SampleFooter(showsSample: store.showsSampleData)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Giáo án")
        .toolbarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Tạo giáo án", systemImage: "plus") { creating = true }
                    .disabled(plans.count >= AppStore.planCountLimit)
            }
        }
        .sheet(isPresented: $creating) {
            PlanCreateView { created = $0 }
        }
        .navigationDestination(for: UUID.self) { PlanDetailView(lineageId: $0) }
        .navigationDestination(item: $created) { PlanDetailView(lineageId: $0) }
    }

    @ViewBuilder
    private func group(_ title: String, trailing: String? = nil, plans: [WorkoutPlan], now: Date) -> some View {
        if !plans.isEmpty || trailing != nil {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SectionHeader(title: title, trailing: trailing)
                if plans.isEmpty {
                    Text("Chưa theo giáo án nào. Mở một giáo án nháp và chọn \"Bắt đầu theo\".")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                        .caliCard(padding: Spacing.m)
                }
                ForEach(plans, id: \.lineageId) { plan in
                    NavigationLink(value: plan.lineageId) { PlanCard(plan: plan, now: now) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func archived(_ plans: [WorkoutPlan], now: Date) -> some View {
        if !plans.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Button {
                    withAnimation { showsArchived.toggle() }
                } label: {
                    HStack {
                        SectionHeader(title: "Lưu trữ", trailing: "\(plans.count)")
                        Image(systemName: showsArchived ? "chevron.up" : "chevron.down")
                            .foregroundStyle(Color.caliSecondary)
                    }
                    .frame(minHeight: minTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(showsArchived ? "Thu gọn" : "Mở rộng")
                if showsArchived {
                    ForEach(plans, id: \.lineageId) { plan in
                        NavigationLink(value: plan.lineageId) { PlanCard(plan: plan, now: now) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Chưa có giáo án", systemImage: "calendar.badge.plus")
                .font(.title3.bold())
                .foregroundStyle(Color.caliText)
            Text("Tạo giáo án trống, hoặc bắt đầu từ giáo án mẫu rồi sửa theo ý bạn.")
                .font(.subheadline)
                .foregroundStyle(Color.caliSecondary)
            Button("Tạo giáo án", systemImage: "plus") { creating = true }
                .buttonStyle(.caliPrimary)
        }
        .caliCard()
    }
}

/// One plan in the list: posters of its workouts, title, status, schedule and the event date.
struct PlanCard: View {
    @Environment(AppStore.self) private var store
    let plan: WorkoutPlan
    let now: Date

    var body: some View {
        let status = store.status(of: plan, now: now)
        HStack(alignment: .top, spacing: Spacing.m) {
            PosterStack(exercises: posters, size: 44, limit: 3)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(plan.title)
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                    .lineLimit(2)
                Text(caption(status))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    PlanStatusChip(status: status)
                    if let discipline = plan.primaryDiscipline { TagChip(text: discipline.label, systemImage: discipline.systemImage) }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(Color.caliSecondary)
        }
        .caliCard(padding: Spacing.m)
        .accessibilityElement(children: .combine)
    }

    private var posters: [Exercise?] {
        Array(plan.workouts.sorted { $0.weekday < $1.weekday }.flatMap { $0.exercises.map(\.exerciseId) }.uniqued().prefix(3)).map(store.exercise)
    }

    private func caption(_ status: PlanStatus) -> String {
        var parts = ["\(plan.slots.count) buổi / tuần"]
        if plan.kind == .event, let date = plan.eventDate {
            parts.append("\(plan.eventName ?? "Sự kiện") \(Fmt.shortDate(date))")
            if let days = store.daysUntilEvent(plan, now: now), days >= 0, [.active, .scheduled].contains(status) {
                parts.append("còn \(days) ngày")
            }
        }
        if status == .scheduled, let from = plan.activations.map(\.fromDate).filter({ $0 > store.today(now) }).min() {
            parts.append("bắt đầu \(Fmt.shortDate(from))")
        }
        if store.isFinished(plan, now: now) { parts.append("chờ bạn chọn tiếp theo") }
        return parts.joined(separator: " · ")
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

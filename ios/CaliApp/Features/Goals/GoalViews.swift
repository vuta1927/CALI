import CaliDomain
import SwiftUI

/// Formatting shared by the goal, roadmap and progress screens.
enum GoalFmt {
    static func number(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "vi_VN")
        formatter.maximumFractionDigits = 1
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    static func value(_ value: Decimal?, unit: String) -> String {
        value.map { "\(number($0)) \(unit)" } ?? "—"
    }

    static func target(_ target: GoalTarget, unit: String) -> String {
        switch target {
        case .value(let v): "\(number(v)) \(unit)"
        case .range(let lo, let hi): "\(number(lo))–\(number(hi)) \(unit)"
        }
    }

    /// Mockup `autoTitle`, used when the user leaves the title empty.
    static func autoTitle(indicator: IndicatorDefinition, exercise: Exercise?, target: Decimal) -> String {
        let name = exercise?.name ?? "Bài tập"
        let t = number(target)
        switch indicator.id {
        case "best_hold_seconds": return "Giữ \(name) \(t) giây"
        case "best_set_reps": return "\(name) \(t) lần một set"
        case "milestone_hold_seconds": return "\(name) giữ \(t) giây"
        case "milestone_reps": return "\(name) \(t) lần liền"
        case "weekly_total_reps": return "\(name) \(t) lần mỗi tuần"
        case "weekly_total_hold_seconds": return "\(name) giữ \(t) giây mỗi tuần"
        default: return "\(indicator.label) \(t) \(indicator.unit)"
        }
    }

    /// Delta line: never red; equal reads "Chưa đổi" (docs/18 §6.6).
    static func delta(_ summary: ProgressSummary, unit: String) -> String {
        guard let delta = summary.delta else { return "Chưa đủ dữ liệu để so" }
        if delta == 0 { return "Chưa đổi" }
        let sign = delta > 0 ? "+" : "−"
        let magnitude = number(delta < 0 ? -delta : delta)
        let percent = summary.percent.map { " (\($0 > 0 ? "+" : "")\($0)%)" } ?? ""
        return "\(sign)\(magnitude) \(unit)\(percent) so với tuần \(summary.referenceWeek ?? 1)"
    }
}

/// Status chip labels from the mockup.
struct GoalStatusChip: View {
    let goal: PlanGoal
    let locked: Bool
    let met: Bool

    var body: some View {
        let (text, icon, tint): (String, String, Color) = {
            if locked { return ("Chưa mở", "lock", .caliSecondary) }
            switch goal.status {
            case .active: return met ? ("Đang đạt", "checkmark", .caliAccentInk) : ("Đang theo đuổi", "scope", .caliAccentInk)
            case .reached: return ("Chờ xác nhận", "hand.raised", .caliWarning)
            case .achieved: return ("Đã đạt", "checkmark.seal.fill", .caliAccentInk)
            case .missed: return ("Chưa đạt", "clock", .caliSecondary)
            case .archived: return ("Đã lưu trữ", "archivebox", .caliSecondary)
            }
        }()
        TagChip(text: text, systemImage: icon, tint: tint)
    }
}

/// One goal: poster, title, baseline → current → target, actions for its state.
struct GoalCard: View {
    @Environment(AppStore.self) private var store
    let goal: PlanGoal
    let plan: WorkoutPlan
    var compact = false
    var onEdit: (() -> Void)?

    var body: some View {
        let indicator = store.indicator(goal.indicatorId)
        let unit = indicator?.unit ?? ""
        let exercise = goal.exerciseId.flatMap(store.exercise)
        let locked = store.isLocked(goal)
        let current = store.current(of: goal)
        let met = goal.target.isMet(by: current)
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.m) {
                PosterThumb(exercise: exercise, size: compact ? 44 : 56)
                    .opacity(locked ? 0.5 : 1)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(goal.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    Text("\(indicator?.label ?? goal.indicatorId) · \(store.scopeLabel(goal, in: plan))")
                        .font(.caption)
                        .foregroundStyle(Color.caliSecondary)
                    GoalStatusChip(goal: goal, locked: locked, met: met)
                }
                Spacer(minLength: 0)
                if !compact, goal.status != .archived, goal.status != .achieved {
                    Button {
                        store.setPinned(goal.id, !goal.pinned)
                    } label: {
                        Image(systemName: goal.pinned ? "star.fill" : "star")
                            .foregroundStyle(goal.pinned ? Color.caliAccentInk : Color.caliSecondary)
                            .frame(width: minTapTarget, height: minTapTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(goal.pinned ? "Bỏ ghim" : "Ghim lên tổng quan")
                }
            }
            if locked, let after = goal.unlockAfterGoalId.flatMap(store.goal) {
                Text("Mở khi đạt “\(after.title)”")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(goal.baseline.map { "Ban đầu \(GoalFmt.value($0, unit: unit))" } ?? "Chưa có mốc ban đầu")
                    Spacer()
                    Text("Hiện tại ").foregroundStyle(Color.caliSecondary)
                        + Text(GoalFmt.value(current, unit: unit)).foregroundStyle(Color.caliText).bold()
                    Text("/ \(GoalFmt.target(goal.target, unit: unit))")
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.caliSecondary)
                LinearProgress(progress: GoalProgress.fraction(current: current, baseline: goal.baseline, target: goal.target))
            }
            if !compact { actions(locked: locked) }
        }
        .caliCard()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actions(locked: Bool) -> some View {
        switch goal.status {
        case .reached:
            Text("Đã chạm mức đích trong buổi tập. Bạn xác nhận đã đạt chưa?")
                .font(.footnote)
                .foregroundStyle(Color.caliText)
            HStack {
                Button("Chưa, giữ tiếp") { store.keepGoal(goal.id) }.buttonStyle(.caliSecondary)
                Button("Xác nhận đạt") { store.confirmGoal(goal.id) }.buttonStyle(.caliPrimary)
            }
        case .active where !locked && goal.target.isMet(by: store.current(of: goal)):
            Button("Xác nhận đạt", systemImage: "checkmark.seal") { store.confirmGoal(goal.id) }.buttonStyle(.caliSecondary)
        case .missed:
            HStack {
                Button("Lưu trữ") { store.archiveGoal(goal.id) }.buttonStyle(.caliQuiet)
                Button("Gia hạn", systemImage: "arrow.clockwise") { store.extendGoal(goal.id) }.buttonStyle(.caliSecondary)
            }
        case .archived:
            Button("Khôi phục", systemImage: "arrow.uturn.backward") { store.restoreGoal(goal.id) }.buttonStyle(.caliQuiet)
        default:
            EmptyView()
        }
        if let onEdit, goal.status != .archived {
            Button("Sửa", systemImage: "pencil", action: onEdit).buttonStyle(.caliLink)
        }
    }
}

/// docs/18 §6.3 (mockup `goalList`): goals grouped by state.
struct GoalsView: View {
    @Environment(AppStore.self) private var store
    let lineageId: UUID
    @State private var editing: GoalDraft?

    var body: some View {
        if let plan = store.plan(lineageId) {
            let goals = store.goals(of: lineageId)
            let editable = store.isEditable(plan)
            let waiting = goals.filter { $0.status == .reached }
            let live = goals.filter { $0.status == .active }
            let missed = goals.filter { $0.status == .missed }
            let done = goals.filter { $0.status == .achieved }
            let archived = goals.filter { $0.status == .archived }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text("Ghim tối đa \(GoalRules.pinnedLimit) mục tiêu để thấy ở tổng quan. Mục tiêu chỉ được tính là đạt khi bạn xác nhận.")
                        .font(.footnote)
                        .foregroundStyle(Color.caliSecondary)
                    if live.count + waiting.count >= GoalRules.focusHintThreshold {
                        Label("Đang theo đuổi khá nhiều mục tiêu. Tập trung vào ít mục tiêu hơn thường dễ tiến bộ hơn.", systemImage: "lightbulb")
                            .font(.footnote)
                            .foregroundStyle(Color.caliText)
                            .caliCard(padding: Spacing.m)
                    }
                    if goals.isEmpty {
                        ContentUnavailableView("Chưa có mục tiêu", systemImage: "scope",
                                               description: Text("Thêm một mục tiêu nhỏ cho một bài trong giáo án."))
                    }
                    section("Chờ xác nhận", waiting, plan: plan, editable: editable)
                    section("Đang theo đuổi", live, plan: plan, editable: editable)
                    section("Chưa đạt", missed, plan: plan, editable: editable)
                    section("Đã đạt", done, plan: plan, editable: false)
                    section("Đã lưu trữ", archived, plan: plan, editable: false)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .caliScreen()
            .navigationTitle("Mục tiêu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if editable {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Thêm mục tiêu", systemImage: "plus") { editing = GoalDraft(plan: plan) }
                    }
                }
            }
            .sheet(item: $editing) { GoalEditorView(draft: $0, plan: plan) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ goals: [PlanGoal], plan: WorkoutPlan, editable: Bool) -> some View {
        if !goals.isEmpty {
            SectionHeader(title: title, trailing: "\(goals.count)")
            ForEach(goals) { goal in
                GoalCard(goal: goal, plan: plan, onEdit: editable ? { editing = GoalDraft(goal: goal, kind: store.indicator(goal.indicatorId)?.kind) } : nil)
            }
        }
    }
}

/// Editor state; `existing` locks the exercise and indicator (ADR-047).
struct GoalDraft: Identifiable {
    var id: UUID
    var existing: PlanGoal?
    var kind: IndicatorKind = .performance
    var exerciseId: UUID?
    var indicatorId: String?
    var target: Decimal = 10
    var scopePhaseId: UUID?
    var unlockAfterGoalId: UUID?
    var title = ""
    var note = ""
    var pinned = false

    init(plan: WorkoutPlan) {
        id = UUID()
        pinned = false
    }

    init(goal: PlanGoal, kind: IndicatorKind?) {
        id = goal.id
        existing = goal
        self.kind = kind ?? .performance
        exerciseId = goal.exerciseId
        indicatorId = goal.indicatorId
        if case .value(let v) = goal.target { target = v }
        scopePhaseId = goal.scopePhaseId
        unlockAfterGoalId = goal.unlockAfterGoalId
        title = goal.title
        note = goal.note ?? ""
        pinned = goal.pinned
    }
}

/// docs/18 §6.4 (mockup `goalEditor`): kind → poster grid → indicator → target → scope → unlock → title.
struct GoalEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: GoalDraft
    let plan: WorkoutPlan
    @State private var commandId = UUID()

    private static let kinds: [(IndicatorKind, String, String)] = [
        (.performance, "Thành tích", "trophy"), (.milestone, "Cột mốc kỹ năng", "flag"), (.volume, "Khối lượng / tuần", "chart.bar"),
    ]

    var body: some View {
        let locked = draft.existing != nil
        let indicators = store.indicators.filter { item in item.kind == draft.kind && (exercise.map { item.applies(to: $0.type) } ?? true) }
        let indicator = draft.indicatorId.flatMap(store.indicator)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    if locked {
                        Label("Không đổi được bài và chỉ số của mục tiêu đã có. Muốn đổi, hãy lưu trữ và tạo mục tiêu mới.", systemImage: "lock")
                            .font(.footnote)
                            .foregroundStyle(Color.caliSecondary)
                    } else {
                        group("Loại mục tiêu") {
                            HStack {
                                ForEach(Self.kinds, id: \.0) { kind, label, icon in
                                    FilterChip(title: label, systemImage: icon, isSelected: draft.kind == kind) {
                                        draft.kind = kind
                                        draft.indicatorId = nil
                                        if kind != .milestone { draft.unlockAfterGoalId = nil }
                                    }
                                }
                            }
                        }
                        group("Bài tập") { posterGrid }
                    }
                    if let exercise, locked {
                        HStack(spacing: Spacing.m) {
                            PosterThumb(exercise: exercise, size: 56)
                            Text(exercise.name).font(.headline).foregroundStyle(Color.caliText)
                        }
                    }
                    if exercise != nil {
                        group("Chỉ số") {
                            if locked, let indicator {
                                Text(indicator.label).foregroundStyle(Color.caliText)
                            } else if indicators.isEmpty {
                                Text("Chưa có chỉ số loại này cho bài đã chọn.").font(.footnote).foregroundStyle(Color.caliSecondary)
                            } else {
                                ForEach(indicators) { item in
                                    FilterChip(title: "\(item.label) (\(item.unit))", isSelected: draft.indicatorId == item.id) {
                                        draft.indicatorId = item.id
                                    }
                                }
                            }
                        }
                    }
                    if let indicator {
                        group("Mức đích") {
                            Stepper(value: $draft.target, in: 0...9999, step: indicator.step) {
                                Text(GoalFmt.value(draft.target, unit: indicator.unit))
                                    .font(.title3.bold().monospacedDigit())
                                    .foregroundStyle(Color.caliText)
                            }
                            if let baseline = baseline(indicator) {
                                Text("Mốc ban đầu: \(GoalFmt.value(baseline, unit: indicator.unit)) (tuần đầu có dữ liệu)")
                                    .font(.footnote).foregroundStyle(Color.caliSecondary)
                            }
                        }
                        group("Phạm vi") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    FilterChip(title: "Cả giáo án", isSelected: draft.scopePhaseId == nil) { draft.scopePhaseId = nil }
                                    ForEach(store.phaseSpans(of: plan), id: \.phase.id) { span in
                                        FilterChip(title: "\(span.phase.name) · \(span.label)", isSelected: draft.scopePhaseId == span.phase.id) {
                                            draft.scopePhaseId = span.phase.id
                                        }
                                    }
                                }
                            }
                        }
                        if draft.kind == .milestone {
                            let candidates = store.goals(of: plan.lineageId).filter { goal in
                                goal.id != draft.id && store.indicator(goal.indicatorId)?.kind == .milestone && goal.status != .archived
                            }
                            if !candidates.isEmpty {
                                group("Mở sau khi đạt") {
                                    FilterChip(title: "Không", isSelected: draft.unlockAfterGoalId == nil) { draft.unlockAfterGoalId = nil }
                                    ForEach(candidates) { goal in
                                        FilterChip(title: goal.title, isSelected: draft.unlockAfterGoalId == goal.id) { draft.unlockAfterGoalId = goal.id }
                                    }
                                }
                            }
                        }
                        group("Tên") {
                            TextField(GoalFmt.autoTitle(indicator: indicator, exercise: exercise, target: draft.target), text: $draft.title)
                                .textFieldStyle(.roundedBorder)
                            TextField("Ghi chú (không bắt buộc)", text: $draft.note, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    if let existing = draft.existing {
                        Button("Lưu trữ mục tiêu", systemImage: "archivebox") {
                            if store.archiveGoal(existing.id) { dismiss() }
                        }
                        .buttonStyle(.caliQuiet)
                    }
                }
                .padding(Spacing.l)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Lưu", action: save)
                    .buttonStyle(.caliPrimary)
                    .disabled(indicator == nil)
                    .padding(Spacing.l)
                    .background(Color.caliCanvas)
            }
            .caliScreen()
            .navigationTitle(locked ? "Sửa mục tiêu" : "Mục tiêu mới")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } } }
        }
    }

    private var exercise: Exercise? { draft.exerciseId.flatMap(store.exercise) }

    /// Plan exercises first (visual-first: chosen by poster).
    private var posterGrid: some View {
        var seen: Set<UUID> = []
        let planIds = plan.workouts.flatMap(\.exercises).map(\.exerciseId).filter { seen.insert($0).inserted }
        let choices = planIds.compactMap(store.exercise).filter { ex in
            store.indicators.contains { $0.kind == draft.kind && $0.applies(to: ex.type) }
        }
        return Group {
            if choices.isEmpty {
                Text("Giáo án chưa có bài nào đo được bằng loại mục tiêu này.").font(.footnote).foregroundStyle(Color.caliSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.s)], spacing: Spacing.s) {
                    ForEach(choices) { ex in
                        Button {
                            draft.exerciseId = ex.id
                            draft.indicatorId = store.indicators.first { $0.kind == draft.kind && $0.applies(to: ex.type) }?.id
                        } label: {
                            PosterView(exercise: ex, height: 110)
                                .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                    .strokeBorder(draft.exerciseId == ex.id ? Color.caliAccent : .clear, lineWidth: 3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ex.name)
                        .accessibilityAddTraits(draft.exerciseId == ex.id ? .isSelected : [])
                    }
                }
            }
        }
    }

    private func baseline(_ indicator: IndicatorDefinition) -> Decimal? {
        if let existing = draft.existing { return existing.baseline }
        return draft.exerciseId.flatMap { store.suggestedBaseline(indicator: indicator, exerciseId: $0, in: plan) }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.caliSecondary)
            content()
        }
    }

    private func save() {
        guard let indicator = draft.indicatorId.flatMap(store.indicator) else { return }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        var goal = draft.existing ?? PlanGoal(id: draft.id, planLineageId: plan.lineageId, title: "", indicatorId: indicator.id,
                                              exerciseId: draft.exerciseId, baseline: baseline(indicator), target: .value(draft.target))
        goal.title = title.isEmpty ? GoalFmt.autoTitle(indicator: indicator, exercise: exercise, target: draft.target) : title
        goal.target = .value(draft.target)
        goal.scopePhaseId = draft.scopePhaseId
        goal.unlockAfterGoalId = draft.unlockAfterGoalId
        goal.note = note.isEmpty ? nil : note
        if store.saveGoal(goal, commandId: commandId) { dismiss() }
    }
}

/// Mockup `overview`: "Tuần x/y" with the current phase, pinned goals, the "chạm mức đích" banner and
/// links to Lộ trình / Mục tiêu / Tiến bộ.
struct PlanOverviewCard: View {
    @Environment(AppStore.self) private var store
    let plan: WorkoutPlan
    let now: Date

    var body: some View {
        let goals = store.goals(of: plan.lineageId)
        let pinned = goals.filter { $0.pinned && $0.isLive }
        let waiting = goals.filter { $0.status == .reached }.count
        let week = store.currentWeek(of: plan, now: now)
        let total = PhaseTimeline.totalWeeks(plan.phases)
        let current = store.phaseSpans(of: plan, now: now).first { $0.state == .current }
        VStack(alignment: .leading, spacing: Spacing.m) {
            if waiting > 0 {
                NavigationLink { GoalsView(lineageId: plan.lineageId) } label: {
                    Label("\(waiting) mục tiêu đã chạm mức đích. Chạm để xác nhận.", systemImage: "hand.raised")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.caliText)
                        .frame(maxWidth: .infinity, minHeight: minTapTarget, alignment: .leading)
                        .caliCard(padding: Spacing.m)
                }
                .buttonStyle(.plain)
            }
            if plan.kind == .weekly {
                NavigationLink { RoadmapView(lineageId: plan.lineageId) } label: {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "map").foregroundStyle(Color.caliAccentInk).font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(weekTitle(week: week, total: total)).font(.headline).foregroundStyle(Color.caliText)
                            Text(current.map { "\($0.phase.name) · \($0.label)" } ?? (plan.phases.isEmpty ? "Chưa chia giai đoạn" : "Lộ trình"))
                                .font(.caption).foregroundStyle(Color.caliSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.caliSecondary)
                    }
                    .frame(minHeight: minTapTarget)
                    .caliCard(padding: Spacing.m)
                }
                .buttonStyle(.plain)
            }
            if !pinned.isEmpty {
                SectionHeader(title: "Mục tiêu đã ghim", trailing: "\(pinned.count)/\(GoalRules.pinnedLimit)")
                ForEach(pinned) { goal in
                    NavigationLink { GoalsView(lineageId: plan.lineageId) } label: { GoalCard(goal: goal, plan: plan, compact: true) }
                        .buttonStyle(.plain)
                }
            }
            HStack(spacing: Spacing.s) {
                NavigationLink { GoalsView(lineageId: plan.lineageId) } label: {
                    Label("Mục tiêu", systemImage: "scope").frame(maxWidth: .infinity)
                }
                NavigationLink { PlanProgressView(lineageId: plan.lineageId) } label: {
                    Label("Tiến bộ", systemImage: "chart.line.uptrend.xyaxis").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.caliSecondary)
        }
    }

    private func weekTitle(week: CurrentWeek, total: Int) -> String {
        switch week.state {
        case .notStarted: return total > 0 ? "\(total) tuần" : "Chưa bắt đầu"
        case .finished: return total > 0 ? "Đã xong \(total) tuần" : "Đã xong"
        case .inProgress: return total > 0 ? "Tuần \(week.week)/\(total)" : "Tuần \(week.week)"
        }
    }
}

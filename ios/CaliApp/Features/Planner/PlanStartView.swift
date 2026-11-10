import CaliDomain
import SwiftUI

/// MP-04 "Bắt đầu theo" / "Tiếp tục" and MP-05 (limit reached). The start date is today or later (D9);
/// days before it are never counted as missed.
// TODO(IOS-013): late start ("bắt đầu từ tuần x"); program length now comes from phases (IOS-015).
struct PlanStartView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let lineageId: UUID

    private enum Choice: Hashable { case today, nextMonday, custom }
    @State private var choice: Choice = .today
    @State private var customDay = Date()
    @State private var resolution: LimitResolution?
    @State private var error: String?
    @State private var commandId = UUID()

    var body: some View {
        if let plan = store.plan(lineageId) {
            content(plan)
        } else {
            ContentUnavailableView("Không tìm thấy giáo án", systemImage: "calendar.badge.exclamationmark")
                .caliScreen()
        }
    }

    private func content(_ plan: WorkoutPlan) -> some View {
        let from = startDay
        let conflicts = store.limitConflicts(starting: lineageId, from: from)
        let overlaps = store.overlappingPlans(with: lineageId)
        let resuming = store.status(of: plan) == .paused
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text(plan.title)
                    .font(.title2.bold())
                    .foregroundStyle(Color.caliText)
                dateSection
                if !conflicts.isEmpty { limitSection(conflicts) }
                if !overlaps.isEmpty { overlapSection(overlaps) }
                previewSection(plan, from: from)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Color.caliError)
                }
                Button(resuming ? "Tiếp tục từ \(Fmt.shortDate(from))" : "Bắt đầu từ \(Fmt.shortDate(from))", systemImage: "play.fill") {
                    start(from: from)
                }
                .buttonStyle(.caliPrimary)
                .disabled(!conflicts.isEmpty && resolution == nil)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle(resuming ? "Tiếp tục giáo án" : "Bắt đầu theo")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: from) { resolution = nil }
    }

    private var startDay: LocalDate {
        let today = store.today()
        switch choice {
        case .today: return today
        case .nextMonday: return today.adding(days: 8 - today.isoWeekday)
        case .custom: return max(today, LocalDate.today(at: customDay, in: store.calendar.timeZone))
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Ngày bắt đầu")
            HStack(spacing: Spacing.s) {
                FilterChip(title: "Hôm nay", isSelected: choice == .today) { choice = .today }
                FilterChip(title: "Thứ Hai tới", isSelected: choice == .nextMonday) { choice = .nextMonday }
                FilterChip(title: "Chọn ngày", isSelected: choice == .custom) { choice = .custom }
            }
            if choice == .custom {
                DatePicker("Ngày bắt đầu", selection: $customDay, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Fmt.vi)
                    .caliCard(padding: Spacing.s)
            }
            Text("Trước ngày bắt đầu không có buổi nào bị tính là bỏ lỡ.")
                .font(.footnote)
                .foregroundStyle(Color.caliSecondary)
        }
    }

    /// MP-05: the plan would be the fourth followed one; free a slot in the same step.
    private func limitSection(_ conflicts: [WorkoutPlan]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Đã đủ \(PlanLifecycle.defaultActivePlanLimit) giáo án đang theo", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(Color.caliText)
            Text("Chọn một giáo án để tạm dừng hoặc kết thúc khi bắt đầu giáo án này. Lịch sử của giáo án đó được giữ nguyên.")
                .font(.footnote)
                .foregroundStyle(Color.caliSecondary)
            ForEach(conflicts, id: \.lineageId) { other in
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(other.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.caliText)
                    HStack(spacing: Spacing.s) {
                        option(other, .pause, "Tạm dừng")
                        option(other, .end, "Kết thúc")
                    }
                }
                CardDivider()
            }
        }
        .caliCard()
    }

    private func option(_ plan: WorkoutPlan, _ action: LimitResolution.Action, _ title: String) -> some View {
        let value = LimitResolution(lineageId: plan.lineageId, action: action)
        return FilterChip(title: title, isSelected: resolution == value) {
            resolution = resolution == value ? nil : value
        }
        .accessibilityLabel("\(title) \(plan.title)")
    }

    /// D5: same-day workouts are allowed; this only informs.
    private func overlapSection(_ overlaps: [(plan: WorkoutPlan, weekdays: [Int])]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Trùng ngày tập", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.caliText)
            ForEach(overlaps, id: \.plan.lineageId) { overlap in
                Text("\(overlap.plan.title): \(overlap.weekdays.map(Fmt.weekdayShort).joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            }
            Text("Những ngày này sẽ có nhiều buổi. Bạn vẫn có thể bắt đầu.")
                .font(.footnote)
                .foregroundStyle(Color.caliSecondary)
        }
        .caliCard(padding: Spacing.m)
    }

    private func previewSection(_ plan: WorkoutPlan, from: LocalDate) -> some View {
        let activation = PlanActivation(id: UUID(), fromDate: from, timezone: store.calendar.timeZone.identifier)
        let days = PlanSchedule.occurrences(program: plan.program, activations: [activation], slots: plan.slots,
                                            from: from, through: from.adding(days: 6))
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Tuần đầu", trailing: "\(days.count) buổi")
            if days.isEmpty {
                Text("Không có buổi nào trong 7 ngày đầu.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            }
            ForEach(days, id: \.date) { occurrence in
                if let workout = plan.workouts.first(where: { $0.id == occurrence.plannedWorkoutId }) {
                    HStack(spacing: Spacing.m) {
                        PosterStack(exercises: store.exercises(of: workout), size: 36, limit: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.day(occurrence.date)).font(.caption).foregroundStyle(Color.caliSecondary)
                            Text(workout.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.caliText)
                        }
                        Spacer(minLength: 0)
                    }
                    .caliCard(padding: Spacing.m)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func start(from: LocalDate) {
        if store.startPlan(lineageId, from: from, resolving: resolution, commandId: commandId) {
            dismiss()
        } else {
            error = store.alertMessage
            store.alertMessage = nil
            commandId = UUID()
        }
    }
}

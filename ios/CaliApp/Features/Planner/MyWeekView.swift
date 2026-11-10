import CaliDomain
import SwiftUI

/// MP-06 "Tuần của tôi": every followed plan merged by day, last week to next week. Past days show the
/// I4 outcome per plan (done / missed); a missed workout is never marked done by the app.
struct MyWeekView: View {
    @Environment(AppStore.self) private var store
    @State private var offset = 0

    var body: some View {
        let now = Date()
        let today = store.today(now)
        let monday = store.monday(of: today).adding(days: offset * 7)
        let items = store.scheduledItems(from: monday, through: monday.adding(days: 6), now: now)
        let showsPlan = Set(items.map(\.plan.lineageId)).count > 1
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Picker("Tuần", selection: $offset) {
                    Text("Tuần trước").tag(-1)
                    Text("Tuần này").tag(0)
                    Text("Tuần sau").tag(1)
                }
                .pickerStyle(.segmented)
                Text("\(Fmt.shortDate(monday)) – \(Fmt.shortDate(monday.adding(days: 6))) · \(items.filter(\.isDone).count)/\(items.count) buổi")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
                ForEach(0..<7, id: \.self) { index in
                    let day = monday.adding(days: index)
                    DayCard(day: day, isToday: day == today, items: items.filter { $0.date == day }, showsPlan: showsPlan)
                }
                Text("Những ngày có nhiều buổi được giữ nguyên; bạn tự chọn tập buổi nào.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Tuần của tôi")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DayCard: View {
    @Environment(AppStore.self) private var store
    let day: LocalDate
    let isToday: Bool
    let items: [ScheduledItem]
    let showsPlan: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(isToday ? "Hôm nay · \(Fmt.day(day))" : Fmt.day(day))
                    .font(.subheadline.weight(isToday ? .bold : .semibold))
                    .foregroundStyle(isToday ? Color.caliAccentInk : Color.caliText)
                Spacer()
                if items.count > 1 { TagChip(text: "\(items.count) buổi", tint: .caliAccentInk) }
            }
            if items.isEmpty {
                Text("Nghỉ").font(.footnote).foregroundStyle(Color.caliSecondary)
            }
            ForEach(items) { item in
                NavigationLink {
                    WorkoutDetailView(workoutId: item.workout.id)
                } label: {
                    HStack(spacing: Spacing.m) {
                        PosterStack(exercises: store.exercises(of: item.workout), size: 36, limit: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.workout.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.caliText)
                                .lineLimit(1)
                            if showsPlan {
                                Label(item.plan.title, systemImage: "calendar")
                                    .font(.caption)
                                    .foregroundStyle(Color.caliSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        outcome(item)
                    }
                    .frame(minHeight: minTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
        .caliCard(padding: Spacing.m)
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.caliAccent, lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private func outcome(_ item: ScheduledItem) -> some View {
        switch item.outcome {
        case .completed: TagChip(text: "Đã tập", systemImage: "checkmark", tint: .caliAccent, filled: true)
        case .missed: TagChip(text: "Bỏ lỡ", systemImage: "xmark", tint: .caliWarning)
        case .pending: EmptyView()
        }
    }
}

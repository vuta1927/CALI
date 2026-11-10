import CaliDomain
import SwiftUI

/// "Hôm nay" tab (UX-02, MP-09): resume banner, event countdowns, today's workouts from every followed
/// plan, this week, AI.
///
/// Mockup blocks that need features not built yet are left out rather than filled with sample
/// numbers: running card (IOS-016).
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var tab: AppTab

    var body: some View {
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text(Fmt.fullDate(now))
                    .font(.subheadline)
                    .foregroundStyle(Color.caliSecondary)
                if let player = store.player, player.state.isActive {
                    ResumeCard(model: player) { store.resumeWorkout() }
                }
                todaySection(now: now)
                weekSection(now: now)
                if store.pendingRecommendationCount > 0 {
                    recommendationSection
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Hôm nay")
        .toolbarTitleDisplayMode(.large)
        .toolbar {
            if store.showsSampleData {
                ToolbarItem(placement: .primaryAction) { MockBadge() }
            }
        }
    }

    @ViewBuilder
    private func todaySection(now: Date) -> some View {
        let items = store.scheduledItems(on: store.today(now), now: now)
        let followed = store.followedPlans(now: now)
        let showsPlan = followed.count > 1
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: items.count > 1 ? "Hôm nay · \(items.count) buổi" : "Buổi tập hôm nay")
            ForEach(countdowns(followed, now: now), id: \.lineageId) { plan in
                EventCountdownRow(plan: plan, days: store.daysUntilEvent(plan, now: now) ?? 0)
            }
            if items.isEmpty {
                if followed.isEmpty { noPlanCard } else { restCard(now: now) }
            } else {
                ForEach(items) { item in
                    WorkoutHeroCard(workout: item.workout, date: now, done: item.isDone, planTitle: showsPlan ? item.plan.title : nil,
                                    phaseCaption: store.phaseCaption(item.plan, now: now)) {
                        store.startWorkout(item.workout)
                    }
                }
            }
            if !followed.isEmpty {
                NavigationLink {
                    MyWeekView()
                } label: {
                    Label("Tuần của tôi", systemImage: "calendar.day.timeline.left")
                }
                .buttonStyle(.caliLink)
            }
        }
    }

    /// Event plans still ahead, nearest first.
    private func countdowns(_ plans: [WorkoutPlan], now: Date) -> [WorkoutPlan] {
        plans.filter { (store.daysUntilEvent($0, now: now) ?? -1) >= 0 }
            .sorted { (store.daysUntilEvent($0, now: now) ?? 0) < (store.daysUntilEvent($1, now: now) ?? 0) }
    }

    /// MP-09 empty state: no active or scheduled plan.
    private var noPlanCard: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Chưa theo giáo án nào", systemImage: "calendar.badge.plus")
                .font(.title3.bold())
                .foregroundStyle(Color.caliText)
            Text("Bắt đầu theo một giáo án để các buổi tập hiện ở đây. Bạn vẫn có thể thử nhanh bên dưới.")
                .font(.subheadline)
                .foregroundStyle(Color.caliSecondary)
            Button("Mở Giáo án", systemImage: "calendar") { tab = .plan }
                .buttonStyle(.caliSecondary)
        }
        .caliCard()
    }

    private func restCard(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Hôm nay là ngày nghỉ", systemImage: "moon.zzz")
                .font(.title3.bold())
                .foregroundStyle(Color.caliText)
            Text("Nghỉ ngơi giúp cơ phục hồi. Bạn vẫn có thể tập buổi khác hoặc thử nhanh bên dưới.")
                .font(.subheadline)
                .foregroundStyle(Color.caliSecondary)
            if let next = store.nextScheduledDay(now: now), let item = next.items.first {
                CardDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Buổi tiếp theo · \(Fmt.day(next.day))")
                            .font(.caption)
                            .foregroundStyle(Color.caliSecondary)
                        Text(next.items.count > 1 ? "\(item.workout.title) +\(next.items.count - 1)" : item.workout.title)
                            .font(.headline)
                            .foregroundStyle(Color.caliText)
                    }
                    Spacer()
                    Button("Tập luôn") { store.startWorkout(item.workout) }
                        .buttonStyle(.caliSecondary)
                        .fixedSize()
                }
            }
        }
        .caliCard()
    }

    private func weekSection(now: Date) -> some View {
        let done = store.sessionsThisWeek(now: now)
        let today = store.today(now)
        let monday = store.monday(of: today)
        let items = store.scheduledItems(from: monday, through: monday.adding(days: 6), now: now)
        let doneWeekdays = Set(done.filter { $0.status == .completed }.map { Fmt.isoWeekday($0.startedAt) })
        let doneCount = done.filter { $0.status == .completed }.count
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Tuần này", trailing: "\(doneCount)/\(items.count) buổi")
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(spacing: 0) {
                    ForEach(1...7, id: \.self) { day in
                        WeekDayDot(
                            day: day, isToday: day == today.isoWeekday, completed: doneWeekdays.contains(day),
                            scheduled: items.contains { $0.date.isoWeekday == day }
                        )
                    }
                }
                HStack(spacing: Spacing.m) {
                    StatTile(value: "\(doneCount)/\(items.count)", label: "Buổi xong", systemImage: "checkmark.circle", tint: .caliAccent)
                    StatTile(value: "\(done.reduce(0) { $0 + $1.completedSetCount })", label: "Set xong", systemImage: "square.stack.3d.up")
                    StatTile(value: "\(done.reduce(0) { $0 + $1.durationMinutes })", label: "Phút tập", systemImage: "clock")
                }
            }
            .caliCard()
        }
    }

    private var recommendationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Đề xuất AI")
            NavigationLink {
                AIReviewView()
            } label: {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.caliAccentInk)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(store.pendingRecommendationCount) đề xuất chờ bạn duyệt")
                            .font(.headline)
                            .foregroundStyle(Color.caliText)
                        Text("Không thay đổi giáo án khi bạn chưa chấp nhận.")
                            .font(.footnote)
                            .foregroundStyle(Color.caliSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.caliSecondary)
                }
                .caliCard(padding: Spacing.m)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Pieces

/// MP-09: "Còn 125 ngày tới Giải 10 km" for an event plan.
struct EventCountdownRow: View {
    let plan: WorkoutPlan
    let days: Int

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "flag.fill")
                .foregroundStyle(Color.caliAccentInk)
            VStack(alignment: .leading, spacing: 2) {
                Text(days == 0 ? "Hôm nay: \(plan.eventName ?? plan.title)" : "Còn \(days) ngày tới \(plan.eventName ?? plan.title)")
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                if let date = plan.eventDate {
                    Text("\(plan.title) · \(Fmt.day(date))")
                        .font(.footnote)
                        .foregroundStyle(Color.caliSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .caliCard(padding: Spacing.m)
        .accessibilityElement(children: .combine)
    }
}

/// One day of the week strip: orange check when trained, ring around today.
struct WeekDayDot: View {
    let day: Int
    let isToday: Bool
    let completed: Bool
    let scheduled: Bool
    var dateLabel: String?
    var abandoned = false
    /// Scheduled in the past and not done: a dashed outline with a dash, never red (UX-10).
    var missed = false

    var body: some View {
        VStack(spacing: Spacing.s) {
            Text(Fmt.weekdayShort(day))
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.caliText : Color.caliSecondary)
            ZStack {
                Circle()
                    .fill(completed ? Color.caliAccent : ((scheduled || abandoned) ? Color.caliSurfaceRaised : Color.clear))
                Circle()
                    .strokeBorder(isToday ? Color.caliAccent : (missed ? Color.caliSecondary : Color.caliSurfaceRaised),
                                  style: StrokeStyle(lineWidth: isToday ? 2 : 1, dash: missed ? [3, 3] : []))
                if completed {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.caliOnAccent)
                } else if missed {
                    Image(systemName: "minus")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.caliSecondary)
                } else if abandoned {
                    Image(systemName: "flag.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.caliWarning)
                }
            }
            .frame(width: 32, height: 32)
            if let dateLabel {
                Text(dateLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.weekdayLong(day)): \(completed ? "đã tập" : abandoned ? "dừng sớm" : missed ? "bỏ lỡ" : (scheduled ? "có lịch" : "nghỉ"))")
    }
}

private struct ResumeCard: View {
    let model: WorkoutPlayerModel
    let onResume: () -> Void

    var body: some View {
        Button(action: onResume) {
            HStack(spacing: Spacing.m) {
                PosterThumb(exercise: model.currentExercise, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đang tập dở")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.caliSecondary)
                    Text(model.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    Text(position)
                        .font(.footnote)
                        .foregroundStyle(Color.caliSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundStyle(Color.caliAccentInk)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.coamiOrange.opacity(0.22), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.caliAccent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Mở lại buổi tập đang dở")
    }

    /// "Bài 2/5 · Pull-up · Set 2/3"
    private var position: String {
        let state = model.state
        guard let execution = state.currentExecution else {
            return "\(state.resolvedSets.count)/\(state.totalPlannedSets) set"
        }
        let name = model.currentExercise?.name ?? "Bài tập"
        return "Bài \(state.currentExecutionIndex + 1)/\(state.executions.count) · \(name) · Set \(state.currentSetIndex)/\(execution.setCount)"
    }
}

/// Today's workout (mockup hero card): overlapping posters, discipline, title, meta, start, details.
struct WorkoutHeroCard: View {
    @Environment(AppStore.self) private var store
    let workout: PlannedWorkout
    let date: Date
    var done = false
    /// Shown when several plans are followed (MP-09 plan chip).
    var planTitle: String?
    /// "Tuần x/y · giai đoạn" when the plan has a roadmap (IOS-015).
    var phaseCaption: String?
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top) {
                PosterStack(exercises: store.exercises(of: workout), size: 64)
                Spacer()
                if done {
                    TagChip(text: "Đã tập", systemImage: "checkmark", tint: .caliAccent, filled: true)
                }
            }
            HStack(spacing: Spacing.s) {
                DisciplineChip(discipline: store.discipline(of: workout))
                if let planTitle { TagChip(text: planTitle, systemImage: "calendar") }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text([Fmt.weekdayLong(Fmt.isoWeekday(date)), phaseCaption].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
                Text(workout.title)
                    .font(.title3.bold())
                    .foregroundStyle(Color.caliText)
                Text(Fmt.workoutMeta(workout))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
            }
            Button(done ? "Tập lại" : "Bắt đầu tập", systemImage: "play.fill", action: onStart)
                .buttonStyle(.caliPrimary)
            NavigationLink("Xem chi tiết buổi") {
                WorkoutDetailView(workoutId: workout.id)
            }
            .buttonStyle(.caliLink)
        }
        .caliCard()
    }
}

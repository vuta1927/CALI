import CaliDomain
import SwiftUI

/// "Hôm nay" tab (UX-02, mockup `today`): resume banner, today's workout, this week, quick test, AI.
///
/// Mockup blocks that need features not built yet are left out rather than filled with sample
/// numbers: race countdown and running card (IOS-016), "Tuần của tôi" across plans (IOS-015),
/// plan week/phase caption (IOS-013).
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
                quickTestSection
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
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Buổi tập hôm nay")
            if store.plan.deletedAt == nil, let workout = store.workout(on: now) {
                let doneToday = store.history.contains {
                    $0.plannedWorkoutId == workout.id && $0.status == .completed && Calendar.current.isDateInToday($0.startedAt)
                }
                WorkoutHeroCard(workout: workout, date: now, done: doneToday) { store.startWorkout(workout) }
            } else {
                restCard(now: now)
            }
        }
    }

    private func restCard(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Hôm nay là ngày nghỉ", systemImage: "moon.zzz")
                .font(.title3.bold())
                .foregroundStyle(Color.caliText)
            Text("Nghỉ ngơi giúp cơ phục hồi. Bạn vẫn có thể tập buổi khác hoặc thử nhanh bên dưới.")
                .font(.subheadline)
                .foregroundStyle(Color.caliSecondary)
            if store.plan.deletedAt == nil, let next = store.nextWorkout(after: now) {
                CardDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Buổi tiếp theo · \(Fmt.weekdayLong(next.workout.weekday))")
                            .font(.caption)
                            .foregroundStyle(Color.caliSecondary)
                        Text(next.workout.title)
                            .font(.headline)
                            .foregroundStyle(Color.caliText)
                    }
                    Spacer()
                    Button("Tập luôn") { store.startWorkout(next.workout) }
                        .buttonStyle(.caliSecondary)
                        .fixedSize()
                }
            }
        }
        .caliCard()
    }

    private func weekSection(now: Date) -> some View {
        let done = store.sessionsThisWeek(now: now)
        let scheduled = store.plan.deletedAt == nil ? store.plan.workouts.filter { (1...7).contains($0.weekday) } : []
        let doneWeekdays = Set(done.map { Fmt.isoWeekday($0.startedAt) })
        let today = Fmt.isoWeekday(now)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Tuần này", trailing: "\(done.count)/\(scheduled.count) buổi")
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(spacing: 0) {
                    ForEach(1...7, id: \.self) { day in
                        WeekDayDot(
                            day: day, isToday: day == today, completed: doneWeekdays.contains(day),
                            scheduled: scheduled.contains { $0.weekday == day }
                        )
                    }
                }
                HStack(spacing: Spacing.m) {
                    StatTile(value: "\(done.count)/\(scheduled.count)", label: "Buổi xong", systemImage: "checkmark.circle", tint: .caliAccent)
                    StatTile(value: "\(done.reduce(0) { $0 + $1.completedSetCount })", label: "Set xong", systemImage: "square.stack.3d.up")
                    StatTile(value: "\(done.reduce(0) { $0 + $1.durationMinutes })", label: "Phút tập", systemImage: "clock")
                }
            }
            .caliCard()
        }
    }

    private var quickTestSection: some View {
        let quick = MockData.quickTest
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Thử nhanh")
            VStack(alignment: .leading, spacing: Spacing.m) {
                PosterStack(exercises: store.exercises(of: quick), size: 48)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quick.title)
                            .font(.headline)
                            .foregroundStyle(Color.caliText)
                        Text(quick.focus)
                            .font(.footnote)
                            .foregroundStyle(Color.caliSecondary)
                    }
                    Spacer()
                    Button("Thử", systemImage: "play.fill") { store.startWorkout(quick) }
                        .buttonStyle(.caliSecondary)
                        .fixedSize()
                        .accessibilityHint("Bắt đầu buổi thử với đủ 5 loại bài tập")
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

/// One day of the week strip: orange check when trained, ring around today.
struct WeekDayDot: View {
    let day: Int
    let isToday: Bool
    let completed: Bool
    let scheduled: Bool
    var dateLabel: String?
    var abandoned = false

    var body: some View {
        VStack(spacing: Spacing.s) {
            Text(Fmt.weekdayShort(day))
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.caliText : Color.caliSecondary)
            ZStack {
                Circle()
                    .fill(completed ? Color.caliAccent : ((scheduled || abandoned) ? Color.caliSurfaceRaised : Color.clear))
                Circle()
                    .strokeBorder(isToday ? Color.caliAccent : Color.caliSurfaceRaised, lineWidth: isToday ? 2 : 1)
                if completed {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.caliOnAccent)
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
        .accessibilityLabel("\(Fmt.weekdayLong(day)): \(completed ? "đã tập" : abandoned ? "dừng sớm" : (scheduled ? "có lịch" : "nghỉ"))")
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
            DisciplineChip(discipline: store.discipline(of: workout))
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.weekdayLong(Fmt.isoWeekday(date)))
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

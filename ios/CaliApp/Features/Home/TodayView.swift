import CaliDomain
import SwiftUI

/// "Hôm nay" tab (UX-02): resume banner, today's workout, weekly progress, quick test.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var tab: AppTab

    var body: some View {
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                greeting(now: now)
                if let player = store.player, player.state.isActive {
                    ResumeCard(model: player) { store.resumeWorkout() }
                }
                todaySection(now: now)
                weekSection(now: now)
                quickTestSection
                if store.pendingRecommendationCount > 0 {
                    recommendationTeaser
                }
            }
            .padding(Spacing.l)
        }
        .caliScreen()
        .navigationTitle("Hôm nay")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private func greeting(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            BrandHeader(tagline: nil)
            Divider()
                .overlay(Color.caliBorder.opacity(0.7))
            Text(Fmt.fullDate(now).capitalized(with: Fmt.vi))
                .font(.subheadline)
                .foregroundStyle(Color.caliSecondary)
            Text(store.plan.title)
                .font(.headline)
                .foregroundStyle(Color.caliText)
        }
    }

    @ViewBuilder
    private func todaySection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Buổi tập hôm nay")
            if let workout = store.workout(on: now) {
                let doneToday = store.history.contains {
                    $0.plannedWorkoutId == workout.id && $0.status == .completed && Calendar.current.isDateInToday($0.startedAt)
                }
                WorkoutHeroCard(workout: workout, done: doneToday) { store.startWorkout(workout) }
            } else {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    Label("Hôm nay là ngày nghỉ", systemImage: "moon.zzz")
                        .font(.title3.bold())
                        .foregroundStyle(Color.caliText)
                    Text("Nghỉ ngơi giúp cơ phục hồi. Bạn vẫn có thể tập buổi khác hoặc thử nhanh bên dưới.")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                    if let next = store.nextWorkout(after: now) {
                        Divider().overlay(Color.caliSurfaceRaised)
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
        }
    }

    private func weekSection(now: Date) -> some View {
        let done = store.sessionsThisWeek(now: now)
        let planned = store.plan.workouts.count
        let doneWeekdays = Set(done.map { Fmt.isoWeekday($0.startedAt) })
        let today = Fmt.isoWeekday(now)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Tuần này", trailing: "\(done.count)/\(planned) buổi")
            VStack(spacing: Spacing.l) {
                HStack(spacing: 0) {
                    ForEach(1...7, id: \.self) { day in
                        let scheduled = store.plan.workouts.contains { $0.weekday == day }
                        let completed = doneWeekdays.contains(day)
                        VStack(spacing: Spacing.s) {
                            Text(Fmt.weekdayShort(day))
                                .font(.caption.weight(day == today ? .bold : .regular))
                                .foregroundStyle(day == today ? Color.caliText : Color.caliSecondary)
                            ZStack {
                                Circle()
                                    .fill(completed ? Color.caliAccent : (scheduled ? Color.caliSurfaceRaised : Color.clear))
                                Circle()
                                    .strokeBorder(day == today ? Color.caliAccent : Color.caliSurfaceRaised, lineWidth: day == today ? 2 : 1)
                                if completed {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(Color.caliOnAccent)
                                }
                            }
                            .frame(width: 32, height: 32)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(Fmt.weekdayLong(day)): \(completed ? "đã tập" : (scheduled ? "có lịch" : "nghỉ"))")
                    }
                }
                HStack(spacing: Spacing.m) {
                    StatTile(value: "\(done.count)", label: "Buổi xong", systemImage: "checkmark.circle", tint: .caliAccent)
                    StatTile(value: "\(done.reduce(0) { $0 + $1.completedSetCount })", label: "Set hoàn thành", systemImage: "square.stack.3d.up")
                    StatTile(value: "\(done.reduce(0) { $0 + $1.durationMinutes })", label: "Phút tập", systemImage: "clock")
                }
            }
            .caliCard()
        }
    }

    private var quickTestSection: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Thử nhanh")
            Button {
                store.startWorkout(MockData.quickTest)
            } label: {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "bolt.fill")
                        .font(.title2)
                        .foregroundStyle(Color.caliOnAccent)
                        .frame(width: 52, height: 52)
                        .background(Color.caliWarning, in: RoundedRectangle(cornerRadius: Radius.chip))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(MockData.quickTest.title)
                            .font(.headline)
                            .foregroundStyle(Color.caliText)
                        Text(MockData.quickTest.focus)
                            .font(.subheadline)
                            .foregroundStyle(Color.caliSecondary)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color.caliAccent)
                }
                .caliCard(padding: Spacing.m)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Bắt đầu buổi thử với đủ 5 loại bài tập")
        }
    }

    private var recommendationTeaser: some View {
        NavigationLink {
            AIReviewView()
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.caliAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.pendingRecommendationCount) đề xuất điều chỉnh giáo án")
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    Text("Xem và quyết định chấp nhận hoặc từ chối")
                        .font(.subheadline)
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

// MARK: - Cards

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
                        .foregroundStyle(Color.caliOnAccent)
                    Text(model.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliOnAccent)
                    Text("\(model.state.phase.label) · \(model.state.resolvedSets.count)/\(model.state.totalPlannedSets) set")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliOnAccent)
                }
                Spacer()
                Text("Tiếp tục")
                    .font(.headline)
                    .foregroundStyle(Color.caliOnAccent)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.caliOnAccent)
            }
            .padding(Spacing.m)
            .background(COAMIGradient.brand, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(color: Color.coamiOrange.opacity(0.22), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Mở lại buổi tập đang dở")
    }
}

struct WorkoutHeroCard: View {
    @Environment(AppStore.self) private var store
    let workout: PlannedWorkout
    var done = false
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(workout.title)
                        .font(.title2.bold())
                        .foregroundStyle(Color.caliText)
                    Text(workout.focus)
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                }
                Spacer()
                if done {
                    TagChip(text: "Đã tập", systemImage: "checkmark", tint: .caliAccent, filled: true)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.m) {
                    ForEach(workout.exercises) { item in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            PosterView(exercise: store.exercise(item.exerciseId), height: 96, showsLabel: false)
                                .frame(width: 120)
                            Text(store.exercise(item.exerciseId)?.name ?? "")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.caliText)
                                .lineLimit(1)
                            Text(Fmt.prescription(item))
                                .font(.caption2)
                                .foregroundStyle(Color.caliSecondary)
                                .lineLimit(1)
                        }
                        .frame(width: 120)
                    }
                }
            }
            HStack(spacing: Spacing.l) {
                Label("\(workout.exercises.count) bài", systemImage: "list.bullet")
                Label("\(workout.totalSets) set", systemImage: "square.stack.3d.up")
                Label("~\(workout.estimatedMinutes) phút", systemImage: "clock")
            }
            .font(.subheadline)
            .foregroundStyle(Color.caliSecondary)
            Button(done ? "Tập lại" : "Bắt đầu tập", systemImage: "play.fill", action: onStart)
                .buttonStyle(.caliPrimary)
        }
        .caliCard()
    }
}

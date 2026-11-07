import CaliDomain
import SwiftUI

/// "Giáo án" tab (UX-03): weekly schedule of the active plan, each day editable.
struct PlanView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let today = Fmt.isoWeekday(Date())
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(store.plan.title)
                            .font(.title3.bold())
                            .foregroundStyle(Color.caliText)
                        Text("\(store.plan.workouts.count) buổi / tuần")
                            .font(.subheadline)
                            .foregroundStyle(Color.caliSecondary)
                    }
                    Spacer()
                    MockBadge()
                }
                ForEach(1...7, id: \.self) { day in
                    if let workout = store.plan.workouts.first(where: { $0.weekday == day }) {
                        NavigationLink {
                            WorkoutDetailView(workoutId: workout.id)
                        } label: {
                            PlanDayRow(day: day, isToday: day == today, workout: workout)
                        }
                        .buttonStyle(.plain)
                    } else {
                        PlanDayRow(day: day, isToday: day == today, workout: nil)
                    }
                }
                Label("Giáo án mẫu để thử giao diện. Bạn có thể sửa số set, mục tiêu và thời gian nghỉ; mọi thay đổi được ghi vào nhật ký ở tab Cá nhân.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
                    .padding(.top, Spacing.s)
            }
            .padding(Spacing.l)
        }
        .caliScreen()
        .navigationTitle("Giáo án")
        .toolbarTitleDisplayMode(.inlineLarge)
    }
}

private struct PlanDayRow: View {
    @Environment(AppStore.self) private var store
    let day: Int
    let isToday: Bool
    let workout: PlannedWorkout?

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(spacing: 2) {
                Text(Fmt.weekdayShort(day))
                    .font(.headline)
                    .foregroundStyle(isToday ? Color.caliCanvas : Color.caliText)
            }
            .frame(width: 48, height: 48)
            .background(isToday ? Color.caliAccent : Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip))

            if let workout {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(workout.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    Text("\(workout.exercises.count) bài · \(workout.totalSets) set · ~\(workout.estimatedMinutes) phút")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                    HStack(spacing: -8) {
                        ForEach(workout.exercises.prefix(5)) { item in
                            PosterThumb(exercise: store.exercise(item.exerciseId), size: 28)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.caliSurface, lineWidth: 2))
                        }
                    }
                    .accessibilityHidden(true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.caliSecondary)
            } else {
                Text("Nghỉ")
                    .font(.headline)
                    .foregroundStyle(Color.caliSecondary)
                Spacer()
            }
        }
        .caliCard(padding: Spacing.m)
        .opacity(workout == nil ? 0.7 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Fmt.weekdayLong(day))\(isToday ? ", hôm nay" : ""): \(workout?.title ?? "nghỉ")")
    }
}

/// Planned workout detail with start and edit actions.
struct WorkoutDetailView: View {
    @Environment(AppStore.self) private var store
    let workoutId: UUID
    @State private var editing = false

    var body: some View {
        if let workout = store.workout(workoutId) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(workout.weekday == 0 ? "Bất kỳ ngày nào" : Fmt.weekdayLong(workout.weekday))
                            .font(.subheadline)
                            .foregroundStyle(Color.caliAccent)
                        Text(workout.focus)
                            .font(.subheadline)
                            .foregroundStyle(Color.caliSecondary)
                    }
                    HStack(spacing: Spacing.m) {
                        StatTile(value: "\(workout.exercises.count)", label: "Bài", systemImage: "list.bullet")
                        StatTile(value: "\(workout.totalSets)", label: "Set", systemImage: "square.stack.3d.up")
                        StatTile(value: "~\(workout.estimatedMinutes)", label: "Phút", systemImage: "clock")
                    }
                    SectionHeader(title: "Bài tập")
                    ForEach(Array(workout.exercises.enumerated()), id: \.element.id) { index, item in
                        if let exercise = store.exercise(item.exerciseId) {
                            NavigationLink {
                                ExerciseDetailView(exercise: exercise)
                            } label: {
                                PlannedExerciseRow(index: index + 1, item: item, exercise: exercise)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(Spacing.l)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Bắt đầu buổi này", systemImage: "play.fill") { store.startWorkout(workout) }
                    .buttonStyle(.caliPrimary)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                    .background(Color.caliCanvas.opacity(0.95))
            }
            .caliScreen()
            .navigationTitle(workout.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Sửa") { editing = true }
                        .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                }
            }
            .sheet(isPresented: $editing) {
                WorkoutEditorView(workout: workout)
            }
        } else {
            ContentUnavailableView("Không tìm thấy buổi tập", systemImage: "calendar.badge.exclamationmark")
                .caliScreen()
        }
    }
}

struct PlannedExerciseRow: View {
    let index: Int
    let item: PlannedExercise
    let exercise: Exercise

    var body: some View {
        HStack(spacing: Spacing.m) {
            PosterThumb(exercise: exercise, size: 64)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("\(index). \(exercise.name)")
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                Text(Fmt.prescription(item))
                    .font(.subheadline)
                    .foregroundStyle(Color.caliAccent)
                Text("Nghỉ \(Fmt.seconds(item.restSeconds)) · \(exercise.type.label)")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Color.caliSecondary)
        }
        .caliCard(padding: Spacing.m)
        .accessibilityElement(children: .combine)
    }
}

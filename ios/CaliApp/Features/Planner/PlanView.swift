import CaliDomain
import SwiftUI

/// "Giáo án" tab (UX-03, mockup `overview`): the followed plan with its weekly schedule.
///
/// Only one plan exists until IOS-015 (multi-plan list), so the tab opens the plan directly and the
/// Lộ trình / Tiến bộ segments, phase card, goals and weekly focus are left out until IOS-013/014.
struct PlanView: View {
    @Environment(AppStore.self) private var store
    @State private var editingPlan = false
    @State private var deletingPlan = false
    @State private var newWorkout: PlannedWorkout?
    @State private var title = ""
    @State private var planError: String?

    var body: some View {
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if store.plan.deletedAt != nil {
                    ContentUnavailableView("Chưa có giáo án", systemImage: "calendar", description: Text("Tạo giáo án rồi thêm buổi tập vào các ngày trong tuần."))
                    Button("Tạo giáo án") { title = "Giáo án của tôi"; editingPlan = true }.buttonStyle(.caliPrimary)
                } else {
                    header
                    weekSection(now: now)
                    schedule(now: now)
                    SampleFooter(showsSample: store.showsSampleData)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Giáo án")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.plan.deletedAt == nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Sửa tên giáo án", systemImage: "pencil") { title = store.plan.title; editingPlan = true }
                        Button("Xóa giáo án", systemImage: "trash", role: .destructive) { deletingPlan = true }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: minTapTarget, minHeight: minTapTarget) }
                    .accessibilityLabel("Tuỳ chọn giáo án")
                }
            }
        }
        .sheet(isPresented: $editingPlan) {
            NavigationStack {
                Form {
                    TextField("Tên giáo án", text: $title)
                    if let planError { Text(planError).foregroundStyle(Color.caliError) }
                }
                    .navigationTitle("Giáo án")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Hủy") { editingPlan = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Lưu") {
                                if store.renamePlan(title) { planError = nil; editingPlan = false }
                                else { planError = store.alertMessage; store.alertMessage = nil }
                            }
                                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
        }
        .sheet(item: $newWorkout) { WorkoutEditorView(workout: $0) }
        .confirmationDialog("Xóa giáo án và các buổi đã lên lịch?", isPresented: $deletingPlan, titleVisibility: .visible) {
            Button("Xóa giáo án", role: .destructive) { store.deletePlan() }
            Button("Hủy", role: .cancel) {}
        } message: { Text("Lịch sử và buổi đang tập được giữ lại. Thao tác này không thể hoàn tác.") }
    }

    private var scheduled: [PlannedWorkout] {
        store.plan.workouts.filter { (1...7).contains($0.weekday) }
    }

    private var header: some View {
        let discipline = Discipline(types: scheduled.flatMap { $0.exercises.map(\.target.type) })
        // Plan titles are long ("Planche Foundation / …"); a wrapping heading instead of the large nav title.
        return VStack(alignment: .leading, spacing: Spacing.m) {
            Text(store.plan.title)
                .font(.largeTitle.bold())
                .foregroundStyle(Color.caliText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Spacing.s) {
                TagChip(text: "\(scheduled.count) buổi / tuần", systemImage: "calendar")
                if !scheduled.isEmpty { DisciplineChip(discipline: discipline) }
                if store.showsSampleData { MockBadge() }
            }
        }
    }

    private func weekSection(now: Date) -> some View {
        let done = store.sessionsThisWeek(now: now).filter { s in scheduled.contains { $0.id == s.plannedWorkoutId } }
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Tuần này", trailing: "\(Set(done.compactMap(\.plannedWorkoutId)).count)/\(scheduled.count) buổi")
            HStack(spacing: Spacing.m) {
                StatTile(value: "\(done.count)", label: "Buổi đã tập", systemImage: "checkmark.circle", tint: .caliAccent)
                StatTile(value: "\(done.reduce(0) { $0 + $1.completedSetCount })", label: "Set xong", systemImage: "square.stack.3d.up")
                StatTile(value: "\(done.reduce(0) { $0 + $1.durationMinutes })", label: "Phút tập", systemImage: "clock")
            }
        }
    }

    private func schedule(now: Date) -> some View {
        let today = Fmt.isoWeekday(now)
        let doneIds = Set(store.sessionsThisWeek(now: now).compactMap(\.plannedWorkoutId))
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Lịch tuần", trailing: "Chạm để xem buổi")
            ForEach(1...7, id: \.self) { day in
                if let workout = scheduled.first(where: { $0.weekday == day }) {
                    NavigationLink {
                        WorkoutDetailView(workoutId: workout.id)
                    } label: {
                        PlanDayRow(day: day, isToday: day == today, workout: workout, done: doneIds.contains(workout.id))
                    }
                    .buttonStyle(.plain)
                } else {
                    RestDayRow(day: day, isToday: day == today) {
                        newWorkout = PlannedWorkout(id: UUID(), weekday: day, title: "Buổi tập mới", focus: "", exercises: [])
                    }
                }
            }
        }
    }
}

private struct PlanDayRow: View {
    @Environment(AppStore.self) private var store
    let day: Int
    let isToday: Bool
    let workout: PlannedWorkout
    let done: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            DayBox(day: day, isToday: isToday)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Text(workout.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                        .lineLimit(1)
                    if done {
                        TagChip(text: "Đã tập", systemImage: "checkmark", tint: .caliAccent, filled: true)
                    } else if isToday {
                        TagChip(text: "Hôm nay", tint: .caliAccentInk)
                    }
                }
                Text(Fmt.workoutMeta(workout))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
                PosterStack(exercises: store.exercises(of: workout), size: 28, limit: 4)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(Color.caliSecondary)
        }
        .caliCard(padding: Spacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Fmt.weekdayLong(day))\(isToday ? ", hôm nay" : ""): \(workout.title)\(done ? ", đã tập" : "")")
    }
}

private struct RestDayRow: View {
    let day: Int
    let isToday: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            DayBox(day: day, isToday: isToday)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nghỉ")
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                Text(Fmt.weekdayLong(day))
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            }
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus.circle")
                    .font(.title3)
                    .foregroundStyle(Color.caliAccentInk)
                    .frame(width: minTapTarget, height: minTapTarget)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thêm buổi vào \(Fmt.weekdayLong(day))")
        }
        .caliCard(padding: Spacing.m)
        .opacity(0.7)
    }
}

private struct DayBox: View {
    let day: Int
    let isToday: Bool

    var body: some View {
        Text(Fmt.weekdayShort(day))
            .font(.subheadline.bold())
            .foregroundStyle(isToday ? Color.caliOnAccent : Color.caliText)
            .frame(width: 48, height: 48)
            .background(isToday ? Color.caliAccent : Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Planned workout detail (mockup `workout`): day caption, title, tiles, exercises, start button.
struct WorkoutDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
    let workoutId: UUID
    @State private var editing = false

    var body: some View {
        if let workout = store.workout(workoutId) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text((workout.weekday == 0 ? "Bất kỳ ngày nào" : Fmt.weekdayLong(workout.weekday)).uppercased(with: Fmt.vi))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.caliAccentInk)
                        Text(workout.title)
                            .font(.title.bold())
                            .foregroundStyle(Color.caliText)
                        if !workout.focus.isEmpty {
                            Text(workout.focus)
                                .font(.subheadline)
                                .foregroundStyle(Color.caliSecondary)
                        }
                    }
                    HStack(spacing: Spacing.m) {
                        StatTile(value: "\(workout.exercises.count)", label: "Bài", systemImage: "list.bullet")
                        StatTile(value: "\(workout.totalSets)", label: "Set", systemImage: "square.stack.3d.up")
                        StatTile(value: "~\(workout.estimatedMinutes)", label: "Phút", systemImage: "clock")
                    }
                    VStack(alignment: .leading, spacing: Spacing.m) {
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
                }
                .padding(Spacing.l)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Bắt đầu buổi này", systemImage: "play.fill") { store.startWorkout(workout) }
                    .buttonStyle(.caliPrimary)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
                    .background(LinearGradient(colors: [Color.caliCanvas.opacity(0), Color.caliCanvas], startPoint: .top, endPoint: .center))
            }
            .caliScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Sửa buổi tập", systemImage: "pencil") { editing = true }
                        Button("Xóa buổi tập", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "pencil").frame(minWidth: minTapTarget, minHeight: minTapTarget) }
                    .accessibilityLabel("Sửa buổi tập")
                }
            }
            .confirmationDialog("Xóa buổi tập này?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Xóa buổi tập", role: .destructive) { if store.deleteWorkout(workoutId) { dismiss() } }
                Button("Hủy", role: .cancel) {}
            } message: { Text("Lịch sử và buổi đang tập được giữ lại.") }
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
                Text(Fmt.setsTarget(item))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color.caliAccentInk)
                Text(Fmt.restLine(item))
                    .font(.footnote)
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

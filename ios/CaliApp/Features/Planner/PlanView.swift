import CaliDomain
import SwiftUI

/// "Giáo án" tab (UX-03): weekly schedule of the active plan, each day editable.
struct PlanView: View {
    @Environment(AppStore.self) private var store
    @State private var editingPlan = false
    @State private var deletingPlan = false
    @State private var newWorkout: PlannedWorkout?
    @State private var title = ""
    @State private var planError: String?

    var body: some View {
        let today = Fmt.isoWeekday(Date())
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if store.plan.deletedAt != nil {
                    ContentUnavailableView("Chưa có giáo án", systemImage: "calendar", description: Text("Tạo giáo án rồi thêm buổi tập vào các ngày trong tuần."))
                    Button("Tạo giáo án") { title = "Giáo án của tôi"; editingPlan = true }.buttonStyle(.caliPrimary)
                } else {
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
                        TagChip(text: "Lưu trên máy", systemImage: "internaldrive")
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
                            Button {
                                newWorkout = PlannedWorkout(id: UUID(), weekday: day, title: "Buổi tập mới", focus: "", exercises: [])
                            } label: {
                                HStack {
                                    PlanDayRow(day: day, isToday: day == today, workout: nil)
                                    Image(systemName: "plus.circle").accessibilityLabel("Thêm buổi tập")
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    Label("Bạn có thể sửa tên giáo án, thêm/sửa/xóa buổi tập. Mọi thay đổi được lưu trên máy và ghi vào nhật ký ở tab Cá nhân.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(Color.caliSecondary)
                        .padding(.top, Spacing.s)
                }
            }
            .padding(Spacing.l)
        }
        .caliScreen()
        .navigationTitle("Giáo án")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            if store.plan.deletedAt == nil {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Sửa tên giáo án", systemImage: "pencil") { title = store.plan.title; editingPlan = true }
                        Button("Xóa giáo án", systemImage: "trash", role: .destructive) { deletingPlan = true }
                    } label: { Image(systemName: "ellipsis.circle").frame(minWidth: minTapTarget, minHeight: minTapTarget) }
                    .accessibilityLabel("Quản lý giáo án")
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
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false
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
                    Menu {
                        Button("Sửa buổi tập", systemImage: "pencil") { editing = true }
                        Button("Xóa buổi tập", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "ellipsis.circle").frame(minWidth: minTapTarget, minHeight: minTapTarget) }
                    .accessibilityLabel("Quản lý buổi tập")
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

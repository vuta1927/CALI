import CaliDomain
import SwiftUI

/// Edits one planned workout on a draft copy; nothing is written until "Lưu" (audit entry is
/// added by `AppStore.updateWorkout`).
struct WorkoutEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlannedWorkout
    @State private var showPicker = false
    @State private var confirmDiscard = false
    private let original: PlannedWorkout

    init(workout: PlannedWorkout) {
        original = workout
        _draft = State(initialValue: workout)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Tên buổi", text: $draft.title)
                    TextField("Trọng tâm", text: $draft.focus)
                } header: {
                    Text("Thông tin")
                }
                .listRowBackground(Color.caliSurface)

                Section {
                    ForEach($draft.exercises) { $item in
                        PlannedExerciseEditor(item: $item, exercise: store.exercise(item.exerciseId))
                    }
                    .onDelete { draft.exercises.remove(atOffsets: $0) }
                    .onMove { draft.exercises.move(fromOffsets: $0, toOffset: $1) }
                    Button("Thêm bài tập", systemImage: "plus.circle.fill") { showPicker = true }
                        .frame(minHeight: minTapTarget)
                } header: {
                    Text("Bài tập (\(draft.exercises.count)) · \(draft.totalSets) set · ~\(draft.estimatedMinutes) phút")
                } footer: {
                    Text("Vuốt sang trái để xoá, giữ và kéo để đổi thứ tự.")
                }
                .listRowBackground(Color.caliSurface)
            }
            .caliScreen()
            .navigationTitle("Sửa buổi tập")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") {
                        if draft != original { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        store.updateWorkout(draft)
                        dismiss()
                    }
                    .disabled(draft == original || draft.exercises.isEmpty || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Bỏ các thay đổi?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Bỏ thay đổi", role: .destructive) { dismiss() }
                Button("Tiếp tục sửa", role: .cancel) {}
            }
            .sheet(isPresented: $showPicker) {
                ExercisePickerView { exercise in
                    draft.exercises.append(PlannedExercise(
                        id: UUID(), exerciseId: exercise.id, setCount: 3,
                        target: exercise.type.defaultTarget, restSeconds: 90
                    ))
                }
            }
        }
        .interactiveDismissDisabled(draft != original)
        .preferredColorScheme(.dark)
    }
}

private struct PlannedExerciseEditor: View {
    @Binding var item: PlannedExercise
    let exercise: Exercise?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                PosterThumb(exercise: exercise, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise?.name ?? "Bài tập")
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    Text(Fmt.prescription(item))
                        .font(.caption)
                        .foregroundStyle(Color.caliAccent)
                }
            }
            Stepper("Số set: \(item.setCount)", value: $item.setCount, in: 1...10)
            targetEditor
            Stepper("Nghỉ: \(Fmt.seconds(item.restSeconds))", value: $item.restSeconds, in: 0...300, step: 15)
        }
        .padding(.vertical, Spacing.xs)
        .font(.subheadline)
        .foregroundStyle(Color.caliText)
    }

    @ViewBuilder
    private var targetEditor: some View {
        switch item.target {
        case .staticHold(let hold):
            Stepper("Giữ: \(hold) giây", value: binding(hold) { .staticHold(holdSeconds: $0) }, in: 5...120, step: 5)
        case .reps(let lo, let hi):
            Stepper("Tối thiểu: \(lo) lần", value: binding(lo) { .reps(repMin: $0, repMax: max($0, hi)) }, in: 1...50)
            Stepper("Tối đa: \(hi) lần", value: binding(hi) { .reps(repMin: min(lo, $0), repMax: $0) }, in: 1...50)
        case .timedReps(let time):
            Stepper("Thời gian: \(time) giây", value: binding(time) { .timedReps(timeSeconds: $0) }, in: 10...180, step: 5)
        case .interval(let work, let rest):
            Stepper("Tập: \(work) giây", value: binding(work) { .interval(workSeconds: $0, restSeconds: rest) }, in: 5...180, step: 5)
            Stepper("Nghỉ trong hiệp: \(rest) giây", value: binding(rest) { .interval(workSeconds: work, restSeconds: $0) }, in: 0...120, step: 5)
        case .skillAttempt(let attempts):
            Stepper("Số lần thử: \(attempts)", value: binding(attempts) { .skillAttempt(attempts: $0) }, in: 1...10)
        }
    }

    private func binding(_ current: Int, make: @escaping (Int) -> Prescription) -> Binding<Int> {
        Binding(get: { current }, set: { item.target = make($0) })
    }
}

/// Catalog picker used by the plan editor.
struct ExercisePickerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onPick: (Exercise) -> Void

    var body: some View {
        NavigationStack {
            List(filtered) { exercise in
                Button {
                    onPick(exercise)
                    dismiss()
                } label: {
                    HStack(spacing: Spacing.m) {
                        PosterThumb(exercise: exercise, size: 52)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(exercise.name)
                                .font(.headline)
                                .foregroundStyle(Color.caliText)
                            Text("\(exercise.type.label) · \(exercise.level.label)")
                                .font(.caption)
                                .foregroundStyle(Color.caliSecondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle")
                            .foregroundStyle(Color.caliAccent)
                    }
                }
                .listRowBackground(Color.caliSurface)
            }
            .searchable(text: $query, prompt: "Tìm bài tập")
            .caliScreen()
            .navigationTitle("Chọn bài tập")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var filtered: [Exercise] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.catalog }
        return store.catalog.filter { $0.name.localizedStandardContains(q) }
    }
}

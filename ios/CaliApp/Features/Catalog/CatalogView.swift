import CaliDomain
import SwiftUI

/// "Bài tập" tab (UX-04): visual-first catalog with search and type/level filters.
struct CatalogView: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var query = ""
    @State private var type: ExerciseType?
    @State private var level: ExerciseLevel?

    private let columns = [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        FilterChip(title: "Tất cả", isSelected: type == nil) { type = nil }
                        ForEach(ExerciseType.allCases, id: \.self) { t in
                            FilterChip(title: t.label, systemImage: t.systemImage, isSelected: type == t) {
                                type = type == t ? nil : t
                            }
                        }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(ExerciseLevel.allCases, id: \.self) { l in
                            FilterChip(title: l.label, isSelected: level == l) {
                                level = level == l ? nil : l
                            }
                        }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView("Không có bài phù hợp", systemImage: "magnifyingglass",
                                           description: Text("Thử bỏ bớt bộ lọc hoặc đổi từ khoá."))
                        .padding(.top, Spacing.xxl)
                } else {
                    LazyVGrid(columns: columns, spacing: Spacing.m) {
                        ForEach(filtered) { exercise in
                            NavigationLink {
                                ExerciseDetailView(exercise: exercise)
                            } label: {
                                ExerciseCard(exercise: exercise)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Bạn có thể thêm/sửa bài và gắn ảnh/video của mình. Bài chưa có ảnh sẽ hiển thị PLACEHOLDER.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            }
            .padding(Spacing.l)
        }
        .searchable(text: $query, prompt: "Tìm bài tập, nhóm cơ")
        .caliScreen()
        .navigationTitle("Bài tập")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Thêm bài tập", systemImage: "plus") { adding = true }.frame(minWidth: minTapTarget, minHeight: minTapTarget) } }
        .sheet(isPresented: $adding) { ExerciseEditorView() }
    }

    private var filtered: [Exercise] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.catalog.filter { e in
            (type == nil || e.type == type)
                && (level == nil || e.level == level)
                && (q.isEmpty || e.name.localizedStandardContains(q) || e.muscles.contains { $0.localizedStandardContains(q) })
        }
    }
}

private struct ExerciseCard: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            PosterView(exercise: exercise, height: 130)
            Text(exercise.name)
                .font(.headline)
                .foregroundStyle(Color.caliText)
                .lineLimit(2, reservesSpace: true)
            HStack(spacing: Spacing.xs) {
                Image(systemName: exercise.type.systemImage)
                Text(exercise.type.label)
                Text("·")
                Text(exercise.level.label)
            }
            .font(.caption)
            .foregroundStyle(Color.caliSecondary)
            .lineLimit(1)
        }
        .padding(Spacing.s)
        .background(Color.caliSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Exercise guide: poster, cues, common mistakes. Reused as the in-workout guide sheet
/// (`showsStartActions: false`).
struct ExerciseDetailView: View {
    @Environment(AppStore.self) private var store
    private let original: Exercise
    private var exercise: Exercise { store.exercise(original.id) ?? original }
    @State private var editing = false
    var showsStartActions = true

    init(exercise: Exercise, showsStartActions: Bool = true) {
        original = exercise
        self.showsStartActions = showsStartActions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                PosterView(exercise: exercise, height: 260)
                if let media = exercise.video, let url = media.url {
                    ExerciseVideoView(url: url).id(url)
                    if media.source == .remote { Link("Mở liên kết video", destination: url) }
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(exercise.name)
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.caliText)
                    FlowTags(exercise: exercise)
                }
                InfoBlock(title: "Nhóm cơ", systemImage: "figure.arms.open", lines: [exercise.muscles.joined(separator: ", ")])
                InfoBlock(title: "Dụng cụ", systemImage: "dumbbell", lines: [exercise.equipmentLabel])
                InfoBlock(title: "Điểm cần nhớ", systemImage: "checkmark.seal", lines: exercise.cues, numbered: true, tint: .caliAccentInk)
                InfoBlock(title: "Lỗi thường gặp", systemImage: "exclamationmark.triangle", lines: exercise.mistakes, tint: .caliWarning)
                Label("Hướng dẫn chỉ mang tính tham khảo, không thay thế tư vấn y tế. Dừng lại nếu thấy đau.", systemImage: "cross.case")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
                Text("Thư viện bài tập v\(exercise.catalogVersion)")
                    .font(.caption2)
                    .foregroundStyle(Color.caliSecondary)
            }
            .padding(Spacing.l)
        }
        .safeAreaInset(edge: .bottom) {
            if showsStartActions {
                Button("Tập thử bài này", systemImage: "play.fill") {
                    store.startWorkout(singleExerciseWorkout)
                }
                .buttonStyle(.caliPrimary)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .background(Color.caliCanvas.opacity(0.95))
            }
        }
        .caliScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsStartActions { ToolbarItem(placement: .primaryAction) { Button("Sửa") { editing = true } } }
        }
        .sheet(isPresented: $editing) { ExerciseEditorView(exercise: exercise) }
    }

    /// Ad-hoc 2-set workout with the exercise's default target (not saved to the plan).
    private var singleExerciseWorkout: PlannedWorkout {
        PlannedWorkout(
            id: UUID(), weekday: 0, title: "Tập thử: \(exercise.name)", focus: exercise.type.label,
            exercises: [PlannedExercise(id: UUID(), exerciseId: exercise.id, setCount: 2,
                                        target: exercise.type.defaultTarget, restSeconds: 30)]
        )
    }
}

private struct FlowTags: View {
    let exercise: Exercise

    var body: some View {
        HStack(spacing: Spacing.s) {
            TagChip(text: exercise.type.label, systemImage: exercise.type.systemImage, tint: .caliAccentInk)
            TagChip(text: exercise.level.label, systemImage: "chart.bar")
            TagChip(text: Fmt.target(exercise.type.defaultTarget), systemImage: "target")
        }
    }
}

private struct InfoBlock: View {
    let title: String
    let systemImage: String
    let lines: [String]
    var numbered = false
    var tint: Color = .caliSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(numbered ? "\(index + 1)." : "•")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(Color.caliSecondary)
                    Text(line)
                        .font(.body)
                        .foregroundStyle(Color.caliText)
                }
            }
        }
        .caliCard()
        .accessibilityElement(children: .combine)
    }
}

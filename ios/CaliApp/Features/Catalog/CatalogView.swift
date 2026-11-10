import CaliDomain
import SwiftUI

/// "Bài tập" tab (UX-04, mockup `catalog`): visual-first grid with search and level filter.
struct CatalogView: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var query = ""
    @State private var level: ExerciseLevel?

    private let columns = [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                SearchField(text: $query, prompt: "Tìm bài tập, nhóm cơ")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        FilterChip(title: "Tất cả", isSelected: level == nil) { level = nil }
                        ForEach(ExerciseLevel.allCases, id: \.self) { l in
                            FilterChip(title: l.label, isSelected: level == l) { level = l }
                        }
                    }
                }
                if filtered.isEmpty {
                    ContentUnavailableView("Không có bài phù hợp", systemImage: "magnifyingglass",
                                           description: Text("Thử từ khoá khác hoặc bỏ bộ lọc cấp độ."))
                        .padding(.top, Spacing.xxl)
                } else {
                    LazyVGrid(columns: columns, spacing: Spacing.l) {
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
                Text("Ảnh bài tập là ảnh tạm (PLACEHOLDER).")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Bài tập")
        .toolbarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Thêm bài tập", systemImage: "plus") { adding = true }
                    .frame(minWidth: minTapTarget, minHeight: minTapTarget)
            }
        }
        .sheet(isPresented: $adding) { ExerciseEditorView() }
    }

    private var filtered: [Exercise] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return store.catalog.filter { e in
            (level == nil || e.level == level)
                && (q.isEmpty || e.name.localizedStandardContains(q) || e.muscles.contains { $0.localizedStandardContains(q) })
        }
    }
}

/// Inline search field (mockup `.search`), kept in the content so it is always visible.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.caliSecondary)
            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.caliSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Xoá từ khoá")
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: minTapTarget)
        .background(Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }
}

private struct ExerciseCard: View {
    let exercise: Exercise

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            PosterView(exercise: exercise, height: 160, cornerRadius: 12)
                .padding(.bottom, Spacing.xs)
            Text(exercise.name)
                .font(.headline)
                .foregroundStyle(Color.caliText)
                .lineLimit(1)
            Text("\(exercise.groupLabel) · \(exercise.level.label)")
                .font(.caption)
                .foregroundStyle(Color.caliSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Exercise {
    /// Short group shown under a poster: first muscle group, else the measurement type.
    var groupLabel: String { muscles.first ?? type.label }
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
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(exercise.name)
                        .font(.title2.bold())
                        .foregroundStyle(Color.caliText)
                    HStack(spacing: 6) {
                        TagChip(text: exercise.level.label, tint: .caliAccentInk)
                        TagChip(text: exercise.type.label, systemImage: "clock")
                        TagChip(text: Discipline(types: [exercise.type]).label, systemImage: Discipline(types: [exercise.type]).systemImage)
                    }
                }
                videoBlock
                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader(title: "Nhóm cơ")
                    if exercise.muscles.isEmpty {
                        Text("Chưa ghi nhóm cơ").foregroundStyle(Color.caliSecondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) { ForEach(exercise.muscles, id: \.self) { TagChip(text: $0) } }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader(title: "Dụng cụ")
                    Text(exercise.equipmentLabel).foregroundStyle(Color.caliText)
                }
                if !exercise.cues.isEmpty {
                    BulletCard(title: "Điểm cần nhớ", systemImage: "checkmark.circle", tint: .caliAccentInk, lines: exercise.cues)
                }
                if !exercise.mistakes.isEmpty {
                    BulletCard(title: "Lỗi thường gặp", systemImage: "exclamationmark.triangle", tint: .caliWarning, lines: exercise.mistakes)
                }
                Label("Hướng dẫn chỉ mang tính tham khảo, không thay thế lời khuyên y tế. Dừng lại nếu thấy đau.", systemImage: "info.circle")
                    .font(.caption)
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
                .background(LinearGradient(colors: [Color.caliCanvas.opacity(0), Color.caliCanvas], startPoint: .top, endPoint: .center))
            }
        }
        .caliScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsStartActions {
                ToolbarItem(placement: .primaryAction) {
                    Button("Sửa bài tập", systemImage: "pencil") { editing = true }
                        .frame(minWidth: minTapTarget, minHeight: minTapTarget)
                }
            }
        }
        .sheet(isPresented: $editing) { ExerciseEditorView(exercise: exercise) }
    }

    @ViewBuilder
    private var videoBlock: some View {
        if let media = exercise.video, let url = media.url {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ExerciseVideoView(url: url).id(url)
                if media.source == .remote { Link("Mở liên kết video", destination: url).buttonStyle(.caliLink) }
            }
        } else {
            HStack(spacing: Spacing.m) {
                Image(systemName: "play.fill")
                    .foregroundStyle(Color.caliSecondary)
                    .frame(width: 44, height: 44)
                    .background(Color.caliSurfaceRaised, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video hướng dẫn").font(.headline).foregroundStyle(Color.caliText)
                    Text(showsStartActions ? "Chưa có video · thêm trong Sửa bài tập" : "Chưa có video")
                        .font(.footnote).foregroundStyle(Color.caliSecondary)
                }
            }
            .caliCard(padding: Spacing.m)
        }
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

private struct BulletCard: View {
    let title: String
    let systemImage: String
    let tint: Color
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: title)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: systemImage).foregroundStyle(tint)
                    Text(line).foregroundStyle(Color.caliText)
                }
            }
        }
        .caliCard()
        .accessibilityElement(children: .combine)
    }
}

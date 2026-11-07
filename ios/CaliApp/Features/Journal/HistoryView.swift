import CaliDomain
import SwiftUI

/// "Lịch sử" tab (UX-08): finished/abandoned sessions grouped by week, newest first.
struct HistoryView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.history.isEmpty {
                ContentUnavailableView("Chưa có buổi tập nào", systemImage: "clock.arrow.circlepath",
                                       description: Text("Hoàn thành một buổi tập để xem lại kết quả ở đây."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.l) {
                        summary
                        ForEach(groups, id: \.start) { group in
                            SectionHeader(title: group.title, trailing: "\(group.sessions.count) buổi")
                            ForEach(group.sessions) { session in
                                NavigationLink {
                                    SessionDetailView(session: session)
                                } label: {
                                    SessionRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(Spacing.l)
                }
            }
        }
        .caliScreen()
        .navigationTitle("Lịch sử")
        .toolbarTitleDisplayMode(.inlineLarge)
    }

    private var summary: some View {
        let completed = store.history.filter { $0.status == .completed }
        return HStack(spacing: Spacing.m) {
            StatTile(value: "\(completed.count)", label: "Buổi hoàn thành", systemImage: "checkmark.circle", tint: .caliAccent)
            StatTile(value: "\(store.history.reduce(0) { $0 + $1.completedSetCount })", label: "Set đạt", systemImage: "square.stack.3d.up")
            StatTile(value: "\(store.history.reduce(0) { $0 + $1.durationMinutes })", label: "Phút", systemImage: "clock")
        }
    }

    private struct WeekGroup {
        let start: Date
        let title: String
        let sessions: [CompletedSession]
    }

    private var groups: [WeekGroup] {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let byWeek = Dictionary(grouping: store.history) { calendar.dateInterval(of: .weekOfYear, for: $0.startedAt)?.start ?? $0.startedAt }
        return byWeek.keys.sorted(by: >).map { start in
            let weeksAgo = calendar.dateComponents([.weekOfYear], from: start, to: thisWeek).weekOfYear ?? 0
            let title = switch weeksAgo {
            case 0: "Tuần này"
            case 1: "Tuần trước"
            default: "Tuần \(Fmt.dayMonth(start))"
            }
            return WeekGroup(start: start, title: title, sessions: byWeek[start, default: []].sorted { $0.startedAt > $1.startedAt })
        }
    }
}

private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    let session: CompletedSession

    var body: some View {
        HStack(spacing: Spacing.m) {
            PosterThumb(exercise: session.exerciseIds.first.flatMap(store.exercise), size: 56)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Text(session.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                        .lineLimit(1)
                    if session.isSample { MockBadge() }
                }
                Text("\(Fmt.relativeDay(session.startedAt)) · \(Fmt.time(session.startedAt)) · \(session.durationMinutes) phút")
                    .font(.subheadline)
                    .foregroundStyle(Color.caliSecondary)
                HStack(spacing: Spacing.s) {
                    LinearProgress(progress: Double(session.completedSetCount) / Double(max(session.plannedSetCount, 1)),
                                   tint: session.status == .completed ? .caliAccent : .caliWarning)
                    Text("\(session.completedSetCount)/\(session.plannedSetCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.caliSecondary)
                }
            }
            if session.status != .completed {
                TagChip(text: "Dừng sớm", tint: .caliWarning)
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(Color.caliSecondary)
        }
        .caliCard(padding: Spacing.m)
        .accessibilityElement(children: .combine)
    }
}

/// Per-exercise breakdown of one past session.
struct SessionDetailView: View {
    @Environment(AppStore.self) private var store
    let session: CompletedSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(Fmt.fullDate(session.startedAt).capitalized(with: Fmt.vi))
                            .font(.subheadline)
                            .foregroundStyle(Color.caliSecondary)
                        Text("\(Fmt.time(session.startedAt)) – \(Fmt.time(session.finishedAt))")
                            .font(.subheadline)
                            .foregroundStyle(Color.caliSecondary)
                    }
                    Spacer()
                    if session.isSample { MockBadge() }
                }
                HStack(spacing: Spacing.m) {
                    StatTile(value: "\(session.completedSetCount)/\(session.plannedSetCount)", label: "Set đạt", systemImage: "checkmark.circle", tint: .caliAccent)
                    StatTile(value: "\(session.skippedSetCount)", label: "Bỏ qua", systemImage: "forward")
                    StatTile(value: "\(session.durationMinutes)", label: "Phút", systemImage: "clock")
                }
                if session.status != .completed {
                    Label("Buổi này đã dừng trước khi hoàn thành.", systemImage: "exclamationmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliWarning)
                }
                ForEach(exerciseOrder, id: \.self) { exerciseId in
                    let sets = session.sets.filter { $0.exerciseId == exerciseId }.sorted { $0.setIndex < $1.setIndex }
                    let exercise = store.exercise(exerciseId)
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        HStack(spacing: Spacing.m) {
                            PosterThumb(exercise: exercise, size: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exercise?.name ?? "Bài tập")
                                    .font(.headline)
                                    .foregroundStyle(Color.caliText)
                                if let target = sets.first?.target {
                                    Text("Mục tiêu \(Fmt.target(target))")
                                        .font(.caption)
                                        .foregroundStyle(Color.caliSecondary)
                                }
                            }
                        }
                        if sets.isEmpty {
                            Text("Chưa tập")
                                .font(.subheadline)
                                .foregroundStyle(Color.caliSecondary)
                        }
                        ForEach(sets) { set in
                            LoggedSetRow(set: set)
                        }
                    }
                    .caliCard(padding: Spacing.m)
                }
            }
            .padding(Spacing.l)
        }
        .caliScreen()
        .navigationTitle(session.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var exerciseOrder: [UUID] {
        var seen = Set<UUID>()
        return (session.exerciseIds + session.sets.map(\.exerciseId)).filter { seen.insert($0).inserted }
    }
}

struct LoggedSetRow: View {
    let set: LoggedSet

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 24)
                Text("Set \(set.setIndex)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.caliText)
                Spacer()
                Text(Fmt.actual(set))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.caliText)
                if let rpe = set.rpe {
                    TagChip(text: "RPE \(rpe)")
                }
            }
            if let reason = set.skipReason, !reason.isEmpty {
                Text("Lý do: \(reason)")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
                    .padding(.leading, 32)
            }
            if let note = set.note, !note.isEmpty {
                Text("“\(note)”")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
                    .padding(.leading, 32)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch set.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.circle"
        case .skipped: "forward.circle"
        }
    }

    private var tint: Color {
        switch set.status {
        case .completed: .caliAccent
        case .failed: .caliWarning
        case .skipped: .caliSecondary
        }
    }
}

import CaliDomain
import SwiftUI

/// "Lịch sử" tab (UX-08, mockup `history`): week / month view of recorded sessions.
///
/// Only recorded sessions are shown. "Bỏ lỡ" days and the per-plan filter need plan activation
/// history and running sessions, which come with IOS-015/016; until then nothing is inferred.
struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @State private var mode: Mode = .week
    @State private var weekOffset = 0
    @State private var monthOffset = 0
    @State private var selectedDay: Date?

    enum Mode: Hashable { case week, month }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.locale = Fmt.vi
        return c
    }

    var body: some View {
        let now = Date()
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Picker("Chế độ xem", selection: $mode) {
                    Text("Tuần").tag(Mode.week)
                    Text("Tháng").tag(Mode.month)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { selectedDay = nil }
                if mode == .week { weekView(now: now) } else { monthView(now: now) }
                SampleFooter(showsSample: store.showsSampleData)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Lịch sử")
        .toolbarTitleDisplayMode(.large)
        .toolbar {
            if store.showsSampleData {
                ToolbarItem(placement: .primaryAction) { MockBadge() }
            }
        }
    }

    // MARK: Periods

    private func sessions(_ interval: DateInterval) -> [CompletedSession] {
        store.history.filter { $0.startedAt >= interval.start && $0.startedAt < interval.end }.sorted { $0.startedAt > $1.startedAt }
    }

    private func week(_ offset: Int, now: Date) -> DateInterval {
        let current = calendar.dateInterval(of: .weekOfYear, for: now)!
        let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: current.start)!
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 7, to: start)!)
    }

    private func month(_ offset: Int, now: Date) -> DateInterval {
        let current = calendar.dateInterval(of: .month, for: now)!
        let start = calendar.date(byAdding: .month, value: -offset, to: current.start)!
        return calendar.dateInterval(of: .month, for: start)!
    }

    /// Oldest offset that still has data (navigation stops there).
    private func maxOffset(_ component: Calendar.Component, now: Date) -> Int {
        guard let oldest = store.history.map(\.startedAt).min() else { return 0 }
        let a = calendar.dateInterval(of: component, for: oldest)!.start
        let b = calendar.dateInterval(of: component, for: now)!.start
        return max(0, calendar.dateComponents([component], from: a, to: b).value(for: component) ?? 0)
    }

    // MARK: Week

    @ViewBuilder
    private func weekView(now: Date) -> some View {
        let interval = week(weekOffset, now: now)
        let list = sessions(interval)
        let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: interval.start)! }
        let subtitle = weekOffset == 0 ? "Tuần này" : weekOffset == 1 ? "Tuần trước" : "\(weekOffset) tuần trước"
        PeriodNavigator(title: Fmt.range(interval.start, days[6]), subtitle: subtitle,
                        canGoBack: weekOffset < maxOffset(.weekOfYear, now: now), canGoForward: weekOffset > 0) { step in
            weekOffset += step
        }
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let state = dayState(day, in: list)
                WeekDayDot(day: Fmt.isoWeekday(day, calendar: calendar), isToday: calendar.isDate(day, inSameDayAs: now),
                           completed: state == .done, scheduled: state == .planned,
                           dateLabel: "\(calendar.component(.day, from: day))", abandoned: state == .partial)
            }
        }
        .caliCard(padding: Spacing.m)
        summary(list, comparison: weekComparison(now: now))
        sessionList(title: "Các buổi tập", list, empty: weekOffset == 0 ? "Tuần này chưa có buổi tập nào" : "Tuần này không có buổi tập nào")
    }

    /// Current week: compare Mon…yesterday with the same days last week (today may not be trained yet).
    private func weekComparison(now: Date) -> Comparison? {
        let cur = week(weekOffset, now: now)
        guard weekOffset < maxOffset(.weekOfYear, now: now) else { return nil }
        let prev = week(weekOffset + 1, now: now)
        if weekOffset == 0 {
            let today = calendar.startOfDay(for: now)
            let days = calendar.dateComponents([.day], from: cur.start, to: today).day ?? 0
            let prevEnd = calendar.date(byAdding: .day, value: days, to: prev.start)!
            let label = days == 0 ? "tuần trước" : "cùng kỳ tuần trước (T2–\(Fmt.weekdayShort(days)))"
            return Comparison(current: sessions(DateInterval(start: cur.start, end: today)),
                              previous: sessions(DateInterval(start: prev.start, end: prevEnd)), label: label)
        }
        return Comparison(current: sessions(cur), previous: sessions(prev), label: "tuần trước")
    }

    // MARK: Month

    @ViewBuilder
    private func monthView(now: Date) -> some View {
        let interval = month(monthOffset, now: now)
        let list = sessions(interval)
        let subtitle = monthOffset == 0 ? "Tháng này" : monthOffset == 1 ? "Tháng trước" : " "
        let c = calendar.dateComponents([.month, .year], from: interval.start)
        PeriodNavigator(title: "Tháng \(c.month ?? 0), \(String(c.year ?? 0))", subtitle: subtitle,
                        canGoBack: monthOffset < maxOffset(.month, now: now), canGoForward: monthOffset > 0) { step in
            monthOffset += step
            selectedDay = nil
        }
        MonthGrid(interval: interval, calendar: calendar, now: now, selected: $selectedDay) { dayState($0, in: list) }
        summary(list, comparison: monthComparison(now: now))
        if let day = selectedDay {
            let dayList = list.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "\(Fmt.weekdayLong(Fmt.isoWeekday(day, calendar: calendar))), \(Fmt.dayMonthShort(day))")
                    Button("Xem cả tháng") { selectedDay = nil }.buttonStyle(.caliLink)
                }
                if dayList.isEmpty { EmptyPeriod(text: "Ngày nghỉ, không có buổi tập") }
                ForEach(dayList) { HistoryRow(session: $0) }
            }
        } else {
            let weeks = Dictionary(grouping: list) { calendar.dateInterval(of: .weekOfYear, for: $0.startedAt)!.start }
            if weeks.isEmpty { EmptyPeriod(text: monthOffset == 0 ? "Tháng này chưa có buổi tập nào" : "Tháng này không có buổi tập nào") }
            ForEach(weeks.keys.sorted(by: >), id: \.self) { start in
                let end = calendar.date(byAdding: .day, value: 6, to: start)!
                sessionList(title: Fmt.range(start, end), weeks[start, default: []], empty: "")
            }
        }
    }

    private func monthComparison(now: Date) -> Comparison? {
        guard monthOffset < maxOffset(.month, now: now) else { return nil }
        let cur = month(monthOffset, now: now)
        let prev = month(monthOffset + 1, now: now)
        if monthOffset == 0 {
            let today = calendar.startOfDay(for: now)
            let days = calendar.dateComponents([.day], from: cur.start, to: today).day ?? 0
            let prevEnd = min(calendar.date(byAdding: .day, value: days, to: prev.start)!, prev.end)
            let pm = calendar.component(.month, from: prev.start)
            let label = days == 0 ? "tháng trước" : "cùng kỳ tháng trước (1–\(days)/\(pm))"
            return Comparison(current: sessions(DateInterval(start: cur.start, end: today)),
                              previous: sessions(DateInterval(start: prev.start, end: prevEnd)), label: label)
        }
        return Comparison(current: sessions(cur), previous: sessions(prev), label: "tháng trước")
    }

    // MARK: Shared pieces

    private func dayState(_ day: Date, in list: [CompletedSession]) -> DayState {
        let onDay = list.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
        if onDay.contains(where: { $0.status == .completed }) { return .done }
        if !onDay.isEmpty { return .partial }
        let today = calendar.startOfDay(for: Date())
        let local = LocalDate.today(at: day, in: calendar.timeZone)
        if day >= today, !store.scheduledItems(on: local).isEmpty { return .planned }
        return .none
    }

    private func summary(_ list: [CompletedSession], comparison: Comparison?) -> some View {
        let done = list.filter { $0.status == .completed }
        let abandoned = list.count - done.count
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                StatTile(value: "\(done.count)", label: "Buổi hoàn thành", systemImage: "checkmark.circle", tint: .caliAccent)
                StatTile(value: "\(list.reduce(0) { $0 + $1.completedSetCount })", label: "Set đạt", systemImage: "square.stack.3d.up")
                StatTile(value: "\(list.reduce(0) { $0 + $1.durationMinutes })", label: "Phút", systemImage: "clock")
            }
            VStack(alignment: .leading, spacing: 2) {
                if abandoned > 0 {
                    Text("\(abandoned) dừng sớm").font(.footnote).foregroundStyle(Color.caliSecondary)
                }
                Text(comparison?.text ?? "Kỳ đầu tiên có dữ liệu")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
            }
            .padding(.horizontal, Spacing.xs)
        }
    }

    @ViewBuilder
    private func sessionList(title: String, _ list: [CompletedSession], empty: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: title, trailing: "\(list.count) buổi")
            if list.isEmpty && !empty.isEmpty { EmptyPeriod(text: empty) }
            ForEach(list) { HistoryRow(session: $0) }
        }
    }
}

enum DayState { case none, done, partial, planned }

private struct Comparison {
    let current: [CompletedSession]
    let previous: [CompletedSession]
    let label: String

    var text: String {
        let d = current.filter { $0.status == .completed }.count - previous.filter { $0.status == .completed }.count
        let s = current.reduce(0) { $0 + $1.completedSetCount } - previous.reduce(0) { $0 + $1.completedSetCount }
        let m = current.reduce(0) { $0 + $1.durationMinutes } - previous.reduce(0) { $0 + $1.durationMinutes }
        return "So với \(label): \(Self.signed(d)) buổi · \(Self.signed(s)) set · \(Self.signed(m)) phút"
    }

    static func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : n < 0 ? "−\(-n)" : "±0" }
}

private struct PeriodNavigator: View {
    let title: String
    let subtitle: String
    let canGoBack: Bool
    let canGoForward: Bool
    let step: (Int) -> Void

    var body: some View {
        HStack {
            arrow("chevron.left", label: "Kỳ trước", enabled: canGoBack) { step(1) }
            Spacer()
            VStack(spacing: 0) {
                Text(title).font(.headline.monospacedDigit()).foregroundStyle(Color.caliText)
                Text(subtitle).font(.caption).foregroundStyle(Color.caliSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            arrow("chevron.right", label: "Kỳ sau", enabled: canGoForward) { step(-1) }
        }
    }

    private func arrow(_ image: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.headline)
                .foregroundStyle(Color.caliAccentInk)
                .frame(width: minTapTarget, height: minTapTarget)
                .background(Color.caliSurfaceRaised, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

private struct MonthGrid: View {
    let interval: DateInterval
    let calendar: Calendar
    let now: Date
    @Binding var selected: Date?
    let state: (Date) -> DayState

    var body: some View {
        let days = calendar.range(of: .day, in: .month, for: interval.start)!.map { calendar.date(byAdding: .day, value: $0 - 1, to: interval.start)! }
        let lead = Fmt.isoWeekday(interval.start, calendar: calendar) - 1
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        VStack(alignment: .leading, spacing: Spacing.m) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(1...7, id: \.self) { Text(Fmt.weekdayShort($0)).font(.caption).foregroundStyle(Color.caliSecondary) }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: minTapTarget) }
                ForEach(days, id: \.self) { day in cell(day) }
            }
            HStack(spacing: Spacing.l) {
                legend(Color.caliAccent, "Hoàn thành")
                legend(Color.caliWarning, "Dừng sớm")
                legend(Color.caliSecondary, "Theo lịch")
            }
            .font(.caption)
            .foregroundStyle(Color.caliSecondary)
        }
        .caliCard(padding: Spacing.m)
    }

    private func cell(_ day: Date) -> some View {
        let st = state(day)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let isSelected = selected.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let future = day > now
        return Button {
            selected = isSelected ? nil : day
        } label: {
            VStack(spacing: 2) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.subheadline.monospacedDigit().weight(isToday ? .bold : .regular))
                    .foregroundStyle(st == .done ? Color.caliOnAccent : Color.caliText)
                Circle().fill(dotColor(st)).frame(width: 5, height: 5).opacity(st == .none || st == .done ? 0 : 1)
            }
            .frame(maxWidth: .infinity, minHeight: minTapTarget)
            .background(st == .done ? Color.caliAccent : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.caliText : (isToday ? Color.caliAccent : Color.clear), lineWidth: isSelected || isToday ? 2 : 0)
            }
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel("\(Fmt.weekdayLong(Fmt.isoWeekday(day, calendar: calendar))) \(Fmt.dayMonthShort(day))\(label(st))")
    }

    private func dotColor(_ st: DayState) -> Color {
        switch st {
        case .partial: .caliWarning
        case .planned: .caliSecondary
        default: .clear
        }
    }

    private func label(_ st: DayState) -> String {
        switch st {
        case .done: ", hoàn thành"
        case .partial: ", dừng sớm"
        case .planned: ", theo lịch"
        case .none: ""
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

private struct EmptyPeriod: View {
    let text: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon").foregroundStyle(Color.caliSecondary)
            Text(text).font(.footnote).foregroundStyle(Color.caliSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
        .caliCard(padding: Spacing.m)
    }
}

/// Session row (mockup `hRow`): poster cluster, title, when, result chips.
private struct HistoryRow: View {
    @Environment(AppStore.self) private var store
    let session: CompletedSession

    var body: some View {
        NavigationLink {
            SessionDetailView(session: session)
        } label: {
            HStack(spacing: Spacing.m) {
                PosterStack(exercises: session.exerciseIds.map(store.exercise), size: 44, limit: 3)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(session.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                        .lineLimit(1)
                    Text("\(Fmt.relativeDayLong(session.startedAt)) · \(Fmt.time(session.startedAt))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.caliSecondary)
                    HStack(spacing: 6) {
                        let full = session.completedSetCount == session.plannedSetCount
                        TagChip(text: "\(session.completedSetCount)/\(session.plannedSetCount) set", tint: full ? .caliAccentInk : .caliSecondary)
                        TagChip(text: "\(session.durationMinutes) phút")
                        if session.status != .completed { TagChip(text: "Dừng sớm", tint: .caliWarning) }
                        if session.isSample { MockBadge() }
                    }
                    if let plan = store.planLabel(for: session) {
                        Label(plan, systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(Color.caliSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.caliSecondary)
            }
            .caliCard(padding: Spacing.m)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// One past session (mockup `sessionDetail`): tiles, then a set grid per exercise.
struct SessionDetailView: View {
    @Environment(AppStore.self) private var store
    let session: CompletedSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(caption)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.caliSecondary)
                    Text(session.title)
                        .font(.title2.bold())
                        .foregroundStyle(Color.caliText)
                    HStack(spacing: 6) {
                        if session.status != .completed { TagChip(text: "Dừng sớm", tint: .caliWarning) }
                        if session.isSample { MockBadge() }
                    }
                    if let plan = store.planLabel(for: session) {
                        Label(plan, systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(Color.caliSecondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: Spacing.m) {
                    StatTile(value: "\(session.completedSetCount)/\(session.plannedSetCount)", label: "Set đạt", systemImage: "checkmark.circle", tint: .caliAccent)
                    if let meters = runningMeters {
                        // Running (CON-004): the distance and time the user entered, not the wall-clock span.
                        StatTile(value: Fmt.km(meters), label: "Quãng đường", systemImage: "figure.run", tint: .caliAccent)
                        StatTile(value: Fmt.duration(runningSeconds), label: "Thời gian chạy", systemImage: "stopwatch")
                    } else {
                        StatTile(value: "\(session.skippedSetCount)", label: "Bỏ qua", systemImage: "forward")
                        StatTile(value: "\(session.durationMinutes)", label: "Phút", systemImage: "clock")
                    }
                }
                ForEach(exerciseOrder, id: \.self) { exerciseId in
                    ExerciseResultCard(exercise: store.exercise(exerciseId),
                                       sets: session.sets.filter { $0.exerciseId == exerciseId }.sorted { $0.setIndex < $1.setIndex })
                }
                Text("Kết quả chỉ ghi khi bạn xác nhận từng set.")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
                SampleFooter(showsSample: session.isSample)
            }
            .padding(Spacing.l)
        }
        .caliScreen()
        .navigationBarTitleDisplayMode(.inline)
    }

    private var runningSets: [LoggedSet] { session.sets.filter { $0.status != .skipped && $0.target.running != nil } }
    private var runningMeters: Int? {
        let meters = runningSets.compactMap(\.distanceMeters)
        return meters.isEmpty ? nil : meters.reduce(0, +)
    }
    private var runningSeconds: Int { runningSets.compactMap(\.durationSeconds).reduce(0, +) }

    /// "Thứ Sáu, 6/11/2026 · 07:30 – 08:28"; a session entered by hand afterwards (race result) has no span.
    private var caption: String {
        let year = Calendar.current.component(.year, from: session.startedAt)
        let day = "\(Fmt.weekdayLong(Fmt.isoWeekday(session.startedAt))), \(Fmt.dayMonthShort(session.startedAt))/\(String(year))"
        guard session.finishedAt.timeIntervalSince(session.startedAt) >= 60 else { return day }
        return "\(day) · \(Fmt.time(session.startedAt)) – \(Fmt.time(session.finishedAt))"
    }

    private var exerciseOrder: [UUID] {
        var seen = Set<UUID>()
        return (session.exerciseIds + session.sets.map(\.exerciseId)).filter { seen.insert($0).inserted }
    }
}

/// Poster + target + grid of logged sets; shared by session detail and the player summary.
struct ExerciseResultCard: View {
    let exercise: Exercise?
    let sets: [LoggedSet]
    var plannedSetCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                PosterThumb(exercise: exercise, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise?.name ?? "Bài tập")
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    if let target = sets.first?.target {
                        Text("Mục tiêu: \(plannedSetCount.map { "\($0) × " } ?? "")\(Fmt.target(target))")
                            .font(.footnote)
                            .foregroundStyle(Color.caliSecondary)
                    }
                }
            }
            if sets.isEmpty {
                Text("Chưa có set nào")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            } else if sets.first?.target.running != nil {
                // "8,25 km 42:18 · 5:08/km" does not fit a grid cell; one row per segment.
                ForEach(sets) { set in
                    HStack(alignment: .firstTextBaseline) {
                        Text("Set \(set.setIndex)").font(.caption).foregroundStyle(Color.caliSecondary)
                        Text(Fmt.actual(set)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.caliText)
                        Spacer(minLength: 0)
                        if let detail = detail(set) {
                            Text(detail).font(.caption).foregroundStyle(Color.caliSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: Spacing.s)], spacing: Spacing.s) {
                    ForEach(sets) { set in
                        SetCell(index: set.setIndex,
                                value: set.status == .skipped ? nil : Fmt.actual(set),
                                detail: detail(set))
                    }
                }
                ForEach(sets.filter { !($0.note ?? "").isEmpty }) { set in
                    Text("Set \(set.setIndex): “\(set.note ?? "")”")
                        .font(.caption)
                        .foregroundStyle(Color.caliSecondary)
                }
            }
        }
        .caliCard()
    }

    private func detail(_ set: LoggedSet) -> String? {
        switch set.status {
        case .skipped: set.skipReason.map { "Bỏ qua · \($0)" } ?? "Bỏ qua"
        case .failed: set.rpe.map { "Chưa đạt · RPE \($0)" } ?? "Chưa đạt"
        case .completed: set.rpe.map { "RPE \($0)" }
        }
    }
}

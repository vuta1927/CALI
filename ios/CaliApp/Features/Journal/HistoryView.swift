import CaliCore
import CaliDomain
import SwiftUI

/// "Lịch sử" tab (UX-10, mockup `history`): week / month view of sessions across every plan, with a plan filter.
///
/// Sessions are a log, independent of plans (docs/02 §3.1). Missed days come from the plan schedule
/// (`PlanSchedule.adherence`, I4), shown dashed and not tappable; "today" opens Today; future days are dots only.
struct HistoryView: View {
    @Environment(AppStore.self) private var store
    @Binding var tab: AppTab
    @State private var mode: Mode = .week
    @State private var weekOffset = 0
    @State private var monthOffset = 0
    @State private var selectedDay: Date?
    /// Plan lineage to show; nil = "Tất cả" (cross-plan totals).
    @State private var planFilter: UUID?

    enum Mode: Hashable { case week, month }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        c.timeZone = store.calendar.timeZone
        c.locale = Fmt.vi
        return c
    }

    private var kind: HistoryPeriodKind { mode == .week ? .week : .month }

    var body: some View {
        let now = Date()
        let options = store.historyPlanOptions(now: now)
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Picker("Chế độ xem", selection: $mode) {
                    Text("Tuần").tag(Mode.week)
                    Text("Tháng").tag(Mode.month)
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { selectedDay = nil }
                if options.count > 1 { filterBar(options) }
                if mode == .week { weekView(now: now) } else { monthView(now: now) }
                SampleFooter(showsSample: store.showsSampleData)
                Color.clear.frame(height: 1).id("history-end")
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        #if DEBUG
        // `-uiScrollEnd YES` scrolls to the bottom for screenshots of the list below the summary.
        .task {
            if UserDefaults.standard.bool(forKey: "uiScrollEnd") {
                try? await Task.sleep(for: .seconds(1))
                withAnimation(nil) { proxy.scrollTo("history-end", anchor: .bottom) }
            }
        }
        #endif
        }
        .caliScreen()
        .navigationTitle("Lịch sử")
        .toolbarTitleDisplayMode(.large)
        .toolbar {
            if store.showsSampleData {
                ToolbarItem(placement: .primaryAction) { MockBadge() }
            }
        }
        .onChange(of: options) { _, new in
            if let id = planFilter, !new.contains(where: { $0.lineageId == id }) { planFilter = nil }
        }
    }

    private func filterBar(_ options: [HistoryPlanOption]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                FilterChip(title: "Tất cả", isSelected: planFilter == nil) { planFilter = nil }
                ForEach(options) { option in
                    FilterChip(title: option.title, isSelected: planFilter == option.lineageId) {
                        planFilter = planFilter == option.lineageId ? nil : option.lineageId
                    }
                }
            }
        }
        .accessibilityLabel("Lọc theo giáo án")
    }

    // MARK: Data of a period

    /// Sessions and planned workouts of `interval`, narrowed to the plan filter.
    private struct PeriodData {
        var sessions: [CompletedSession]
        var slots: [ScheduleSlot]
    }

    private func local(_ date: Date) -> LocalDate { LocalDate.today(at: date, in: calendar.timeZone) }

    private func matchesFilter(_ session: CompletedSession) -> Bool { planFilter == nil || session.planLineageId == planFilter }

    private func sessions(_ interval: DateInterval) -> [CompletedSession] {
        store.history.filter { matchesFilter($0) && $0.startedAt >= interval.start && $0.startedAt < interval.end }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func data(_ interval: DateInterval, now: Date) -> PeriodData {
        let last = local(interval.end.addingTimeInterval(-1))
        let slots = store.scheduledItems(from: local(interval.start), through: last, includeEnded: true, now: now)
            .map(\.slot).filter { planFilter == nil || $0.lineageId == planFilter }
        return PeriodData(sessions: sessions(interval), slots: slots)
    }

    private func state(of day: Date, in data: PeriodData, now: Date) -> HistoryDayState {
        let date = local(day)
        return HistoryDayState.of(
            day: date,
            sessions: data.sessions.filter { calendar.isDate($0.startedAt, inSameDayAs: day) },
            slots: data.slots.filter { $0.date == date },
            today: store.today(now))
    }

    private var oldestSession: Date? { store.history.map(\.startedAt).min() }

    // MARK: Week

    @ViewBuilder
    private func weekView(now: Date) -> some View {
        let interval = HistoryPeriods.interval(.week, offset: weekOffset, now: now, calendar: calendar)
        let period = data(interval, now: now)
        let days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: interval.start)! }
        let subtitle = weekOffset == 0 ? "Tuần này" : weekOffset == 1 ? "Tuần trước" : "\(weekOffset) tuần trước"
        let maxOffset = HistoryPeriods.maxOffset(.week, oldest: oldestSession, now: now, calendar: calendar)
        PeriodNavigator(title: Fmt.range(interval.start, days[6]), subtitle: subtitle,
                        canGoBack: weekOffset < maxOffset, canGoForward: weekOffset > 0) { step in
            weekOffset += step
        }
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { day in
                let st = state(of: day, in: period, now: now)
                WeekDayDot(day: Fmt.isoWeekday(day, calendar: calendar), isToday: calendar.isDate(day, inSameDayAs: now),
                           completed: st == .done, scheduled: st == .planned || st == .today,
                           dateLabel: "\(calendar.component(.day, from: day))", abandoned: st == .stoppedEarly, missed: st == .missed)
            }
        }
        .caliCard(padding: Spacing.m)
        summary(period, comparison: comparisonText(now: now))
        entryList(title: "Các buổi tập", entries(period, now: now),
                  empty: weekOffset == 0 ? "Tuần này chưa có buổi tập nào" : "Tuần này không có buổi tập nào")
    }

    // MARK: Month

    @ViewBuilder
    private func monthView(now: Date) -> some View {
        let interval = HistoryPeriods.interval(.month, offset: monthOffset, now: now, calendar: calendar)
        let period = data(interval, now: now)
        let subtitle = monthOffset == 0 ? "Tháng này" : monthOffset == 1 ? "Tháng trước" : " "
        let c = calendar.dateComponents([.month, .year], from: interval.start)
        let maxOffset = HistoryPeriods.maxOffset(.month, oldest: oldestSession, now: now, calendar: calendar)
        PeriodNavigator(title: "Tháng \(c.month ?? 0), \(String(c.year ?? 0))", subtitle: subtitle,
                        canGoBack: monthOffset < maxOffset, canGoForward: monthOffset > 0) { step in
            monthOffset += step
            selectedDay = nil
        }
        MonthGrid(interval: interval, calendar: calendar, now: now, selected: $selectedDay) { state(of: $0, in: period, now: now) }
        summary(period, comparison: comparisonText(now: now))
        if let day = selectedDay {
            let dayData = PeriodData(sessions: period.sessions.filter { calendar.isDate($0.startedAt, inSameDayAs: day) },
                                     slots: period.slots.filter { $0.date == local(day) })
            let list = entries(dayData, now: now)
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "\(Fmt.weekdayLong(Fmt.isoWeekday(day, calendar: calendar))), \(Fmt.dayMonthShort(day))")
                    Button("Xem cả tháng") { selectedDay = nil }.buttonStyle(.caliLink)
                }
                if list.isEmpty { EmptyPeriod(text: "Ngày nghỉ, không có buổi tập") }
                ForEach(list) { entryRow($0) }
            }
        } else {
            let list = entries(period, now: now)
            if list.isEmpty { EmptyPeriod(text: monthOffset == 0 ? "Tháng này chưa có buổi tập nào" : "Tháng này không có buổi tập nào") }
            let weeks = Dictionary(grouping: list) { calendar.dateInterval(of: .weekOfYear, for: $0.date(in: calendar))!.start }
            ForEach(weeks.keys.sorted(by: >), id: \.self) { start in
                let end = calendar.date(byAdding: .day, value: 6, to: start)!
                let slots = period.slots.filter { $0.date >= local(start) && $0.date <= local(end) }
                let done = (weeks[start] ?? []).filter { $0.isDoneSession }.count
                // Month view groups by week and shows done/scheduled per week (docs/02 §3.1).
                entryList(title: Fmt.range(start, end), weeks[start, default: []], empty: "",
                          trailing: slots.isEmpty ? nil : "\(done)/\(slots.count) buổi")
            }
        }
    }

    // MARK: Entries

    /// A row of the list: a recorded session, a scheduled one that was missed, or today's that is still open.
    private enum Entry: Identifiable {
        case session(CompletedSession)
        case missed(ScheduleSlot)
        case today(ScheduleSlot)

        var id: String {
            switch self {
            case .session(let s): "s-\(s.id)"
            case .missed(let s): "m-\(s.lineageId)-\(s.date)-\(s.workoutTitle)"
            case .today(let s): "t-\(s.lineageId)-\(s.date)-\(s.workoutTitle)"
            }
        }

        var isDoneSession: Bool {
            if case .session(let s) = self { return s.status == .completed }
            return false
        }

        func date(in calendar: Calendar) -> Date {
            switch self {
            case .session(let s): s.startedAt
            case .missed(let s), .today(let s): s.date.startOfDay(in: calendar.timeZone)
            }
        }
    }

    private func entries(_ period: PeriodData, now: Date) -> [Entry] {
        let today = store.today(now)
        var list = period.sessions.map(Entry.session)
        for slot in period.slots {
            if slot.outcome == .missed { list.append(.missed(slot)) }
            if slot.outcome == .pending, slot.date == today { list.append(.today(slot)) }
        }
        return list.sorted { $0.date(in: calendar) > $1.date(in: calendar) }
    }

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        switch entry {
        case .session(let session): HistoryRow(session: session)
        case .missed(let slot): MissedRow(slot: slot)
        case .today(let slot): TodayRow(slot: slot) { tab = .today }
        }
    }

    @ViewBuilder
    private func entryList(title: String, _ list: [Entry], empty: String, trailing: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: title, trailing: trailing ?? "\(list.filter { if case .session = $0 { true } else { false } }.count) buổi")
            if list.isEmpty && !empty.isEmpty { EmptyPeriod(text: empty) }
            ForEach(list) { entryRow($0) }
        }
    }

    // MARK: Totals and comparison

    private func summary(_ period: PeriodData, comparison: String) -> some View {
        let totals = PeriodTotals(period.sessions)
        let scheduled = period.slots.count
        return VStack(alignment: .leading, spacing: Spacing.s) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.m)], spacing: Spacing.m) {
                StatTile(value: "\(totals.sessionsDone)", label: "Buổi xong", systemImage: "checkmark.circle", tint: .caliAccent)
                StatTile(value: "\(totals.setsDone)", label: "Set đạt", systemImage: "square.stack.3d.up")
                StatTile(value: "\(totals.minutes)", label: "Phút", systemImage: "clock")
                // Kilometres are their own tile: sets and distance are never added together.
                if totals.distanceMeters > 0 {
                    StatTile(value: Fmt.km(totals.distanceMeters), label: "Quãng đường", systemImage: "figure.run")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                if scheduled > 0 {
                    // Planned sessions only: a free session is not counted against the schedule.
                    Text("Theo lịch: \(period.slots.filter { $0.outcome == .completed }.count)/\(scheduled) buổi")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(Color.caliSecondary)
                }
                if totals.sessionsStoppedEarly > 0 {
                    Text("\(totals.sessionsStoppedEarly) dừng sớm").font(.footnote).foregroundStyle(Color.caliSecondary)
                }
                Text(comparison)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
            }
            .padding(.horizontal, Spacing.xs)
        }
    }

    /// docs/02 §3.1: the period in progress is compared with the same elapsed days of the one before, today left out.
    private func comparisonText(now: Date) -> String {
        let offset = mode == .week ? weekOffset : monthOffset
        let oldest = store.history.filter(matchesFilter).map(\.startedAt).min()
        switch HistoryPeriods.comparison(kind, offset: offset, oldest: oldest, now: now, calendar: calendar) {
        case .firstPeriod:
            return "Kỳ đầu tiên có dữ liệu"
        case .notEnoughDays:
            return "Chưa có ngày nào trôi qua để so với \(mode == .week ? "tuần" : "tháng") trước"
        case .compare(let current, let previous, let days):
            let label: String
            if let days {
                if mode == .week {
                    label = "cùng kỳ tuần trước (T2–\(Fmt.weekdayShort(days)))"
                } else {
                    label = "cùng kỳ tháng trước (1–\(days)/\(calendar.component(.month, from: previous.start)))"
                }
            } else {
                label = mode == .week ? "tuần trước" : "tháng trước"
            }
            let a = PeriodTotals(sessions(current)), b = PeriodTotals(sessions(previous))
            var parts = ["\(Self.signed(a.sessionsDone - b.sessionsDone)) buổi", "\(Self.signed(a.setsDone - b.setsDone)) set",
                         "\(Self.signed(a.minutes - b.minutes)) phút"]
            if a.distanceMeters > 0 || b.distanceMeters > 0 {
                parts.append("\(Self.signedKm(a.distanceMeters - b.distanceMeters))")
            }
            return "So với \(label): " + parts.joined(separator: " · ")
        }
    }

    static func signed(_ n: Int) -> String { n > 0 ? "+\(n)" : n < 0 ? "−\(-n)" : "±0" }

    static func signedKm(_ meters: Int) -> String {
        meters == 0 ? "±0 km" : (meters > 0 ? "+" : "−") + Fmt.km(abs(meters))
    }
}

/// A planned session whose day passed with no completed session: dashed, not tappable, never red (UX-10).
private struct MissedRow: View {
    @Environment(AppStore.self) private var store
    let slot: ScheduleSlot

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "minus.circle")
                .font(.title3)
                .foregroundStyle(Color.caliSecondary)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(slot.workoutTitle).font(.headline).foregroundStyle(Color.caliText).lineLimit(1)
                Text("\(Fmt.weekdayLong(slot.date.isoWeekday)), \(Fmt.dayMonthShort(slot.date.startOfDay(in: store.calendar.timeZone)))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
                HStack(spacing: 6) {
                    TagChip(text: "Bỏ lỡ", systemImage: "minus")
                    Label(slot.planTitle, systemImage: "calendar").font(.caption).foregroundStyle(Color.caliSecondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Color.caliSecondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bỏ lỡ: \(slot.workoutTitle), giáo án \(slot.planTitle)")
    }
}

/// Today's planned session that has not been done; opens the Today tab.
private struct TodayRow: View {
    let slot: ScheduleSlot
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "figure.run.circle")
                    .font(.title3)
                    .foregroundStyle(Color.caliAccentInk)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(slot.workoutTitle).font(.headline).foregroundStyle(Color.caliText).lineLimit(1)
                    HStack(spacing: 6) {
                        TagChip(text: "Hôm nay", systemImage: "calendar.badge.clock", tint: .caliAccentInk)
                        Label(slot.planTitle, systemImage: "calendar").font(.caption).foregroundStyle(Color.caliSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Color.caliSecondary)
            }
            .caliCard(padding: Spacing.m)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hôm nay: \(slot.workoutTitle), giáo án \(slot.planTitle). Mở Hôm nay")
    }
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
    let state: (Date) -> HistoryDayState

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
                HStack(spacing: 6) {
                    Circle().strokeBorder(Color.caliSecondary, style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).frame(width: 8, height: 8)
                    Text("Bỏ lỡ")
                }
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
                dot(st)
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

    /// Status never relies on colour alone: a missed day is a hollow dashed ring, a planned one a filled dot.
    @ViewBuilder
    private func dot(_ st: HistoryDayState) -> some View {
        switch st {
        case .stoppedEarly: Circle().fill(Color.caliWarning).frame(width: 5, height: 5)
        case .planned: Circle().fill(Color.caliSecondary).frame(width: 5, height: 5)
        case .today: Circle().fill(Color.caliAccent).frame(width: 5, height: 5)
        case .missed:
            Circle().strokeBorder(Color.caliSecondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 6, height: 6)
        case .rest, .done: Circle().fill(Color.clear).frame(width: 5, height: 5)
        }
    }

    private func label(_ st: HistoryDayState) -> String {
        switch st {
        case .done: ", hoàn thành"
        case .stoppedEarly: ", dừng sớm"
        case .planned: ", theo lịch"
        case .today: ", hôm nay có lịch"
        case .missed: ", bỏ lỡ"
        case .rest: ""
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
    @Environment(AppStore.self) private var store
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
            ForEach(sets.compactMap { set in store.criteriaSummary(of: set).map { (set.setIndex, $0) } }, id: \.0) { index, text in
                Text("Set \(index): \(text)")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
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

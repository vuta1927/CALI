import CaliDomain
import SwiftUI

/// One plan (MP-08 detail, mockup `overview`): status, schedule and lifecycle actions.
///
/// The Lộ trình / Tiến bộ segments, phase card and goals come with IOS-015; program length (and with it
/// "Tuần x/y" and the late-start choice) comes from phases (CON-005).
struct PlanDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let lineageId: UUID

    @State private var renaming = false
    @State private var title = ""
    @State private var renameError: String?
    @State private var ending = false
    @State private var deleting = false
    @State private var newWorkout: PlannedWorkout?
    @State private var starting = false
    @State private var cloning: PlanDraft?
    @State private var recordingRace = false

    var body: some View {
        if let plan = store.plan(lineageId), plan.deletedAt == nil {
            content(plan)
        } else {
            ContentUnavailableView("Không tìm thấy giáo án", systemImage: "calendar.badge.exclamationmark")
                .caliScreen()
        }
    }

    private func content(_ plan: WorkoutPlan) -> some View {
        let now = Date()
        let status = store.status(of: plan, now: now)
        let editable = store.isEditable(plan, now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header(plan, status: status)
                if store.isFinished(plan, now: now) {
                    FinishedPlanCard(plan: plan, onEnd: { ending = true }, onRepeat: { cloning = repeatDraft(plan) })
                } else {
                    statusCard(plan, status: status)
                }
                if store.canRecordRaceResult(plan, now: now) || !store.raceResults(of: plan).isEmpty {
                    RaceResultCard(plan: plan, canRecord: store.canRecordRaceResult(plan, now: now)) { recordingRace = true }
                }
                if status == .active { weekSection(plan, now: now) }
                schedule(plan, now: now, editable: editable)
                SampleFooter(showsSample: store.showsSampleData)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle(plan.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { menu(plan, status: status, editable: editable) }
        }
        .sheet(isPresented: $renaming) { renameSheet(plan) }
        .sheet(isPresented: $ending) { EndPlanSheet(plan: plan) }
        .sheet(item: $newWorkout) { WorkoutEditorView(workout: $0, lineageId: plan.lineageId) }
        .sheet(item: $cloning) { draft in PlanCreateView(initial: draft) }
        .sheet(isPresented: $recordingRace) {
            RaceResultSheet(plan: plan, plannedDistance: store.raceWorkout(of: plan).flatMap { pair in
                if case .distance(let meters, _) = pair.item.target { meters } else { nil }
            })
        }
        .navigationDestination(isPresented: $starting) { PlanStartView(lineageId: plan.lineageId) }
        .confirmationDialog("Xoá \"\(plan.title)\"?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Xoá giáo án", role: .destructive) { if store.deletePlan(plan.lineageId) { dismiss() } }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Lịch sử các buổi đã tập vẫn được giữ, kèm nhãn \"(đã xoá)\". Nên lưu trữ nếu bạn có thể dùng lại giáo án này.")
        }
    }

    private func header(_ plan: WorkoutPlan, status: PlanStatus) -> some View {
        let scheduled = plan.slots.count
        return VStack(alignment: .leading, spacing: Spacing.m) {
            Text(plan.title)
                .font(.largeTitle.bold())
                .foregroundStyle(Color.caliText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    PlanStatusChip(status: status)
                    TagChip(text: "\(scheduled) buổi / tuần", systemImage: "calendar")
                    if let discipline = plan.primaryDiscipline {
                        TagChip(text: discipline.label, systemImage: discipline.systemImage, tint: .caliAccentInk)
                    }
                    if store.showsSampleData { MockBadge() }
                }
            }
            if let line = subtitle(plan, status: status) {
                Text(line)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
            }
        }
    }

    /// "Tuần 2 · bắt đầu 3/11", "Giải 10 km · 14/3/2027 · còn 125 ngày", "Bắt đầu từ 16/11".
    private func subtitle(_ plan: WorkoutPlan, status: PlanStatus) -> String? {
        let today = store.today()
        var parts: [String] = []
        if plan.kind == .event, let eventDate = plan.eventDate {
            parts.append("\(plan.eventName ?? "Sự kiện") · \(Fmt.shortDate(eventDate))")
            if let days = store.daysUntilEvent(plan), days >= 0 { parts.append(days == 0 ? "hôm nay" : "còn \(days) ngày") }
        }
        switch status {
        case .active:
            let week = PlanSchedule.currentWeek(program: plan.program, activations: plan.activations, today: today)
            if week.state == .inProgress, plan.kind == .weekly { parts.insert("Tuần \(week.week)", at: 0) }
        case .scheduled:
            if let from = plan.activations.map(\.fromDate).filter({ $0 > today }).min() { parts.append("Bắt đầu từ \(Fmt.shortDate(from))") }
        default: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusCard(_ plan: WorkoutPlan, status: PlanStatus) -> some View {
        switch status {
        case .draft, .paused:
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(status == .draft ? "Giáo án chưa bắt đầu" : "Giáo án đang tạm dừng")
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                Text(status == .draft
                     ? "Chọn ngày bắt đầu để đưa các buổi vào Hôm nay. Trước ngày đó không có buổi nào bị tính là bỏ lỡ."
                     : "Những ngày tạm dừng không tính là bỏ lỡ. Tiếp tục để quay lại đúng tuần đang dở.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
                Button(status == .draft ? "Bắt đầu theo" : "Tiếp tục", systemImage: "play.fill") { starting = true }
                    .buttonStyle(.caliPrimary)
                    .disabled(plan.slots.isEmpty)
                if plan.slots.isEmpty {
                    Text("Thêm ít nhất một buổi tập vào lịch tuần trước.")
                        .font(.caption)
                        .foregroundStyle(Color.caliSecondary)
                }
            }
            .caliCard()
        case .ended, .archived:
            VStack(alignment: .leading, spacing: Spacing.m) {
                Label(status == .ended ? endedLine(plan) : "Giáo án đã lưu trữ", systemImage: status.systemImage)
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                if let note = plan.endNote {
                    Text(note).font(.footnote).foregroundStyle(Color.caliSecondary)
                }
                Text("Chỉ xem. Muốn sửa, hãy nhân bản thành giáo án mới.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
                Button("Nhân bản để sửa", systemImage: "plus.square.on.square") { cloning = repeatDraft(plan) }
                    .buttonStyle(.caliPrimary)
                Button(status == .archived ? "Khôi phục" : "Lưu trữ", systemImage: status == .archived ? "tray.and.arrow.up" : "archivebox") {
                    store.setArchived(plan.lineageId, status != .archived)
                }
                .buttonStyle(.caliSecondary)
            }
            .caliCard()
        default:
            EmptyView()
        }
    }

    private func endedLine(_ plan: WorkoutPlan) -> String {
        let reason = plan.endReason == .completed ? "Hoàn thành" : "Dừng sớm"
        return plan.endedAt.map { "Đã kết thúc · \(reason) · \(Fmt.dayMonthShort($0))" } ?? "Đã kết thúc · \(reason)"
    }

    /// MP-03: a copy keeps kind and discipline; an event copy needs a new event day.
    private func repeatDraft(_ plan: WorkoutPlan) -> PlanDraft {
        PlanDraft(method: .clone(plan.lineageId), title: plan.title, discipline: plan.primaryDiscipline ?? .calisthenics,
                  kind: plan.kind, eventName: plan.eventName ?? "", eventDate: nil)
    }

    private func menu(_ plan: WorkoutPlan, status: PlanStatus, editable: Bool) -> some View {
        Menu {
            if editable {
                Button("Sửa tên giáo án", systemImage: "pencil") { title = plan.title; renaming = true }
            }
            if status == .active || status == .scheduled {
                Button("Tạm dừng", systemImage: "pause.circle") { store.pausePlan(plan.lineageId) }
            }
            if [.active, .scheduled, .paused].contains(status) {
                Button("Kết thúc giáo án", systemImage: "flag.checkered") { ending = true }
            }
            Button("Nhân bản", systemImage: "plus.square.on.square") { cloning = repeatDraft(plan) }
            if [.draft, .paused, .ended].contains(status) {
                Button("Lưu trữ", systemImage: "archivebox") { store.setArchived(plan.lineageId, true) }
            }
            Button("Xoá giáo án", systemImage: "trash", role: .destructive) { deleting = true }
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: minTapTarget, minHeight: minTapTarget)
        }
        .accessibilityLabel("Tuỳ chọn giáo án")
    }

    private func renameSheet(_ plan: WorkoutPlan) -> some View {
        NavigationStack {
            Form {
                TextField("Tên giáo án", text: $title)
                if let renameError { Text(renameError).foregroundStyle(Color.caliError) }
            }
            .navigationTitle("Sửa tên")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { renaming = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        if store.renamePlan(plan.lineageId, title: title) { renameError = nil; renaming = false }
                        else { renameError = store.alertMessage; store.alertMessage = nil }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func weekSection(_ plan: WorkoutPlan, now: Date) -> some View {
        let monday = store.monday(of: store.today(now))
        let items = store.scheduledItems(from: monday, through: monday.adding(days: 6), now: now).filter { $0.plan.lineageId == plan.lineageId }
        let done = store.sessionsThisWeek(now: now).filter { $0.planLineageId == plan.lineageId && $0.status == .completed }
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Tuần này", trailing: "\(items.filter(\.isDone).count)/\(items.count) buổi")
            HStack(spacing: Spacing.m) {
                StatTile(value: "\(done.count)", label: "Buổi đã tập", systemImage: "checkmark.circle", tint: .caliAccent)
                StatTile(value: "\(done.reduce(0) { $0 + $1.completedSetCount })", label: "Set xong", systemImage: "square.stack.3d.up")
                StatTile(value: "\(done.reduce(0) { $0 + $1.durationMinutes })", label: "Phút tập", systemImage: "clock")
            }
        }
    }

    private func schedule(_ plan: WorkoutPlan, now: Date, editable: Bool) -> some View {
        let today = store.today(now)
        let monday = store.monday(of: today)
        let thisWeek = store.scheduledItems(from: monday, through: monday.adding(days: 6), now: now).filter { $0.plan.lineageId == plan.lineageId }
        let active = store.status(of: plan, now: now) == .active
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title: "Lịch tuần", trailing: "Chạm để xem buổi")
            ForEach(1...7, id: \.self) { day in
                if let workout = plan.workouts.first(where: { $0.weekday == day }) {
                    NavigationLink {
                        WorkoutDetailView(workoutId: workout.id)
                    } label: {
                        PlanDayRow(day: day, isToday: active && day == today.isoWeekday, workout: workout,
                                   done: thisWeek.contains { $0.workout.id == workout.id && $0.isDone })
                    }
                    .buttonStyle(.plain)
                } else {
                    RestDayRow(day: day, isToday: active && day == today.isoWeekday, canAdd: editable) {
                        newWorkout = PlannedWorkout(id: UUID(), weekday: day, title: "Buổi tập mới", focus: "", exercises: [])
                    }
                }
            }
        }
    }
}

/// Status chip with label and icon (never colour alone, docs/19 §7).
struct PlanStatusChip: View {
    let status: PlanStatus

    var body: some View {
        TagChip(text: status.label, systemImage: status.systemImage, tint: tint, filled: status == .active)
            .fixedSize()
    }

    private var tint: Color {
        switch status {
        case .active: .caliAccent
        case .scheduled: .caliAccentInk
        case .paused: .caliWarning
        default: .caliSecondary
        }
    }
}

/// MP-07: the event day has passed (or the program is over). Nothing changes until the user chooses.
struct FinishedPlanCard: View {
    @Environment(AppStore.self) private var store
    let plan: WorkoutPlan
    let onEnd: () -> Void
    let onRepeat: () -> Void

    var body: some View {
        let event = plan.kind == .event
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label(event ? "Đã qua ngày sự kiện" : "Đã hết lộ trình", systemImage: "flag.fill")
                .font(.title3.bold())
                .foregroundStyle(Color.caliText)
            if event, let date = plan.eventDate {
                Text("\(plan.eventName ?? "Sự kiện") · \(Fmt.day(date))")
                    .font(.subheadline)
                    .foregroundStyle(Color.caliSecondary)
            }
            Text("Giáo án không tự kết thúc. Không có buổi theo lịch hay buổi bỏ lỡ nào cho tới khi bạn chọn.")
                .font(.footnote)
                .foregroundStyle(Color.caliSecondary)
            Button("Kết thúc giáo án", systemImage: "flag.checkered", action: onEnd)
                .buttonStyle(.caliPrimary)
            HStack(spacing: Spacing.s) {
                if event {
                    Button("Kéo dài") { store.extendPlan(plan.lineageId) }
                        .buttonStyle(.caliSecondary)
                        .accessibilityHint("Chuyển thành giáo án theo tuần và tiếp tục theo")
                }
                Button("Lặp lại", action: onRepeat)
                    .buttonStyle(.caliSecondary)
                    .accessibilityHint("Tạo giáo án mới từ giáo án này")
            }
        }
        .caliCard()
    }
}

/// MP-07 (IOS-014): the event day has come; record the official result, entered by hand.
struct RaceResultCard: View {
    @Environment(AppStore.self) private var store
    let plan: WorkoutPlan
    let canRecord: Bool
    let onRecord: () -> Void

    var body: some View {
        let results = store.raceResults(of: plan)
        VStack(alignment: .leading, spacing: Spacing.m) {
            Label("Kết quả thi", systemImage: "medal")
                .font(.headline)
                .foregroundStyle(Color.caliText)
            if results.isEmpty {
                Text("Nhập quãng đường và thời gian chính thức. Pace được tự tính.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            }
            ForEach(results) { session in
                if let set = session.sets.first(where: { $0.distanceMeters != nil }) {
                    NavigationLink { SessionDetailView(session: session) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Fmt.actual(set)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.caliText)
                                Text(Fmt.fullDate(session.finishedAt)).font(.caption).foregroundStyle(Color.caliSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.caliSecondary)
                        }
                        .frame(minHeight: minTapTarget)
                    }
                    .buttonStyle(.plain)
                }
            }
            if canRecord && results.isEmpty {
                Button("Ghi kết quả thi", systemImage: "square.and.pencil", action: onRecord)
                    .buttonStyle(.caliPrimary)
            } else if canRecord {
                Button("Ghi thêm kết quả", systemImage: "square.and.pencil", action: onRecord)
                    .buttonStyle(.caliSecondary)
            }
        }
        .caliCard()
    }
}

/// docs/19 §4.3 "Kết thúc": reason and an optional note (≤ 500 characters).
struct EndPlanSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: WorkoutPlan
    @State private var reason: PlanEndReason = .completed
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Lý do", selection: $reason) {
                        Text("Hoàn thành").tag(PlanEndReason.completed)
                        Text("Dừng sớm").tag(PlanEndReason.stopped)
                    }
                    .pickerStyle(.segmented)
                    TextField("Ghi chú (không bắt buộc)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("Giáo án chuyển vào \"Đã kết thúc\" và chỉ xem được. Lịch sử và tiến bộ được giữ nguyên. \(note.count)/\(AppStore.endNoteLimit)")
                }
                if let error { Text(error).foregroundStyle(Color.caliError) }
            }
            .navigationTitle("Kết thúc \(plan.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kết thúc") {
                        if store.endPlan(plan.lineageId, reason: reason, note: note) { dismiss() }
                        else { error = store.alertMessage; store.alertMessage = nil }
                    }
                    .disabled(note.count > AppStore.endNoteLimit)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
    var canAdd = true
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
            if canAdd {
                Button(action: onAdd) {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(Color.caliAccentInk)
                        .frame(width: minTapTarget, height: minTapTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Thêm buổi vào \(Fmt.weekdayLong(day))")
            }
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
                if let plan = store.plan(containing: workoutId), store.isEditable(plan) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Sửa buổi tập", systemImage: "pencil") { editing = true }
                        Button("Xóa buổi tập", systemImage: "trash", role: .destructive) { deleting = true }
                    } label: { Image(systemName: "pencil").frame(minWidth: minTapTarget, minHeight: minTapTarget) }
                    .accessibilityLabel("Sửa buổi tập")
                }
                }
            }
            .confirmationDialog("Xóa buổi tập này?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Xóa buổi tập", role: .destructive) { if store.deleteWorkout(workoutId) { dismiss() } }
                Button("Hủy", role: .cancel) {}
            } message: { Text("Lịch sử và buổi đang tập được giữ lại.") }
            .sheet(isPresented: $editing) {
                if let plan = store.plan(containing: workoutId) {
                    WorkoutEditorView(workout: workout, lineageId: plan.lineageId)
                }
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

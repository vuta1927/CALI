import CaliDomain
import SwiftUI

/// Result entry for one set (UX-07, ADR-009). Nothing is counted until the user taps "Lưu set";
/// when the domain could not measure the duration (late reconcile / clock change) the field starts
/// empty and must be filled in by the user.
struct ResultFormView: View {
    let model: WorkoutPlayerModel

    @State private var status: SetStatus = .completed
    @State private var reps: Int?
    @State private var seconds: Double?
    /// CON-006: kilograms for a load set, kept exactly as entered (never rounded).
    @State private var loadKg: Decimal?
    /// CON-004: running segment typed by hand (km + h:mm:ss); pace is shown, never stored.
    @State private var run = RunEntry()
    @State private var rpe: Int?
    @State private var note = ""
    @State private var showSkipReasons = false
    @State private var didPrefill = false
    @FocusState private var focused: Bool

    private var draft: ResultDraft? { model.state.pendingResult }
    private var target: Prescription? { model.currentExecution?.target }
    private var deadlineReached: Bool {
        if case .targetDeadlineReached? = draft?.endReason { true } else { false }
    }
    private var durationUnknown: Bool { draft != nil && draft?.suggestedActualMs == nil }

    var body: some View {
        PlayerScaffold {
            Text("Nhập kết quả set")
                .font(.headline)
                .foregroundStyle(Color.caliText)
            header
            if let target {
                inputs(for: target)
                statusPicker(for: target)
            }
            rpePicker
            noteField
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: "info.circle").foregroundStyle(Color.caliSecondary)
                Text("COAMI không tự đánh dấu set hoàn thành khi hết giờ. Set chỉ được ghi khi bạn bấm Lưu.")
                    .font(.footnote)
                    .foregroundStyle(Color.caliSecondary)
            }
            .caliCard(padding: Spacing.m)
        } actions: {
            HStack(spacing: Spacing.m) {
                Button("Bỏ qua set") { showSkipReasons = true }
                    .buttonStyle(.caliSecondary)
                Button("Lưu", systemImage: "checkmark", action: save)
                    .buttonStyle(.caliPrimary)
                    .disabled(!canSave)
            }
        }
        .skipReasonDialog(isPresented: $showSkipReasons) { model.skipCurrentSet(reason: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Xong") { focused = false }
            }
        }
        .onAppear(perform: prefill)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if deadlineReached {
                Label("Đã hết thời gian — xác nhận kết quả", systemImage: "bell.badge")
                    .font(.headline)
                    .foregroundStyle(Color.caliWarning)
            }
            HStack(spacing: Spacing.m) {
                PosterThumb(exercise: model.currentExercise, size: 72)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(model.currentExercise?.name ?? "")
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                    if let execution = model.currentExecution {
                        Text("Set \(draft?.key.setIndex ?? model.state.currentSetIndex)/\(execution.setCount) · Mục tiêu \(Fmt.target(execution.target))")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.caliSecondary)
                        HStack(spacing: 6) {
                            let discipline = Discipline(types: [execution.target.type])
                            TagChip(text: discipline.label, systemImage: discipline.systemImage)
                            if let draft, draft.measuredElapsedMs > 0 {
                                TagChip(text: "Đo được \(Fmt.clock(ms: draft.measuredElapsedMs))", systemImage: "clock")
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .caliCard(padding: Spacing.m)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func inputs(for target: Prescription) -> some View {
        switch target {
        case .staticHold(let hold):
            durationInput(title: "Thời gian giữ thực tế", targetSeconds: hold)
        case .reps(let lo, let hi):
            RepsInput(title: "Số lần thực tế", value: $reps, hint: "Mục tiêu \(lo)–\(hi) lần", focused: $focused)
        case .timedReps(let time):
            RepsInput(title: "Số lần thực tế", value: $reps, hint: "Trong khoảng \(time) giây", focused: $focused)
            durationInput(title: "Thời gian tập thực tế", targetSeconds: time)
        case .interval(let work, _):
            durationInput(title: "Thời gian tập thực tế", targetSeconds: work)
        case .skillAttempt:
            EmptyView()
        case .load(let lo, let kg):
            KgInput(title: "Mức tạ thực tế", value: $loadKg, targetKg: kg, focused: $focused)
            RepsInput(title: "Số lần thực tế", value: $reps, hint: "Mục tiêu \(lo) lần", focused: $focused)
        case .distance, .duration:
            if durationUnknown {
                Label("COAMI không đo được chính xác thời gian chặng này. Hãy nhập thời gian bạn thực sự chạy.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.caliWarning)
            }
            RunEntryFields(entry: $run, distanceOptional: target.type == .duration, focused: $focused)
            Label("Nhập tay", systemImage: "pencil")
                .font(.caption)
                .foregroundStyle(Color.caliSecondary)
        }
    }

    private func durationInput(title: String, targetSeconds: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if durationUnknown {
                Label("COAMI không đo được chính xác (app ở nền hoặc giờ thiết bị thay đổi). Hãy nhập thời gian bạn thực sự tập.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.caliWarning)
            }
            SecondsInput(title: title, value: $seconds, targetSeconds: targetSeconds, focused: $focused)
        }
    }

    @ViewBuilder
    private func statusPicker(for target: Prescription) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(target.type == .skillAttempt ? "Kết quả lần thử" : "Đánh giá set", systemImage: "star")
                .font(.headline)
                .foregroundStyle(Color.caliText)
                .labelStyle(AccentIconLabelStyle())
            HStack(spacing: Spacing.s) {
                FilterChip(title: target.type == .skillAttempt ? "Thành công" : "Đạt mục tiêu",
                           systemImage: "checkmark", isSelected: status == .completed) { status = .completed }
                FilterChip(title: "Chưa đạt", systemImage: "xmark", isSelected: status == .failed) { status = .failed }
            }
        }
        .caliCard()
    }

    private var rpePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Label("Mức gắng sức (RPE)", systemImage: "flame")
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                    .labelStyle(AccentIconLabelStyle())
                Spacer()
                Text(rpe.map(Self.rpeLabel) ?? "Không bắt buộc")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 5), spacing: Spacing.s) {
                ForEach(1...10, id: \.self) { value in
                    Button {
                        rpe = rpe == value ? nil : value
                    } label: {
                        Text("\(value)")
                            .font(.headline.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: minTapTarget)
                            .foregroundStyle(rpe == value ? Color.caliOnAccent : Color.caliText)
                            .background(rpe == value ? Color.caliAccent : Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("RPE \(value), \(Self.rpeLabel(value))")
                    .accessibilityAddTraits(rpe == value ? .isSelected : [])
                }
            }
            Text("Không bắt buộc.").font(.caption).foregroundStyle(Color.caliSecondary)
        }
        .caliCard()
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("Ghi chú", systemImage: "square.and.pencil")
                .font(.headline)
                .foregroundStyle(Color.caliText)
                .labelStyle(AccentIconLabelStyle())
            TextField("Ví dụ: hơi mỏi cổ tay", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .focused($focused)
                .padding(Spacing.m)
                .frame(minHeight: minTapTarget)
                .background(Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip))
                .foregroundStyle(Color.caliText)
        }
        .caliCard()
    }

    // MARK: Logic

    private var needsReps: Bool {
        switch target {
        case .reps, .timedReps, .load: true
        default: false
        }
    }

    private var needsLoad: Bool {
        if case .load? = target { true } else { false }
    }

    private var needsDuration: Bool {
        switch target {
        case .staticHold, .timedReps, .interval: true
        default: false
        }
    }

    private var isRunning: Bool { target?.running != nil }

    private var canSave: Bool {
        if isRunning {
            // Completed needs what pace (distance) or the segment (duration) requires; the domain re-checks bounds.
            guard !run.hasInvalidTime else { return false }
            if status == .failed { return true }
            return (run.durationSeconds ?? 0) > 0 && (target?.type == .duration || (run.distanceMeters ?? 0) > 0)
        }
        return (!needsReps || reps != nil) && (!needsDuration || seconds != nil) && (!needsLoad || loadKg != nil)
    }

    private func prefill() {
        guard !didPrefill, let draft else { return }
        didPrefill = true
        if let suggested = draft.suggestedActualMs {
            seconds = (Double(suggested) / 100).rounded() / 10
        }
        if case .reps(let lo, _)? = target { reps = lo }
        if case .load(let r, let kg)? = target {
            reps = r
            loadKg = kg
        }
        // Running: time from the measured segment, distance from the plan; both stay editable and nothing
        // is saved until "Lưu".
        if isRunning {
            // Under a second measured (stopped right away) is not a time worth suggesting.
            let measured = draft.suggestedActualMs.map { Int(($0 + 500) / 1000) }.flatMap { $0 > 0 ? $0 : nil }
            if case .distance(let meters, _)? = target { run = RunEntry(distanceMeters: meters, durationSeconds: measured) }
            else { run = RunEntry(distanceMeters: nil, durationSeconds: measured) }
        }
        if case .staticHold(let hold)? = target, let s = seconds, s + 0.05 < Double(hold) {
            status = .failed
        }
    }

    private func save() {
        focused = false
        let ms = seconds.map { Int64(($0 * 1000).rounded()) }
        model.confirm(
            status: status,
            reps: needsReps ? reps : nil,
            holdMs: target?.type == .staticHold ? ms : nil,
            workMs: (target?.type == .timedReps || target?.type == .interval) ? ms : nil,
            rpe: rpe,
            note: note,
            loadKg: needsLoad ? loadKg : nil,
            distanceMeters: isRunning ? run.distanceMeters : nil,
            durationSeconds: isRunning ? run.durationSeconds : nil
        )
    }

    static func rpeLabel(_ value: Int) -> String {
        switch value {
        case ...4: "Nhẹ"
        case 5...6: "Vừa"
        case 7...8: "Nặng"
        case 9: "Rất nặng"
        default: "Tối đa"
        }
    }
}

// MARK: - Inputs

private struct SecondsInput: View {
    let title: String
    @Binding var value: Double?
    let targetSeconds: Int
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                Spacer()
                Button("= mục tiêu \(targetSeconds) giây") { value = Double(targetSeconds) }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: minTapTarget)
            }
            HStack(spacing: Spacing.m) {
                CircleIconButton(systemImage: "minus", label: "Bớt 1 giây") {
                    value = max(0, (value ?? Double(targetSeconds)) - 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    TextField("—", value: $value, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .focused(focused)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.caliText)
                    Text("giây")
                        .font(.headline)
                        .foregroundStyle(Color.caliSecondary)
                }
                .frame(maxWidth: .infinity)
                CircleIconButton(systemImage: "plus", label: "Thêm 1 giây") {
                    value = (value ?? Double(targetSeconds) - 1) + 1
                }
            }
        }
        .caliCard()
        .accessibilityElement(children: .contain)
    }
}

private struct RepsInput: View {
    let title: String
    @Binding var value: Int?
    let hint: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                Spacer()
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
            }
            HStack(spacing: Spacing.m) {
                CircleIconButton(systemImage: "minus", label: "Bớt 1 lần") {
                    value = max(0, (value ?? 1) - 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    TextField("—", value: $value, format: .number)
                        .keyboardType(.numberPad)
                        .focused(focused)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.caliText)
                    Text("lần")
                        .font(.headline)
                        .foregroundStyle(Color.caliSecondary)
                }
                .frame(maxWidth: .infinity)
                CircleIconButton(systemImage: "plus", label: "Thêm 1 lần") {
                    value = (value ?? 0) + 1
                }
            }
        }
        .caliCard()
        .accessibilityElement(children: .contain)
    }
}

/// Kilogram entry for a load set (docs/18 §4, ADR-046: kg only). The ±2.5 kg buttons are a UI step
/// hint only: a typed value is kept exactly as entered, never rounded or snapped to the step. Values
/// with more than 2 decimals are rejected by the domain with a message, not silently fixed (ADR-062).
private struct KgInput: View {
    let title: String
    @Binding var value: Decimal?
    let targetKg: Decimal
    var focused: FocusState<Bool>.Binding

    private let step: Decimal = 2.5

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                Spacer()
                Button("= mục tiêu \(Fmt.loadKg(targetKg))") { value = targetKg }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: minTapTarget)
            }
            HStack(spacing: Spacing.m) {
                CircleIconButton(systemImage: "minus", label: "Bớt 2,5 kg") {
                    value = max(0, (value ?? targetKg) - step)
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    // Shows up to 4 decimals so an over-precise entry stays visible until the domain rejects it.
                    TextField("—", value: $value, format: .number.precision(.fractionLength(0...4)))
                        .keyboardType(.decimalPad)
                        .focused(focused)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.caliText)
                    Text("kg")
                        .font(.headline)
                        .foregroundStyle(Color.caliSecondary)
                }
                .frame(maxWidth: .infinity)
                CircleIconButton(systemImage: "plus", label: "Thêm 2,5 kg") {
                    value = min(1000, (value ?? targetKg - step) + step)
                }
            }
        }
        .caliCard()
        .accessibilityElement(children: .contain)
    }
}

/// Headline label whose icon uses the accent ink (mockup criteria cards).
private struct AccentIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.s) {
            configuration.icon.foregroundStyle(Color.caliAccentInk)
            configuration.title
        }
    }
}

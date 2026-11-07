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
            header
            if let target {
                inputs(for: target)
                statusPicker(for: target)
            }
            rpePicker
            noteField
        } actions: {
            Button("Lưu set", systemImage: "checkmark.circle.fill", action: save)
                .buttonStyle(.caliPrimary)
                .disabled(!canSave)
            Button("Bỏ qua set này") { showSkipReasons = true }
                .buttonStyle(.caliQuiet)
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
        VStack(spacing: Spacing.m) {
            if deadlineReached {
                Label("Đã hết thời gian — xác nhận kết quả", systemImage: "bell.badge")
                    .font(.headline)
                    .foregroundStyle(Color.caliWarning)
            } else {
                Text("Nhập kết quả set")
                    .font(.headline)
                    .foregroundStyle(Color.caliSecondary)
            }
            HStack(spacing: Spacing.m) {
                PosterThumb(exercise: model.currentExercise, size: 72)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(model.currentExercise?.name ?? "")
                        .font(.title3.bold())
                        .foregroundStyle(Color.caliText)
                    if let execution = model.currentExecution {
                        Text("Set \(draft?.key.setIndex ?? model.state.currentSetIndex)/\(execution.setCount) · Mục tiêu \(Fmt.target(execution.target))")
                            .font(.subheadline)
                            .foregroundStyle(Color.caliAccent)
                    }
                    if let draft, draft.measuredElapsedMs > 0 {
                        Text("Đo được: \(Fmt.holdSeconds(ms: draft.measuredElapsedMs))")
                            .font(.caption)
                            .foregroundStyle(Color.caliSecondary)
                    }
                }
                Spacer()
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
        }
    }

    private func durationInput(title: String, targetSeconds: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if durationUnknown {
                Label("CALI không đo được chính xác (app ở nền hoặc giờ thiết bị thay đổi). Hãy nhập thời gian bạn thực sự tập.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.caliWarning)
            }
            SecondsInput(title: title, value: $seconds, targetSeconds: targetSeconds, focused: $focused)
        }
    }

    @ViewBuilder
    private func statusPicker(for target: Prescription) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(target.type == .skillAttempt ? "Kết quả lần thử" : "Đánh giá set")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.caliSecondary)
            HStack(spacing: Spacing.s) {
                FilterChip(title: target.type == .skillAttempt ? "Thành công" : "Đạt mục tiêu",
                           systemImage: "checkmark", isSelected: status == .completed) { status = .completed }
                FilterChip(title: "Chưa đạt", systemImage: "xmark", isSelected: status == .failed) { status = .failed }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rpePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Mức gắng sức (RPE)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.caliSecondary)
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
                            .foregroundStyle(rpe == value ? Color.caliCanvas : Color.caliText)
                            .background(rpe == value ? Color.caliAccent : Color.caliSurface, in: RoundedRectangle(cornerRadius: Radius.chip))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("RPE \(value), \(Self.rpeLabel(value))")
                    .accessibilityAddTraits(rpe == value ? .isSelected : [])
                }
            }
        }
    }

    private var noteField: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Ghi chú")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.caliSecondary)
            TextField("Ví dụ: hơi mỏi cổ tay", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .focused($focused)
                .padding(Spacing.m)
                .frame(minHeight: minTapTarget)
                .background(Color.caliSurface, in: RoundedRectangle(cornerRadius: Radius.chip))
                .foregroundStyle(Color.caliText)
        }
    }

    // MARK: Logic

    private var needsReps: Bool {
        switch target {
        case .reps, .timedReps: true
        default: false
        }
    }

    private var needsDuration: Bool {
        switch target {
        case .staticHold, .timedReps, .interval: true
        default: false
        }
    }

    private var canSave: Bool {
        (!needsReps || reps != nil) && (!needsDuration || seconds != nil)
    }

    private func prefill() {
        guard !didPrefill, let draft else { return }
        didPrefill = true
        if let suggested = draft.suggestedActualMs {
            seconds = (Double(suggested) / 100).rounded() / 10
        }
        if case .reps(let lo, _)? = target { reps = lo }
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
            note: note
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.caliSecondary)
                Spacer()
                Button("= mục tiêu \(targetSeconds)s") { value = Double(targetSeconds) }
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
            .caliCard(padding: Spacing.m)
        }
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.caliSecondary)
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
            .caliCard(padding: Spacing.m)
        }
        .accessibilityElement(children: .contain)
    }
}

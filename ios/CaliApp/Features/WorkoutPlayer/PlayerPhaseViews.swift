import CaliDomain
import SwiftUI

// MARK: - Ready (UX-05)

struct ReadyPhaseView: View {
    let model: WorkoutPlayerModel
    let onShowGuide: () -> Void

    @State private var showSkipReasons = false

    var body: some View {
        PlayerScaffold {
            PlayerExerciseHeader(model: model, posterHeight: 240)
            if let exercise = model.currentExercise, let cue = exercise.cues.first {
                Label(cue, systemImage: "lightbulb")
                    .font(.subheadline)
                    .foregroundStyle(Color.caliSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .caliCard(padding: Spacing.m)
            }
            Button("Xem hướng dẫn kỹ thuật", systemImage: "book", action: onShowGuide)
                .buttonStyle(.caliQuiet)
        } actions: {
            Button("Bắt đầu set", systemImage: "play.fill") { model.startSet() }
                .buttonStyle(.caliPrimary)
            Button("Bỏ qua set này") { showSkipReasons = true }
                .buttonStyle(.caliQuiet)
        }
        .skipReasonDialog(isPresented: $showSkipReasons) { model.skipCurrentSet(reason: $0) }
    }
}

// MARK: - Pre-countdown (UX-06)

struct CountdownPhaseView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer()
            PosterView(exercise: model.currentExercise, height: 160, showsLabel: false)
                .padding(.horizontal, Spacing.xxl)
            Text("Chuẩn bị")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.caliSecondary)
            TimerText(text: "\(Int(((model.remainingMs ?? 0) + 999) / 1000))", size: 140, tint: .caliAccent)
                .accessibilityLabel("Bắt đầu sau \(Int(((model.remainingMs ?? 0) + 999) / 1000)) giây")
            Text(model.currentExercise?.name ?? "")
                .font(.title2.bold())
                .foregroundStyle(Color.caliText)
            Spacer()
        }
        .padding(Spacing.l)
    }
}

// MARK: - Exercising (UX-06/07)

struct ActivePhaseView: View {
    let model: WorkoutPlayerModel

    @State private var showSkipReasons = false

    private var isTimed: Bool { model.currentExecution?.target.targetDurationSeconds != nil }

    var body: some View {
        PlayerScaffold {
            PosterView(exercise: model.currentExercise, height: 150, showsLabel: false)
            Text(model.currentExercise?.name ?? "")
                .font(.title2.bold())
                .foregroundStyle(Color.caliText)
            if let execution = model.currentExecution {
                Text("Set \(model.state.currentSetIndex)/\(execution.setCount) · \(Fmt.target(execution.target))")
                    .font(.headline)
                    .foregroundStyle(Color.caliAccent)
            }
            if isTimed {
                ZStack {
                    ProgressRing(progress: 1 - model.phaseProgress, lineWidth: 16)
                    VStack(spacing: Spacing.xs) {
                        TimerText(text: Fmt.countdown(ms: model.remainingMs ?? 0))
                        Text("còn lại")
                            .font(.subheadline)
                            .foregroundStyle(Color.caliSecondary)
                    }
                }
                .frame(width: 250, height: 250)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Còn lại \(Fmt.countdown(ms: model.remainingMs ?? 0))")
            } else {
                VStack(spacing: Spacing.xs) {
                    TimerText(text: Fmt.clock(ms: model.elapsedMs))
                    Text(openEndedHint)
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, Spacing.xl)
            }
        } actions: {
            Button(isTimed ? "Kết thúc sớm" : "Xong set", systemImage: "checkmark") { model.stopSet() }
                .buttonStyle(isTimed ? .caliSecondary : .caliPrimary)
            HStack(spacing: Spacing.m) {
                Button("Tạm dừng", systemImage: "pause.fill") { model.pause() }
                    .buttonStyle(.caliSecondary)
                Button("Bỏ qua") { showSkipReasons = true }
                    .buttonStyle(.caliQuiet)
            }
        }
        .skipReasonDialog(isPresented: $showSkipReasons) { model.skipCurrentSet(reason: $0) }
    }

    private var openEndedHint: String {
        switch model.currentExecution?.target {
        case .skillAttempt: "Thực hiện lần thử, bấm Xong set khi kết thúc"
        default: "Bấm Xong set khi bạn hoàn thành số lần"
        }
    }
}

// MARK: - Paused

struct PausedPhaseView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        PlayerScaffold {
            PlayerExerciseHeader(model: model, posterHeight: 160)
            VStack(spacing: Spacing.s) {
                Label("Đã tạm dừng", systemImage: "pause.circle.fill")
                    .font(.title3.bold())
                    .foregroundStyle(Color.caliWarning)
                if let remaining = model.state.pausedRemainingMs {
                    TimerText(text: Fmt.countdown(ms: remaining), tint: .caliSecondary)
                    Text("còn lại khi tiếp tục")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                } else {
                    TimerText(text: Fmt.clock(ms: model.state.accumulatedExerciseMs), tint: .caliSecondary)
                    Text("đã tập")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                }
            }
            .padding(.vertical, Spacing.l)
        } actions: {
            Button("Tiếp tục", systemImage: "play.fill") { model.resume() }
                .buttonStyle(.caliPrimary)
        }
    }
}

// MARK: - Rest (UX-08)

struct RestPhaseView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        PlayerScaffold {
            Text("Nghỉ")
                .font(.title.bold())
                .foregroundStyle(Color.caliText)
            ZStack {
                ProgressRing(progress: 1 - model.phaseProgress, lineWidth: 16, tint: .caliWarning)
                VStack(spacing: Spacing.xs) {
                    TimerText(text: Fmt.countdown(ms: model.remainingMs ?? 0))
                    Text("thời gian nghỉ")
                        .font(.subheadline)
                        .foregroundStyle(Color.caliSecondary)
                }
            }
            .frame(width: 250, height: 250)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Nghỉ còn \(Fmt.countdown(ms: model.remainingMs ?? 0))")

            if let next = model.nextUp {
                HStack(spacing: Spacing.m) {
                    PosterThumb(exercise: model.exercise(for: next.execution), size: 64)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tiếp theo")
                            .font(.caption)
                            .foregroundStyle(Color.caliSecondary)
                        Text(model.exercise(for: next.execution)?.name ?? "")
                            .font(.headline)
                            .foregroundStyle(Color.caliText)
                        Text("Set \(next.setIndex)/\(next.execution.setCount) · \(Fmt.target(next.execution.target))")
                            .font(.subheadline)
                            .foregroundStyle(Color.caliAccent)
                    }
                    Spacer()
                }
                .caliCard(padding: Spacing.m)
                .accessibilityElement(children: .combine)
            }
        } actions: {
            Button("Bắt đầu set tiếp", systemImage: "play.fill") { model.startNextSet() }
                .buttonStyle(.caliPrimary)
            HStack(spacing: Spacing.m) {
                Button("+30 giây", systemImage: "plus") { model.extendRest(30) }
                    .buttonStyle(.caliSecondary)
                Button("Bỏ nghỉ") { model.skipRest() }
                    .buttonStyle(.caliQuiet)
            }
        }
    }
}

// MARK: - Summary (UX-09)

struct SummaryPhaseView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        PlayerScaffold {
            Image(systemName: "flag.checkered")
                .font(.system(size: 48))
                .foregroundStyle(Color.caliAccent)
            Text("Đã xong tất cả set")
                .font(.title.bold())
                .foregroundStyle(Color.caliText)
            SessionStatsRow(model: model)
            SessionSetList(model: model)
        } actions: {
            Button("Lưu buổi tập", systemImage: "checkmark.circle.fill") { model.finish() }
                .buttonStyle(.caliPrimary)
        }
    }
}

// MARK: - Completed / abandoned

struct FinishedPhaseView: View {
    let model: WorkoutPlayerModel
    let onClose: () -> Void

    private var completed: Bool { model.state.phase == .completed }

    var body: some View {
        PlayerScaffold {
            Image(systemName: completed ? "checkmark.seal.fill" : "stop.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(completed ? Color.caliAccent : Color.caliWarning)
            Text(completed ? "Buổi tập hoàn thành!" : "Đã dừng buổi tập")
                .font(.title.bold())
                .foregroundStyle(Color.caliText)
            Text(completed
                 ? "Kết quả đã được lưu vào Lịch sử trên máy của bạn."
                 : "Các set đã xác nhận vẫn được lưu trong Lịch sử\(model.state.abandonReason.map { " · Lý do: \($0)" } ?? "").")
                .font(.subheadline)
                .foregroundStyle(Color.caliSecondary)
                .multilineTextAlignment(.center)
            if model.state.abandonReason == "Đau" {
                Label("Nếu cơn đau kéo dài hoặc tăng lên, hãy nghỉ tập và hỏi ý kiến chuyên gia y tế.", systemImage: "cross.case")
                    .font(.subheadline)
                    .foregroundStyle(Color.caliWarning)
                    .caliCard(padding: Spacing.m)
            }
            SessionStatsRow(model: model)
            SessionSetList(model: model)
        } actions: {
            Button("Đóng", action: onClose)
                .buttonStyle(.caliPrimary)
        }
    }
}

struct SessionStatsRow: View {
    let model: WorkoutPlayerModel

    var body: some View {
        HStack(spacing: Spacing.m) {
            StatTile(value: Fmt.clock(seconds: model.sessionElapsedSeconds), label: "Thời gian", systemImage: "clock")
            StatTile(value: "\(model.state.confirmedSetCount)", label: "Set xong", systemImage: "checkmark.circle", tint: .caliAccent)
            StatTile(value: "\(model.state.skippedSetCount)", label: "Bỏ qua", systemImage: "forward", tint: .caliSecondary)
        }
    }
}

struct SessionSetList: View {
    let model: WorkoutPlayerModel

    var body: some View {
        VStack(spacing: Spacing.m) {
            ForEach(model.state.executions, id: \.id) { execution in
                let sets = model.records(for: execution)
                HStack(alignment: .top, spacing: Spacing.m) {
                    PosterThumb(exercise: model.exercise(for: execution), size: 52)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(model.exercise(for: execution)?.name ?? "")
                            .font(.headline)
                            .foregroundStyle(Color.caliText)
                        Text("Mục tiêu: \(execution.setCount) × \(Fmt.target(execution.target))")
                            .font(.caption)
                            .foregroundStyle(Color.caliSecondary)
                        if sets.isEmpty {
                            Text("Chưa có set nào")
                                .font(.subheadline)
                                .foregroundStyle(Color.caliSecondary)
                        } else {
                            ForEach(sets, id: \.setResultId) { record in
                                let logged = LoggedSet(record: record)
                                HStack {
                                    Text("Set \(record.key.setIndex)")
                                        .foregroundStyle(Color.caliSecondary)
                                    Spacer()
                                    Text(Fmt.actual(logged))
                                        .foregroundStyle(record.status == .skipped ? Color.caliSecondary : Color.caliText)
                                    if let rpe = record.actual.rpe {
                                        Text("RPE \(rpe)")
                                            .font(.caption)
                                            .foregroundStyle(Color.caliSecondary)
                                    }
                                }
                                .font(.subheadline.monospacedDigit())
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .caliCard(padding: Spacing.m)
            }
        }
    }
}

// MARK: - Layout scaffold

/// Scrollable content with actions pinned to the bottom (thumb reach, ≥ 44 pt targets).
struct PlayerScaffold<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                content
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Spacing.s) {
                actions
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.s)
            .background(Color.caliCanvas.opacity(0.96))
        }
    }
}

// MARK: - Skip reasons

extension View {
    func skipReasonDialog(isPresented: Binding<Bool>, onSkip: @escaping (String) -> Void) -> some View {
        confirmationDialog("Lý do bỏ qua set?", isPresented: isPresented, titleVisibility: .visible) {
            ForEach(["Mệt", "Đau / khó chịu", "Thiếu dụng cụ", "Khác"], id: \.self) { reason in
                Button(reason) { onSkip(reason) }
            }
            Button("Huỷ", role: .cancel) {}
        }
    }
}

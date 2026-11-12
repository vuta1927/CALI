import CaliDomain
import SwiftUI

// MARK: - Ready (UX-05, mockup `pReady`)

struct ReadyPhaseView: View {
    let model: WorkoutPlayerModel
    let onShowGuide: () -> Void

    @State private var showSkipReasons = false

    var body: some View {
        PlayerScaffold {
            PosterView(exercise: model.currentExercise, height: 240)
            if let execution = model.currentExecution {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.currentExercise?.name ?? "Bài tập")
                        .font(.title2.bold())
                        .foregroundStyle(Color.caliText)
                    SetLine(model: model, execution: execution, font: .headline)
                    HStack(spacing: 6) {
                        TagChip(text: execution.target.type.label)
                        TagChip(text: "Nghỉ \(Fmt.seconds(execution.restSeconds))", systemImage: "clock")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Xem hướng dẫn kỹ thuật", systemImage: "doc.text", action: onShowGuide)
                .buttonStyle(.caliSecondary)
        } actions: {
            Button("Bắt đầu set", systemImage: "play.fill") { model.startSet() }
                .buttonStyle(.caliPrimary)
            Button("Bỏ qua set này") { showSkipReasons = true }
                .buttonStyle(.caliSecondary)
        }
        .skipReasonDialog(isPresented: $showSkipReasons) { model.skipCurrentSet(reason: $0) }
    }
}

// MARK: - Pre-countdown (UX-06, mockup `pCountdown`)

struct CountdownPhaseView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        let seconds = Int(((model.remainingMs ?? 0) + 999) / 1000)
        VStack(spacing: Spacing.xl) {
            PosterView(exercise: model.currentExercise, height: 160, showsLabel: false)
                .opacity(0.45)
            TimerRing(progress: 1, size: 210) {
                Text("Chuẩn bị")
                    .font(.subheadline)
                    .foregroundStyle(Color.caliSecondary)
                TimerText(text: "\(seconds)", size: 96)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Bắt đầu sau \(seconds) giây")
            if let execution = model.currentExecution {
                Text("\(model.currentExercise?.name ?? "") · Set \(model.state.currentSetIndex)/\(execution.setCount) · \(Fmt.target(execution.target))")
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(Spacing.l)
    }
}

// MARK: - Exercising (UX-06/07, mockup `pActive`)

struct ActivePhaseView: View {
    let model: WorkoutPlayerModel

    @State private var showSkipReasons = false

    private var isTimed: Bool { model.currentExecution?.target.targetDurationSeconds != nil }

    var body: some View {
        PlayerScaffold {
            ExerciseRow(model: model)
            if isTimed {
                TimerRing(progress: 1 - model.phaseProgress) {
                    TimerText(text: Fmt.countdown(ms: model.remainingMs ?? 0), size: 68)
                    Text("còn lại").font(.subheadline).foregroundStyle(Color.caliSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Còn lại \(Fmt.countdown(ms: model.remainingMs ?? 0))")
                Text("Hết giờ: rung + chuyển sang Nhập kết quả. Set chỉ được ghi khi bạn bấm Lưu.")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
                    .multilineTextAlignment(.center)
            } else {
                TimerRing(progress: 0) {
                    TimerText(text: model.currentExecution.map { Fmt.target($0.target) } ?? "", size: 44)
                    Text("mục tiêu").font(.subheadline).foregroundStyle(Color.caliSecondary)
                    Text(Fmt.clock(ms: model.elapsedMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.caliSecondary)
                        .padding(.top, 6)
                }
                .accessibilityElement(children: .combine)
                Text(openEndedHint)
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
                    .multilineTextAlignment(.center)
            }
        } actions: {
            Button(isTimed ? "Kết thúc sớm" : "Xong set", systemImage: "checkmark") { model.stopSet() }
                .buttonStyle(.caliPrimary)
            HStack(spacing: Spacing.s) {
                Button("Tạm dừng", systemImage: "pause.fill") { model.pause() }
                    .buttonStyle(.caliSecondary)
                Button("Bỏ qua") { showSkipReasons = true }
                    .buttonStyle(.caliSecondary)
            }
        }
        .skipReasonDialog(isPresented: $showSkipReasons) { model.skipCurrentSet(reason: $0) }
    }

    private var openEndedHint: String {
        switch model.currentExecution?.target {
        case .skillAttempt: "Thực hiện lần thử, bấm Xong set khi kết thúc."
        case .distance: "Chạy hết chặng rồi bấm Xong set. Thời gian chỉ để tham khảo; bạn nhập quãng đường và thời gian ở bước sau."
        default: "Bấm Xong set khi bạn hoàn thành số lần."
        }
    }
}

// MARK: - Paused (mockup `pPaused`)

struct PausedPhaseView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        PlayerScaffold {
            ExerciseRow(model: model, paused: true)
            if let remaining = model.state.pausedRemainingMs {
                TimerRing(progress: progress(remaining)) {
                    TimerText(text: Fmt.countdown(ms: remaining), size: 68, tint: .caliSecondary)
                    Text("còn lại khi tiếp tục").font(.subheadline).foregroundStyle(Color.caliSecondary)
                }
                .accessibilityElement(children: .combine)
            } else {
                TimerRing(progress: 0) {
                    TimerText(text: Fmt.clock(ms: model.state.accumulatedExerciseMs), size: 56, tint: .caliSecondary)
                    Text("đã tập").font(.subheadline).foregroundStyle(Color.caliSecondary)
                }
                .accessibilityElement(children: .combine)
            }
        } actions: {
            Button("Tiếp tục", systemImage: "play.fill") { model.resume() }
                .buttonStyle(.caliPrimary)
        }
    }

    private func progress(_ remainingMs: Int64) -> Double {
        guard let total = model.currentExecution?.target.targetDurationSeconds, total > 0 else { return 0 }
        return min(1, Double(remainingMs) / Double(total * 1000))
    }
}

// MARK: - Rest (UX-08, mockup `pRest`)

struct RestPhaseView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        if model.state.isTransitionRest {
            TransitionRestView(model: model)
        } else {
            setRest
        }
    }

    private var setRest: some View {
        PlayerScaffold {
            Text("Nghỉ")
                .font(.title2.bold())
                .foregroundStyle(Color.caliText)
            TimerRing(progress: 1 - model.phaseProgress) {
                TimerText(text: Fmt.countdown(ms: model.remainingMs ?? 0), size: 68)
                Text("thời gian nghỉ").font(.subheadline).foregroundStyle(Color.caliSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Nghỉ còn \(Fmt.countdown(ms: model.remainingMs ?? 0))")
            HStack(spacing: Spacing.s) {
                Button("+30 giây", systemImage: "plus") { model.extendRest(30) }
                    .buttonStyle(.caliSecondary)
                Button("Bỏ nghỉ") { model.skipRest() }
                    .buttonStyle(.caliSecondary)
            }
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
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.caliSecondary)
                    }
                    Spacer()
                }
                .caliCard(padding: Spacing.m)
                .accessibilityElement(children: .combine)
            }
            Text(model.autoAdvanceEnabled && model.state.restAutoAdvances
                 ? "Hết giờ nghỉ khi app đang mở, set tiếp tự bắt đầu. Set chỉ được ghi khi bạn bấm Xong set / Lưu."
                 : "Hết giờ nghỉ chỉ nhắc (rung / thông báo), không tự bắt đầu set.")
                .font(.caption)
                .foregroundStyle(Color.caliSecondary)
                .multilineTextAlignment(.center)
        } actions: {
            Button("Bắt đầu set tiếp", systemImage: "play.fill") { model.startNextSet() }
                .buttonStyle(.caliPrimary)
        }
    }
}

// MARK: - Transition rest (IOS-022)

/// Rest before a new exercise: the next exercise's poster leads (visual-first), the countdown is secondary.
/// Ends in READY; the user starts the first set (never auto-started, even with "Tự động chuyển set").
struct TransitionRestView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        PlayerScaffold {
            Text("Chuẩn bị bài mới")
                .font(.title2.bold())
                .foregroundStyle(Color.caliText)
                .frame(maxWidth: .infinity, alignment: .leading)
            PosterView(exercise: model.currentExercise, height: 220)
            if let execution = model.currentExecution {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.currentExercise?.name ?? "Bài tập")
                        .font(.title3.bold())
                        .foregroundStyle(Color.caliText)
                    Text("\(execution.setCount) set · \(Fmt.target(execution.target))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Color.caliAccentInk)
                    HStack(spacing: 6) {
                        TagChip(text: execution.target.type.label)
                        TagChip(text: "Nghỉ giữa set \(Fmt.seconds(execution.restSeconds))", systemImage: "clock")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: Spacing.m) {
                TimerText(text: Fmt.countdown(ms: model.remainingMs ?? 0), size: 56)
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Button("+30 giây", systemImage: "plus") { model.extendRest(30) }
                        .buttonStyle(.caliSecondary)
                    Button("Bỏ nghỉ") { model.skipRest() }
                        .buttonStyle(.caliSecondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chuẩn bị còn \(Fmt.countdown(ms: model.remainingMs ?? 0))")
            Text("Hết giờ chỉ nhắc, không tự bắt đầu bài mới. Bấm Bắt đầu khi bạn đã sẵn sàng.")
                .font(.caption)
                .foregroundStyle(Color.caliSecondary)
                .multilineTextAlignment(.center)
        } actions: {
            Button("Bắt đầu bài mới", systemImage: "play.fill") { model.startNextSet() }
                .buttonStyle(.caliPrimary)
        }
    }
}

// MARK: - Summary (UX-09, mockup `pSummary`)

struct SummaryPhaseView: View {
    let model: WorkoutPlayerModel

    var body: some View {
        PlayerScaffold {
            Text("Đã xong tất cả set")
                .font(.title2.bold())
                .foregroundStyle(Color.caliText)
                .frame(maxWidth: .infinity, alignment: .leading)
            SessionStatsRow(model: model)
            SessionSetList(model: model)
        } actions: {
            Button("Lưu buổi tập", systemImage: "checkmark.circle") { model.finish() }
                .buttonStyle(.caliPrimary)
        }
    }
}

// MARK: - Completed / abandoned (mockup `pFinished`)

struct FinishedPhaseView: View {
    let model: WorkoutPlayerModel
    let onClose: () -> Void

    private var completed: Bool { model.state.phase == .completed }

    var body: some View {
        PlayerScaffold {
            Image(systemName: completed ? "checkmark" : "flag.fill")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(completed ? Color.caliOnAccent : Color.caliWarning)
                .frame(width: 96, height: 96)
                .background(completed ? Color.caliAccent : Color.caliSurfaceRaised, in: Circle())
                .padding(.top, Spacing.xl)
                .accessibilityHidden(true)
            Text(completed ? "Buổi tập hoàn thành!" : "Đã dừng buổi tập")
                .font(.title2.bold())
                .foregroundStyle(Color.caliText)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.caliSecondary)
                .multilineTextAlignment(.center)
            SessionStatsRow(model: model)
            Text(completed ? "Đã lưu vào Lịch sử." : "Các set đã xác nhận được giữ lại trong Lịch sử, buổi được đánh dấu “Dừng sớm”.")
                .font(.footnote)
                .foregroundStyle(Color.caliSecondary)
                .multilineTextAlignment(.center)
            Label("Nếu cơn đau kéo dài hoặc tăng lên, hãy nghỉ tập và hỏi ý kiến chuyên gia y tế.", systemImage: "cross.case")
                .font(.caption)
                .foregroundStyle(model.state.abandonReason == "Đau" ? Color.caliWarning : Color.caliSecondary)
                .caliCard(padding: Spacing.m)
        } actions: {
            Button("Đóng", action: onClose)
                .buttonStyle(.caliPrimary)
        }
    }

    /// "Pull / Legs · 52 phút" or "Pull / Legs · Dừng ở bài 2/5 · lý do: Mệt"
    private var subtitle: String {
        let s = model.state
        if completed { return "\(model.title) · \(max(1, model.sessionElapsedSeconds / 60)) phút" }
        let reason = s.abandonReason.map { " · lý do: \($0)" } ?? ""
        return "\(model.title) · Dừng ở bài \(min(s.currentExecutionIndex + 1, s.executions.count))/\(s.executions.count)\(reason)"
    }
}

struct SessionStatsRow: View {
    let model: WorkoutPlayerModel

    var body: some View {
        let s = model.state
        HStack(spacing: Spacing.m) {
            StatTile(value: "\(s.confirmedSetCount)/\(s.totalPlannedSets)", label: "Set đạt", systemImage: "checkmark.circle", tint: .caliAccent)
            StatTile(value: "\(s.skippedSetCount)", label: "Bỏ qua", systemImage: "forward")
            StatTile(value: "\(max(1, model.sessionElapsedSeconds / 60))", label: "Phút", systemImage: "clock")
        }
    }
}

struct SessionSetList: View {
    let model: WorkoutPlayerModel

    var body: some View {
        VStack(spacing: Spacing.m) {
            ForEach(model.state.executions, id: \.id) { execution in
                ExerciseResultCard(exercise: model.exercise(for: execution),
                                   sets: model.records(for: execution).map(LoggedSet.init(record:)),
                                   plannedSetCount: execution.setCount)
            }
        }
    }
}

// MARK: - Shared pieces

/// "Set 2/4 · giữ 12 giây" in the accent color.
private struct SetLine: View {
    let model: WorkoutPlayerModel
    let execution: ExecutionSpec
    var font: Font = .footnote

    var body: some View {
        Text("Set \(model.state.currentSetIndex)/\(execution.setCount) · \(Fmt.target(execution.target))")
            .font(font.monospacedDigit())
            .foregroundStyle(Color.caliAccentInk)
    }
}

/// Poster + name + set line, with a paused chip (mockup `pActive` header row).
private struct ExerciseRow: View {
    let model: WorkoutPlayerModel
    var paused = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            PosterThumb(exercise: model.currentExercise, size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentExercise?.name ?? "Bài tập")
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                if let execution = model.currentExecution {
                    SetLine(model: model, execution: execution)
                }
            }
            Spacer(minLength: 0)
            if paused { TagChip(text: "Đã tạm dừng", systemImage: "pause.fill", tint: .caliWarning) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Orange progress ring with centered content (mockup `ring`, 230pt).
struct TimerRing<Content: View>: View {
    let progress: Double
    var size: CGFloat = 230
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            ProgressRing(progress: progress, lineWidth: 14)
            VStack(spacing: 2) { content }
                .padding(Spacing.xl)
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity)
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
            .background(LinearGradient(colors: [Color.caliCanvas.opacity(0), Color.caliCanvas], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3)))
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

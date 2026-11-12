import CaliDomain
import SwiftUI

/// Full-screen workout player (docs/02 UX-05..09). Renders the domain phase; every button maps to
/// exactly one domain command.
struct WorkoutPlayerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: WorkoutPlayerModel

    @State private var showExitOptions = false
    @State private var guideExercise: Exercise?

    var body: some View {
        VStack(spacing: 0) {
            PlayerHeader(model: model) {
                if model.state.isActive {
                    showExitOptions = true
                } else {
                    store.closePlayer()
                }
            }
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.s)
            }
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            // IOS-023: undo a skip for 10 s ("tập lại ngay" for that exercise).
            if model.showsUndoSkip, let undo = model.undoSkip {
                HStack {
                    Text("Đã bỏ qua")
                        .foregroundStyle(Color.caliText)
                    Spacer()
                    Button("Hoàn tác") { model.reopenSkipped(executionId: undo.executionId, setIndex: undo.setIndex) }
                        .font(.body.bold())
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .background(Color.caliSurface, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, 96)
                .accessibilityElement(children: .contain)
            }
        }
        .background(Color.caliCanvas.ignoresSafeArea())
        .task {
            while !Task.isCancelled {
                model.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.sceneDidBecomeActive() }
        }
        .sensoryFeedback(trigger: model.feedbackTick) { _, _ in
            store.settings.hapticsEnabled ? .impact(weight: .medium) : nil
        }
        .confirmationDialog("Rời màn hình tập?", isPresented: $showExitOptions, titleVisibility: .visible) {
            Button("Thu nhỏ — tập tiếp sau") { store.closePlayer() }
            Button("Dừng buổi tập (mệt)", role: .destructive) { model.abandon(reason: "Mệt") }
            Button("Dừng buổi tập (đau / khó chịu)", role: .destructive) { model.abandon(reason: "Đau") }
            Button("Dừng buổi tập (lý do khác)", role: .destructive) { model.abandon(reason: "Khác") }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text("Các set đã xác nhận luôn được giữ lại. Thu nhỏ để quay lại sau từ tab Hôm nay.")
        }
        .alert("Giờ thiết bị đã thay đổi", isPresented: clockAlertBinding) {
            Button("Giờ hiện tại là đúng") { model.acknowledgeClockChange() }
            Button("Dừng buổi tập", role: .destructive) {
                model.clockAnomaly = nil
                model.abandon(reason: "Giờ thiết bị thay đổi")
            }
        } message: {
            Text("\(model.clockAnomaly.map(WorkoutPlayerModel.describe) ?? "") Kết quả đã ghi không bị thay đổi. Nếu giờ hiện tại là đúng, COAMI sẽ tính tiếp theo giờ mới.")
        }
        .alert("Tiếp tục buổi tập?", isPresented: $model.showRecoveryPrompt) {
            Button("Tiếp tục buổi tập") {}
            Button("Dừng buổi tập", role: .destructive) { model.abandon(reason: "Bỏ dở lâu") }
        } message: {
            Text("Buổi \"\(model.title)\" đã tạm ngưng khá lâu. Bạn muốn tập tiếp hay kết thúc?")
        }
        .sheet(item: $guideExercise) { exercise in
            NavigationStack {
                ExerciseDetailView(exercise: exercise, showsStartActions: false)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Đóng") { guideExercise = nil }
                        }
                    }
            }
        }
    }

    private var clockAlertBinding: Binding<Bool> {
        Binding(
            get: { model.clockAnomaly != nil },
            set: { if !$0 { /* buttons resolve the anomaly */ } }
        )
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.state.phase {
        case .ready:
            ReadyPhaseView(model: model) { guideExercise = model.currentExercise }
        case .preCountdown:
            CountdownPhaseView(model: model)
        case .exercising:
            ActivePhaseView(model: model)
        case .paused:
            PausedPhaseView(model: model)
        case .awaitingResult:
            ResultFormView(model: model)
                .id(model.state.pendingResult?.key)
        case .resting:
            RestPhaseView(model: model)
        case .reviewingSummary:
            SummaryPhaseView(model: model)
        case .completed, .abandoned:
            FinishedPhaseView(model: model) { store.closePlayer() }
        }
    }
}

// MARK: - Header

private struct PlayerHeader: View {
    let model: WorkoutPlayerModel
    let onClose: () -> Void

    var body: some View {
        let s = model.state
        VStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                if s.isActive {
                    CircleIconButton(systemImage: "chevron.down", label: "Thu nhỏ hoặc dừng", action: onClose)
                } else {
                    Color.clear.frame(width: minTapTarget, height: minTapTarget)
                }
                VStack(spacing: 0) {
                    Text(model.title)
                        .font(.headline)
                        .foregroundStyle(Color.caliText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.caliSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                CircleIconButton(systemImage: "xmark", label: s.isActive ? "Rời buổi tập" : "Đóng", action: onClose)
            }
            HStack(spacing: Spacing.s) {
                LinearProgress(progress: model.progress)
                Text("\(s.resolvedSets.count)/\(s.totalPlannedSets) set")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Đã xong \(s.resolvedSets.count) trên \(s.totalPlannedSets) set")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.s)
    }

    /// "Bài 1/5 · 18:42"
    private var subtitle: String {
        let s = model.state
        let clock = Fmt.clock(seconds: model.sessionElapsedSeconds)
        guard s.isActive, s.phase != .reviewingSummary else { return clock }
        return "Bài \(s.currentExecutionIndex + 1)/\(s.executions.count) · \(clock)"
    }
}

// MARK: - Banner

struct BannerView: View {
    let banner: WorkoutPlayerModel.Banner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? Color.caliError : Color.caliWarning)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.caliText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(Color.caliSecondary)
                    .frame(width: minTapTarget, height: minTapTarget)
            }
            .accessibilityLabel("Ẩn thông báo")
        }
        .padding(.leading, Spacing.m)
        .background((isError ? Color.caliError : Color.caliWarning).opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.chip))
    }

    private var isError: Bool { if case .error = banner { true } else { false } }
    private var text: String {
        switch banner {
        case .info(let t), .error(let t): t
        }
    }
}

// MARK: - Shared pieces

/// Large timer text (≥ 56 pt, docs/02 accessibility).
struct TimerText: View {
    let text: String
    var size: CGFloat = 76
    var tint: Color = .caliText

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(tint)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .contentTransition(.numericText(countsDown: true))
    }
}

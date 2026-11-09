import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Lock Screen + Dynamic Island presentation of `WorkoutAttributes`.
/// Countdown is system-rendered from UTC deadlines; nothing here ticks or mutates state
/// (docs/05 §2: no per-second Activity updates, no business transitions from the widget).
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutAttributes.self) { context in
            WorkoutLockScreenView(state: context.state, showsPOCActions: context.attributes.deviceGatePOC == true)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 5) {
                        CompactCOAMIMark()
                            .frame(width: 18, height: 18)
                        Text(verbatim: context.state.exerciseShortName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutCountdownText(state: context.state)
                        .font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(verbatim: context.state.phaseAndSetLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if context.attributes.deviceGatePOC == true {
                            Spacer(minLength: 8)
                            POCLiveActivityActionButton(state: context.state)
                        }
                    }
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    CompactCOAMIMark()
                        .frame(width: 12, height: 12)
                    Text(verbatim: "\(context.state.setIndex)/\(context.state.setCount)")
                        .monospacedDigit()
                }
            } compactTrailing: {
                WorkoutCountdownText(state: context.state)
                    .monospacedDigit()
                    .frame(width: 48)
            } minimal: {
                WorkoutCountdownText(state: context.state)
                    .monospacedDigit()
                    .font(.caption2)
            }
        }
    }
}

struct WorkoutLockScreenView: View {
    let state: WorkoutAttributes.ContentState
    /// POC-001 device gate only (`WorkoutAttributes.deviceGatePOC`); the normal workout stays read-only.
    var showsPOCActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    CompactCOAMIMark()
                        .frame(width: 20, height: 20)
                    Text(verbatim: state.exerciseShortName)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                WorkoutCountdownText(state: state)
                    .font(.title2.monospacedDigit())
            }
            HStack {
                Text(verbatim: state.phaseAndSetLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if showsPOCActions {
                    Spacer(minLength: 8)
                    POCLiveActivityActionButton(state: state)
                }
            }
        }
        .padding()
    }
}

/// POC-001 Lock Screen button: "+30s" while resting, "Xong set" while awaiting a result. Runs
/// `POCLiveActivityIntent` (authenticationPolicy = requiresAuthentication) in the app process; the widget
/// itself never writes state. The intent carries the rendered revision so a stale snapshot is rejected.
/// TODO(IOS-001): replace with the production buttons after the GO decision.
struct POCLiveActivityActionButton: View {
    let state: WorkoutAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .resting:
            button("+30s", action: "extend_rest_30")
        case .awaitingResult:
            button("Xong set", action: "confirm_current_set")
        default:
            EmptyView()
        }
    }

    private func button(_ title: String, action: String) -> some View {
        Button(intent: POCLiveActivityIntent(sessionId: state.sessionId.uuidString, revision: state.revision, action: action)) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color(red: 1.0, green: 0x6A / 255.0, blue: 0x2B / 255.0))
    }
}

/// Flat, high-contrast logo for compact system surfaces. It intentionally avoids glass,
/// blur and animation so the timer and workout state keep visual priority.
struct CompactCOAMIMark: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle()
                    .trim(from: 0.12, to: 0.88)
                    // COAMI orange (dark-mode accent #FF6A2B); the widget target does not link Theme.swift.
                    .stroke(Color(red: 1.0, green: 0x6A / 255.0, blue: 0x2B / 255.0), style: StrokeStyle(lineWidth: side * 0.18, lineCap: .round))
                    .rotationEffect(.degrees(45))
                Capsule()
                    .fill(.white)
                    .frame(width: side * 0.14, height: side * 0.42)
                    .rotationEffect(.degrees(45))
                Circle()
                    .fill(.white)
                    .frame(width: side * 0.18, height: side * 0.18)
                    .offset(x: side * 0.24, y: -side * 0.24)
            }
            .frame(width: side, height: side)
        }
        .accessibilityHidden(true)
    }
}

/// Read-only countdown. When `pausedTimeUtc` is set the system shows the frozen remaining time.
struct WorkoutCountdownText: View {
    let state: WorkoutAttributes.ContentState

    var body: some View {
        if let interval = state.countdownInterval {
            Text(
                timerInterval: interval,
                pauseTime: state.pausedTimeUtc,
                countsDown: true,
                showsHours: false
            )
            .multilineTextAlignment(.trailing)
        } else {
            Text(verbatim: "--:--")
        }
    }
}

extension WorkoutAttributes.ContentState {
    /// e.g. "Đang giữ • Set 2/4". Copy follows docs/05 §3; localization comes later.
    var phaseAndSetLine: String {
        "\(phase.label) • Set \(setIndex)/\(setCount)"
    }
}

extension WorkoutAttributes.Phase {
    var label: String {
        switch self {
        case .ready: return "Sẵn sàng tập"
        case .preCountdown: return "Sẵn sàng"
        case .exercising: return "Đang giữ"
        case .awaitingResult: return "Xác nhận set"
        case .resting: return "Nghỉ"
        case .paused: return "Đã tạm dừng"
        case .reviewingSummary: return "Sẵn sàng tổng kết"
        case .completed: return "Buổi tập hoàn thành"
        case .abandoned: return "Đã dừng buổi tập"
        }
    }
}

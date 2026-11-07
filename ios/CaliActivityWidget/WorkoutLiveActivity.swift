import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen + Dynamic Island presentation of `WorkoutAttributes`.
/// Countdown is system-rendered from UTC deadlines; nothing here ticks or mutates state
/// (docs/05 §2: no per-second Activity updates, no business transitions from the widget).
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutAttributes.self) { context in
            WorkoutLockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(verbatim: context.state.exerciseShortName)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WorkoutCountdownText(state: context.state)
                        .font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(verbatim: context.state.phaseAndSetLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Text(verbatim: "\(context.state.setIndex)/\(context.state.setCount)")
                    .monospacedDigit()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: state.exerciseShortName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                WorkoutCountdownText(state: state)
                    .font(.title2.monospacedDigit())
            }
            Text(verbatim: state.phaseAndSetLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding()
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

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
                    Text(verbatim: context.state.phaseAndSetLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            Text(verbatim: state.phaseAndSetLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding()
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

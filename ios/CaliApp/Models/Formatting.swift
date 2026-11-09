import CaliDomain
import Foundation

enum Fmt {
    static let vi = Locale(identifier: "vi_VN")

    /// "1:05" / "0:12" from milliseconds (floors partial seconds for elapsed time).
    static func clock(ms: Int64) -> String {
        clock(seconds: Int(max(ms, 0) / 1000))
    }

    /// Remaining-time display: rounds partial seconds up so "0:00" only shows at the deadline.
    static func countdown(ms: Int64) -> String {
        clock(seconds: Int((max(ms, 0) + 999) / 1000))
    }

    static func clock(seconds: Int) -> String {
        let s = max(seconds, 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func seconds(_ s: Int) -> String {
        if s >= 60 && s % 60 == 0 { return "\(s / 60) phút" }
        if s > 60 { return "\(s / 60)p\(String(format: "%02d", s % 60))s" }
        return "\(s)s"
    }

    static func holdSeconds(ms: Int64) -> String {
        let tenths = Double(ms) / 1000
        return tenths.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(tenths))s" : String(format: "%.1fs", tenths)
    }

    /// Target of one set: "giữ 12s", "8–10 lần".
    static func target(_ p: Prescription) -> String {
        switch p {
        case .staticHold(let s): "giữ \(s)s"
        case .reps(let lo, let hi): lo == hi ? "\(lo) lần" : "\(lo)–\(hi) lần"
        case .timedReps(let s): "\(s)s tối đa lần"
        case .interval(let work, let rest): "\(work)s tập / \(rest)s nghỉ"
        case .skillAttempt(let n): "\(n) lần thử"
        case .load(let reps, let kg): "\(reps) lần @ \(loadKg(kg))"
        }
    }

    /// Kilograms with the `vi` decimal comma: "60 kg", "57,5 kg" (docs/18 §4). Display only, always kg
    /// (ADR-046); shows up to the 2 decimals the domain allows (ADR-062), so nothing is hidden.
    static func loadKg(_ kg: Decimal) -> String {
        "\(kg.formatted(.number.precision(.fractionLength(0...2)).locale(vi))) kg"
    }

    /// "4 × giữ 12s · nghỉ 90s", "3 × 5 lần @ 60 kg · nghỉ 2 phút"
    static func prescription(_ item: PlannedExercise) -> String {
        "\(item.setCount) × \(target(item.target)) · nghỉ \(seconds(item.restSeconds))"
    }

    static func weekdayShort(_ iso: Int) -> String {
        switch iso {
        case 1: "T2"
        case 2: "T3"
        case 3: "T4"
        case 4: "T5"
        case 5: "T6"
        case 6: "T7"
        case 7: "CN"
        default: "—"
        }
    }

    static func weekdayLong(_ iso: Int) -> String {
        switch iso {
        case 1: "Thứ Hai"
        case 2: "Thứ Ba"
        case 3: "Thứ Tư"
        case 4: "Thứ Năm"
        case 5: "Thứ Sáu"
        case 6: "Thứ Bảy"
        case 7: "Chủ Nhật"
        default: "Bất kỳ ngày nào"
        }
    }

    /// ISO weekday (1 = Monday) for a date in the current calendar.
    static func isoWeekday(_ date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date) // 1 = Sunday
        return ((weekday + 5) % 7) + 1
    }

    static func dayMonth(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.wide).locale(vi))
    }

    static func fullDate(_ date: Date) -> String {
        "\(weekdayLong(isoWeekday(date))), \(dayMonth(date))"
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(vi))
    }

    static func relativeDay(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Hôm nay" }
        if cal.isDateInYesterday(date) { return "Hôm qua" }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: now)).day ?? 0
        return days > 0 ? "\(days) ngày trước" : dayMonth(date)
    }

    /// Actual result of a logged set: "11.5s", "9 lần", "Bỏ qua".
    static func actual(_ set: LoggedSet) -> String {
        if set.status == .skipped { return "Bỏ qua" }
        var parts: [String] = []
        switch set.target {
        case .staticHold:
            if let ms = set.holdMs { parts.append(holdSeconds(ms: ms)) }
        case .reps:
            if let r = set.reps { parts.append("\(r) lần") }
        case .timedReps:
            if let r = set.reps { parts.append("\(r) lần") }
            if let ms = set.workMs { parts.append("trong \(holdSeconds(ms: ms))") }
        case .interval:
            if let ms = set.workMs { parts.append(holdSeconds(ms: ms)) }
        case .skillAttempt:
            parts.append(set.status == .completed ? "Thành công" : "Chưa đạt")
        case .load:
            if let r = set.reps { parts.append("\(r) lần") }
            if let kg = set.loadKg { parts.append("@ \(loadKg(kg))") }
        }
        if set.status == .failed, set.target.type != .skillAttempt {
            parts.append("(chưa đạt)")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " ")
    }
}

extension ExerciseType {
    var label: String {
        switch self {
        case .staticHold: "Giữ tĩnh"
        case .reps: "Số lần"
        case .timedReps: "Theo thời gian"
        case .interval: "Interval"
        case .skillAttempt: "Kỹ năng"
        case .load: "Tạ"
        }
    }

    var systemImage: String {
        switch self {
        case .staticHold: "pause.circle"
        case .reps: "number.circle"
        case .timedReps: "timer"
        case .interval: "repeat.circle"
        case .skillAttempt: "star.circle"
        case .load: "dumbbell"
        }
    }

    /// Default target when an exercise is added to a plan.
    var defaultTarget: Prescription {
        switch self {
        case .staticHold: .staticHold(holdSeconds: 15)
        case .reps: .reps(repMin: 8, repMax: 12)
        case .timedReps: .timedReps(timeSeconds: 30)
        case .interval: .interval(workSeconds: 30, restSeconds: 15)
        case .skillAttempt: .skillAttempt(attempts: 3)
        // Conservative starting point; the plan editor steps kg by 2.5 (docs/18 §4).
        case .load: .load(reps: 5, loadKg: 20)
        }
    }
}

extension Phase {
    var label: String {
        switch self {
        case .ready: "Sẵn sàng"
        case .preCountdown: "Chuẩn bị"
        case .exercising: "Đang tập"
        case .paused: "Tạm dừng"
        case .awaitingResult: "Xác nhận kết quả"
        case .resting: "Nghỉ"
        case .reviewingSummary: "Tổng kết"
        case .completed: "Hoàn thành"
        case .abandoned: "Đã dừng"
        }
    }
}

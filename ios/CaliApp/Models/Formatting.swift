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

    /// "90 giây", "2 phút", "2 phút 30 giây" (mockup wording, no unit abbreviations).
    static func seconds(_ s: Int) -> String {
        if s >= 60 && s % 60 == 0 { return "\(s / 60) phút" }
        if s > 60 { return "\(s / 60) phút \(s % 60) giây" }
        return "\(s) giây"
    }

    /// "12 giây", "11,5 giây" with the `vi` decimal comma.
    static func holdSeconds(ms: Int64) -> String {
        let value = Double(ms) / 1000
        return "\(value.formatted(.number.precision(.fractionLength(0...1)).locale(vi))) giây"
    }

    /// Target of one set: "giữ 12 giây", "8–10 lần".
    static func target(_ p: Prescription) -> String {
        switch p {
        case .staticHold(let s): "giữ \(s) giây"
        case .reps(let lo, let hi): lo == hi ? "\(lo) lần" : "\(lo)–\(hi) lần"
        case .timedReps(let s): "\(s) giây tối đa lần"
        case .interval(let work, let rest): "\(work) giây tập / \(rest) giây nghỉ"
        case .skillAttempt(let n): "\(n) lần thử"
        case .load(let reps, let kg): "\(reps) lần @ \(loadKg(kg))"
        case .distance(let meters, let seconds):
            seconds.map { "\(km(meters)) trong \(duration($0))" } ?? km(meters)
        case .duration(let s): "chạy \(seconds(s))"
        }
    }

    /// "5 km", "8,25 km" (ADR-055: kilometres only, `vi` decimal comma, at most 2 decimals).
    static func km(_ meters: Int) -> String {
        RunningFormat.kilometers(distanceMeters: meters).replacingOccurrences(of: ",00 km", with: " km")
    }

    /// "29:00", "1:58:40" (h:mm:ss; minutes and seconds only under an hour).
    static func duration(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Kilograms with the `vi` decimal comma: "60 kg", "57,5 kg" (docs/18 §4). Display only, always kg
    /// (ADR-046); shows up to the 2 decimals the domain allows (ADR-062), so nothing is hidden.
    static func loadKg(_ kg: Decimal) -> String {
        "\(kg.formatted(.number.precision(.fractionLength(0...2)).locale(vi))) kg"
    }

    /// "4 × giữ 12 giây · nghỉ 90 giây", "3 × 5 lần @ 60 kg · nghỉ 2 phút"
    static func prescription(_ item: PlannedExercise) -> String {
        "\(setsTarget(item)) · nghỉ \(seconds(item.restSeconds))"
    }

    /// "4 × giữ 12 giây"
    static func setsTarget(_ item: PlannedExercise) -> String {
        "\(item.setCount) × \(target(item.target))"
    }

    /// "Nghỉ 2 phút · Giữ tĩnh"
    static func restLine(_ item: PlannedExercise) -> String {
        "Nghỉ \(seconds(item.restSeconds)) · \(item.target.type.label)"
    }

    /// "5 bài · 15 set · ~55 phút"
    static func workoutMeta(_ workout: PlannedWorkout) -> String {
        "\(workout.exercises.count) bài · \(workout.totalSets) set · ~\(workout.estimatedMinutes) phút"
    }

    /// "6/11"
    static func dayMonthShort(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.day, .month], from: date)
        return "\(c.day ?? 0)/\(c.month ?? 0)"
    }

    /// "2 – 8/11", "27/10 – 2/11"
    static func range(_ start: Date, _ end: Date, calendar: Calendar = .current) -> String {
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        return sameMonth ? "\(calendar.component(.day, from: start)) – \(dayMonthShort(end))" : "\(dayMonthShort(start)) – \(dayMonthShort(end))"
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

    /// "Hôm nay, 9/11", "Thứ Sáu, 6/11"
    static func relativeDayLong(_ date: Date) -> String {
        let day = Calendar.current.isDateInToday(date) ? "Hôm nay" : weekdayLong(isoWeekday(date))
        return "\(day), \(dayMonthShort(date))"
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
        case .distance, .duration:
            if let meters = set.distanceMeters { parts.append(km(meters)) }
            if let seconds = set.durationSeconds { parts.append(duration(seconds)) }
            if let pace = set.pace { parts.append("· \(pace.formatted)") }
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
        case .distance: "Quãng đường"
        case .duration: "Thời gian chạy"
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
        case .distance: "figure.run"
        case .duration: "stopwatch"
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
        case .distance: .distance(distanceMeters: 5000, durationSeconds: nil)
        case .duration: .duration(durationSeconds: 1200)
        }
    }
}

/// Training discipline shown as a chip (mockup `pchip`). Derived from exercise types like db/006:
/// `load` is Gym, `distance`/`duration` Running, everything else Calisthenics; several is Mixed.
enum Discipline: Equatable {
    case calisthenics, gym, running, mixed

    init(types: [ExerciseType]) {
        let kinds = Set(types.map { type -> Discipline in
            switch type {
            case .load: .gym
            case .distance, .duration: .running
            default: .calisthenics
            }
        })
        self = kinds.count > 1 ? .mixed : (kinds.first ?? .calisthenics)
    }

    var label: String {
        switch self {
        case .calisthenics: "Calisthenics"
        case .gym: "Gym"
        case .running: "Chạy bộ"
        case .mixed: "Kết hợp"
        }
    }

    var systemImage: String {
        switch self {
        case .calisthenics: "figure.strengthtraining.functional"
        case .gym: "dumbbell"
        case .running: "figure.run"
        case .mixed: "square.stack.3d.up"
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

// MARK: - Multi-plan (IOS-013)

extension PlanDiscipline {
    var label: String {
        switch self {
        case .calisthenics: "Calisthenics"
        case .running: "Chạy bộ"
        case .gym: "Gym"
        case .mixed: "Kết hợp"
        }
    }

    var systemImage: String {
        switch self {
        case .calisthenics: "figure.strengthtraining.functional"
        case .running: "figure.run"
        case .gym: "dumbbell"
        case .mixed: "square.stack.3d.up"
        }
    }
}

extension PlanStatus {
    /// docs/19 §4.2 labels; `scheduled` gets its date from the caller ("Bắt đầu từ dd/mm").
    var label: String {
        switch self {
        case .draft: "Nháp"
        case .scheduled: "Đã lên lịch"
        case .active: "Đang theo"
        case .paused: "Tạm dừng"
        case .ended: "Đã kết thúc"
        case .archived: "Lưu trữ"
        case .deleted: "Đã xoá"
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "pencil"
        case .scheduled: "calendar"
        case .active: "play.circle"
        case .paused: "pause.circle"
        case .ended: "flag.checkered"
        case .archived: "archivebox"
        case .deleted: "trash"
        }
    }
}

extension Fmt {
    /// "Thứ Hai, 9/11" for a local date.
    static func day(_ day: LocalDate) -> String {
        "\(weekdayLong(day.isoWeekday)), \(day.day)/\(day.month)"
    }

    /// "9/11", or "14/3/2027" outside the current year.
    static func shortDate(_ day: LocalDate, currentYear: Int = Calendar.current.component(.year, from: Date())) -> String {
        day.year == currentYear ? "\(day.day)/\(day.month)" : "\(day.day)/\(day.month)/\(day.year)"
    }
}

import Foundation

/// A calendar day with no time and no zone, e.g. `2026-11-09`. Used for `plan_activation.fromDate/toDate`
/// and `training_plan.eventDate`, which are stored as local dates plus an IANA `timezone` (docs/19 BR-1).
///
/// Arithmetic counts proleptic-Gregorian days with integers only, so it never depends on DST, the device
/// time zone or wall-clock jumps. The only place a zone enters is `today(at:in:)`: a clock or time-zone
/// change moves "today" and nothing else (BR-1: activations are never rewritten).
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month),
              (1...Self.daysInMonth(month, year: year)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Strict `YYYY-MM-DD` (the JSON Schema `format: date` shape used by the contracts).
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Days since 1970-01-01 (negative before it).
    public var dayNumber: Int {
        // H. Hinnant, "days_from_civil".
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public init(dayNumber: Int) {
        // H. Hinnant, "civil_from_days".
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.year = yoe + era * 400 + (m <= 2 ? 1 : 0)
        self.month = m
        self.day = d
    }

    public func adding(days: Int) -> LocalDate { LocalDate(dayNumber: dayNumber + days) }

    /// Signed number of days from `self` to `other` (`other - self`).
    public func days(until other: LocalDate) -> Int { other.dayNumber - dayNumber }

    /// ISO weekday: 1 = Monday ... 7 = Sunday (same convention as `planned_workout.weekday`).
    public var isoWeekday: Int {
        // 1970-01-01 was a Thursday (ISO 4).
        ((dayNumber % 7 + 7) % 7 + 3) % 7 + 1
    }

    /// The local calendar day of `instant` in `timeZone`. Uses the zone offset in effect at that instant,
    /// so DST transitions are handled by the time-zone database.
    public static func today(at instant: Date, in timeZone: TimeZone) -> LocalDate {
        let local = instant.timeIntervalSince1970 + Double(timeZone.secondsFromGMT(for: instant))
        return LocalDate(dayNumber: Int((local / 86_400).rounded(.down)))
    }

    /// `today(at:in:)` for an IANA identifier; `nil` when the identifier is unknown.
    public static func today(at instant: Date, timeZoneIdentifier: String) -> LocalDate? {
        TimeZone(identifier: timeZoneIdentifier).map { today(at: instant, in: $0) }
    }

    public static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public var description: String {
        let y = String(year), m = String(month), d = String(day)
        return String(repeating: "0", count: max(0, 4 - y.count)) + y + "-"
            + (m.count < 2 ? "0" : "") + m + "-" + (d.count < 2 ? "0" : "") + d
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let text = try c.decode(String.self)
        guard let value = LocalDate(text) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid local date (YYYY-MM-DD): \(text)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

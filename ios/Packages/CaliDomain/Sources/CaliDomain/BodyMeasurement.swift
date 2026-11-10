import Foundation

// IOS-018 / CON-007 (ADR-063, ADR-064): user-entered body measurements.
// Sensitive data: never AI input, never on the Lock Screen, widget, Live Activity or notifications, and the
// value is never written to a log or an audit row. Nothing here is advice; a measurement is only recorded.

public enum BodyMeasurementKind: String, Codable, CaseIterable, Sendable {
    /// Kilograms. The unit is fixed by the kind and there is no unit field (ADR-063).
    case weight

    /// db/007 `ck_body_measurements_value`: 20..500 for weight.
    public var range: ClosedRange<Decimal> {
        switch self {
        case .weight: 20...500
        }
    }

    /// Excess decimals are rejected, never rounded.
    public var fractionDigits: Int { 2 }
}

public struct BodyMeasurement: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: BodyMeasurementKind
    public var value: Decimal
    public var measuredAt: Date
    /// Set when the user deletes the entry (soft delete, so sync can carry it).
    public var deletedAt: Date?

    public init(id: UUID = UUID(), kind: BodyMeasurementKind = .weight, value: Decimal, measuredAt: Date, deletedAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.measuredAt = measuredAt
        self.deletedAt = deletedAt
    }
}

public enum BodyMeasurementRules {
    /// `value` in range with at most 2 decimals, and `measuredAt` not after `now` (the change time,
    /// `clientChangedAt`); a future measurement is rejected, never clamped.
    public static func validate(kind: BodyMeasurementKind, value: Decimal, measuredAt: Date, now: Date) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if !kind.range.contains(value) {
            issues.append(ValidationIssue(field: "value", reason: .outOfRange,
                                          detail: "not in \(kind.range.lowerBound)...\(kind.range.upperBound)"))
        } else {
            var source = value
            var rounded = Decimal()
            NSDecimalRound(&rounded, &source, kind.fractionDigits, .plain)
            if rounded != value {
                issues.append(ValidationIssue(field: "value", reason: .outOfRange, detail: "more than \(kind.fractionDigits) decimals"))
            }
        }
        if measuredAt > now {
            issues.append(ValidationIssue(field: "measuredAt", reason: .notAllowed, detail: "after the change time"))
        }
        return issues
    }

    /// Live entries of `kind`, newest measurement first (several per day are allowed).
    public static func entries(_ all: [BodyMeasurement], kind: BodyMeasurementKind = .weight) -> [BodyMeasurement] {
        all.filter { $0.kind == kind && $0.deletedAt == nil }.sorted { $0.measuredAt > $1.measuredAt }
    }

    /// Latest minus the one before it, nil with fewer than two entries. Shown as a plain signed number.
    public static func lastChange(_ all: [BodyMeasurement], kind: BodyMeasurementKind = .weight) -> Decimal? {
        let list = entries(all, kind: kind)
        guard list.count >= 2 else { return nil }
        return list[0].value - list[1].value
    }
}

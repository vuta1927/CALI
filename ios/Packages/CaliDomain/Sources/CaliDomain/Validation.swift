import Foundation

/// Product-policy limits (docs/07 §5, contracts/entity-payloads.schema.json, docs/02 §5).
public enum DomainLimits {
    /// `set_count` integer 1..20.
    public static let setCount: ClosedRange<Int> = 1...20
    /// `rest_seconds` integer 0..3600.
    public static let restSeconds: ClosedRange<Int> = 0...3600
    /// `rpe` integer 1..10.
    public static let rpe: ClosedRange<Int> = 1...10
    /// `holdSeconds` 1..3600 (schema `target.static_hold`).
    public static let holdSeconds: ClosedRange<Int> = 1...3600
    /// Pre-countdown seconds accepted by `StartSet` (0 = countdown disabled in Settings; default 3).
    public static let countdownSeconds: ClosedRange<Int> = 0...10
    /// Single `ExtendRest` increment (UX default is +30s).
    public static let restExtensionSeconds: ClosedRange<Int> = 1...3600
    /// Upper bound for the *remaining* rest after an extension (reuses the rest policy cap).
    public static let maxRemainingRestSeconds = 3600
    /// Free-text reason length for skip/abandon.
    public static let maxReasonLength = 500
    /// Maximum exercises per session (defensive bound; not a documented product policy).
    public static let maxExecutionsPerSession = 50
    /// CON-006 (ADR-062): load `reps` 1..500 (schema `target.load`).
    public static let loadReps: ClosedRange<Int> = 1...500
    /// CON-006 (ADR-062): `loadKg` / `actualLoadKg` 0..1000 kg (ADR-046: kilograms only).
    public static let loadKg: ClosedRange<Decimal> = 0...1000
    /// CON-006 (ADR-062): at most 2 decimals; more precision is rejected, never rounded (db/006).
    public static let loadKgFractionDigits = 2
}

/// A single validation failure. `field` uses the contract JSON key names.
public struct ValidationIssue: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Reason: String, Codable, Sendable {
        case outOfRange = "out_of_range"
        case missing
        case notAllowed = "not_allowed"
        case inconsistent
        case duplicate
    }

    public let field: String
    public let reason: Reason
    public let detail: String

    public init(field: String, reason: Reason, detail: String) {
        self.field = field
        self.reason = reason
        self.detail = detail
    }

    public var description: String { "\(field): \(reason.rawValue) (\(detail))" }

    static func range<T: Comparable>(_ field: String, _ value: T, _ range: ClosedRange<T>) -> ValidationIssue? {
        range.contains(value) ? nil : ValidationIssue(field: field, reason: .outOfRange, detail: "\(value) not in \(range.lowerBound)...\(range.upperBound)")
    }

    static func min<T: Comparable>(_ field: String, _ value: T, _ minimum: T) -> ValidationIssue? {
        value >= minimum ? nil : ValidationIssue(field: field, reason: .outOfRange, detail: "\(value) < \(minimum)")
    }

    /// CON-006 (ADR-062): kilograms in `DomainLimits.loadKg` with at most `DomainLimits.loadKgFractionDigits` decimals.
    static func loadKg(_ field: String, _ value: Decimal) -> ValidationIssue? {
        if let issue = range(field, value, DomainLimits.loadKg) { return issue }
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, DomainLimits.loadKgFractionDigits, .plain)
        return rounded == value ? nil : ValidationIssue(field: field, reason: .outOfRange, detail: "\(value) has more than \(DomainLimits.loadKgFractionDigits) decimals")
    }
}

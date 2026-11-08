import Foundation

/// Running bounds from CON-004 (`contracts/entity-payloads.schema.json`, `db/003_running_measurement.sql`).
/// Kept apart from `DomainLimits` so CON-006 (`load`) and IOS-011 do not edit the same enum.
public enum RunningLimits {
    /// `target.distance.distanceMeters` 1..500000.
    public static let targetDistanceMeters: ClosedRange<Int> = 1...500_000
    /// `target.distance.durationSeconds` / `target.duration.durationSeconds` 1..86400 (24 h).
    public static let targetDurationSeconds: ClosedRange<Int> = 1...86_400
    /// `set_result.distanceMeters` 0..1000000 (SQL `ck_set_results_distance_meters`).
    public static let resultDistanceMeters: ClosedRange<Int> = 0...1_000_000
    /// `set_result.durationSeconds` 0..86400 (SQL `ck_set_results_duration_seconds`).
    public static let resultDurationSeconds: ClosedRange<Int> = 0...86_400
}

/// Planned target of a running exercise, JSON shape of `$defs/target` kinds `distance` / `duration`,
/// e.g. `{ "kind": "distance", "distanceMeters": 5000, "durationSeconds": 1800 }`.
///
/// Deliberately a separate type, not new `Prescription` cases: adding cases would change the reducer
/// (`validateActuals`, `ConfirmSet` actuals) and the CON-002 vectors, which are not approved yet.
// TODO(CON-002): fold into `Prescription` + reducer actuals once CON-002 is approved.
public enum RunningTarget: Equatable, Hashable, Sendable {
    /// Distance in metres with an optional goal time (`5 × 1 km @ 4:50/km` → 1000 m, 290 s).
    case distance(distanceMeters: Int, durationSeconds: Int?)
    case duration(durationSeconds: Int)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case distance
        case duration
    }

    public var kind: Kind {
        switch self {
        case .distance: .distance
        case .duration: .duration
        }
    }

    /// Schema bounds. Field names use the contract keys (`target.distanceMeters`, `target.durationSeconds`).
    public func validate() -> [ValidationIssue] {
        switch self {
        case .distance(let meters, let seconds):
            return [
                ValidationIssue.range("target.distanceMeters", meters, RunningLimits.targetDistanceMeters),
                seconds.flatMap { ValidationIssue.range("target.durationSeconds", $0, RunningLimits.targetDurationSeconds) },
            ].compactMap { $0 }
        case .duration(let seconds):
            return [ValidationIssue.range("target.durationSeconds", seconds, RunningLimits.targetDurationSeconds)].compactMap { $0 }
        }
    }
}

extension RunningTarget: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, distanceMeters, durationSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .distance:
            self = .distance(distanceMeters: try c.decode(Int.self, forKey: .distanceMeters),
                             durationSeconds: try c.decodeIfPresent(Int.self, forKey: .durationSeconds))
        case .duration:
            self = .duration(durationSeconds: try c.decode(Int.self, forKey: .durationSeconds))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .distance(let meters, let seconds):
            try c.encode(meters, forKey: .distanceMeters)
            try c.encodeIfPresent(seconds, forKey: .durationSeconds)
        case .duration(let seconds):
            try c.encode(seconds, forKey: .durationSeconds)
        }
    }
}

/// Measured values of one running segment (`set_result.distanceMeters` / `durationSeconds`).
/// Only what the user entered is stored; pace is always derived (CON-004, ADR-055).
public struct RunningResult: Equatable, Hashable, Sendable, Codable {
    public var distanceMeters: Int?
    public var durationSeconds: Int?

    public init(distanceMeters: Int? = nil, durationSeconds: Int? = nil) {
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
    }

    /// Cross-field rules of CON-004 (docs/03 §3.1, `fixtures/validation/business_rules.json`):
    /// - running fields are only allowed when the snapshot target kind is `distance` or `duration`;
    /// - bounds 0..1000000 m and 0..86400 s (a duration over 24 h is rejected);
    /// - a completed `distance` set needs distance > 0 and duration > 0 (so pace can be derived);
    /// - a completed `duration` set needs duration > 0 (distance optional).
    /// `snapshotTargetKind` is the raw `prescribedSnapshot.target.kind`.
    public func validate(snapshotTargetKind: String, isCompleted: Bool) -> [ValidationIssue] {
        guard let kind = RunningTarget.Kind(rawValue: snapshotTargetKind) else {
            return [
                distanceMeters.map { _ in ValidationIssue(field: "distanceMeters", reason: .notAllowed, detail: "only for distance/duration targets, got \(snapshotTargetKind)") },
                durationSeconds.map { _ in ValidationIssue(field: "durationSeconds", reason: .notAllowed, detail: "only for distance/duration targets, got \(snapshotTargetKind)") },
            ].compactMap { $0 }
        }
        var issues = [
            distanceMeters.flatMap { ValidationIssue.range("distanceMeters", $0, RunningLimits.resultDistanceMeters) },
            durationSeconds.flatMap { ValidationIssue.range("durationSeconds", $0, RunningLimits.resultDurationSeconds) },
        ].compactMap { $0 }
        guard isCompleted, issues.isEmpty else { return issues }
        if kind == .distance, (distanceMeters ?? 0) <= 0 {
            issues.append(ValidationIssue(field: "distanceMeters", reason: .missing, detail: "completed distance set needs distanceMeters > 0"))
        }
        if (durationSeconds ?? 0) <= 0 {
            issues.append(ValidationIssue(field: "durationSeconds", reason: .missing, detail: "completed \(kind.rawValue) set needs durationSeconds > 0"))
        }
        return issues
    }
}

/// Pace in seconds per kilometre, derived from distance and time and never stored (CON-004).
/// Kilometres only (ADR-055): there is no per-mile variant.
public struct Pace: Equatable, Hashable, Sendable {
    public let distanceMeters: Int
    public let durationSeconds: Int

    /// Rejects what cannot give a meaningful pace: distance 0 (division by zero), duration 0, and values
    /// outside the stored result bounds (duration over 24 h, distance over 1000 km).
    public static func derive(distanceMeters: Int, durationSeconds: Int) -> Result<Pace, ValidationIssue> {
        if distanceMeters <= 0 {
            return .failure(ValidationIssue(field: "distanceMeters", reason: .outOfRange, detail: "pace needs distanceMeters > 0"))
        }
        if let issue = ValidationIssue.range("distanceMeters", distanceMeters, RunningLimits.resultDistanceMeters) {
            return .failure(issue)
        }
        if durationSeconds <= 0 {
            return .failure(ValidationIssue(field: "durationSeconds", reason: .outOfRange, detail: "pace needs durationSeconds > 0"))
        }
        if let issue = ValidationIssue.range("durationSeconds", durationSeconds, RunningLimits.resultDurationSeconds) {
            return .failure(issue)
        }
        return .success(Pace(distanceMeters: distanceMeters, durationSeconds: durationSeconds))
    }

    /// Exact value, `durationSeconds / (distanceMeters / 1000)`.
    public var secondsPerKilometer: Double { Double(durationSeconds) * 1000 / Double(distanceMeters) }

    /// Rounded to the nearest whole second, halves up (integer arithmetic, no floating-point drift).
    public var roundedSecondsPerKilometer: Int {
        (durationSeconds * 2000 + distanceMeters) / (2 * distanceMeters)
    }

    /// `4:50/km`; at one hour per km or slower `1:02:05/km`.
    public var formatted: String {
        let total = roundedSecondsPerKilometer
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let ss = (s < 10 ? "0" : "") + String(s)
        if h > 0 {
            return "\(h):" + (m < 10 ? "0" : "") + "\(m):" + ss + "/km"
        }
        return "\(m):" + ss + "/km"
    }
}

/// Display helpers for running values (docs/19 §4.1, locale vi: decimal comma, `.` thousands separator).
/// Implemented with integers so output does not depend on the platform's locale data.
public enum RunningFormat {
    /// Kilometres with two decimals, rounded half up from metres: 8254 m → `8,25 km`, 8255 m → `8,26 km`.
    public static func kilometers(distanceMeters: Int) -> String {
        let hundredths = (max(0, distanceMeters) + 5) / 10
        let whole = hundredths / 100, fraction = hundredths % 100
        var digits = String(whole)
        var grouped = ""
        while digits.count > 3 {
            grouped = "." + digits.suffix(3) + grouped
            digits.removeLast(3)
        }
        return digits + grouped + "," + (fraction < 10 ? "0" : "") + String(fraction) + " km"
    }
}

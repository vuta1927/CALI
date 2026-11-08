import Foundation

/// One `plan_activation` row (CON-003, docs/19 §4): an inclusive local-date range of a plan lineage.
/// `toDate == nil` means open-ended. Callers pass live (not soft-deleted) rows only.
public struct PlanActivation: Equatable, Hashable, Sendable, Codable {
    public var id: UUID
    public var fromDate: LocalDate
    public var toDate: LocalDate?
    /// IANA zone the local dates refer to (BR-1). Needed to decide "today" for a new activation.
    public var timezone: String

    public init(id: UUID, fromDate: LocalDate, toDate: LocalDate? = nil, timezone: String) {
        self.id = id
        self.fromDate = fromDate
        self.toDate = toDate
        self.timezone = timezone
    }

    public func contains(_ day: LocalDate) -> Bool {
        fromDate <= day && (toDate.map { day <= $0 } ?? true)
    }

    /// Inclusive ranges intersect (`daterange(..., '[]') &&` in db/004).
    public func overlaps(_ other: PlanActivation) -> Bool {
        let selfEnd = toDate, otherEnd = other.toDate
        let startsBeforeOtherEnds = otherEnd.map { fromDate <= $0 } ?? true
        let otherStartsBeforeSelfEnds = selfEnd.map { other.fromDate <= $0 } ?? true
        return startsBeforeOtherEnds && otherStartsBeforeSelfEnds
    }
}

/// What the lifecycle needs to know about the current revision of one plan lineage.
public struct PlanLineageState: Equatable, Hashable, Sendable, Codable {
    public var lineageId: UUID
    public var endedAt: Date?
    public var archivedAt: Date?
    /// Soft delete (tombstone, ADR-040).
    public var deletedAt: Date?
    public var activations: [PlanActivation]

    public init(lineageId: UUID, endedAt: Date? = nil, archivedAt: Date? = nil, deletedAt: Date? = nil, activations: [PlanActivation] = []) {
        self.lineageId = lineageId
        self.endedAt = endedAt
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.activations = activations
    }
}

/// Computed plan status (docs/19 §4.2). Never stored: it is always derived from activations and timestamps.
public enum PlanStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case scheduled
    case active
    case paused
    case ended
    case archived
    case deleted

    /// D1/I2: only `scheduled` and `active` plans take a slot of the active-plan limit.
    public var countsTowardActiveLimit: Bool { self == .scheduled || self == .active }
}

/// Result of the client-side I2 check (mirror of the `plan_activations_guard` trigger in db/004).
public enum ActivePlanLimitCheck: Equatable, Sendable {
    case allowed
    /// `count` distinct plans would be followed on `day` (the worst, earliest such day).
    /// `lineageIds` are the plans covering that day, sorted, including the candidate's.
    case exceedsLimit(day: LocalDate, count: Int, limit: Int, lineageIds: [UUID])

    /// Error code shared with the server (`RAISE EXCEPTION 'active_plan_limit'`).
    public static let errorCode = "active_plan_limit"
}

public enum PlanLifecycle {
    /// D1, accepted 2026-11-08. The server value is configurable (`cali_setting_int('active_plan_limit')`);
    /// callers should pass the server's value when they have it.
    public static let defaultActivePlanLimit = 3

    /// docs/19 §4.2. Precedence: deleted > archived > ended > active > scheduled > paused > draft.
    /// - `active`: an activation contains `today`.
    /// - `scheduled`: no activation contains today, but one starts after today.
    /// - `paused`: had activations, none open now or later, not ended.
    /// - `draft`: no activation.
    /// Archive stores no status: clearing `archivedAt` returns to the computed one. An event plan past its
    /// event date stays `active` until the user chooses (MP-07); that is a card, not a status.
    public static func status(of plan: PlanLineageState, today: LocalDate) -> PlanStatus {
        if plan.deletedAt != nil { return .deleted }
        if plan.archivedAt != nil { return .archived }
        if plan.endedAt != nil { return .ended }
        if plan.activations.contains(where: { $0.contains(today) }) { return .active }
        if plan.activations.contains(where: { $0.fromDate > today }) { return .scheduled }
        return plan.activations.isEmpty ? .draft : .paused
    }

    /// Plan IDs with status `active` or `scheduled` (what the limit counts today).
    public static func plansTakingSlots(_ plans: [PlanLineageState], today: LocalDate) -> [UUID] {
        plans.filter { status(of: $0, today: today).countsTowardActiveLimit }.map(\.lineageId).sorted { $0.uuidString < $1.uuidString }
    }

    /// I1: pairs of activations of the same plan whose ranges overlap, as `(a.id, b.id)` in input order.
    public static func overlappingActivations(_ activations: [PlanActivation]) -> [(UUID, UUID)] {
        var pairs: [(UUID, UUID)] = []
        for i in activations.indices {
            for j in activations.indices where j > i && activations[i].overlaps(activations[j]) {
                pairs.append((activations[i].id, activations[j].id))
            }
        }
        return pairs
    }

    /// Rules for creating (or re-opening) an activation, run before the command is persisted:
    /// - BR-1 / ADR-041: `fromDate` is not before the local date of `now` in the activation's own `timezone`
    ///   (today is allowed). An unknown zone is rejected on `timezone`.
    /// - `toDate >= fromDate` (`ck_plan_activations_dates`).
    /// - I1: no overlap with the plan's other live activations (`existing`).
    /// `now` is the command's `clientChangedAt`. A later clock or zone change never rewrites a stored
    /// activation; it only changes what "today" is for the next command.
    public static func validateNewActivation(_ activation: PlanActivation, existing: [PlanActivation] = [], now: Date) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if let today = LocalDate.today(at: now, timeZoneIdentifier: activation.timezone) {
            if activation.fromDate < today {
                issues.append(ValidationIssue(field: "fromDate", reason: .outOfRange, detail: "\(activation.fromDate) is before today \(today) in \(activation.timezone)"))
            }
        } else {
            issues.append(ValidationIssue(field: "timezone", reason: .outOfRange, detail: "unknown time zone \(activation.timezone)"))
        }
        if let to = activation.toDate, to < activation.fromDate {
            issues.append(ValidationIssue(field: "toDate", reason: .inconsistent, detail: "\(to) is before fromDate \(activation.fromDate)"))
        }
        if let clash = existing.first(where: { $0.id != activation.id && $0.overlaps(activation) }) {
            issues.append(ValidationIssue(field: "fromDate", reason: .inconsistent, detail: "overlaps activation \(clash.id.uuidString.lowercased())"))
        }
        return issues
    }

    /// Client-side I2 check with the same semantics as the db/004 trigger, so the UI can refuse early
    /// (the server stays authoritative):
    /// - An update of the same activation and plan that only shrinks or closes the range is always allowed.
    /// - Counted: the candidate, plus live activations (other IDs) of plans that are neither deleted nor ended.
    /// - The number of followed plans only rises at an activation start, so only the candidate's `fromDate`
    ///   and every counted `fromDate` inside the candidate's range are checked.
    /// - The worst day is the one with the most distinct plans, earliest on ties.
    /// `previous` is the stored version of the candidate when this is an update.
    public static func checkActivePlanLimit(
        candidate: PlanActivation,
        candidateLineageId: UUID,
        previous: (lineageId: UUID, activation: PlanActivation)? = nil,
        plans: [PlanLineageState],
        limit: Int = defaultActivePlanLimit
    ) -> ActivePlanLimitCheck {
        if let previous, previous.lineageId == candidateLineageId, previous.activation.id == candidate.id,
           candidate.fromDate >= previous.activation.fromDate, isEnd(candidate.toDate, notAfter: previous.activation.toDate) {
            return .allowed
        }

        var live: [(lineageId: UUID, activation: PlanActivation)] = plans
            .filter { $0.deletedAt == nil && $0.endedAt == nil }
            .flatMap { plan in plan.activations.filter { $0.id != candidate.id }.map { (plan.lineageId, $0) } }
        live.append((candidateLineageId, candidate))

        let candidateDays = Set(live.map(\.activation.fromDate).filter { candidate.contains($0) })
        var worst: (day: LocalDate, lineages: Set<UUID>)?
        for day in candidateDays.sorted() {
            let covering = Set(live.filter { $0.activation.contains(day) }.map(\.lineageId))
            if worst == nil || covering.count > worst!.lineages.count {
                worst = (day, covering)
            }
        }
        guard let worst, worst.lineages.count > limit else { return .allowed }
        return .exceedsLimit(day: worst.day, count: worst.lineages.count, limit: limit,
                             lineageIds: worst.lineages.sorted { $0.uuidString < $1.uuidString })
    }

    /// `COALESCE(new, 'infinity') <= COALESCE(old, 'infinity')`.
    private static func isEnd(_ new: LocalDate?, notAfter old: LocalDate?) -> Bool {
        guard let old else { return true }
        guard let new else { return false }
        return new <= old
    }
}

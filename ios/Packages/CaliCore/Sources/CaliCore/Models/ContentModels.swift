import CaliDomain
import Foundation

// App content models (catalog, plan, history, AI review, settings). Moved from the app target in IOS-001
// so the GRDB store and the one-time JSON importer can use them on Linux. Shapes follow
// contracts/entity-payloads.schema.json where a contract exists; local-only fields are marked as such.
// The JSON coding keys are unchanged: `cali-poc.json` snapshots written before IOS-001 still decode.

public enum ExerciseLevel: String, Codable, Sendable, CaseIterable {
    case beginner, intermediate, advanced

    public var label: String {
        switch self {
        case .beginner: "Cơ bản"
        case .intermediate: "Trung cấp"
        case .advanced: "Nâng cao"
        }
    }
}

/// Local media metadata. Relative filenames survive changes to the app container path; the app resolves
/// them to a file URL. User media is never uploaded.
public struct ExerciseMediaReference: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case remote, local }
    public var source: Source
    public var value: String

    public init(source: Source, value: String) {
        self.source = source
        self.value = value
    }

    /// HTTPS links only, without credentials.
    public static func remote(_ text: String) -> Self? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return Self(source: .remote, value: value)
    }

    /// A bare filename inside the app's media directory (no path components).
    public var isValidLocalName: Bool {
        source == .local && !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }
}

public struct Exercise: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var slug: String
    public var name: String
    public var type: ExerciseType
    public var level: ExerciseLevel
    public var equipment: [String]
    public var muscles: [String]
    public var cues: [String]
    public var mistakes: [String]
    public var catalogVersion: Int
    /// Local-only: SF Symbol + palette used by the placeholder poster.
    public var symbol: String
    public var paletteIndex: Int

    /// Local-only user media, never included in the server catalog payload.
    public var poster: ExerciseMediaReference? = nil
    public var video: ExerciseMediaReference? = nil

    public init(
        id: UUID, slug: String, name: String, type: ExerciseType, level: ExerciseLevel, equipment: [String],
        muscles: [String], cues: [String], mistakes: [String], catalogVersion: Int, symbol: String, paletteIndex: Int,
        poster: ExerciseMediaReference? = nil, video: ExerciseMediaReference? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.type = type
        self.level = level
        self.equipment = equipment
        self.muscles = muscles
        self.cues = cues
        self.mistakes = mistakes
        self.catalogVersion = catalogVersion
        self.symbol = symbol
        self.paletteIndex = paletteIndex
        self.poster = poster
        self.video = video
    }

    public var equipmentLabel: String {
        equipment.isEmpty ? "Không cần dụng cụ" : equipment.joined(separator: ", ")
    }
}

public struct PlannedExercise: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var exerciseId: UUID
    public var setCount: Int
    public var target: Prescription
    public var restSeconds: Int

    public init(id: UUID, exerciseId: UUID, setCount: Int, target: Prescription, restSeconds: Int) {
        self.id = id
        self.exerciseId = exerciseId
        self.setCount = setCount
        self.target = target
        self.restSeconds = restSeconds
    }
}

public struct PlannedWorkout: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// ISO weekday: 1 = Thứ 2 ... 7 = Chủ nhật. 0 = not tied to a day (quick test, never stored in a plan).
    public var weekday: Int
    public var title: String
    /// Local-only subtitle.
    public var focus: String
    public var exercises: [PlannedExercise]

    public init(id: UUID, weekday: Int, title: String, focus: String, exercises: [PlannedExercise]) {
        self.id = id
        self.weekday = weekday
        self.title = title
        self.focus = focus
        self.exercises = exercises
    }

    public var totalSets: Int { exercises.reduce(0) { $0 + $1.setCount } }

    /// Rough duration: work + rest + ~20 s setup per set.
    public var estimatedMinutes: Int {
        let seconds = exercises.reduce(0) { total, item in
            let work: Int
            switch item.target {
            // A distance segment: its goal time, else an easy 6:00/km (estimate only, shown with "~").
            case .distance(let meters, let goal): work = goal ?? meters * 360 / 1000
            default: work = item.target.targetDurationSeconds ?? 40
            }
            return total + item.setCount * (work + 20) + max(item.setCount - 1, 0) * item.restSeconds
        }
        return max(1, Int((Double(seconds) / 60).rounded()))
    }
}

/// docs/19 D3 / CON-003 `training_plan.kind`.
public enum PlanKind: String, Codable, Sendable, CaseIterable {
    case weekly, event
}

/// docs/19 D2 / CON-003 `training_plan.primaryDiscipline`.
public enum PlanDiscipline: String, Codable, Sendable, CaseIterable {
    case calisthenics, running, gym, mixed
}

/// CON-003 `training_plan.endReason`.
public enum PlanEndReason: String, Codable, Sendable {
    case completed, stopped
}

/// The current revision of one plan lineage (CON-003), with its activations. The user-facing status is
/// never stored; it is computed from `activations`, `endedAt`, `archivedAt` and `deletedAt` (docs/19 §4.2).
public struct WorkoutPlan: Codable, Hashable, Sendable, Identifiable {
    /// Soft delete (tombstone, ADR-040); historical sessions keep their original IDs.
    public var deletedAt: Date? = nil
    /// Revision id (`training_plan.id`).
    public var id: UUID
    public var title: String
    public var workouts: [PlannedWorkout]
    /// The plan the user sees (docs/19 D4). A root revision has `lineageId == id`.
    public var lineageId: UUID
    public var revision: Int
    public var kind: PlanKind
    /// Required when `kind == .event`.
    public var eventDate: LocalDate?
    public var eventName: String?
    /// `nil` = derive from the exercises when writing (BR-10).
    public var primaryDiscipline: PlanDiscipline?
    public var endedAt: Date?
    public var endReason: PlanEndReason?
    /// At most 500 characters.
    public var endNote: String?
    public var archivedAt: Date?
    public var createdAt: Date?
    /// Live (not cancelled) activations of the lineage, oldest first.
    public var activations: [PlanActivation]
    /// CON-005 phases of this revision, in order. Their total is the weekly program length.
    public var phases: [PlanPhase] = []

    public init(
        deletedAt: Date? = nil, id: UUID, title: String, workouts: [PlannedWorkout], lineageId: UUID? = nil, revision: Int = 1,
        kind: PlanKind = .weekly, eventDate: LocalDate? = nil, eventName: String? = nil, primaryDiscipline: PlanDiscipline? = nil,
        endedAt: Date? = nil, endReason: PlanEndReason? = nil, endNote: String? = nil, archivedAt: Date? = nil,
        createdAt: Date? = nil, activations: [PlanActivation] = [], phases: [PlanPhase] = []
    ) {
        self.phases = phases
        self.deletedAt = deletedAt
        self.id = id
        self.title = title
        self.workouts = workouts
        self.lineageId = lineageId ?? id
        self.revision = revision
        self.kind = kind
        self.eventDate = eventDate
        self.eventName = eventName
        self.primaryDiscipline = primaryDiscipline
        self.endedAt = endedAt
        self.endReason = endReason
        self.endNote = endNote
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.activations = activations
    }

    private enum CodingKeys: String, CodingKey {
        case deletedAt, id, title, workouts, lineageId, revision, kind, eventDate, eventName, primaryDiscipline,
             endedAt, endReason, endNote, archivedAt, createdAt, activations, phases
    }

    /// Snapshots written before IOS-013 only have `id`, `title`, `workouts` and `deletedAt`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        workouts = try c.decode([PlannedWorkout].self, forKey: .workouts)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        lineageId = try c.decodeIfPresent(UUID.self, forKey: .lineageId) ?? id
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        kind = try c.decodeIfPresent(PlanKind.self, forKey: .kind) ?? .weekly
        eventDate = try c.decodeIfPresent(LocalDate.self, forKey: .eventDate)
        eventName = try c.decodeIfPresent(String.self, forKey: .eventName)
        primaryDiscipline = try c.decodeIfPresent(PlanDiscipline.self, forKey: .primaryDiscipline)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        endReason = try c.decodeIfPresent(PlanEndReason.self, forKey: .endReason)
        endNote = try c.decodeIfPresent(String.self, forKey: .endNote)
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        activations = try c.decodeIfPresent([PlanActivation].self, forKey: .activations) ?? []
        phases = try c.decodeIfPresent([PlanPhase].self, forKey: .phases) ?? []
    }

    public var lineageState: PlanLineageState {
        PlanLineageState(lineageId: lineageId, endedAt: endedAt, archivedAt: archivedAt, deletedAt: deletedAt, activations: activations)
    }

    /// docs/19 §4.2.
    public func status(today: LocalDate) -> PlanStatus {
        PlanLifecycle.status(of: lineageState, today: today)
    }

    /// A weekly plan's length is the sum of its phases (CON-005); without phases it never finishes on its own.
    public var program: PlanProgram {
        if kind == .event, let eventDate { return .event(eventDate: eventDate) }
        return .weekly(totalWeeks: phases.isEmpty ? nil : PhaseTimeline.totalWeeks(phases))
    }

    /// Workouts tied to a weekday, as schedule slots.
    public var slots: [WeeklySlot] {
        workouts.filter { (1...7).contains($0.weekday) }.map { WeeklySlot(plannedWorkoutId: $0.id, weekday: $0.weekday) }
    }

    /// The activation that is open on or after `today` (the one pause / end / delete close).
    public func openActivation(today: LocalDate) -> PlanActivation? {
        activations.first { $0.toDate.map { $0 >= today } ?? true }
    }
}

/// One set as stored in local history. Built from a domain `SetRecord` for real sessions, or
/// directly for labelled sample history.
public struct LoggedSet: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var exerciseId: UUID
    public var setIndex: Int
    public var status: SetStatus
    public var target: Prescription
    public var reps: Int?
    public var holdMs: Int64?
    public var workMs: Int64?
    public var rpe: Int?
    public var note: String?
    public var skipReason: String?
    /// CON-006 (ADR-046/062): kilograms lifted for a load set; nil otherwise and for older snapshots.
    public var loadKg: Decimal? = nil
    /// CON-004: running segment entered by hand; pace is derived (`pace`), never stored.
    public var distanceMeters: Int? = nil
    public var durationSeconds: Int? = nil
    /// CON-008: the `pain` criterion and the extra criteria values with the config version they were entered with.
    public var painReported: Bool? = nil
    public var criteriaVersion: Int? = nil
    public var criteria: [String: CriteriaValue]? = nil

    public init(
        id: UUID, exerciseId: UUID, setIndex: Int, status: SetStatus, target: Prescription, reps: Int? = nil,
        holdMs: Int64? = nil, workMs: Int64? = nil, rpe: Int? = nil, note: String? = nil, skipReason: String? = nil,
        loadKg: Decimal? = nil, distanceMeters: Int? = nil, durationSeconds: Int? = nil,
        painReported: Bool? = nil, criteriaVersion: Int? = nil, criteria: [String: CriteriaValue]? = nil
    ) {
        self.painReported = painReported
        self.criteriaVersion = criteriaVersion
        self.criteria = criteria
        self.id = id
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.status = status
        self.target = target
        self.reps = reps
        self.holdMs = holdMs
        self.workMs = workMs
        self.rpe = rpe
        self.note = note
        self.skipReason = skipReason
        self.loadKg = loadKg
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
    }

    public var pace: Pace? {
        SetActuals(distanceMeters: distanceMeters, durationSeconds: durationSeconds).pace
    }
}

extension LoggedSet {
    public init(record: SetRecord) {
        self.init(
            id: record.setResultId,
            exerciseId: record.prescribed.exerciseId,
            setIndex: record.key.setIndex,
            status: record.status,
            target: record.prescribed.target,
            reps: record.actual.reps,
            holdMs: record.actual.holdMs,
            workMs: record.actual.workMs,
            rpe: record.actual.rpe,
            note: record.actual.note,
            skipReason: record.skipReason,
            loadKg: record.actual.loadKg,
            distanceMeters: record.actual.distanceMeters,
            durationSeconds: record.actual.durationSeconds,
            painReported: record.actual.painReported,
            criteriaVersion: record.actual.criteriaVersion,
            criteria: record.actual.criteria
        )
    }
}

public struct CompletedSession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var plannedWorkoutId: UUID?
    public var startedAt: Date
    public var finishedAt: Date
    public var status: SessionStatus
    /// Exercise order as planned in the session (for grouping in detail views).
    public var exerciseIds: [UUID]
    public var plannedSetCount: Int
    public var sets: [LoggedSet]
    /// True for generated demo history (always shown with a "Dữ liệu mẫu" badge).
    public var isSample: Bool
    /// The plan lineage the planned workout belonged to when the session finished (MP-10). Kept on the
    /// session so it stays attributable after the workout is removed or the plan is deleted. `nil` for free
    /// sessions; older rows are resolved from `planned_workouts` when loaded.
    public var planLineageId: UUID? = nil

    public init(
        id: UUID, title: String, plannedWorkoutId: UUID?, startedAt: Date, finishedAt: Date, status: SessionStatus,
        exerciseIds: [UUID], plannedSetCount: Int, sets: [LoggedSet], isSample: Bool, planLineageId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.plannedWorkoutId = plannedWorkoutId
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.exerciseIds = exerciseIds
        self.plannedSetCount = plannedSetCount
        self.sets = sets
        self.isSample = isSample
        self.planLineageId = planLineageId
    }

    public var durationMinutes: Int { max(1, Int(finishedAt.timeIntervalSince(startedAt) / 60)) }
    public var completedSetCount: Int { sets.filter { $0.status == .completed }.count }
    public var skippedSetCount: Int { sets.filter { $0.status == .skipped }.count }
}

/// AI recommendation (docs/09). The app ships fixed sample recommendations; nothing calls an LLM.
public struct Recommendation: Identifiable, Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case accepted, rejected
    }

    public var id: UUID
    public var title: String
    public var rationale: String
    public var uncertainty: String
    /// 0...1
    public var confidence: Double
    public var exerciseId: UUID?
    public var fromLabel: String
    public var toLabel: String
    public var change: PlanChange?
    public var decision: Decision?
    public var decidedAt: Date?
    public var isSample: Bool

    public init(
        id: UUID, title: String, rationale: String, uncertainty: String, confidence: Double, exerciseId: UUID?,
        fromLabel: String, toLabel: String, change: PlanChange?, decision: Decision? = nil, decidedAt: Date? = nil,
        isSample: Bool
    ) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.uncertainty = uncertainty
        self.confidence = confidence
        self.exerciseId = exerciseId
        self.fromLabel = fromLabel
        self.toLabel = toLabel
        self.change = change
        self.decision = decision
        self.decidedAt = decidedAt
        self.isSample = isSample
    }
}

/// The concrete plan edit a recommendation proposes. Applied only after explicit approval (AGENTS rule 5).
public struct PlanChange: Codable, Hashable, Sendable {
    public var plannedWorkoutId: UUID
    public var plannedExerciseId: UUID
    public var newSetCount: Int?
    public var newTarget: Prescription?
    public var newRestSeconds: Int?

    public init(plannedWorkoutId: UUID, plannedExerciseId: UUID, newSetCount: Int? = nil, newTarget: Prescription? = nil, newRestSeconds: Int? = nil) {
        self.plannedWorkoutId = plannedWorkoutId
        self.plannedExerciseId = plannedExerciseId
        self.newSetCount = newSetCount
        self.newTarget = newTarget
        self.newRestSeconds = newRestSeconds
    }
}

public struct AuditEntry: Identifiable, Codable, Hashable, Sendable {
    /// The `commandId` of the change it records, so a repeated command finds its entry and is a no-op.
    public var id: UUID
    public var at: Date
    public var action: String
    public var detail: String

    public init(id: UUID, at: Date, action: String, detail: String) {
        self.id = id
        self.at = at
        self.action = action
        self.detail = detail
    }
}

/// Light, dark, or whatever the system uses. Chosen in Profile; stored on this device only.
public enum AppearanceMode: String, Codable, Sendable, CaseIterable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: "Theo hệ thống"
        case .light: "Sáng"
        case .dark: "Tối"
        }
    }
}

public struct AppSettings: Codable, Hashable, Sendable {
    public var countdownSeconds: Int = 3
    public var hapticsEnabled = true
    public var notificationsEnabled = true
    public var liveActivityEnabled = true
    /// IOS-019 (ADR-078): spoken cues; independent of haptics.
    public var voiceCuesEnabled = true
    /// IOS-021 (PO D3): "Tự động chuyển set" — a rest that ends while the app is open starts the next set. Default ON.
    public var autoAdvanceSets = true
    public var hasSeenWelcome = false
    /// ADR-046: load is stored in kg; this only changes how it is shown and typed.
    public var weightUnit: WeightUnit = .kg
    public var appearance: AppearanceMode = .system

    private enum CodingKeys: String, CodingKey {
        case countdownSeconds, hapticsEnabled, notificationsEnabled, liveActivityEnabled, voiceCuesEnabled, autoAdvanceSets, hasSeenWelcome, weightUnit, appearance
    }

    /// Settings saved by an older build have no `weightUnit` or `appearance`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        countdownSeconds = try c.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? 3
        hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        liveActivityEnabled = try c.decodeIfPresent(Bool.self, forKey: .liveActivityEnabled) ?? true
        voiceCuesEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceCuesEnabled) ?? true
        autoAdvanceSets = try c.decodeIfPresent(Bool.self, forKey: .autoAdvanceSets) ?? true
        hasSeenWelcome = try c.decodeIfPresent(Bool.self, forKey: .hasSeenWelcome) ?? false
        weightUnit = try c.decodeIfPresent(WeightUnit.self, forKey: .weightUnit) ?? .kg
        // An unknown value from a newer build falls back to the system setting instead of failing the whole settings row.
        appearance = (try? c.decodeIfPresent(AppearanceMode.self, forKey: .appearance)).flatMap { $0 } ?? .system
    }

    public init(
        countdownSeconds: Int = 3, hapticsEnabled: Bool = true, notificationsEnabled: Bool = true,
        liveActivityEnabled: Bool = true, hasSeenWelcome: Bool = false, weightUnit: WeightUnit = .kg,
        appearance: AppearanceMode = .system, voiceCuesEnabled: Bool = true
    ) {
        self.voiceCuesEnabled = voiceCuesEnabled
        self.weightUnit = weightUnit
        self.appearance = appearance
        self.countdownSeconds = countdownSeconds
        self.hapticsEnabled = hapticsEnabled
        self.notificationsEnabled = notificationsEnabled
        self.liveActivityEnabled = liveActivityEnabled
        self.hasSeenWelcome = hasSeenWelcome
    }
}

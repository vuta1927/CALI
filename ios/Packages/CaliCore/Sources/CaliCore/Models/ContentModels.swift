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
            let work = item.target.targetDurationSeconds ?? 40
            return total + item.setCount * (work + 20) + max(item.setCount - 1, 0) * item.restSeconds
        }
        return max(1, Int((Double(seconds) / 60).rounded()))
    }
}

public struct WorkoutPlan: Codable, Hashable, Sendable {
    /// Soft delete (tombstone); historical sessions keep their original IDs.
    public var deletedAt: Date? = nil
    public var id: UUID
    public var title: String
    public var workouts: [PlannedWorkout]

    public init(deletedAt: Date? = nil, id: UUID, title: String, workouts: [PlannedWorkout]) {
        self.deletedAt = deletedAt
        self.id = id
        self.title = title
        self.workouts = workouts
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

    public init(
        id: UUID, exerciseId: UUID, setIndex: Int, status: SetStatus, target: Prescription, reps: Int? = nil,
        holdMs: Int64? = nil, workMs: Int64? = nil, rpe: Int? = nil, note: String? = nil, skipReason: String? = nil,
        loadKg: Decimal? = nil
    ) {
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
            loadKg: record.actual.loadKg
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

    public init(
        id: UUID, title: String, plannedWorkoutId: UUID?, startedAt: Date, finishedAt: Date, status: SessionStatus,
        exerciseIds: [UUID], plannedSetCount: Int, sets: [LoggedSet], isSample: Bool
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

public struct AppSettings: Codable, Hashable, Sendable {
    public var countdownSeconds: Int = 3
    public var hapticsEnabled = true
    public var notificationsEnabled = true
    public var liveActivityEnabled = true
    public var hasSeenWelcome = false

    public init(
        countdownSeconds: Int = 3, hapticsEnabled: Bool = true, notificationsEnabled: Bool = true,
        liveActivityEnabled: Bool = true, hasSeenWelcome: Bool = false
    ) {
        self.countdownSeconds = countdownSeconds
        self.hapticsEnabled = hapticsEnabled
        self.notificationsEnabled = notificationsEnabled
        self.liveActivityEnabled = liveActivityEnabled
        self.hasSeenWelcome = hasSeenWelcome
    }
}

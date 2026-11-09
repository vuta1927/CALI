import CaliDomain
import Foundation

// App-level view models for the POC. Shapes follow contracts/entity-payloads.schema.json where a
// contract exists (catalog, plan, planned exercise); POC-only fields are marked as such.

enum ExerciseLevel: String, Codable, Sendable, CaseIterable {
    case beginner, intermediate, advanced

    var label: String {
        switch self {
        case .beginner: "Cơ bản"
        case .intermediate: "Trung cấp"
        case .advanced: "Nâng cao"
        }
    }
}

struct Exercise: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var slug: String
    var name: String
    var type: ExerciseType
    var level: ExerciseLevel
    var equipment: [String]
    var muscles: [String]
    var cues: [String]
    var mistakes: [String]
    var catalogVersion: Int
    /// POC-only: SF Symbol + palette used by the placeholder poster.
    var symbol: String
    var paletteIndex: Int

    /// Local-only user media, never included in the server catalog payload.
    var poster: ExerciseMediaReference? = nil
    var video: ExerciseMediaReference? = nil

    var equipmentLabel: String {
        equipment.isEmpty ? "Không cần dụng cụ" : equipment.joined(separator: ", ")
    }
}

struct PlannedExercise: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var exerciseId: UUID
    var setCount: Int
    var target: Prescription
    var restSeconds: Int
}

struct PlannedWorkout: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// ISO weekday: 1 = Thứ 2 ... 7 = Chủ nhật. 0 = not tied to a day (quick test).
    var weekday: Int
    var title: String
    var focus: String
    var exercises: [PlannedExercise]

    var totalSets: Int { exercises.reduce(0) { $0 + $1.setCount } }

    /// Rough duration: work + rest + ~20 s setup per set.
    var estimatedMinutes: Int {
        let seconds = exercises.reduce(0) { total, item in
            let work = item.target.targetDurationSeconds ?? 40
            return total + item.setCount * (work + 20) + max(item.setCount - 1, 0) * item.restSeconds
        }
        return max(1, Int((Double(seconds) / 60).rounded()))
    }
}

struct WorkoutPlan: Codable, Hashable, Sendable {
    /// Local-only tombstone; historical sessions keep their original IDs.
    var deletedAt: Date? = nil
    var id: UUID
    var title: String
    var workouts: [PlannedWorkout]
}

/// One set as stored in local history. Built from a domain `SetRecord` for real sessions, or
/// directly for labelled sample history.
struct LoggedSet: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var exerciseId: UUID
    var setIndex: Int
    var status: SetStatus
    var target: Prescription
    var reps: Int?
    var holdMs: Int64?
    var workMs: Int64?
    var rpe: Int?
    var note: String?
    var skipReason: String?
    /// CON-006 (ADR-046/062): kilograms lifted for a load set; nil otherwise and for older snapshots.
    var loadKg: Decimal? = nil
}

extension LoggedSet {
    init(record: SetRecord) {
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

struct CompletedSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var plannedWorkoutId: UUID?
    var startedAt: Date
    var finishedAt: Date
    var status: SessionStatus
    /// Exercise order as planned in the session (for grouping in detail views).
    var exerciseIds: [UUID]
    var plannedSetCount: Int
    var sets: [LoggedSet]
    /// True for generated demo history (always shown with a "Dữ liệu mẫu" badge).
    var isSample: Bool

    var durationMinutes: Int { max(1, Int(finishedAt.timeIntervalSince(startedAt) / 60)) }
    var completedSetCount: Int { sets.filter { $0.status == .completed }.count }
    var skippedSetCount: Int { sets.filter { $0.status == .skipped }.count }
}

/// AI recommendation (docs/09). The POC ships fixed sample recommendations; nothing calls an LLM.
struct Recommendation: Identifiable, Codable, Hashable, Sendable {
    enum Decision: String, Codable, Sendable {
        case accepted, rejected
    }

    var id: UUID
    var title: String
    var rationale: String
    var uncertainty: String
    /// 0...1
    var confidence: Double
    var exerciseId: UUID?
    var fromLabel: String
    var toLabel: String
    var change: PlanChange?
    var decision: Decision?
    var decidedAt: Date?
    var isSample: Bool
}

/// The concrete plan edit a recommendation proposes. Applied only after explicit approval (AGENTS rule 5).
struct PlanChange: Codable, Hashable, Sendable {
    var plannedWorkoutId: UUID
    var plannedExerciseId: UUID
    var newSetCount: Int?
    var newTarget: Prescription?
    var newRestSeconds: Int?
}

struct AuditEntry: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var at: Date
    var action: String
    var detail: String
}

struct AppSettings: Codable, Hashable, Sendable {
    var countdownSeconds: Int = 3
    var hapticsEnabled = true
    var notificationsEnabled = true
    var liveActivityEnabled = true
    var hasSeenWelcome = false
}

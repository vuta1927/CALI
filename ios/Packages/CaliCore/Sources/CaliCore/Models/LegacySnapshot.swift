import CaliDomain
import Foundation

/// The JSON snapshot the app wrote to `Application Support/cali-poc.json` before IOS-001 (schema 1).
/// Kept only so `LegacySnapshotImporter` can move it into GRDB once; nothing writes this shape after
/// the import.
public struct PersistedSnapshot: Codable, Sendable {
    public static let currentSchema = 1

    public var schemaVersion = PersistedSnapshot.currentSchema
    /// Absent in snapshots written before IOS-009; the importer then uses the bundled catalog.
    public var catalog: [Exercise]? = nil
    public var plan: WorkoutPlan
    public var history: [CompletedSession]
    public var recommendations: [Recommendation]
    public var audit: [AuditEntry]
    public var settings: AppSettings
    public var active: ActiveSession?
    public var createdAt: Date

    public init(
        schemaVersion: Int = PersistedSnapshot.currentSchema, catalog: [Exercise]? = nil, plan: WorkoutPlan,
        history: [CompletedSession], recommendations: [Recommendation], audit: [AuditEntry], settings: AppSettings,
        active: ActiveSession? = nil, createdAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.catalog = catalog
        self.plan = plan
        self.history = history
        self.recommendations = recommendations
        self.audit = audit
        self.settings = settings
        self.active = active
        self.createdAt = createdAt
    }
}

/// The in-flight workout: the domain state plus the set records produced so far.
public struct ActiveSession: Codable, Sendable {
    public var state: SessionState
    public var title: String
    public var records: [SetRecord]

    public init(state: SessionState, title: String, records: [SetRecord]) {
        self.state = state
        self.title = title
        self.records = records
    }
}

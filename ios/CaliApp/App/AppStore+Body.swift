import CaliCore
import CaliDomain
import Foundation

// IOS-018 / CON-007: body measurements (weight, kg). Sensitive: never AI input, never on the Lock Screen,
// widget, Live Activity or notifications (ADR-064). The value is never written to an audit row or a log.
extension AppStore {
    /// Live weight entries, newest measurement first.
    var weightEntries: [BodyMeasurement] { BodyMeasurementRules.entries(bodyMeasurements, kind: .weight) }

    /// Adds or edits one measurement. Repeating the same `commandId` is safe.
    @discardableResult
    func saveBodyMeasurement(_ measurement: BodyMeasurement, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        if let issue = BodyMeasurementRules.validate(kind: measurement.kind, value: measurement.value, measuredAt: measurement.measuredAt, now: now).first {
            return refuse(Self.describe(issue))
        }
        let isNew = !bodyMeasurements.contains { $0.id == measurement.id }
        // The audit row names the action only: the number stays out of the change log (docs/11).
        return commitContent(ContentChange(bodyMeasurements: [measurement]), action: isNew ? "Thêm số đo cơ thể" : "Sửa số đo cơ thể",
                             detail: "Cân nặng", commandId: commandId, now: now)
    }

    /// Soft delete: the row stays so sync can carry the deletion.
    @discardableResult
    func deleteBodyMeasurement(_ id: UUID, now: Date = Date(), commandId: UUID = UUID()) -> Bool {
        if audit.contains(where: { $0.id == commandId }) { return true }
        guard var measurement = bodyMeasurements.first(where: { $0.id == id }) else { return refuse("Không tìm thấy số đo.") }
        measurement.deletedAt = now
        return commitContent(ContentChange(bodyMeasurements: [measurement]), action: "Xoá số đo cơ thể", detail: "Cân nặng",
                             commandId: commandId, now: now)
    }
}

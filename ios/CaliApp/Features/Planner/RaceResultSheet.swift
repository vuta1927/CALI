import CaliDomain
import SwiftUI

/// MP-07 "Ghi kết quả thi": official distance and time, entered by hand; pace is shown, never stored.
struct RaceResultSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let plan: WorkoutPlan
    @State private var entry: RunEntry
    /// Mockup `raceResult`: the distance is the event's, locked; only the official time is entered.
    private let locksDistance: Bool
    @State private var error: String?
    @State private var commandId = UUID()
    @FocusState private var focused: Bool

    init(plan: WorkoutPlan, plannedDistance: Int?) {
        self.plan = plan
        _entry = State(initialValue: RunEntry(distanceMeters: plannedDistance))
        locksDistance = plannedDistance != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(plan.eventName ?? plan.title)
                            .font(.title3.bold())
                            .foregroundStyle(Color.caliText)
                        if let date = plan.eventDate {
                            Text(Fmt.day(date)).font(.subheadline).foregroundStyle(Color.caliSecondary)
                        }
                    }
                    RunEntryFields(entry: $entry, lockDistance: locksDistance, focused: $focused)
                    Label("Nhập tay", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(Color.caliSecondary)
                    Text("Kết quả được lưu thành một buổi chạy trong Lịch sử. Giáo án giữ nguyên cho tới khi bạn chọn Kết thúc, Kéo dài hoặc Lặp lại.")
                        .font(.footnote)
                        .foregroundStyle(Color.caliSecondary)
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Color.caliError)
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
            }
            .caliScreen()
            .navigationTitle("Kết quả thi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu", action: save).disabled(entry.distanceMeters == nil || entry.durationSeconds == nil)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Xong") { focused = false }
                }
            }
        }
    }

    private func save() {
        guard let meters = entry.distanceMeters, let seconds = entry.durationSeconds else { return }
        if store.recordRaceResult(plan.lineageId, distanceMeters: meters, durationSeconds: seconds, commandId: commandId) {
            dismiss()
        } else {
            error = store.alertMessage
            store.alertMessage = nil
            commandId = UUID()
        }
    }
}

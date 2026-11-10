import CaliDomain
import SwiftUI

/// MP-02 "Tạo giáo án" and MP-03 "Nhân bản / Lặp lại". Saving creates a draft; starting is a separate
/// step (MP-04) so nothing appears in Hôm nay by surprise.
struct PlanCreateView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlanDraft
    @State private var eventDay: Date
    @State private var error: String?
    /// The plan id, once saved; a repeated tap reuses it so the draft is created once.
    @State private var commandId = UUID()
    var onCreated: (UUID) -> Void = { _ in }

    init(initial: PlanDraft = PlanDraft(), onCreated: @escaping (UUID) -> Void = { _ in }) {
        _draft = State(initialValue: initial)
        _eventDay = State(initialValue: Calendar.current.date(byAdding: .day, value: 84, to: Date()) ?? Date())
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            Form {
                if case .clone(let source) = draft.method, let original = store.plan(source) {
                    Section {
                        Label("Sao chép \(original.workouts.count) buổi từ \"\(original.title)\"", systemImage: "plus.square.on.square")
                    } footer: {
                        Text("Bản sao là giáo án nháp riêng. Lịch sử, ngày theo và đề xuất AI của giáo án gốc không được sao chép.")
                    }
                    .listRowBackground(Color.caliSurface)
                }

                Section("Thông tin") {
                    TextField("Tên giáo án", text: $draft.title)
                    Picker("Môn chính", selection: $draft.discipline) {
                        ForEach(PlanDiscipline.allCases, id: \.self) { Label($0.label, systemImage: $0.systemImage).tag($0) }
                    }
                }
                .listRowBackground(Color.caliSurface)

                Section {
                    Picker("Kiểu giáo án", selection: $draft.kind) {
                        Text("Theo tuần").tag(PlanKind.weekly)
                        Text("Theo sự kiện").tag(PlanKind.event)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Kiểu giáo án")
                    if draft.kind == .event {
                        TextField("Tên sự kiện (ví dụ Giải 10 km)", text: $draft.eventName)
                        DatePicker("Ngày sự kiện", selection: $eventDay, in: Calendar.current.startOfDay(for: Date())..., displayedComponents: .date)
                            .environment(\.locale, Fmt.vi)
                    }
                } header: {
                    Text("Kiểu")
                } footer: {
                    Text(draft.kind == .weekly
                         ? "Lặp lại mỗi tuần cho tới khi bạn kết thúc."
                         : "Đếm ngược tới ngày sự kiện. Qua ngày đó, giáo án chờ bạn chọn kết thúc, kéo dài hoặc lặp lại.")
                }
                .listRowBackground(Color.caliSurface)

                if let error {
                    Text(error).foregroundStyle(Color.caliError)
                        .listRowBackground(Color.caliSurface)
                }
            }
            .caliScreen()
            .navigationTitle(isClone ? "Nhân bản giáo án" : "Tạo giáo án")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Tạo") { save() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var isClone: Bool {
        if case .clone = draft.method { return true }
        return false
    }

    private func save() {
        var draft = draft
        draft.eventDate = draft.kind == .event ? LocalDate.today(at: eventDay, in: store.calendar.timeZone) : nil
        if let id = store.createPlan(draft, commandId: commandId) {
            dismiss()
            onCreated(id)
        } else {
            error = store.alertMessage
            store.alertMessage = nil
        }
    }
}

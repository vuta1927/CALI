import CaliCore
import CaliDomain
import Charts
import SwiftUI

/// "Số đo cơ thể" (IOS-018, CON-007): weight in kilograms, entered by the user. Sensitive data (ADR-064):
/// no AI input, no share toggle, nothing on the Lock Screen, widget, Live Activity or notifications.
/// A number is only recorded and shown; the screen never judges it or gives advice.
struct BodyMeasurementsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: BodyDraft?
    @State private var pendingDelete: BodyMeasurement?

    var body: some View {
        let entries = store.weightEntries
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                if let latest = entries.first {
                    latestCard(latest, change: BodyMeasurementRules.lastChange(store.bodyMeasurements))
                    if entries.count >= 2 { trendCard(entries) }
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        SectionHeader(title: "Các lần đo", trailing: "\(entries.count)")
                        ForEach(entries) { entry in row(entry) }
                    }
                } else {
                    emptyState
                }
                Text("Số đo chỉ để bạn theo dõi. COAMI không đưa lời khuyên ăn uống hay y tế và không gửi số đo này cho AI.")
                    .font(.caption)
                    .foregroundStyle(Color.caliSecondary)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .caliScreen()
        .navigationTitle("Số đo cơ thể")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = BodyDraft(latest: entries.first?.value) } label: {
                    Label("Thêm số đo", systemImage: "plus")
                }
            }
        }
        #if DEBUG
        // `-uiOpenEditor YES` opens the add sheet for screenshots.
        .task {
            if UserDefaults.standard.bool(forKey: "uiOpenEditor") {
                try? await Task.sleep(for: .seconds(1))
                editing = BodyDraft(latest: entries.first?.value)
            }
        }
        #endif
        .sheet(item: $editing) { draft in
            BodyMeasurementEditor(draft: draft).environment(store)
        }
        .confirmationDialog("Xoá lần đo này?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Xoá", role: .destructive) {
                if let target = pendingDelete { store.deleteBodyMeasurement(target.id) }
                pendingDelete = nil
            }
            Button("Giữ lại", role: .cancel) { pendingDelete = nil }
        }
    }

    // MARK: Cards

    private func latestCard(_ latest: BodyMeasurement, change: Decimal?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Gần nhất").font(.caption).foregroundStyle(Color.caliSecondary)
            Text(Fmt.bodyKg(latest.value))
                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.caliText)
            Text("\(Fmt.relativeDayLong(latest.measuredAt)) · \(Fmt.time(latest.measuredAt))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Color.caliSecondary)
            // A neutral signed difference: no colour, no verdict.
            if let change {
                Text("\(Fmt.signedBodyKg(change)) so với lần đo trước")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Color.caliSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .caliCard()
        .accessibilityElement(children: .combine)
    }

    private func trendCard(_ entries: [BodyMeasurement]) -> some View {
        let points = Array(entries.prefix(60).reversed())
        let low = points.map(\.value).min() ?? 0, high = points.map(\.value).max() ?? 0
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Diễn biến").font(.headline).foregroundStyle(Color.caliText)
            Chart(points) { point in
                LineMark(x: .value("Ngày", point.measuredAt), y: .value("kg", NSDecimalNumber(decimal: point.value).doubleValue))
                    .foregroundStyle(Color.caliAccent)
                PointMark(x: .value("Ngày", point.measuredAt), y: .value("kg", NSDecimalNumber(decimal: point.value).doubleValue))
                    .foregroundStyle(Color.caliAccent)
            }
            .chartYScale(domain: (NSDecimalNumber(decimal: low).doubleValue - 1)...(NSDecimalNumber(decimal: high).doubleValue + 1))
            .frame(height: 140)
            .accessibilityLabel("Biểu đồ cân nặng, \(points.count) lần đo")
        }
        .caliCard()
    }

    private func row(_ entry: BodyMeasurement) -> some View {
        HStack(spacing: Spacing.m) {
            Button { editing = BodyDraft(entry) } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.bodyKg(entry.value))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(Color.caliText)
                        Text("\(Fmt.relativeDayLong(entry.measuredAt)) · \(Fmt.time(entry.measuredAt))")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(Color.caliSecondary)
                    }
                    Spacer()
                    Image(systemName: "pencil").foregroundStyle(Color.caliSecondary)
                }
                .frame(minHeight: minTapTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sửa lần đo \(Fmt.bodyKg(entry.value)), \(Fmt.relativeDayLong(entry.measuredAt))")
            CircleIconButton(systemImage: "trash", label: "Xoá lần đo \(Fmt.bodyKg(entry.value))", tint: .caliSecondary) {
                pendingDelete = entry
            }
        }
        .caliCard(padding: Spacing.m)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: "scalemass").font(.largeTitle).foregroundStyle(Color.caliSecondary)
            Text("Chưa có số đo nào").font(.headline).foregroundStyle(Color.caliText)
            Text("Ghi cân nặng khi bạn muốn theo dõi. Có thể nhập nhiều lần trong một ngày.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.caliSecondary)
            Button("Thêm số đo") { editing = BodyDraft(latest: nil) }
                .buttonStyle(.caliPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
        .caliCard()
    }
}

/// What the editor works on: a new entry (id nil) or an existing one.
struct BodyDraft: Identifiable {
    let id = UUID()
    var existingId: UUID?
    var value: Decimal?
    var measuredAt: Date

    /// New entry: starts from the latest value (people weigh within a kilo of last time), measured now.
    init(latest: Decimal?) {
        value = latest
        measuredAt = Date()
    }

    init(_ entry: BodyMeasurement) {
        existingId = entry.id
        value = entry.value
        measuredAt = entry.measuredAt
    }
}

private struct BodyMeasurementEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: BodyDraft
    @FocusState private var focused: Bool
    /// One id per editor session, so a double tap on Lưu records once (AGENTS rule 5).
    @State private var commandId = UUID()

    private var issues: [ValidationIssue] {
        guard let value = draft.value else { return [] }
        return BodyMeasurementRules.validate(kind: .weight, value: value, measuredAt: draft.measuredAt, now: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Cân nặng").font(.headline).foregroundStyle(Color.caliText)
                        HStack(spacing: Spacing.m) {
                            CircleIconButton(systemImage: "minus", label: "Bớt 0,1 kg") { nudge(-0.1) }
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                                TextField("—", value: $draft.value, format: .number.precision(.fractionLength(0...3)))
                                    .keyboardType(.decimalPad)
                                    .focused($focused)
                                    .multilineTextAlignment(.center)
                                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(Color.caliText)
                                Text("kg").font(.headline).foregroundStyle(Color.caliSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            CircleIconButton(systemImage: "plus", label: "Thêm 0,1 kg") { nudge(0.1) }
                        }
                    }
                    .caliCard()
                    DatePicker("Thời điểm đo", selection: $draft.measuredAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                        .frame(minHeight: minTapTarget)
                        .caliCard()
                    if let issue = issues.first {
                        Text(AppStore.describe(issue)).font(.footnote).foregroundStyle(Color.caliWarning)
                    }
                }
                .padding(Spacing.l)
            }
            .caliScreen()
            .navigationTitle(draft.existingId == nil ? "Thêm số đo" : "Sửa số đo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Xong") { focused = false }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Lưu", action: save)
                    .buttonStyle(.caliPrimary)
                    .disabled(draft.value == nil || !issues.isEmpty)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.m)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func nudge(_ step: Decimal) {
        let next = (draft.value ?? 70) + step
        draft.value = min(BodyMeasurementKind.weight.range.upperBound, max(BodyMeasurementKind.weight.range.lowerBound, next))
    }

    private func save() {
        guard let value = draft.value else { return }
        let measurement = BodyMeasurement(id: draft.existingId ?? commandId, value: value, measuredAt: draft.measuredAt)
        if store.saveBodyMeasurement(measurement, commandId: commandId) { dismiss() }
    }
}

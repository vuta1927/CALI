import CaliDomain
import SwiftUI

/// CON-008 (docs/18 §5): the extra fields of the set form, built from the criteria config of the session.
/// Every field is optional (UX rule 6). `rpe` and `pain` only control display of their columns (ADR-045);
/// the other criteria go into the `criteria` map as tokens, numbers, booleans or token lists.
struct CriteriaFields: View {
    let criteria: [Criterion]
    @Binding var rpe: Int?
    @Binding var pain: Bool
    @Binding var values: [String: CriteriaValue]

    var body: some View {
        ForEach(criteria) { criterion in
            switch criterion.type {
            case "scale": scale(criterion)
            case "toggle": toggle(criterion)
            case "choice": choice(criterion)
            case "chips": chips(criterion)
            case "number": number(criterion)
            default: EmptyView()
            }
        }
    }

    // MARK: Renderers

    private func scale(_ c: Criterion) -> some View {
        let lo = Int(truncating: (c.min ?? 1) as NSDecimalNumber), hi = Int(truncating: (c.max ?? 10) as NSDecimalNumber)
        let step = max(1, Int(truncating: (c.step ?? 1) as NSDecimalNumber))
        let selected = current(c)
        return card(c, trailing: selected.map { c.id == "rpe" ? "\($0) · \(ResultFormView.rpeLabel($0))" : "\($0)" } ?? "Không bắt buộc") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 5), spacing: Spacing.s) {
                ForEach(Array(stride(from: lo, through: hi, by: step)), id: \.self) { value in
                    Button { set(c, selected == value ? nil : value) } label: {
                        Text("\(value)")
                            .font(.headline.monospacedDigit())
                            .frame(maxWidth: .infinity, minHeight: minTapTarget)
                            .foregroundStyle(selected == value ? Color.caliOnAccent : Color.caliText)
                            .background(selected == value ? Color.caliAccent : Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(c.label) \(value)")
                    .accessibilityAddTraits(selected == value ? .isSelected : [])
                }
            }
        }
    }

    private func toggle(_ c: Criterion) -> some View {
        let isOn = c.id == "pain" ? pain : (values[c.id] == .bool(true))
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(c.label, isOn: Binding(get: { isOn }, set: { on in
                if c.id == "pain" { pain = on } else { values[c.id] = on ? .bool(true) : nil }
            }))
            .font(.headline)
            .foregroundStyle(Color.caliText)
            .frame(minHeight: minTapTarget)
            if let hint = c.hint { Text(hint).font(.caption).foregroundStyle(Color.caliSecondary) }
        }
        .caliCard()
    }

    private func choice(_ c: Criterion) -> some View {
        let selected: String? = if case .token(let v)? = values[c.id] { v } else { nil }
        return card(c, trailing: selected.flatMap { v in c.options?.first { $0.v == v }?.hint } ?? "Không bắt buộc") {
            optionChips(c) { option in
                FilterChip(title: option.label, isSelected: selected == option.v) {
                    values[c.id] = selected == option.v ? nil : .token(option.v)
                }
            }
        }
    }

    private func chips(_ c: Criterion) -> some View {
        let selected: Set<String> = switch values[c.id] {
        case .tokens(let list)?: Set(list)
        case .token(let v)?: [v]
        default: []
        }
        return card(c, trailing: selected.isEmpty ? "Không bắt buộc" : "Chọn được nhiều") {
            optionChips(c) { option in
                FilterChip(title: option.label, isSelected: selected.contains(option.v)) {
                    var next = selected
                    if !next.insert(option.v).inserted { next.remove(option.v) }
                    // Option order, not selection order: the stored list is stable.
                    let ordered = (c.options ?? []).map(\.v).filter(next.contains)
                    values[c.id] = ordered.isEmpty ? nil : .tokens(ordered)
                }
            }
        }
    }

    private func number(_ c: Criterion) -> some View {
        let binding = Binding<Decimal?>(
            get: { if case .number(let n)? = values[c.id] { n } else { nil } },
            set: { values[c.id] = $0.map(CriteriaValue.number) }
        )
        return card(c, trailing: c.unit ?? "Không bắt buộc") {
            TextField("—", value: binding, format: .number)
                .keyboardType(.decimalPad)
                .padding(Spacing.m)
                .frame(minHeight: minTapTarget)
                .background(Color.caliSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.chip))
                .foregroundStyle(Color.caliText)
        }
    }

    // MARK: Helpers

    private func card<Content: View>(_ c: Criterion, trailing: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Label(c.label, systemImage: Self.symbol(c.icon))
                    .font(.headline)
                    .foregroundStyle(Color.caliText)
                    .labelStyle(CriteriaLabelStyle())
                Spacer()
                Text(trailing).font(.caption).foregroundStyle(Color.caliSecondary)
            }
            content()
            if let hint = c.hint { Text(hint).font(.caption).foregroundStyle(Color.caliSecondary) }
        }
        .caliCard()
    }

    private func optionChips<Chip: View>(_ c: Criterion, @ViewBuilder chip: @escaping (CriterionOption) -> Chip) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Spacing.s, alignment: .leading)], alignment: .leading, spacing: Spacing.s) {
            ForEach(c.options ?? [], id: \.v) { chip($0) }
        }
    }

    private func current(_ c: Criterion) -> Int? {
        if c.id == "rpe" { return rpe }
        if case .number(let n)? = values[c.id] { return Int(truncating: n as NSDecimalNumber) }
        return nil
    }

    private func set(_ c: Criterion, _ value: Int?) {
        if c.id == "rpe" { rpe = value } else { values[c.id] = value.map { .number(Decimal($0)) } }
    }

    /// Design-system icon names of the config → SF Symbols; an unknown name renders no icon (OpenAPI Criterion.icon).
    static func symbol(_ name: String?) -> String {
        switch name {
        case "star": "star"
        case "chart": "flame"
        case "swap": "arrow.left.arrow.right"
        case "barbell": "dumbbell"
        case "alert": "exclamationmark.triangle"
        default: "slider.horizontal.3"
        }
    }

    /// Criteria of the previous set in the same execution that ask for `prefill: previousSet`.
    static func prefill(_ criteria: [Criterion], from previous: SetActuals?) -> [String: CriteriaValue] {
        guard let previous, let map = previous.criteria else { return [:] }
        var result: [String: CriteriaValue] = [:]
        for c in criteria where c.prefillsFromPreviousSet && !c.isColumnBacked {
            if let v = map[c.id] { result[c.id] = v }
        }
        return result
    }
}

private struct CriteriaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.s) {
            configuration.icon.foregroundStyle(Color.caliAccentInk)
            configuration.title
        }
    }
}

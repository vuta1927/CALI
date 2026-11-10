import SwiftUI

// MARK: - Buttons

struct CaliButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, quiet }

    var kind: Kind = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, Spacing.l)
            .foregroundStyle(foreground)
            .background {
                let shape = RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                if kind == .primary {
                    shape.fill(COAMIGradient.brand)
                } else {
                    shape.fill(background)
                }
            }
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .strokeBorder(Color.caliBorder, lineWidth: 1)
                }
            }
            .shadow(color: kind == .primary ? Color.coamiOrange.opacity(0.22) : .clear, radius: 14, y: 7)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: .caliOnAccent
        case .secondary: .caliText
        case .destructive: .caliCanvas
        case .quiet: .caliSecondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .caliAccent
        case .secondary: .caliSurface
        case .destructive: .caliError
        case .quiet: .clear
        }
    }
}

extension ButtonStyle where Self == CaliButtonStyle {
    static var caliPrimary: CaliButtonStyle { CaliButtonStyle(kind: .primary) }
    static var caliSecondary: CaliButtonStyle { CaliButtonStyle(kind: .secondary) }
    static var caliDestructive: CaliButtonStyle { CaliButtonStyle(kind: .destructive) }
    static var caliQuiet: CaliButtonStyle { CaliButtonStyle(kind: .quiet) }
}

/// Round icon button with a 44pt+ tap target.
struct CircleIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .caliText
    var size: CGFloat = minTapTarget
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(.thinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.caliBorder.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Card

struct GlassCardModifier: ViewModifier {
    var padding: CGFloat = Spacing.l
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if COAMIEffectPolicy.usesMaterial(reduceTransparency: reduceTransparency) {
                    shape.fill(.thinMaterial)
                } else {
                    shape.fill(Color.caliSurface)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.22), Color.caliBorder.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1
                )
            }
            .shadow(color: Color.black.opacity(0.10), radius: 18, y: 8)
    }
}

typealias CardModifier = GlassCardModifier

extension View {
    func caliCard(padding: CGFloat = Spacing.l) -> some View {
        modifier(GlassCardModifier(padding: padding))
    }

    /// Standard screen background for the dark-first theme.
    func caliScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(COAMIScreenBackground())
    }
}

// MARK: - Chips & badges

struct TagChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .caliSecondary
    var filled = false

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .foregroundStyle(filled ? Color.caliOnAccent : tint)
        .background(
            filled ? tint : tint.opacity(0.15),
            in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        )
    }
}

/// Labels data that is not real user data (AGENTS: no mock data masquerading as production).
struct MockBadge: View {
    var text = "Dữ liệu mẫu"

    var body: some View {
        TagChip(text: text, systemImage: "flask", tint: .caliWarning)
            .accessibilityLabel("\(text). Không phải dữ liệu thật")
    }
}

/// Selectable filter chip with a 44pt tap target.
struct FilterChip: View {
    let title: String
    var systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                if isSelected {
                    Image(systemName: "checkmark").imageScale(.small)
                } else if let systemImage {
                    Image(systemName: systemImage).imageScale(.small)
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: minTapTarget)
            .foregroundStyle(isSelected ? Color.caliOnAccent : Color.caliText)
            .background(isSelected ? Color.caliAccent : Color.caliSurfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Color.caliBorder.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(Color.caliText)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.subheadline)
                    .foregroundStyle(Color.caliSecondary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Progress

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 14
    var tint: Color = .caliAccent

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.caliSurfaceRaised, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

struct LinearProgress: View {
    let progress: Double
    var tint: Color = .caliAccent

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.caliSurfaceRaised)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var systemImage: String?
    var tint: Color = .caliText
    @ScaledMetric(relativeTo: .body) private var iconHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let systemImage {
                // Symbols differ in height; a fixed frame keeps the value and the label on one line across tiles.
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(height: iconHeight, alignment: .leading)
            }
            Text(value)
                .font(.title2.bold().monospacedDigit())
                .foregroundStyle(Color.caliText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.caliSecondary)
                // One line, shrunk when it is long: every tile has the same height, in a stack or in a grid.
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .caliCard(padding: Spacing.m)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Mockup building blocks (docs/design/mockups/plan-module.html)

/// Overlapping poster thumbnails (mockup `.stack`): each tile is outlined in the surface color.
struct PosterStack: View {
    let exercises: [Exercise?]
    var size: CGFloat = 28
    var limit = 5

    var body: some View {
        HStack(spacing: -8) {
            ForEach(Array(exercises.prefix(limit).enumerated()), id: \.offset) { _, exercise in
                PosterThumb(exercise: exercise, size: size)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.caliSurface, lineWidth: 2))
            }
        }
        .accessibilityHidden(true)
    }
}

struct DisciplineChip: View {
    let discipline: Discipline

    var body: some View {
        TagChip(text: discipline.label, systemImage: discipline.systemImage, tint: .caliAccentInk)
    }
}

/// Orange text link with a 44pt tap target (mockup `button.link`).
struct CaliLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.caliAccentInk)
            .frame(minHeight: minTapTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == CaliLinkStyle {
    static var caliLink: CaliLinkStyle { CaliLinkStyle() }
}

/// Centered footnote at the end of screens that show sample content (mockup `sampleFoot`).
struct SampleFooter: View {
    var showsSample = true

    var body: some View {
        Text(showsSample ? "Dữ liệu mẫu.\nCOAMI không đưa ra lời khuyên y tế." : "COAMI không đưa ra lời khuyên y tế.")
            .font(.caption)
            .foregroundStyle(Color.caliSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.s)
    }
}

/// "Hiện tại › Đề xuất" comparison box (mockup `.fromto`).
struct FromToView: View {
    let fromCaption: String
    let from: String
    let toCaption: String
    let to: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            column(fromCaption, from, tint: .caliText)
            Image(systemName: "chevron.right")
                .foregroundStyle(Color.caliSecondary)
                .accessibilityHidden(true)
            column(toCaption, to, tint: .caliAccentInk)
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .background(Color.caliSurfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func column(_ caption: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption).font(.caption).foregroundStyle(Color.caliSecondary)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(tint)
        }
    }
}

/// One cell of a per-set result grid (mockup `.setcell`).
struct SetCell: View {
    let index: Int
    let value: String?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Set \(index)").font(.caption).foregroundStyle(Color.caliSecondary)
            Text(value ?? "—")
                .font(.headline.monospacedDigit())
                .foregroundStyle(value == nil ? Color.caliSecondary : Color.caliText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(Color.caliSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.s)
        .background(Color.caliSurfaceRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Row inside a grouped card (mockup `.lrow` / `.srow`), with a divider drawn by the caller.
struct CardRow<Trailing: View>: View {
    var systemImage: String?
    let title: String
    var tint: Color = .caliText
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.m) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(Color.caliAccentInk).frame(width: 24)
            }
            Text(title).foregroundStyle(tint)
            Spacer(minLength: Spacing.s)
            trailing
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Color.caliBorder.opacity(0.7)).frame(height: 1)
    }
}

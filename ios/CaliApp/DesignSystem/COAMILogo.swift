import SwiftUI

enum COAMISymbolStyle {
    case brand
    case monochrome(Color)
}

/// Code-native counterpart of `brand/logos/coami-symbol.svg`.
struct COAMISymbol: View {
    var style: COAMISymbolStyle = .brand
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let stroke = side * 136 / 1024
            let routeStroke = side * 80 / 1024
            let pointSize = side * 104 / 1024
            let routeColor = colorScheme == .dark ? Color.coamiIce : Color.coamiNavy

            ZStack {
                switch style {
                case .brand:
                    COAMICShape()
                        .stroke(COAMIGradient.brand, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                    COAMIProgressShape()
                        .stroke(routeColor, style: StrokeStyle(lineWidth: routeStroke, lineCap: .round, lineJoin: .round))
                    Circle()
                        .fill(routeColor)
                        .frame(width: pointSize, height: pointSize)
                        .position(x: side * 694 / 1024, y: side * 350 / 1024)
                case .monochrome(let color):
                    COAMICShape()
                        .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                    COAMIProgressShape()
                        .stroke(color, style: StrokeStyle(lineWidth: routeStroke, lineCap: .round, lineJoin: .round))
                    Circle()
                        .fill(color)
                        .frame(width: pointSize, height: pointSize)
                        .position(x: side * 694 / 1024, y: side * 350 / 1024)
                }
            }
            .frame(width: side, height: side)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct COAMICShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 1024
        let x = rect.midX - 512 * scale
        let y = rect.midY - 512 * scale
        func point(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
            CGPoint(x: x + px * scale, y: y + py * scale)
        }

        var path = Path()
        path.move(to: point(746, 264))
        path.addCurve(to: point(500, 156), control1: point(684, 194), control2: point(596, 156))
        path.addCurve(to: point(160, 512), control1: point(304, 156), control2: point(160, 308))
        path.addCurve(to: point(500, 868), control1: point(160, 716), control2: point(304, 868))
        path.addCurve(to: point(746, 760), control1: point(596, 868), control2: point(684, 830))
        return path
    }
}

private struct COAMIProgressShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 1024
        let x = rect.midX - 512 * scale
        let y = rect.midY - 512 * scale
        var path = Path()
        path.move(to: CGPoint(x: x + 406 * scale, y: y + 638 * scale))
        path.addLine(to: CGPoint(x: x + 512 * scale, y: y + 532 * scale))
        path.addLine(to: CGPoint(x: x + 620 * scale, y: y + 424 * scale))
        return path
    }
}

struct COAMIWordmark: View {
    var includesTagline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("COAMI")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .tracking(2.5)
                .foregroundStyle(Color.caliText)
            if includesTagline {
                Text("Your AI Training Companion")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.caliSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct BrandHeader: View {
    var tagline: String? = "Your AI Training Companion"

    var body: some View {
        HStack(spacing: Spacing.m) {
            COAMISymbol()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text("COAMI")
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .tracking(2.5)
                    .foregroundStyle(Color.caliText)
                if let tagline {
                    Text(tagline)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.caliSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct COAMIScreenBackground: View {
    var body: some View {
        ZStack {
            Color.caliCanvas
            COAMIGradient.canvasGlow
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

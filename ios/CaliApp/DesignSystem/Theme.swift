import SwiftUI
import UIKit

/// Source-of-truth brand values (orange palette, see docs/design/mockups/plan-module.html).
/// Keeping the raw values testable prevents visual drift when semantic light/dark colors change.
/// Contrast rules: `orange` is for fills and graphics only (white on it is ~3.4:1); orange text
/// uses `caliAccentInk`; text on orange fills uses `ink` (~5.4:1).
enum COAMIColorToken: UInt32 {
    case flame = 0xFF7A2F
    case orange = 0xFC4C02
    case ember = 0xE83F00
    case blue = 0x0077C8
    case ink = 0x1A1206
    case cream = 0xFFF3EC
    case white = 0xFFFFFF
}

enum COAMIAppearance {
    case light, dark
}

struct COAMIThemePalette: Equatable {
    let canvas: UInt32
    let surface: UInt32
    let surfaceRaised: UInt32
    let text: UInt32
    let secondary: UInt32
    let accent: UInt32
    /// Orange used for text/links on canvas or surface (>= 4.5:1).
    let accentInk: UInt32
    let border: UInt32

    static func palette(for appearance: COAMIAppearance) -> Self {
        switch appearance {
        case .light:
            Self(
                canvas: 0xF5F5F7,
                surface: COAMIColorToken.white.rawValue,
                surfaceRaised: 0xECECF0,
                text: 0x242428,
                secondary: 0x5E5E6A,
                accent: COAMIColorToken.orange.rawValue,
                accentInk: 0xC43C00,
                border: 0xD2D2D9
            )
        case .dark:
            Self(
                canvas: 0x121214,
                surface: 0x1E1E22,
                surfaceRaised: 0x2A2A30,
                text: 0xF2F2F5,
                secondary: 0xA8A8B3,
                accent: 0xFF6A2B,
                accentInk: 0xFF6A2B,
                border: 0x3A3A42
            )
        }
    }
}

enum COAMIEffectPolicy {
    static func usesMaterial(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }
}

enum COAMIGradient {
    static let brand = LinearGradient(
        colors: [Color(hex: COAMIColorToken.flame.rawValue), Color(hex: COAMIColorToken.orange.rawValue), Color(hex: COAMIColorToken.ember.rawValue)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let canvasGlow = RadialGradient(
        colors: [Color(hex: COAMIColorToken.orange.rawValue, opacity: 0.08), .clear],
        center: .topLeading,
        startRadius: 0,
        endRadius: 420
    )
}

extension Color {
    static let coamiFlame = Color(hex: COAMIColorToken.flame.rawValue)
    static let coamiOrange = Color(hex: COAMIColorToken.orange.rawValue)
    static let coamiBlue = Color(hex: COAMIColorToken.blue.rawValue)
    static let coamiInk = Color(hex: COAMIColorToken.ink.rawValue)
    static let coamiCream = Color(hex: COAMIColorToken.cream.rawValue)

    private static let lightPalette = COAMIThemePalette.palette(for: .light)
    private static let darkPalette = COAMIThemePalette.palette(for: .dark)

    static let caliCanvas = adaptive(light: lightPalette.canvas, dark: darkPalette.canvas)
    static let caliSurface = adaptive(light: lightPalette.surface, dark: darkPalette.surface)
    static let caliSurfaceRaised = adaptive(light: lightPalette.surfaceRaised, dark: darkPalette.surfaceRaised)
    /// Fills, strokes, icons and large numerals. Not for body-size text in light mode.
    static let caliAccent = adaptive(light: lightPalette.accent, dark: darkPalette.accent)
    /// Orange text and links (>= 4.5:1 on canvas/surface).
    static let caliAccentInk = adaptive(light: lightPalette.accentInk, dark: darkPalette.accentInk)
    /// Text and icons placed on an accent fill or the brand gradient.
    static let caliOnAccent = Color.coamiInk
    static let caliText = adaptive(light: lightPalette.text, dark: darkPalette.text)
    static let caliSecondary = adaptive(light: lightPalette.secondary, dark: darkPalette.secondary)
    static let caliBorder = adaptive(light: lightPalette.border, dark: darkPalette.border)
    static let caliWarning = adaptive(light: 0xA75B00, dark: 0xFFD166)
    static let caliError = adaptive(light: 0xB93848, dark: 0xFF8795)

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let card: CGFloat = 20
    static let button: CGFloat = 16
    static let chip: CGFloat = 12
}

/// Minimum tap target (docs/02 accessibility: >= 44x44pt).
let minTapTarget: CGFloat = 44

/// Palettes for placeholder posters. Exercise identity stays distinct while the overall
/// temperature stays compatible with the neutral-grey + orange COAMI system.
enum PosterPalette {
    static let all: [[Color]] = [
        [Color(hex: 0x063F43), Color(hex: 0x00BFAE)],
        [Color(hex: 0x12385A), Color(hex: 0x00A7E1)],
        [Color(hex: 0x593A27), Color(hex: 0xE8874B)],
        [Color(hex: 0x3D3564), Color(hex: 0x8B7CF6)],
        [Color(hex: 0x5E2947), Color(hex: 0xE16B9D)],
        [Color(hex: 0x134E4A), Color(hex: 0x2DD4BF)],
        [Color(hex: 0x534614), Color(hex: 0xD4B72C)],
        [Color(hex: 0x243747), Color(hex: 0x6F8FA3)],
    ]

    static func colors(_ index: Int) -> [Color] {
        all[((index % all.count) + all.count) % all.count]
    }
}

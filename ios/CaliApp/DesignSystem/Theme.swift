import SwiftUI
import UIKit

/// Source-of-truth values from the COAMI brand handoff. Keeping the raw values testable
/// prevents visual drift when semantic light/dark colors are adjusted later.
enum COAMIColorToken: UInt32 {
    case mint = 0x2FF6C4
    case teal = 0x00D4C6
    case aqua = 0x00A7E1
    case navy = 0x0B2742
    case ice = 0xEAF7FF
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

    static func palette(for appearance: COAMIAppearance) -> Self {
        switch appearance {
        case .light:
            Self(
                canvas: 0xF4FAFD,
                surface: COAMIColorToken.white.rawValue,
                surfaceRaised: 0xDCEEF5,
                text: COAMIColorToken.navy.rawValue,
                secondary: 0x496B7F,
                accent: COAMIColorToken.teal.rawValue
            )
        case .dark:
            Self(
                canvas: 0x071927,
                surface: 0x102B3E,
                surfaceRaised: 0x193B50,
                text: COAMIColorToken.ice.rawValue,
                secondary: 0x8CB2C8,
                accent: COAMIColorToken.mint.rawValue
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
        colors: [Color(hex: COAMIColorToken.mint.rawValue), Color(hex: COAMIColorToken.teal.rawValue), Color(hex: COAMIColorToken.aqua.rawValue)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let canvasGlow = RadialGradient(
        colors: [Color(hex: COAMIColorToken.teal.rawValue, opacity: 0.14), .clear],
        center: .topLeading,
        startRadius: 0,
        endRadius: 420
    )
}

extension Color {
    static let coamiMint = Color(hex: COAMIColorToken.mint.rawValue)
    static let coamiTeal = Color(hex: COAMIColorToken.teal.rawValue)
    static let coamiAqua = Color(hex: COAMIColorToken.aqua.rawValue)
    static let coamiNavy = Color(hex: COAMIColorToken.navy.rawValue)
    static let coamiIce = Color(hex: COAMIColorToken.ice.rawValue)

    static let caliCanvas = adaptive(light: 0xF4FAFD, dark: 0x071927)
    static let caliSurface = adaptive(light: COAMIColorToken.white.rawValue, dark: 0x102B3E)
    static let caliSurfaceRaised = adaptive(light: 0xDCEEF5, dark: 0x193B50)
    static let caliAccent = adaptive(light: COAMIColorToken.teal.rawValue, dark: COAMIColorToken.mint.rawValue)
    static let caliText = adaptive(light: COAMIColorToken.navy.rawValue, dark: COAMIColorToken.ice.rawValue)
    static let caliSecondary = adaptive(light: 0x496B7F, dark: 0x8CB2C8)
    static let caliBorder = adaptive(light: 0xB8D6E4, dark: 0x31566D)
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
/// temperature remains compatible with the COAMI navy/teal system.
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

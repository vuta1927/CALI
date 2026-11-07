import SwiftUI

// Design tokens from docs/02 (dark-first). Colors are never the only signal: every state
// that uses a color also carries an icon or a text label (accessibility, docs/02).
extension Color {
    static let caliCanvas = Color(hex: 0x111827)
    static let caliSurface = Color(hex: 0x1F2937)
    static let caliSurfaceRaised = Color(hex: 0x374151)
    static let caliAccent = Color(hex: 0x34D399)
    static let caliText = Color(hex: 0xF9FAFB)
    static let caliSecondary = Color(hex: 0x9CA3AF)
    static let caliWarning = Color(hex: 0xFBBF24)
    static let caliError = Color(hex: 0xF87171)

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
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
    static let card: CGFloat = 16
    static let button: CGFloat = 14
    static let chip: CGFloat = 10
}

/// Minimum tap target (docs/02 accessibility: >= 44x44pt).
let minTapTarget: CGFloat = 44

/// Palettes for placeholder posters. Picked per exercise so cards are distinguishable at a glance.
enum PosterPalette {
    static let all: [[Color]] = [
        [Color(hex: 0x065F46), Color(hex: 0x10B981)],
        [Color(hex: 0x1E3A8A), Color(hex: 0x3B82F6)],
        [Color(hex: 0x7C2D12), Color(hex: 0xF97316)],
        [Color(hex: 0x581C87), Color(hex: 0xA855F7)],
        [Color(hex: 0x831843), Color(hex: 0xEC4899)],
        [Color(hex: 0x134E4A), Color(hex: 0x14B8A6)],
        [Color(hex: 0x713F12), Color(hex: 0xEAB308)],
        [Color(hex: 0x1F2937), Color(hex: 0x6B7280)],
    ]

    static func colors(_ index: Int) -> [Color] {
        all[((index % all.count) + all.count) % all.count]
    }
}

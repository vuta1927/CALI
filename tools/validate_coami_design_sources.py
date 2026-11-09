#!/usr/bin/env python3
"""Cross-platform contract check for SwiftUI sources when Xcode is unavailable."""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    theme = (ROOT / "ios/CaliApp/DesignSystem/Theme.swift").read_text(encoding="utf-8")
    components = (ROOT / "ios/CaliApp/DesignSystem/Components.swift").read_text(encoding="utf-8")
    logo_path = ROOT / "ios/CaliApp/DesignSystem/COAMILogo.swift"
    logo = logo_path.read_text(encoding="utf-8") if logo_path.exists() else ""

    expected = {
        "Theme.swift": [
            "enum COAMIColorToken: UInt32",
            "case flame = 0xFF7A2F",
            "case orange = 0xFC4C02",
            "case ember = 0xE83F00",
            "case blue = 0x0077C8",
            "case ink = 0x1A1206",
            "case cream = 0xFFF3EC",
            "struct COAMIThemePalette: Equatable",
            "accentInk: 0xC43C00",
            "static let caliAccentInk",
            "static let caliOnAccent = Color.coamiInk",
            "enum COAMIEffectPolicy",
        ],
        "Components.swift": [
            "struct GlassCardModifier",
            "accessibilityReduceTransparency",
            "case .primary: .caliOnAccent",
            ".foregroundStyle(filled ? Color.caliOnAccent : tint)",
            ".foregroundStyle(isSelected ? Color.caliOnAccent : Color.caliText)",
        ],
        "COAMILogo.swift": ["struct COAMISymbol", "struct COAMIWordmark", "struct BrandHeader"],
    }
    sources = {"Theme.swift": theme, "Components.swift": components, "COAMILogo.swift": logo}
    missing = [f"{name}: {needle}" for name, needles in expected.items() for needle in needles if needle not in sources[name]]
    if missing:
        print("COAMI design source contract missing:\n- " + "\n- ".join(missing), file=sys.stderr)
        return 1
    print("COAMI SwiftUI design source contract valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

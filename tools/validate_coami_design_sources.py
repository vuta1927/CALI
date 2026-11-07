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
            "case mint = 0x2FF6C4",
            "case teal = 0x00D4C6",
            "case aqua = 0x00A7E1",
            "case navy = 0x0B2742",
            "case ice = 0xEAF7FF",
            "struct COAMIThemePalette: Equatable",
            "enum COAMIEffectPolicy",
        ],
        "Components.swift": [
            "struct GlassCardModifier",
            "accessibilityReduceTransparency",
            "case .primary: .coamiNavy",
            ".foregroundStyle(filled ? Color.coamiNavy : tint)",
            ".foregroundStyle(isSelected ? Color.coamiNavy : Color.caliText)",
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

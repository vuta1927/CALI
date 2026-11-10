#!/usr/bin/env python3
"""Minimal cross-platform guard for XcodeGen settings edited from Windows."""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    lines = (ROOT / "ios/project.yml").read_text(encoding="utf-8").splitlines()
    required = {
        "        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon",
        "        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor",
        "    SWIFT_VERSION: \"6.0\"",
        "    TARGETED_DEVICE_FAMILY: \"1\"",
    }
    missing = sorted(required.difference(lines))
    if missing:
        print("XcodeGen base settings are missing or mis-indented:\n- " + "\n- ".join(missing), file=sys.stderr)
        return 1
    if "    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon" in lines:
        print("AppIcon setting must be target-scoped, not global", file=sys.stderr)
        return 1
    # ADR-064 / docs/11: body measurements never reach the widget, the Live Activity or notifications.
    leaks = []
    for folder in ("ios/CaliActivityWidget", "ios/Shared", "ios/CaliApp/Services"):
        for source in (ROOT / folder).rglob("*.swift"):
            text = source.read_text(encoding="utf-8")
            if any(word in text for word in ("BodyMeasurement", "body_measurement", "bodyMeasurements", "bodyKg")):
                leaks.append(str(source.relative_to(ROOT)))
    if leaks:
        print("Body measurements must stay out of widget/Live Activity/notification code (ADR-064):\n- " + "\n- ".join(leaks), file=sys.stderr)
        return 1
    print("XcodeGen COAMI asset settings valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

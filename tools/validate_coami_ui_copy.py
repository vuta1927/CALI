#!/usr/bin/env python3
"""Cross-platform guard for COAMI user-facing branding and adaptive appearance."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOTS = [ROOT / "ios/CaliApp", ROOT / "ios/CaliActivityWidget"]


def main() -> int:
    problems: list[str] = []
    # Whole word only, so discipline names such as "Calisthenics" are not flagged.
    quoted_cali = re.compile(r'"[^"\n]*\b(?:CALI|Cali)\b[^"\n]*"')
    allowed_fragments = ("CaliBuildSHA",)

    for source_root in SOURCE_ROOTS:
        for path in source_root.rglob("*.swift"):
            text = path.read_text(encoding="utf-8")
            for number, line in enumerate(text.splitlines(), start=1):
                if quoted_cali.search(line) and not any(fragment in line for fragment in allowed_fragments):
                    problems.append(f"{path.relative_to(ROOT)}:{number}: stale user-facing CALI copy")
                if ".preferredColorScheme(.dark)" in line:
                    problems.append(f"{path.relative_to(ROOT)}:{number}: forced dark appearance")

    root_view = (ROOT / "ios/CaliApp/App/RootView.swift").read_text(encoding="utf-8")
    today = (ROOT / "ios/CaliApp/Features/Home/TodayView.swift").read_text(encoding="utf-8")
    # plan-module.html: Today starts with the large title; the wordmark lives on the welcome screen.
    if "BrandHeader(" not in root_view and "BrandHeader(" not in today and "COAMIWordmark(" not in root_view:
        problems.append("app shell lacks BrandHeader / COAMIWordmark")
    if "COAMISymbol(" not in root_view:
        problems.append("onboarding lacks COAMISymbol")
    if problems:
        print("COAMI UI copy contract failed:\n- " + "\n- ".join(problems), file=sys.stderr)
        return 1
    print("COAMI UI copy and adaptive-appearance contract valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

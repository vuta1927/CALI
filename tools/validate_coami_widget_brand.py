#!/usr/bin/env python3
"""Static safety/branding contract for compact workout surfaces."""

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    widget = (ROOT / "ios/CaliActivityWidget/WorkoutLiveActivity.swift").read_text(encoding="utf-8")
    player = (ROOT / "ios/CaliApp/Features/WorkoutPlayer/WorkoutPlayerView.swift").read_text(encoding="utf-8")
    problems: list[str] = []
    for needle in ("struct CompactCOAMIMark", "CompactCOAMIMark()"):
        if needle not in widget:
            problems.append(f"widget missing {needle}")
    if "COAMISymbol()" not in player:
        problems.append("workout header missing compact COAMISymbol")
    for forbidden in ("Button(", "AppIntent", "perform()"):
        if forbidden in widget:
            problems.append(f"widget introduces forbidden state-changing surface: {forbidden}")
    if problems:
        print("COAMI compact-surface contract failed:\n- " + "\n- ".join(problems), file=sys.stderr)
        return 1
    print("COAMI compact workout/widget contract valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

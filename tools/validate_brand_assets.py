#!/usr/bin/env python3
"""Deterministic integrity checks for the COAMI brand handoff package."""

from __future__ import annotations

import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

SVG_FILES = [
    "brand/sources/COAMI-brand-master.svg",
    "brand/logos/coami-primary.svg",
    "brand/logos/coami-secondary.svg",
    "brand/logos/coami-symbol.svg",
    "brand/logos/coami-monochrome-dark.svg",
    "brand/logos/coami-monochrome-light.svg",
]

PNG_FILES = [
    "brand/concept-exploration/concept-a-companion-c.png",
    "brand/concept-exploration/concept-b-motion-partner.png",
    "brand/concept-exploration/concept-c-guided-progress.png",
    "brand/app-icon/coami-app-icon-1024.png",
    "brand/app-icon/coami-app-icon-flat-1024.png",
    "brand/app-icon/coami-app-icon-preview.png",
    "brand/previews/coami-brand-board.png",
    "brand/previews/coami-home-screen-preview.png",
    "brand/previews/coami-lock-screen-preview.png",
    "brand/previews/coami-light-dark-preview.png",
    "brand/guidelines/COAMI-brand-guidelines.png",
    "ios/CaliApp/Assets.xcassets/AppIcon.appiconset/coami-app-icon-1024.png",
]


def fail(message: str) -> None:
    raise AssertionError(message)


def identify(path: Path) -> tuple[int, int, str]:
    result = subprocess.run(
        ["magick", "identify", "-format", "%w %h %[channels]", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    width, height, channels = result.stdout.strip().split(maxsplit=2)
    return int(width), int(height), channels.lower()


def main() -> int:
    for relative in SVG_FILES:
        path = ROOT / relative
        if not path.is_file():
            fail(f"missing SVG: {relative}")
        tree = ET.parse(path)
        root = tree.getroot()
        if not root.tag.endswith("svg") or not root.get("viewBox"):
            fail(f"SVG lacks a viewBox: {relative}")
        for node in root.iter():
            if node.tag.endswith("image"):
                fail(f"embedded raster is forbidden: {relative}")
            for value in node.attrib.values():
                if "http://" in value or "https://" in value:
                    fail(f"external asset reference is forbidden: {relative}")

    for relative in PNG_FILES:
        path = ROOT / relative
        if not path.is_file():
            fail(f"missing PNG: {relative}")
        width, height, _ = identify(path)
        if width < 24 or height < 24:
            fail(f"PNG is too small: {relative}")

    for relative in (
        "brand/app-icon/coami-app-icon-1024.png",
        "brand/app-icon/coami-app-icon-flat-1024.png",
        "ios/CaliApp/Assets.xcassets/AppIcon.appiconset/coami-app-icon-1024.png",
    ):
        width, height, channels = identify(ROOT / relative)
        if (width, height) != (1024, 1024):
            fail(f"app icon must be 1024x1024: {relative}")
        if "a" in channels:
            fail(f"app icon must be opaque: {relative} ({channels})")

    catalog = ROOT / "ios/CaliApp/Assets.xcassets/AppIcon.appiconset/Contents.json"
    data = json.loads(catalog.read_text(encoding="utf-8"))
    filenames = {image.get("filename") for image in data.get("images", [])}
    if "coami-app-icon-1024.png" not in filenames:
        fail("asset catalog does not reference coami-app-icon-1024.png")

    guideline_pdf = ROOT / "brand/guidelines/COAMI-brand-guidelines.pdf"
    if not guideline_pdf.is_file() or not guideline_pdf.read_bytes().startswith(b"%PDF"):
        fail("missing or invalid brand guideline PDF")

    print(f"COAMI brand assets valid: {len(SVG_FILES)} SVG, {len(PNG_FILES)} PNG, 1 PDF")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ET.ParseError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"brand validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)

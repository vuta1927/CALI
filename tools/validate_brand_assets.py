#!/usr/bin/env python3
"""Integrity checks for the COAMI brand package in `brand/` (v1, orange brand board).

- every file in `brand/08-quality/file-manifest.csv` exists and matches its SHA-256;
- SVGs parse, have a viewBox, embed no raster and reference nothing external;
- the iOS app icon, launch logo and background colour are the files from the package.
"""

from __future__ import annotations

import csv
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / "brand"
IOS_ASSETS = ROOT / "ios/CaliApp/Assets.xcassets"
CATALOG = BRAND / "05-integration/ios/COAMIBrand.xcassets"

# iOS asset -> its source in the package (must be byte-identical).
IOS_COPIES = {
    IOS_ASSETS / "AppIcon.appiconset" / name: CATALOG / "COAMIAppIcon.appiconset" / name
    for name in ("coami-icon-default.png", "coami-icon-dark.png", "coami-icon-tinted.png", "Contents.json")
} | {
    IOS_ASSETS / "COAMILaunchLogo.imageset" / name: CATALOG / "COAMILaunchLogo.imageset" / name
    for name in (
        "coami-launch-light@1x.png", "coami-launch-light@2x.png", "coami-launch-light@3x.png",
        "coami-launch-dark@1x.png", "coami-launch-dark@2x.png", "coami-launch-dark@3x.png",
        "Contents.json",
    )
} | {
    IOS_ASSETS / "COAMIBackground.colorset/Contents.json": CATALOG / "COAMIBackground.colorset/Contents.json",
}


def fail(message: str) -> None:
    raise AssertionError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_manifest() -> int:
    manifest = BRAND / "08-quality/file-manifest.csv"
    if not manifest.is_file():
        fail("missing brand/08-quality/file-manifest.csv")
    count = 0
    with manifest.open(encoding="utf-8-sig", newline="") as handle:
        for row in csv.DictReader(handle):
            path = BRAND / row["path"]
            if not path.is_file():
                fail(f"missing file from manifest: {row['path']}")
            if sha256(path) != row["sha256"]:
                fail(f"checksum mismatch: {row['path']}")
            count += 1
    return count


def check_svgs() -> int:
    count = 0
    for path in sorted(BRAND.glob("0[0-9]-*/**/*.svg")):
        root = ET.parse(path).getroot()
        if not root.tag.endswith("svg") or not root.get("viewBox"):
            fail(f"SVG lacks a viewBox: {path.relative_to(ROOT)}")
        for node in root.iter():
            if node.tag.endswith("image"):
                fail(f"embedded raster is forbidden: {path.relative_to(ROOT)}")
            for value in node.attrib.values():
                if "http://" in value or "https://" in value:
                    fail(f"external asset reference is forbidden: {path.relative_to(ROOT)}")
        count += 1
    return count


def check_ios() -> None:
    for ios, source in IOS_COPIES.items():
        if not ios.is_file():
            fail(f"missing iOS asset: {ios.relative_to(ROOT)}")
        # The package was made on Windows (CRLF); git stores LF.
        if ios.read_bytes().replace(b"\r\n", b"\n") != source.read_bytes().replace(b"\r\n", b"\n"):
            fail(f"iOS asset differs from the brand package: {ios.relative_to(ROOT)}")
    catalog = json.loads((IOS_ASSETS / "AppIcon.appiconset/Contents.json").read_text(encoding="utf-8"))
    names = {image.get("filename") for image in catalog.get("images", [])}
    if names != {"coami-icon-default.png", "coami-icon-dark.png", "coami-icon-tinted.png"}:
        fail(f"AppIcon catalog references unexpected files: {sorted(n for n in names if n)}")


def main() -> int:
    files = check_manifest()
    svgs = check_svgs()
    check_ios()
    print(f"COAMI brand assets valid: {files} manifest files, {svgs} SVG, {len(IOS_COPIES)} iOS asset files match")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, ET.ParseError, json.JSONDecodeError, KeyError) as error:
        print(f"brand validation failed: {error}", file=sys.stderr)
        raise SystemExit(1)

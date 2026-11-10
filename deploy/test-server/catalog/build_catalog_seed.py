#!/usr/bin/env python3
"""Build the test-server exercise catalog seed: SQL + poster/thumbnail JPEGs.

Inputs
  catalog.json                 curated exercises (this folder)
  --wger-images FILE           https://wger.de/api/v2/exerciseimage/?limit=1000 (JSON)
  --fedb FILE                  free-exercise-db dist/exercises.json
Outputs (in --out, outside the repo)
  media/<storage_key>          poster + thumbnail JPEGs, content-addressed keys
  seed.sql                     idempotent upsert of catalog rows + media rows
  report.json                  per-exercise media source / license summary

Media selection per exercise
  1. wger image (non-AI, license CC-BY-SA-3.0/4.0, CC0, CC-BY-4.0; main image first)
  2. free-exercise-db 0.jpg, license "unverified-test-only" (provenance unknown, replace before release)
  3. nothing (the exercise is still published; the app shows its no-media state)

Test server only: rows are published and media rows are marked reviewed. See README.md.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import sys
import time
import urllib.request
import uuid
from pathlib import Path

from PIL import Image

NAMESPACE = uuid.UUID("6f1c2b0e-3d4a-5b6c-8d7e-9f0a1b2c3d4e")
WGER_LICENSES = {1: "CC-BY-SA-3.0", 2: "CC-BY-SA-4.0", 3: "CC0-1.0", 4: "CC-BY-4.0"}
FEDB_RAW = "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/{id}/0.jpg"
FEDB_LICENSE = "unverified-test-only"
FEDB_ATTRIBUTION = ("free-exercise-db (github.com/yuhonas/free-exercise-db), "
                    "provenance unverified - replace before release")
TYPES = {"static_hold", "reps", "timed_reps", "interval", "skill_attempt", "distance", "duration", "load"}
DISCIPLINES = {"calisthenics", "gym", "running"}
POSTER_MAX = 1280
THUMB = 480
UA = "cali-catalog-seed/1.0"


def exercise_id(item: dict) -> str:
    return item.get("id") or str(uuid.uuid5(NAMESPACE, "cali:catalog:" + item["slug"]))


def sql_str(v: str | None) -> str:
    return "NULL" if v is None else "'" + v.replace("'", "''") + "'"


def sql_json(v) -> str:
    return sql_str(json.dumps(v, ensure_ascii=False)) + "::jsonb"


def fetch(url: str, cache: Path) -> bytes:
    path = cache / hashlib.sha256(url.encode()).hexdigest()
    if path.exists():
        return path.read_bytes()
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                data = r.read()
            path.write_bytes(data)
            return data
        except Exception as e:  # network hiccup: retry, then give up on this source
            if attempt == 2:
                raise RuntimeError(f"download failed {url}: {e}") from e
            time.sleep(1.5 * (attempt + 1))
    raise AssertionError("unreachable")


def flatten(img: Image.Image) -> Image.Image:
    img = img.convert("RGBA")
    bg = Image.new("RGB", img.size, (255, 255, 255))
    bg.paste(img, mask=img.getchannel("A"))
    return bg


def jpeg(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=85, optimize=True, progressive=True)
    return buf.getvalue()


def render(src: bytes) -> dict[str, bytes]:
    img = flatten(Image.open(io.BytesIO(src)))
    poster = img.copy()
    poster.thumbnail((POSTER_MAX, POSTER_MAX), Image.LANCZOS)
    thumb_fit = img.copy()
    thumb_fit.thumbnail((THUMB, THUMB), Image.LANCZOS)
    thumb = Image.new("RGB", (THUMB, THUMB), (255, 255, 255))
    thumb.paste(thumb_fit, ((THUMB - thumb_fit.width) // 2, (THUMB - thumb_fit.height) // 2))
    return {"poster": jpeg(poster), "thumbnail": jpeg(thumb)}


def pick_wger(images: list[dict], wger_id: int) -> dict | None:
    cands = [i for i in images
             if i.get("exercise") == wger_id
             and not i.get("is_ai_generated")
             and i.get("license") in WGER_LICENSES]
    cands.sort(key=lambda i: (not i.get("is_main"), i.get("id", 0)))
    return cands[0] if cands else None


def wger_attribution(img: dict) -> str:
    author = (img.get("license_author") or "").strip() or "wger contributors"
    return f"{author}, via wger.de (exercise image {img['id']})"


def validate(items: list[dict]) -> list[str]:
    errs, slugs, ids = [], set(), set()
    for it in items:
        s = it.get("slug", "?")
        for f in ("slug", "name", "type", "discipline", "focus", "equipment", "cues"):
            if f not in it:
                errs.append(f"{s}: missing {f}")
        if it.get("type") not in TYPES:
            errs.append(f"{s}: bad type {it.get('type')}")
        if it.get("discipline") not in DISCIPLINES:
            errs.append(f"{s}: bad discipline {it.get('discipline')}")
        if not it.get("cues"):
            errs.append(f"{s}: no cues")
        if s in slugs:
            errs.append(f"{s}: duplicate slug")
        slugs.add(s)
        i = exercise_id(it)
        if i in ids:
            errs.append(f"{s}: duplicate id")
        ids.add(i)
    return errs


def main() -> int:
    ap = argparse.ArgumentParser()
    here = Path(__file__).resolve().parent
    ap.add_argument("--catalog", type=Path, default=here / "catalog.json")
    ap.add_argument("--wger-images", type=Path, required=True)
    ap.add_argument("--fedb", type=Path, required=True)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--cache", type=Path, help="download cache (default: <out>/cache)")
    a = ap.parse_args()

    cat = json.loads(a.catalog.read_text(encoding="utf-8"))
    items = cat["items"]
    errs = validate(items)
    wimg = json.loads(a.wger_images.read_text(encoding="utf-8"))
    wimg = wimg["results"] if isinstance(wimg, dict) else wimg
    fedb_ids = {e["id"] for e in json.loads(a.fedb.read_text(encoding="utf-8"))}
    for it in items:
        if "fedb" in it and it["fedb"] not in fedb_ids:
            errs.append(f"{it['slug']}: unknown fedb id {it['fedb']}")
    if errs:
        print("catalog.json invalid:\n  " + "\n  ".join(errs), file=sys.stderr)
        return 1

    out = a.out
    cache = a.cache or out / "cache"
    (out / "media").mkdir(parents=True, exist_ok=True)
    cache.mkdir(parents=True, exist_ok=True)
    version = int(cat.get("catalogVersion", 1))

    cat_rows, media_sql, report = [], [], []
    for it in items:
        eid = exercise_id(it)
        cat_rows.append(
            f" ({sql_str(eid)}, {sql_str(it['slug'])}, {sql_str(it['name'])}, {sql_str(it['type'])}, "
            f"{sql_str(it['discipline'])}, {sql_json(it['focus'])}, {sql_json(it['equipment'])}, "
            f"{sql_json(it['cues'])}, {version}, true)")

        src = None
        w = pick_wger(wimg, it["wger"]) if "wger" in it else None
        if w:
            try:
                src = {"bytes": fetch(w["image"], cache), "license": WGER_LICENSES[w["license"]],
                       "attribution": wger_attribution(w), "source": "wger", "url": w["image"]}
            except RuntimeError as e:
                print(f"warn {it['slug']}: {e}", file=sys.stderr)
        if src is None and "fedb" in it:
            url = FEDB_RAW.format(id=it["fedb"])
            try:
                src = {"bytes": fetch(url, cache), "license": FEDB_LICENSE,
                       "attribution": FEDB_ATTRIBUTION, "source": "fedb", "url": url}
            except RuntimeError as e:
                print(f"warn {it['slug']}: {e}", file=sys.stderr)
        if src is None:
            report.append({"slug": it["slug"], "id": eid, "source": None})
            continue

        for kind, data in render(src["bytes"]).items():
            sha = hashlib.sha256(data).hexdigest()
            key = f"catalog/{eid}/{kind}-{sha[:12]}.jpg"
            dest = out / "media" / key
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
            mid = str(uuid.uuid5(NAMESPACE, f"cali:media:{eid}:{kind}:{sha}"))
            # New content -> next content_version for (exercise, kind); same sha already present -> no-op.
            media_sql.append(
                "INSERT INTO exercise_media (id, exercise_id, kind, content_version, storage_key, mime_type, sha256, "
                "size_bytes, license, attribution, is_public, reviewed_at)\n"
                f"SELECT {sql_str(mid)}, {sql_str(eid)}, '{kind}', "
                f"COALESCE((SELECT max(content_version) FROM exercise_media WHERE exercise_id = {sql_str(eid)} AND kind = '{kind}'), 0) + 1, "
                f"{sql_str(key)}, 'image/jpeg', '{sha}', {len(data)}, {sql_str(src['license'])}, "
                f"{sql_str(src['attribution'])}, true, now()\n"
                f"WHERE NOT EXISTS (SELECT 1 FROM exercise_media WHERE exercise_id = {sql_str(eid)} AND kind = '{kind}' AND sha256 = '{sha}');")
        report.append({"slug": it["slug"], "id": eid, "source": src["source"], "license": src["license"],
                       "attribution": src["attribution"], "url": src["url"]})

    sql = [
        "-- GENERATED by deploy/test-server/catalog/build_catalog_seed.py. Test server only: rows are published",
        "-- and media rows are marked reviewed without a human review. Idempotent; safe to re-run.",
        "BEGIN;",
        "INSERT INTO exercise_catalog (id, slug, name, exercise_type, discipline, focus_tags, equipment, cues, catalog_version, is_published) VALUES",
        ",\n".join(cat_rows),
        "ON CONFLICT (id) DO UPDATE SET slug = EXCLUDED.slug, name = EXCLUDED.name, exercise_type = EXCLUDED.exercise_type,",
        "  discipline = EXCLUDED.discipline, focus_tags = EXCLUDED.focus_tags, equipment = EXCLUDED.equipment, cues = EXCLUDED.cues,",
        "  catalog_version = EXCLUDED.catalog_version, is_published = EXCLUDED.is_published, updated_at = now();",
        "",
        *media_sql,
        "COMMIT;",
        "",
    ]
    (out / "seed.sql").write_text("\n".join(sql), encoding="utf-8")
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")

    by = {}
    for r in report:
        k = r["source"] or "none"
        by[k] = by.get(k, 0) + 1
    print(f"exercises={len(items)} " + " ".join(f"{k}={v}" for k, v in sorted(by.items())))
    print(f"wrote {out / 'seed.sql'} and {len(media_sql)} media files under {out / 'media'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

# Test-server exercise catalog seed

A curated catalog (~170 exercises: calisthenics incl. skill progressions, gym, 2 running) for the
local/Tailscale test server. **Not a release catalog**: rows are published and media rows are marked
reviewed by the script, without the human review `docs/10-media-library.md` requires.

| File | Purpose |
|---|---|
| `catalog.json` | Source of truth: slug, name, type, discipline, focus tags, equipment, Vietnamese cues, media refs (`wger` exercise id, `fedb` free-exercise-db id). The 9 fixture ids (`aaaaaaaa-…a1..a9`) are kept; other ids are UUIDv5 of `cali:catalog:<slug>`. |
| `build_catalog_seed.py` | Validates `catalog.json`, downloads source images, renders poster (≤1280px JPEG) + thumbnail (480×480 JPEG), writes `seed.sql` + `report.json`. |

## Media sources and licenses

1. **wger.de** images (non-AI only), licenses `CC-BY-SA-3.0`, `CC-BY-SA-4.0`, `CC0-1.0`, `CC-BY-4.0`;
   attribution = author + "via wger.de (exercise image N)". CC-BY-SA requires the attribution to be
   shown wherever the image is shown, and derivatives (our resized JPEGs) stay CC-BY-SA.
2. **free-exercise-db** fallback, license `unverified-test-only`. The repo is "Unlicense" but the photos'
   provenance is unknown. **Every `unverified-test-only` row must be replaced before any release.**
   Find them: `SELECT e.slug FROM exercise_media m JOIN exercise_catalog e ON e.id = m.exercise_id WHERE m.license = 'unverified-test-only';`
3. No image: the exercise is still published (skill progressions mostly); the app shows its no-media state.

## Build

```powershell
# source metadata (once)
curl.exe -sL "https://wger.de/api/v2/exerciseimage/?limit=1000" -o $env:TEMP\wger-images.json
curl.exe -sL "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/dist/exercises.json" -o $env:TEMP\fedb.json
pip install pillow
python deploy/test-server/catalog/build_catalog_seed.py --wger-images $env:TEMP\wger-images.json --fedb $env:TEMP\fedb.json --out $env:TEMP\cali-seed
```

Output stays outside the repo. Downloads are cached in `<out>/cache`, so re-runs are fast.

## Apply (docker-compose.testserver.yml stack)

```powershell
$o = "$env:TEMP\cali-seed"
# 1. media -> MinIO bucket cali-media (keys are content-addressed: catalog/<exerciseId>/<kind>-<sha12>.jpg)
docker cp "$o\media\catalog" cali-minio-1:/tmp/seed-catalog
docker exec cali-minio-1 sh -c 'M=/opt/bitnami/minio-client/bin/mc; $M --config-dir /tmp/mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && $M --config-dir /tmp/mc cp --recursive --quiet /tmp/seed-catalog/ local/cali-media/catalog/'
docker exec -u 0 cali-minio-1 rm -rf /tmp/seed-catalog   # docker cp writes as root
# 2. rows (one transaction)
Get-Content "$o\seed.sql" -Raw -Encoding utf8 | docker exec -i cali-db-1 sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Upload media **before** running the SQL so no published row points at a missing object.

Re-running is safe: catalog rows upsert by id; a media row is inserted only when its sha256 is new for
that (exercise, kind), and then gets the next `content_version` (the API serves the newest version).
Changing an image therefore adds a version; it never rewrites an existing key.

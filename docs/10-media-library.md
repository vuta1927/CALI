# Exercise Library / Media Pipeline

## 1. Visual-first requirements
Every catalog exercise must have a poster and thumbnail that show distinctive body position. Preview loop is recommended (5–15s, muted), full tutorial optional. Equipment and camera angle consistent across exercises, so users distinguish Tuck Planche vs Advanced Tuck Planche quickly.

## 2. Media metadata
`mediaId, exerciseId, kind(thumbnail|poster|preview|tutorial|correct|incorrect), contentVersion, locale, durationMs, width, height, aspectRatio, mimeType, sha256, sizeBytes, attribution, license, sourceUrlOrStorageKey, isPublic, lastReviewedAt`.

### 2.1 Offline bundle manifest (ADR-028)
The starter catalog that ships in the app uses its own manifest format, `contracts/catalog-bundle.schema.json`. During development the manifest is `fixtures/exercise_catalog.json`. It is **not** the `GET /v1/exercises` wire shape. The app maps both into the same local tables. Media entries are bundle-relative paths: no URL scheme and no leading slash. When `status` is `development_fixture_only`, plain path strings are allowed. When `status` is `release`, every media entry must be an object `{path, sha256, contentVersion, mimeType, license, attribution?}`. `tools/validate_handoff.py` checks the fixture against this schema. On the wire, `ExerciseMedia.license` is required (ADR-033).

## 3. Offline availability policy
| Media | Policy |
|---|---|
| starter catalog poster+thumbnail | bundle in app or downloadable pack with guaranteed local fallback |
| today's planned exercises | pin poster and preview where downloadable |
| next 7 days planned exercises | Wi-Fi prefetch best effort, show status |
| tutorial videos | explicit download, user may stream |
| history thumbnails | local cached fallback, never block history view |

Media cache can be deleted/rebuilt, session logs cannot. Media files validated by SHA-256 and contentVersion; partial downloads not marked READY. Cache budget configurable (initial suggestion 500MB), manual clear cache, never delete active session pinned files.

## 3.1 Personal media in the local POC (MED-002)
Users can attach their own HTTPS links or import photos/videos through PhotosPicker
or the Files importer. Files are copied into Application Support/exercise-media with
UUID filenames; JSON stores relative references. Imports are capped at 20 MB for images
and 200 MB for videos; video transfer uses a file representation instead of loading
entire videos into RAM. No user media uploads. Cancel discards newly imported files;
saved media is retained across launches and is not treated as an evictable cache.
Remote links require network; webpage videos can open externally. The managed public
catalog licensing and ingestion rules below still apply to distributed starter content.
See [local data and QA rules](17-content-editing.md).

## 4. API and content operations
- Catalog endpoint includes media references/metadata, not huge encoded binaries; media signed URLs expire, client refreshes as needed.
- **Signed URLs (BE-006, ADR-072).** For each public, reviewed media row the catalog returns `url` (AWS SigV4 presigned GET on an S3-compatible bucket such as Cloudflare R2) and `urlExpiresAt` (default 15 minutes, configurable 60..3600 s). The client downloads with a plain GET (Range works), verifies `sha256`, and asks the catalog again when `urlExpiresAt` has passed; it must not store the URL, only the downloaded file. Both are null when the server has no object storage; then the client keeps its bundled or cached copy. The catalog responses are `Cache-Control: no-store` because the URLs expire. `storage_key` is never a field of the response, but it is part of the URL path (S3 cannot hide it), so keys must be opaque (for example `media/{mediaId}/v{contentVersion}`) and immutable per `(exercise, kind, content_version)`. Uploading files and creating `exercise_media` rows is the ingestion tool, not built yet.
- A backend-only content ingestion tool verifies file license, thumbnail quality, orientation, SHA256, version and safety of depicted technique.
- For MVP avoid hot-linking third-party video URLs of unclear license; create/obtain approved assets and keep attribution.

## 5. Playback UX
- AVPlayer preview loops muted, respects reduce motion and playback settings.
- Single active player per screen; stop/pause when sheet dismissed; sheet does **not** pause workout timer.
- If offline video unavailable: display poster, text cues and optional re-download badge; workout remains usable.
- Provide captions/alt descriptions, including side/front camera indication.

## 5.1 Voice pack (CON-010, ADR-077)
- Spoken workout cues are pre-rendered TTS audio (vbee.vn) published as an immutable voice pack per `(locale, version)` (db/011). The sentence script is `fixtures/voice_cues.vi-VN.json`; the publisher job (BE-007) renders, converts to CAF IMA4 mono (≤ 30 s, ≤ 1 MB), stores under an opaque key such as `voice/{locale}/v{version}/{key}.caf` and publishes all cues in one transaction.
- Publisher: `backend/tools/Cali.VoicePack` (BE-007) calls the vbee Realtime API (`mode: sync`, WAV 22050 Hz), converts to CAF IMA4 in process (no `afconvert`/`ffmpeg`, so it runs on Linux), uploads with a presigned PUT and publishes. `render` writes the files locally to listen first; `publish` skips when nothing changed.
- `GET /v1/voice-pack?locale=vi-VN` returns the pack with signed URLs (ADR-072) and sha256; the client keeps only the verified files, never the URLs. Without object storage (Development) `url` is null and the client uses the default sound.

## 6. Media acquisition acceptance
The demo fixture exercises `Tuck Planche`, `Pull-up`, `Dips`, `L-sit`, `Squat`, `Ring Support` may ship with **explicitly marked placeholder assets** until licenses/production videos are secured. Never claim placeholders are exercise-correct without technique review.

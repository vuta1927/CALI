# Exercise Library / Media Pipeline

## 1. Visual-first requirements
Every catalog exercise must have a poster and thumbnail that show distinctive body position. Preview loop is recommended (5–15s, muted), full tutorial optional. Equipment and camera angle consistent across exercises, so users distinguish Tuck Planche vs Advanced Tuck Planche quickly.

## 2. Media metadata
`mediaId, exerciseId, kind(thumbnail|poster|preview|tutorial|correct|incorrect), contentVersion, locale, durationMs, width, height, aspectRatio, mimeType, sha256, sizeBytes, attribution, license, sourceUrlOrStorageKey, isPublic, lastReviewedAt`.

## 3. Offline availability policy
| Media | Policy |
|---|---|
| starter catalog poster+thumbnail | bundle in app or downloadable pack with guaranteed local fallback |
| today's planned exercises | pin poster and preview where downloadable |
| next 7 days planned exercises | Wi-Fi prefetch best effort, show status |
| tutorial videos | explicit download, user may stream |
| history thumbnails | local cached fallback, never block history view |

Media cache can be deleted/rebuilt, session logs cannot. Media files validated by SHA-256 and contentVersion; partial downloads not marked READY. Cache budget configurable (initial suggestion 500MB), manual clear cache, never delete active session pinned files.

## 4. API and content operations
- Catalog endpoint includes media references/metadata, not huge encoded binaries; media signed URLs expire, client refreshes as needed.
- A backend-only content ingestion tool verifies file license, thumbnail quality, orientation, SHA256, version and safety of depicted technique.
- For MVP avoid hot-linking third-party video URLs of unclear license; create/obtain approved assets and keep attribution.

## 5. Playback UX
- AVPlayer preview loops muted, respects reduce motion and playback settings.
- Single active player per screen; stop/pause when sheet dismissed; sheet does **not** pause workout timer.
- If offline video unavailable: display poster, text cues and optional re-download badge; workout remains usable.
- Provide captions/alt descriptions, including side/front camera indication.

## 6. Media acquisition acceptance
The demo fixture exercises `Tuck Planche`, `Pull-up`, `Dips`, `L-sit`, `Squat`, `Ring Support` may ship with **explicitly marked placeholder assets** until licenses/production videos are secured. Never claim placeholders are exercise-correct without technique review.

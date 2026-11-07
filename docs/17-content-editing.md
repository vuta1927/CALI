# Personal exercises, media and plan editing — IOS-009 / MED-002

## Scope
The existing iOS POC has one local weekly plan. Users can add/edit exercises, attach
one poster and one video, rename/delete/recreate their plan and add/edit/delete its
scheduled workouts. Deletion requires UI confirmation and preserves workout history
and the independently persisted active session. Recreating a deleted plan gives it a
new UUID. Each weekday has at most one scheduled workout.

Exercise UUIDs stay stable when edited. Changing an exercise type is rejected if the
exercise occurs in a plan, active session or history, preserving target compatibility.
Session execution prescriptions remain snapshots. Catalog name/cue/media edits are
visible immediately wherever that exercise is displayed.

## Storage and contract boundary
This extends the offline JSON POC, not the shared workout reducer or server schema.
The public catalog API remains managed/read-only. Personal edits and file paths must
not be sent as catalog or sync mutations. OpenAPI, SQL and sync payloads are unchanged;
server ownership, authorization and conflict handling need a separate contract slice
before personal-content synchronization is implemented.

Snapshot `catalog`, exercise `poster/video` and plan `deletedAt` are optional additive
fields. Missing catalog falls back to the original fixture only when reading an older
snapshot; saved edits are authoritative on subsequent launches. No existing history
or active-session migration is needed. Content commands validate, capture a UUID,
atomically save the candidate snapshot plus audit receipt, then publish UI state.
Repeat command IDs return their existing success without applying the change twice.
Write errors retain the current content and keep the editor open.

Imported images/videos are copied under Application Support/exercise-media and referenced
by relative UUID filenames. Security-scoped access is balanced. Photos imports copy
within the transfer callback while the source is available. The picker needs no broad
photo-library read permission. Images are limited to 20 MB and movies to 200 MB.
Canceling the editor discards that draft's imports; successful saves retain only the
imports still selected by the draft. Previously saved replaced files are retained for
now to avoid removing media in use. A later storage-management slice must account for
active references before collecting them. Resetting demo data does not collect these
files. No user files are uploaded.

Only HTTPS links with a host and no embedded credentials are accepted. Linked media
needs network and is not promised offline. Direct compatible videos use AVPlayer with
manual play; webpage video links can open externally. Players pause on disappearance
and do not change workout timers. Missing/unavailable images retain the labeled
placeholder. Built-in examples remain sample data.

## Validation and remaining evidence
`ios/CaliAppTests/ContentEditingTests.swift` covers edit identity, duplicate command
receipts, reference/type protection, delete/history/active-session preservation,
unsafe URL/path rejection, duplicate weekdays, old snapshot decoding, new snapshot
round trips and imported-file durability after source removal.

XCTest requires the macOS workflow (`run_tests=true`) or Xcode. Windows static parsing
does not prove Swift type checking or device behavior. No Lock Screen code changed.

Run this manual matrix on a real iPhone before closing IOS-009 / MED-002:

| Case | Expected | Evidence |
|---|---|---|
| Create/edit/search/relaunch exercise | Edits and identity retained; usable in workout picker | Pending |
| Import JPEG/HEIC/PNG and MOV/MP4 from Photos and Files | Poster/video loads; relaunch and airplane mode still work | Pending |
| Cancel picker, cancel editor, replace/gỡ media | No unintended metadata save; draft imports cleaned | Pending |
| iCloud-only asset, unavailable provider, oversized file | Clear error; editor remains usable | Pending |
| HTTPS image, direct video, webpage video, broken link, airplane mode | Render/play or open link; fallback keeps workout usable | Pending |
| Rename plan, add/move/edit/delete workout, duplicate day | Saved or rejected clearly; one workout/day | Pending |
| Cancel/confirm plan deletion; relaunch; recreate | Confirmation enforced; history/active session retained; new plan works | Pending |
| Full disk/write failure | Error shown; no content published as saved | Pending |
| VoiceOver, largest Dynamic Type, light/dark, Reduce Motion | Labeled controls, readable fields, manual video play, usable targets | Pending |

API references: [fileImporter](https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:oncompletion:)),
[FileRepresentation](https://developer.apple.com/documentation/coretransferable/filerepresentation),
[PhotosPicker](https://developer.apple.com/documentation/photosui/photospicker).

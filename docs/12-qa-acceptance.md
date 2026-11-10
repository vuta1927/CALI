# QA Plan / Test Strategy / Acceptance Matrix

## 1. Test layers
- Unit domain reducer with fake clock; GRDB transaction and command dedupe.
- Widget/AppIntent integration and image snapshot tests.
- Backend .NET unit + PostgreSQL integration + OpenAPI contract tests.
- Offline sync E2E two clients and forced network failure.
- AI contract/evals with deterministic provider stub, then staging actual provider on anonymized fixtures.
- Device manual suite — real iPhone with/without Dynamic Island, varying iOS supported versions.

## 2. Highest priority scenarios
| Test ID | Precondition | Steps | Expected |
|---|---|---|---|
| T-01 | sample plan installed | start Tuck Planche | poster + target + 4 sets, no network needed |
| T-02 | active hold 12s | lock phone at 4s; wake at 10s | system-rendered timer progresses, no ghost confirmed result |
| T-03 | hold target reached | do not press confirm | set not marked completed; result awaits user |
| T-04 | result confirmation | double tap confirm | exactly one `set_result`, one outbox semantic mutation |
| T-05 | rest 90s | add 30s, return foreground | deadline + reminder rescheduled, no duplicate cue |
| T-06 | airplane mode | finish full workout | all data local; sync queued |
| T-07 | online recovered | replay push same mutation 10x | 1 DB row, duplicate receipt consistent (backend: `SyncPushTests.Same_push_sent_ten_times_concurrently_writes_once_and_replays_the_receipt`, B2) |
| T-08 | server returns 409 | modify same plan on 2 devices | no silent overwrite; conflict visible |
| T-09 | app killed after confirm | relaunch | resume from durable state, no duplicate set |
| T-10 | media never downloaded | open exercise offline | poster fallback and cues; workout continues |
| T-11 | locked device | tap Live Activity action | iOS unlock/auth requirement observed; no undocumented bypass |
| T-12 | notifications denied | rest expires | in-app timer remains; nonblocking fallback |
| T-13 | AI provider 500 | complete synced session | analysis failure/retry visible; history/session unaffected |
| T-14 | AI suggests unsafe progression | deterministic rule rejects | no plan alteration; reason logged |
| T-15 | 2 concurrent accept actions | same recommendation | exactly one accepted plan revision |
| T-16 | logout/login another user | inspect session and sync | no cross-account history leak |
| T-17 | wall-clock moved backward | during hold/rest and resume | detect discrepancy, do not invent actual hold |
| T-18 | Large Dynamic Type | home/player/rest screen | primary actions visible and accessible |
| T-19 | voice pack cached, phone locked in pocket | rest 60s ends | `rest.ending_10s` then `rest.done` audible once each; set/rest state unchanged until user acts (CON-010) |
| T-20 | app foreground, music playing | hold target reached | `hold.done` plays once, music ducks then resumes; no duplicate from the notification |
| T-21 | voice pack never downloaded / airplane mode | rest ends | default notification sound; workout unaffected |
| T-22 | rest +30s / pause during rest | wait past old deadline | no cue at old deadline; cue at new deadline only |
| T-23 | ringer switch silent, Focus on | locked rest ends | documented iOS behavior recorded in device matrix (ADR-078 limitation) |

## 3. Acceptance by epic
- **Player**: all legal transitions + invalid transitions tested; no data loss with process termination after commit.
- **Lock Screen**: POC evidence for real devices; timer and phase visible when allowed; auth behavior documented; graceful fallback.
- **Sync**: idempotent, bounded batches, conflict surfaced, cursor atomic, guest attach.
- **AI**: JSON schema guaranteed at API boundary, unsafe recommendations blocked, user approval required.
- **UX**: every planned exercise has visible poster, preview 1 tap, offline fallback, VoiceOver labels.

## 4. Performance budgets to measure
- Screen entry home/play from warm app <=1s p95 on pilot phone (target).
- Local confirm transaction <=100ms p95 on pilot device (target).
- Countdown timestamp accuracy at next render within 1s for normal clock (target); **not** guaranteed notification arrival accuracy.
- Outbox enqueue exactly same transaction as set result; crash consistency test.
- API push 100 operations <=2s p95 under modest pilot load; measure in staging.
- AI analysis async target <60s p95 when provider healthy; no UX hard-block.

## 5. Release gates
No release if T-02, T-04, T-06, T-07, T-09, T-11, T-14 fail. Require evidence of device test, schema migrations from blank DB, pen-test checklist and data rights for shipped media. Test examples in `tests/acceptance.feature`.

# ADR Baseline, Assumptions and Risks

## Accepted baseline decisions
| ADR | Decision | Rationale | Revisit trigger |
|---|---|---|---|
| ADR-001 | Native SwiftUI iOS | seamless WidgetKit/ActivityKit, timers, media | Android scope emerges |
| ADR-002 | GRDB/SQLite local (App Group) | explicit transactional outbox and command dedupe | POC shows locked access issue |
| ADR-003 | Offline writes local first | ensure session never depends on network | none |
| ADR-004 | ASP.NET Core 10 LTS + PostgreSQL | durable backend, familiar stack | organizational hosting constraint |
| ADR-005 | REST push/pull sync + cursor | simple, auditable, idempotent | high real-time collaboration requirement |
| ADR-006 | One server job queue in Postgres | avoid premature broker complexity | high-volume AI jobs |
| ADR-007 | AI has no direct write permissions to plan | safety, explicit consent | none |
| ADR-008 | Video only foreground app; poster for Lock Screen | WidgetKit/ActivityKit constraints | platform APIs materially change |
| ADR-009 | Actual completion needs explicit confirmation | no false logs when timer expires | validated sensor measurement later |
| ADR-010 | iOS deployment target initially 18+ | manageable QA surface, interactive Live Activities | device market/compatibility analysis |

## Implementation-setup decisions (proposed)
ADR-011..015 are defined in [docs/16 §ADR](16-implementation-plan.md): XcodeGen project generation, CaliDomain/CaliCore split, single-writer app process for Live Activity intents, DbUp + Dapper on `db/*.sql`, Development-only dev tokens. ADR-013 changes the App Group assumption of ADR-002 and becomes *Accepted* only with POC-001/002 evidence.

## Contract decisions (CON-001 review, Accepted 2026-11-07)
Resolve items D1–D18 of [CON-001](reviews/CON-001-contract-review.md) §5. Every artifact listed was updated in the same change: `contracts/openapi.yaml`, `contracts/entity-payloads.schema.json`, `contracts/catalog-bundle.schema.json`, `db/001_initial.sql`, fixtures, docs and tests.

| ADR | CON-001 | Decision | Rationale | Revisit trigger |
|---|---|---|---|---|
| ADR-016 | D1 | docs/03 §2 is the **conceptual** model. Wire names (OpenAPI/JSON Schema camelCase, SQL snake_case) are canonical. docs/03 §2.1 maps concept names to wire names | renaming the wire breaks every artifact without any behavior gain | never: new fields use wire naming from the start |
| ADR-017 | D2 | **MVP fields**: `workout_session.pausedAt`, `accumulatedExerciseMs`, `abandonReason` (≤500); `set_result.skipReason` (≤500), `painReported` (bool, default false). `finishedAt` is set for **both** terminal statuses (no separate `abandonedAt` on the wire). **Post-MVP** (marked in docs/03): `TrainingPlan.startDate/weeks`, session `planRevisionId/revision`, `WorkoutNote.revision`, `PlannedExercise.cuesSnapshot`. `ExerciseExecution.setCount` lives in `prescribedSnapshot.setCount` | docs/09 §5 pain rule needs a structured pain flag; pause/abandon state must survive reinstall and reach analytics. Device-local timer details (`pausedRemainingMs`, monotonic marks) stay off the wire | cross-device resume of a paused timer becomes a requirement |
| ADR-018 | D3 | `prescribedSnapshot` = `$defs/prescribed_snapshot`: required `target`, `setCount`, `restSeconds`, `catalogVersion`; optional `exerciseId`, `plannedExerciseId`; closed. The same shape is used on `exercise_execution` and `set_result`. SQL requires the four keys and has no `'{}'` default | history must stay interpretable after plan/catalog edits (docs/03 invariant); this is the same shape as CaliDomain `PrescribedSnapshot` | catalog versioning model changes |
| ADR-019 | D4 | INTERVAL `restSeconds ≥ 1` everywhere (follows docs/03). Zero-rest continuous work is modeled as `timed_reps` | a zero-length REST phase creates a phase with an immediate deadline and no user value | product asks for EMOM/zero-rest intervals |
| ADR-020 | D5 | Cross-field rules (`repMin ≤ repMax`; `target.kind` = catalog `exercise_type`) are enforced in **backend sync validation** (backend-agent) and **CaliDomain** (ios-agent). The result is `rejected` + `validation_failed`. There is no SQL trigger. Shared vectors: `fixtures/validation/business_rules.json` (the validator asserts they are schema-valid) | JSON Schema cannot compare fields or look up the catalog; one fixture set keeps both implementations aligned | a third client appears (then generate validators) |
| ADR-021 | D6 | Receipts are persisted for `applied`, `rejected` and `version_conflict`. **Retryable results (`dependency_missing`) are not persisted**, so the client retries with the same `mutationId` after the parent is acked. `MutationError` = `{code (enum), message, retryable, details?}`. Codes: `dependency_missing`, `version_conflict`, `validation_failed`, `forbidden_entity`, `cross_user_reference`, `mutation_id_reused` | keeps docs/08 "retry with same mutationId" and makes every code machine-actionable | batch dependency ordering moves to the server |
| ADR-022 | D7 | Pull `SyncChange.payload` is discriminated by `entityType` + `operation`. A device-writable upsert uses the **same** `<entity>_payload` schema as push. `ai_analysis` → `Analysis`. `ai_recommendation` → `AnalysisRecommendation` + `analysisId`. Delete → `{id, deletedAt}`. Version is carried by `serverVersion` | one mapper per entity on iOS and backend; no invented field names | a pull-only field is needed (add it to the envelope, not the payload) |
| ADR-023 | D8 | `status=completed ⇔ phase=completed`, `status=abandoned ⇔ phase=abandoned`, and `pausedAt` is non-null only when `phase=paused`. Enforced by SQL CHECK, JSON Schema `if/then` and the domain reducer. `reviewing_summary` belongs to `active` | prevents impossible persisted states (seen in the CON-001 smoke test) | new terminal states |
| ADR-024 | D9 | `date-time` accepts any RFC 3339 offset. The server normalizes to UTC and always emits `Z`. `timezone` must be an IANA id known to the backend tz database (`validation_failed` otherwise). There is no SQL CHECK | lenient input, deterministic output; tzdb lookup cannot be done in a CHECK | a client sends local times without offsets |
| ADR-025 | D10 | `set_results` uniqueness = partial unique index `(execution_id, set_index) WHERE deleted_at IS NULL`. Clients still re-confirm with the **same id** (`revision+1`) per docs/07 §3 | deleting and recording again with a new id must not deadlock sync | never |
| ADR-026 | D11 | `AnalysisRecommendation.exerciseId` is nullable (session-level recommendations such as `needs_more_data`) | matches SQL; avoids fake exercise ids | never |
| ADR-027 | D12 | `planned_workout.title` is optional, ≤120 characters, stored as `''` when omitted | matches OpenAPI and SQL; weekday + order identify a workout | UI requires named workouts |
| ADR-028 | D13 | `fixtures/exercise_catalog.json` is the **offline bundle manifest**, a separate format described by `contracts/catalog-bundle.schema.json`. It is not `GET /v1/exercises`. A `release` bundle requires media objects with `sha256`, `contentVersion`, `mimeType` and `license` | the bundle ships inside the app and needs file paths; the wire needs signed URLs | the bundle is generated from the API |
| ADR-029 | D14 | The docs/03 mermaid diagram now shows abandon from every non-terminal phase and the skip transitions from the command table. No behavior change | the diagram must not contradict the command table | — |
| ADR-030 | D15 | The mutation envelope is closed (`additionalProperties: false` on `SyncMutation` and `mutation_common`); payloads were already closed | "reject unknown fields" must hold for the whole request; there are no clients yet, so this is not breaking now | protocol version 2 |
| ADR-031 | D16 | `sync_mutations.payload_sha256` = SHA-256 (lowercase hex) of the RFC 8785 canonical JSON of `{entityType, entityId, action, baseVersion, payload}`. `clientChangedAt` is excluded because it is advisory. Same `mutationId` with a different hash → `rejected` / `mutation_id_reused` (not persisted; the original receipt is unchanged) | prevents a `duplicate` answer for a mutation the server never applied | — |
| ADR-032 | D17 | The LLM output schema (docs/09 §6, slug-based, kind-less targets) is **separate** from API `AnalysisOutput`. A server mapping step resolves slug→uuid (an unknown slug drops the recommendation and is logged), adds `kind` from the catalog type, sets `decision=proposed`, then runs the policy rules. The pain rule uses action `reduce`/`maintain` + `safetyFlags: ["pain_reported"]`; no new action value. `proposedTarget` is a full `PlannedTarget` or `null` | the LLM never sees uuids; one typed storage model; the action enum stays stable for clients | the provider supports reliable uuid-constrained output |
| ADR-033 | D18 | `set_result.note` ≤1000. `sync_mutations (device_id, user_id)` → FK `devices(id, user_id)`; the first push from a device upserts its `devices` row in the same transaction, and a `deviceId` owned by another user → 409 `device_owner_mismatch`. `ExerciseMedia.license` is required on the wire | bounds abuse; receipts are always attributable to a registered device of the same user | a device management API is added |

> **Migration note.** `db/001_initial.sql` was edited in place because no shared or production database exists yet. Recreate local databases with `docker compose down -v`. After the first deployed environment, every schema change must be a new numbered migration.

## Assumptions requiring validation before public release
- Apple Developer Team ID, Bundle ID, App Group ID, signing and deployment target must be supplied by project owner; files use placeholders, **not production credentials**.
- Brand/app name `CALI` is working title only; legal availability not checked.
- Media licensing and content review before production; demo placeholders not final assets.
- Training heuristics need review by appropriately qualified trainer, especially Iron Cross and high tendon load.
- Product privacy policy, data deletion/export, consent wording, backend region/data residency not yet finalized.
- User appetite for Sign in with Apple, automatic media cache sizes and reminder timing needs usability testing.

## Risk register
| ID | Risk | Impact | Mitigation / owner |
|---|---|---|---|
| R-01 | User expects controls on locked phone without unlock | High | POC early, clarify OS limitation, alternate notification/deep link; Product/iOS |
| R-02 | Background timer state silently wrong | Critical | deadline-based render, explicit confirmation, reconciliation tests; iOS/QA |
| R-03 | Widget and app write race / DB locked | High | App Group SQLite transaction/serial access, dedupe and concurrency tests; iOS |
| R-04 | Reconnect background sync not immediate | Medium | foreground sync, BGTask best effort, honest status badges; iOS |
| R-05 | Duplicate/overwritten workout history | Critical | outbox idempotency, optimistic versions, server receipts and tests; BE |
| R-06 | AI unsafe suggestion or hallucination | High | deterministic guardrails, structured JSON, approval, evals; AI |
| R-07 | Media rights invalid / form inaccurate | High | licensed content process and technique review; Content |
| R-08 | iOS Data Protection blocks widget action on lock state | High | POC & privacy-minded shared storage policy; iOS/Security |
| R-09 | Offline devices resume after tombstones expired | Medium | full resync policy and stale-device UX; BE/iOS |
| R-10 | Clock tampering/time drift affects actual hold | Medium | monotonic while foreground, recorded actual editable, reconciliation; iOS |

## Open questions to resolve without blocking first POC
- Supported iOS versions and iPhone device mix.
- Exact branding and language support for v1.
- Account deletion SLA/data hosting region, whether guest data encryption beyond iOS file protection is needed.
- Precise AI model/vendor and cost budget; prompt schema is provider-independent.
- Media acquisition pipeline and consent for any future camera analysis.

## Documented Apple platform facts
- Interactive widget/Live Activity controls require auth/unlock on locked device: https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- Live Activities active up to 8h, retained on Lock Screen up to 4 additional hours: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Notification delivery is best effort: https://developer.apple.com/documentation/usernotifications
- Background tasks scheduled by system, not real-time: https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler

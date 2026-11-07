# Data Model / Persistence Specification

## 1. Primary entities
| Entity | Ownership | Important fields | Rules |
|---|---|---|---|
| users | server | id, apple_subject, display_name, timezone, created_at | user scoped |
| devices | server | id, user_id, device_name, last_seen_at | multiple devices possible; upserted by the first push from a device (ADR-033) |
| exercise_catalog | server public | id, slug, exercise_type, equipment, cues, catalog_version, is_published | media licensed/versioned |
| exercise_media | server public | id, exercise_id, kind, content_version, storage_key, sha256, license | poster fallback |
| training_plans | user | id, user_id, title, revision, parent_plan_id, status, version | immutable review history via versions |
| planned_workouts | user | id, plan_id, weekday, order_index, title (optional, ≤120, `''` default) | order explicit (ADR-027) |
| planned_exercises | user | id, planned_workout_id, exercise_id, order_index, set_count, target JSON, rest_seconds | validated type |
| workout_sessions | user | id, planned_workout_id?, local_date, timezone, status, phase, paused_at?, accumulated_exercise_ms?, abandon_reason?, version | single active per user (`ux_session_one_active_per_user`); status↔phase CHECK (ADR-023) |
| exercise_executions | user | id, session_id, exercise_id, order_index, prescribed_snapshot | snapshot prescribed (ADR-018) |
| set_results | user | id, execution_id, set_index, prescribed_snapshot, actual_*, status, note (≤1000), skip_reason (≤500), pain_reported, revision | idempotent by ID; one live row per set (ADR-025) |
| workout_notes | user | id, session_id, note_text, version | sensitive; avoid lock screen |
| sync_mutations | server | user_id, mutation_id, device_id, status, receipt, payload_sha256 | unique/idempotent; FK `(device_id,user_id)` → devices (ADR-031, ADR-033) |
| sync_change_log | server | seq, user_id, entity_type, entity_id, operation, payload | ordered sync feed |
| ai_analyses | user | id, session_id, session_version, status, model_provider, model_name, result | immutable result version |
| ai_recommendations | user | id, analysis_id, decision, rationale, proposed_target | approval required |
| ai_jobs | server | id, analysis_id, state, attempts, available_at, leased_until | durable retry |

## 2. Canonical syncable entities
`training_plan`, `planned_workout`, `planned_exercise`, `workout_session`, `exercise_execution`, `set_result`, `workout_note`, `ai_analysis`, `ai_recommendation` (last two server-owned). Client may push only its allowed entities. Catalog is server-owned and versioned; app bundles initial starter subset.

## 3. Invariants
- All user-owned rows have `user_id`; stored procedures/API apply auth-context scoping.
- Client-generated UUID stable across offline and online; `baseVersion=0` for new entity, >0 for update.
- `set_results` has one **live** row per `(execution_id,set_index)`: a partial unique index `WHERE deleted_at IS NULL` (ADR-025). To edit a set, update the same ID, bump revision and preserve audit via change log/revision history. Never insert a second competing set. A soft-deleted result does not block a replacement.
- `prescribed_snapshot` (on executions and set results) = `{target, setCount, restSeconds, catalogVersion, exerciseId?, plannedExerciseId?}` per `entity-payloads.schema.json#/$defs/prescribed_snapshot`. SQL requires the four mandatory keys. The API validates the full shape (ADR-018).
- Session `status=completed ⇔ phase=completed` and `status=abandoned ⇔ phase=abandoned`. `paused_at` is non-null only when `phase=paused` (ADR-023).
- `actual_reps >= 0`, `actual_hold_ms >= 0`, `rpe between 1 and 10`; not all actual metrics required for skipped set.
- `finished_at >= started_at` (UTC `timestamptz`) when provided. The session can be `status=active, phase=reviewing_summary` until FinishSession is tapped.
- `deleted_at` (soft delete) for user-deletable entities; change feed includes tombstone.
- AI recommendation references analysis+session version; reject stale revisions.

## 4. Plan revision policy
For MVP, `training_plans.revision` increments on change; `planned_workouts`/`planned_exercises` represent current editable plan with change log versions; on applying AI recommendation clone plan and descendants to **new plan ID** with `parent_plan_id` and `revision=parent+1`, preserving old plan. Never mutate history of executed session; execution snapshots targets.

## 5. Cross-field validation
- STATIC_HOLD target JSON: `{ "kind":"static_hold", "holdSeconds":12 }`.
- REPS target: `{ "kind":"reps", "repMin":8, "repMax":10 }`.
- `rest_seconds`: integer 0..3600 (product policy initially).
- `set_count`: integer 1..20 (product policy initially).
- Date values in `local_date`. `timezone` must be an IANA id known to the backend tz database, checked in the API rather than SQL (ADR-024).
- Event times: input accepts any RFC 3339 offset. The server stores `timestamptz` and always emits UTC with `Z` (ADR-024).
- Cross-field rules `repMin ≤ repMax` and `target.kind == exercise_catalog.exercise_type` are enforced by API validation and CaliDomain, with vectors in `fixtures/validation/business_rules.json`. There is no SQL trigger (ADR-020).

## 6. Notes for local and physical schema
`db/001_initial.sql` is server DDL baseline. It was edited in place for CON-001 because no deployed database exists. After the first deployed environment, schema changes go in new numbered migrations (see docs/15). Local GRDB migrations should mirror only fields used offline, plus outbox & processed commands. Server change feed retains canonical payload JSON (per entity DTO), so avoid undefined field names. Non-public media URLs should be short-lived and fetched through metadata endpoint.

## 7. Data privacy + deletion
- Export user's workout data JSON or CSV (later UI; architecture supports).
- Account deletion API/cascade policy must be decided prior public launch; can start with operator-managed deletion during pilot.
- Retain AI prompt/output only within privacy limits and document retention; avoid storing free-text notes in external AI vendor logs if not required.

## 8. Typed sync payloads
`contracts/entity-payloads.schema.json` is the normative per-entity payload validator for `POST /v1/sync/push`; OpenAPI specifies the envelope. Use JSON Schema validation server-side and generated/handwritten typed models on iOS, ensuring JSON keys stay aligned.

## POC personal-content persistence (IOS-009 / MED-002)
The app's JSON snapshot adds optional `catalog`; missing means the original bundled
sample catalog, while an explicit array is authoritative. `Exercise.poster/video`
are optional `{source: local|remote, value: string}` references. `WorkoutPlan.deletedAt`
is an optional local tombstone; deleting clears scheduled workouts only. These additive
fields retain snapshot schemaVersion 1 and decode absent fields as nil. See
[scope and migration](17-content-editing.md). These app-only shapes are not sync payloads;
they require no change to the PostgreSQL schema or public API in this POC.

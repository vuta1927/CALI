# Data Model / Persistence Specification

## 1. Primary entities
| Entity | Ownership | Important fields | Rules |
|---|---|---|---|
| users | server | id, apple_subject, created_at | user scoped |
| devices | server | id, user_id, name, last_seen | multiple devices possible |
| exercise_catalog | server public | id, slug, type, equipment, version, cues | media licensed/versioned |
| exercise_media | server public | id, exercise_id, kind, file_key, SHA256, license | poster fallback |
| training_plans | user | id, user_id, title, revision, status | immutable review history via versions |
| planned_workouts | user | id, plan_id, weekday, sequence | order explicit |
| planned_exercises | user | id, workout_id, exercise_id, target JSON, rest | validated type |
| workout_sessions | user | id, planned_workout_id?, status, phase, version | single active per client profile |
| exercise_executions | user | id, session_id, exercise_id, order_index | snapshot prescribed |
| set_results | user | id, execution_id, set_index, actual*, status, revision | idempotent by ID |
| workout_notes | user | id, session_id, text, version | sensitive; avoid lock screen |
| sync_mutations | server | user_id, mutation_id, receipt_json, result | unique/idempotent |
| sync_change_log | server | seq, user_id, entity_type, entity_id, operation, payload | ordered sync feed |
| ai_analyses | user | id, session_id, session_revision, status, model, result | immutable result version |
| ai_recommendations | user | id, analysis_id, decision, rationale, delta | approval required |
| ai_jobs | server | id, kind, entity_id, state, attempts, lease | durable retry |

## 2. Canonical syncable entities
`training_plan`, `planned_workout`, `planned_exercise`, `workout_session`, `exercise_execution`, `set_result`, `workout_note`, `ai_analysis`, `ai_recommendation` (last two server-owned). Client may push only its allowed entities. Catalog is server-owned and versioned; app bundles initial starter subset.

## 3. Invariants
- All user-owned rows have `user_id`; stored procedures/API apply auth-context scoping.
- Client-generated UUID stable across offline and online; `baseVersion=0` for new entity, >0 for update.
- `set_results` unique `(execution_id,set_index)` for current canonical result. If same set must be edited, update same ID, bump revision, preserve audit via change log/revision history, never insert a second competing set.
- `actual_reps >= 0`, `actual_hold_ms >= 0`, `rpe between 1 and 10`; not all actual metrics required for skipped set.
- `finished_at_utc >= started_at_utc` when provided. The session can be `status=active, phase=reviewing_summary` until FinishSession is tapped.
- `soft_deleted_at` for user-deletable entities; change feed includes tombstone.
- AI recommendation references analysis+session version; reject stale revisions.

## 4. Plan revision policy
For MVP, `training_plans.revision` increments on change; `planned_workouts`/`planned_exercises` represent current editable plan with change log versions; on applying AI recommendation clone plan and descendants to **new plan ID** with `parent_plan_id` and `revision=parent+1`, preserving old plan. Never mutate history of executed session; execution snapshots targets.

## 5. Cross-field validation
- STATIC_HOLD target JSON: `{ "kind":"static_hold", "holdSeconds":12 }`.
- REPS target: `{ "kind":"reps", "repMin":8, "repMax":10 }`.
- `rest_seconds`: integer 0..3600 (product policy initially).
- `set_count`: integer 1..20 (product policy initially).
- Date values in `local_date`, `timezone` IANA, UTC event times.

## 6. Notes for local and physical schema
`db/001_initial.sql` is server DDL baseline. Local GRDB migrations should mirror only fields used offline, plus outbox & processed commands. Server change feed retains canonical payload JSON (per entity DTO), so avoid undefined field names. Non-public media URLs should be short-lived and fetched through metadata endpoint.

## 7. Data privacy + deletion
- Export user's workout data JSON or CSV (later UI; architecture supports).
- Account deletion API/cascade policy must be decided prior public launch; can start with operator-managed deletion during pilot.
- Retain AI prompt/output only within privacy limits and document retention; avoid storing free-text notes in external AI vendor logs if not required.

## 8. Typed sync payloads
`contracts/entity-payloads.schema.json` is the normative per-entity payload validator for `POST /v1/sync/push`; OpenAPI specifies the envelope. Use JSON Schema validation server-side and generated/handwritten typed models on iOS, ensuring JSON keys stay aligned.

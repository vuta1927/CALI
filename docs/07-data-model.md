# Data Model / Persistence Specification

## 1. Primary entities
| Entity | Ownership | Important fields | Rules |
|---|---|---|---|
| users | server | id, apple_subject, display_name, timezone, created_at | user scoped |
| devices | server | id, user_id, device_name, last_seen_at | multiple devices possible; upserted by the first push from a device (ADR-033) |
| exercise_catalog | server public | id, slug, exercise_type, discipline, focus_tags, equipment, cues, catalog_version, is_published | media licensed/versioned; `exercise_type` ∈ static_hold, reps, timed_reps, interval, skill_attempt, distance, duration, load (`ck_exercise_catalog_exercise_type`, db/003, db/006); `discipline` NOT NULL ∈ calisthenics, gym, running (`ck_exercise_catalog_discipline`), `focus_tags` jsonb array mặc định `[]` (`ck_exercise_catalog_focus_tags`); không có cột `measurement_type` (ADR-060, db/006) |
| exercise_media | server public | id, exercise_id, kind, content_version, storage_key, sha256, license | poster fallback |
| training_plans | user | id, user_id, lineage_id, title, revision, parent_plan_id, status (`current\|superseded`), kind, event_date?, event_name?, primary_discipline, ended_at?, end_reason?, end_note?, archived_at?, version | immutable review history via versions; một bản `current` chưa xoá mỗi lineage (`ux_training_plans_one_current_per_lineage`); ≤ `plan_count_limit` bản chưa xoá mỗi user (db/004) |
| plan_activations | user | id, user_id, plan_lineage_id, from_date, to_date?, timezone, end_reason?, version, deleted_at? | CON-003: I1 bằng exclusion constraint `ex_plan_activations_no_overlap`; I2 bằng trigger `trg_plan_activations_guard` |
| plan_phases | user | id, user_id, plan_id, order_index, name, weeks (1..52), description?, version, deleted_at? | CON-005: thuộc một phiên bản giáo án; `plan_id` không đổi (`ck_plan_phases_plan_immutable`) |
| plan_goals | user | id, user_id, plan_lineage_id, title, indicator_id, exercise_id?, baseline?, target_value? \| target_min + target_max, scope_phase_id?, unlock_after_goal_id?, status, achieved_at?, pinned, note?, version, deleted_at? | CON-005: thuộc lineage; trigger `trg_plan_goals_guard` (CA003, CA004); không có cột `current` |
| indicator_definitions | server | id (slug), version, kind, label, unit, step, aggregation (`max\|sum`), measurement_types[], enabled | CON-005: không xoá, `kind/unit/aggregation` không đổi (ADR-051, ADR-058) |
| plan_audit_events | server | id, user_id, entity_type (`plan_goal\|plan_phase`), entity_id, entity_version, operation, old_row?, new_row, mutation_id?, changed_at | CON-005: chỉ thêm, ghi bởi trigger (đề xuất ADR-059) |
| body_measurements | user | id, user_id, kind (`weight`), value, measured_at, version, deleted_at? | CON-007: **nhạy cảm**; kg, không có cột đơn vị (ADR-046, ADR-063); không bao giờ là đầu vào AI, không hiện trên Lock Screen (ADR-064) |
| server_settings | server | key, int_value | cấu hình không phụ thuộc user: `active_plan_limit` = 3, `plan_count_limit` = 50 (db/004); `pinned_goal_limit` = 3 (db/005) |
| planned_workouts | user | id, plan_id, weekday, order_index, title (optional, ≤120, `''` default) | order explicit (ADR-027) |
| planned_exercises | user | id, planned_workout_id, exercise_id, order_index, set_count, target JSON, rest_seconds | validated type |
| workout_sessions | user | id, planned_workout_id?, local_date, timezone, status, phase, paused_at?, accumulated_exercise_ms?, abandon_reason?, version | single active per user (`ux_session_one_active_per_user`); status↔phase CHECK (ADR-023) |
| exercise_executions | user | id, session_id, exercise_id, order_index, prescribed_snapshot | snapshot prescribed (ADR-018) |
| set_results | user | id, execution_id, set_index, prescribed_snapshot, actual_*, distance_meters?, duration_seconds?, source, actual_load_kg?, status, note (≤1000), skip_reason (≤500), pain_reported, revision | idempotent by ID; one live row per set (ADR-025); không có cột pace (CON-004) hay volume (CON-006) |
| workout_notes | user | id, session_id, note_text, version | sensitive; avoid lock screen |
| sync_mutations | server | user_id, mutation_id, device_id, status, receipt, payload_sha256 | unique/idempotent; FK `(device_id,user_id)` → devices (ADR-031, ADR-033) |
| sync_change_log | server | seq, user_id, entity_type, entity_id, operation, payload | ordered sync feed |
| ai_analyses | user | id, session_id, session_version, status, model_provider, model_name, result | immutable result version |
| ai_recommendations | user | id, analysis_id, decision, rationale, proposed_target | approval required |
| ai_jobs | server | id, analysis_id, state, attempts, available_at, leased_until | durable retry |

## 2. Canonical syncable entities
`training_plan`, `planned_workout`, `planned_exercise`, `workout_session`, `exercise_execution`, `set_result`, `workout_note`, `plan_activation` (CON-003), `plan_phase`, `plan_goal` (CON-005), `body_measurement` (CON-007), `ai_analysis`, `ai_recommendation` (last two server-owned). Client may push only its allowed entities. Catalog is server-owned and versioned; app bundles initial starter subset.

## 3. Invariants
- All user-owned rows have `user_id`; stored procedures/API apply auth-context scoping.
- Client-generated UUID stable across offline and online; `baseVersion=0` for new entity, >0 for update.
- `set_results` has one **live** row per `(execution_id,set_index)`: a partial unique index `WHERE deleted_at IS NULL` (ADR-025). To edit a set, update the same ID, bump revision and preserve audit via change log/revision history. Never insert a second competing set. A soft-deleted result does not block a replacement.
- `prescribed_snapshot` (on executions and set results) = `{target, setCount, restSeconds, catalogVersion, exerciseId?, plannedExerciseId?}` per `entity-payloads.schema.json#/$defs/prescribed_snapshot`. SQL requires the four mandatory keys. The API validates the full shape (ADR-018).
- Session `status=completed ⇔ phase=completed` and `status=abandoned ⇔ phase=abandoned`. `paused_at` is non-null only when `phase=paused` (ADR-023).
- `actual_reps >= 0`, `actual_hold_ms >= 0`, `rpe between 1 and 10`; not all actual metrics required for skipped set.
- Tạ (db/006): `actual_load_kg` numeric kg, 0..1000 và tối đa 2 chữ số thập phân theo giá trị (`actual_load_kg = round(actual_load_kg, 2)`, nên 57.500 hợp lệ, 57.555 bị từ chối) (`ck_set_results_actual_load_kg`, ADR-062). Volume không được lưu.
- Chạy bộ (db/003): `distance_meters` 0..1000000 (`ck_set_results_distance_meters`), `duration_seconds` 0..86400 (`ck_set_results_duration_seconds`), `source` NOT NULL mặc định `'manual'` và chỉ nhận `'manual'` (`ck_set_results_source`, ADR-043). Pace không được lưu.
- `finished_at >= started_at` (UTC `timestamptz`) when provided. The session can be `status=active, phase=reviewing_summary` until FinishSession is tapped.
- `deleted_at` (soft delete) for user-deletable entities; change feed includes tombstone.
- AI recommendation references analysis+session version; reject stale revisions.
- Giáo án và activation (db/004, docs/03 §2.2): `lineage_id` NOT NULL, mặc định theo phiên bản cha hoặc chính `id`; khác lineage của cha ⇒ `ck_training_plans_lineage_parent`. CHECK `ck_training_plans_{status,kind,event_date,event_name,primary_discipline,end_reason,ended,end_note}`: `ended_at` và `end_reason` cùng có hoặc cùng không; `kind='event'` cần `event_date`. `plan_activations`: `to_date >= from_date` (`ck_plan_activations_dates`), `end_reason` ∈ paused/completed/stopped/deleted và cần `to_date`; lineage phải thuộc cùng user (`fk_plan_activations_lineage`, kiểm tra trong trigger vì lineage không phải khoá duy nhất).
- **I1** `ex_plan_activations_no_overlap`: `EXCLUDE USING gist (user_id, plan_lineage_id, daterange(from_date, to_date, '[]'))` trên các dòng chưa xoá (SQLSTATE 23P01). **I2**: trigger lấy advisory lock theo user rồi đếm theo từng ngày trong khoảng mới, chỉ tính lineage có phiên bản hiện hành chưa xoá, chưa kết thúc; vượt `active_plan_limit` ⇒ SQLSTATE `CA001`. Rút ngắn hoặc đóng activation không bị chặn. Giới hạn số giáo án: trigger với advisory lock, SQLSTATE `CA002`. Cả hai dựa vào mức cô lập READ COMMITTED (mặc định): giao dịch thứ hai chờ lock rồi thấy dòng đã commit của giao dịch thứ nhất. API ánh xạ `CA001` → `active_plan_limit`, `CA002` → `plan_count_limit`, 23P01 → `validation_failed` (field `fromDate`).
- Mục tiêu và giai đoạn (db/005, docs/03 §2.3, CON-005): `ck_plan_goals_target` = chỉ `target_value`, hoặc `target_min` + `target_max` với min ≤ max; `ck_plan_goals_achieved_at`: `status='achieved'` cần `achieved_at`, chỉ `achieved` và `archived` được có `achieved_at`. Server không bao giờ tự ghi `status`. `plan_lineage_id`, `indicator_id`, `exercise_id` không đổi (`ck_plan_goals_{lineage,indicator,exercise}_immutable`); lineage phải tồn tại cho cùng user (`fk_plan_goals_lineage`, kiểm tra trong trigger). `scope_phase_id` và `unlock_after_goal_id` phải cùng lineage (`ck_plan_goals_scope_same_lineage`, `ck_plan_goals_unlock_same_lineage`); giai đoạn đã xoá mềm vẫn được chấp nhận. Trigger lấy advisory lock theo user: vòng `unlock_after` (tính cả mục tiêu đã xoá mềm) ⇒ SQLSTATE `CA004`; ghim thêm khi lineage đã có `pinned_goal_limit` mục tiêu ghim chưa xoá ⇒ `CA003` (chỉ kiểm tra khi thêm ghim, kể cả khôi phục). API ánh xạ `CA003` → `pinned_goal_limit`, `CA004` → `goal_unlock_cycle`, lỗi FK/CHECK còn lại → `validation_failed` hoặc `dependency_missing`.
- `indicator_definitions` (db/005): không xoá được (`ck_indicator_definitions_never_deleted`), đổi `id/kind/unit/aggregation` bị chặn (`ck_indicator_definitions_immutable`), đổi `label/step/measurement_types/enabled` tự tăng `version`. `adherence` và `body` có `measurement_types` rỗng, các loại khác phải có ít nhất một loại đo. Bộ mặc định 6 chỉ số (giữ lâu nhất, set tốt nhất, hai mốc lần đầu, hai tổng tuần).
- `plan_audit_events` (db/005, đề xuất ADR-059): trigger ghi mỗi lần thêm và mỗi thay đổi thật của `plan_goals`/`plan_phases` (`insert|update|delete|restore`, dòng cũ và mới dạng jsonb). `mutation_id` lấy từ `SET LOCAL cali.mutation_id` của handler sync, ngoài sync là NULL. Bảng chỉ thêm (`ck_plan_audit_events_append_only`); dòng chỉ mất khi xoá tài khoản (cascade).
- Không có backfill `training_plan.goal`: chưa migration nào tạo cột này (db/005 §7).
- Số đo cơ thể (db/007, CON-007, ADR-063): `kind` chỉ nhận `weight` (`ck_body_measurements_kind`); `value` là kg, 20..500 và tối đa 2 chữ số thập phân theo giá trị (`value = round(value, 2)`, nên 72.350 hợp lệ, 72.355 bị từ chối, không làm tròn) (`ck_body_measurements_value`). Một ngày được nhiều lần đo; không có `source` hay `note`. `measuredAt` không được sau `clientChangedAt` (kiểm tra ở API và CaliDomain, vector `body_measured_at_in_the_future`; SQL không kiểm tra vì phụ thuộc thời điểm thay đổi phía client). Xoá mềm như các entity khác. Chưa có chỉ số `body` nào được seed (ADR-065).

## 4. Plan revision policy
For MVP, `training_plans.revision` increments on change; `planned_workouts`/`planned_exercises` represent current editable plan with change log versions; on applying AI recommendation clone plan and descendants to **new plan ID** with `parent_plan_id` and `revision=parent+1`, preserving old plan. Never mutate history of executed session; execution snapshots targets.

**Lineage (CON-003, ADR-036).** Các phiên bản cùng `lineage_id`; đúng một bản `current`, bản cũ `superseded` (thay cho `active|archived` của v1, ADR-056). Lưu trữ là `archived_at` trên phiên bản hiện hành, độc lập với `ended_at`. Activation tham chiếu lineage nên không phải chép khi tạo phiên bản mới.

## 5. Cross-field validation
- STATIC_HOLD target JSON: `{ "kind":"static_hold", "holdSeconds":12 }`.
- REPS target: `{ "kind":"reps", "repMin":8, "repMax":10 }`.
- DISTANCE target (CON-004): `{ "kind":"distance", "distanceMeters":5000, "durationSeconds":1800 }`; `durationSeconds` (thời gian mục tiêu) tuỳ chọn.
- DURATION target (CON-004): `{ "kind":"duration", "durationSeconds":300 }`.
- LOAD target (CON-006): `{ "kind":"load", "reps":5, "loadKg":60 }`; `reps` 1..500, `loadKg` 0..1000 kg, tối đa 2 chữ số thập phân (kiểm tra ở API và CaliDomain, vector `load_with_three_decimals`). Kết quả: `actualReps` + `actualLoadKg` (ADR-062).
- `rest_seconds`: integer 0..3600 (product policy initially).
- `set_count`: integer 1..20 (product policy initially).
- Date values in `local_date`. `timezone` must be an IANA id known to the backend tz database, checked in the API rather than SQL (ADR-024).
- Event times: input accepts any RFC 3339 offset. The server stores `timestamptz` and always emits UTC with `Z` (ADR-024).
- `plan_activation.fromDate` của activation mới không được trước ngày địa phương của `clientChangedAt` theo `timezone` (ADR-041); kiểm tra ở API và CaliDomain, vector `activation_from_date_in_the_past`. SQL không kiểm tra vì dữ liệu chuyển đổi (BR-10) có ngày quá khứ.
- Cross-field rules `repMin ≤ repMax` and `target.kind == exercise_catalog.exercise_type` are enforced by API validation and CaliDomain, with vectors in `fixtures/validation/business_rules.json`. There is no SQL trigger (ADR-020).

## 6. Notes for local and physical schema
`db/001_initial.sql` is server DDL baseline. It was edited in place for CON-001 because no deployed database exists. After the first deployed environment, schema changes go in new numbered migrations (see docs/15). Từ CON-003/004, mỗi thay đổi schema là một file mới `db/00N_<mô tả>.sql` (ADR-049); `db/003_running_measurement.sql` là file đầu tiên theo quy ước này. `RunningMeasurementMigrationTests` chạy đường nâng cấp 001→002→003 trên dữ liệu cũ. `db/004_plan_lineage_activation.sql` (CON-003) chuyển dữ liệu v1 theo BR-10: lineage = gốc của chuỗi `parent_plan_id`; bản chưa xoá mới nhất mỗi lineage thành `current`; `archived` của v1 → `archived_at`; `primary_discipline` suy từ loại bài (một môn → môn đó, nhiều môn → `mixed`, không có bài → `calisthenics`); lineage có bản v1 `active` chưa xoá nhận một activation mở với `from_date` = ngày `local_date` của buổi tập đầu tiên, nếu không có thì ngày `created_at` theo múi giờ của user; mỗi user giữ tối đa 3 lineage cập nhật gần nhất. Migration **không** ghi `sync_change_log` cho các dòng chuyển đổi: client chuyển snapshot cục bộ theo cùng quy tắc (IOS-011). `PlanLineageActivationMigrationTests` chạy đường nâng cấp 001→002→003→004. `db/006_exercise_discipline_load.sql` (CON-006, không phụ thuộc db/005) thêm `load` vào `exercise_type`, `discipline` (backfill bằng hàm `cali_default_discipline`: distance/duration → running, load → gym, còn lại → calisthenics) và `focus_tags`, trigger `trg_exercise_catalog_default_discipline` gán mặc định khi insert không ghi `discipline`, cùng cột `set_results.actual_load_kg`; `ExerciseDisciplineLoadMigrationTests` chạy đường 001→004 rồi 006 trên dữ liệu cũ và trên DB mới. `db/007_body_measurement.sql` (CON-007) tạo bảng `body_measurements` và thêm `body_measurement` vào CHECK entity type của `sync_mutations`/`sync_change_log`; không chuyển đổi dữ liệu. `BodyMeasurementMigrationTests` chạy đường nâng cấp từ 006 lên 007. Seed dev db/002 không có bài tạ; bài mẫu `barbell-back-squat` chỉ có trong `fixtures/exercise_catalog.json`. Seed dev `db/002_dev_catalog_seed.sql` chưa có bài chạy; bài mẫu `easy-run`/`timed-run` chỉ có trong `fixtures/exercise_catalog.json` (development fixture). Local GRDB migrations should mirror only fields used offline, plus outbox & processed commands. Server change feed retains canonical payload JSON (per entity DTO), so avoid undefined field names. Non-public media URLs should be short-lived and fetched through metadata endpoint.

## 7. Data privacy + deletion
- Export user's workout data JSON or CSV (later UI; architecture supports).
- Account deletion API/cascade policy must be decided prior public launch; can start with operator-managed deletion during pilot.
- Retain AI prompt/output only within privacy limits and document retention; avoid storing free-text notes in external AI vendor logs if not required.
- Số đo cơ thể (`body_measurements`, CON-007) là dữ liệu nhạy cảm: không bao giờ nằm trong đầu vào AI, không hiện trên Lock Screen, Live Activity hay thông báo, không ghi giá trị vào log (docs/11 §2, ADR-064). Xoá tài khoản xoá cả các dòng này (`ON DELETE CASCADE`).

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

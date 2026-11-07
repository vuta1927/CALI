# CON-001 — Contract review (C0 / PO-001)

**Ngày:** 2026-11-07 · **Branch:** `feature/c0-contract-review` · **Base:** `main` @ `fba7d06`  
**Phạm vi:** `contracts/openapi.yaml`, `contracts/entity-payloads.schema.json`, `db/001_initial.sql`, `db/002_dev_catalog_seed.sql`, `fixtures/*.json`, [`docs/03`](../03-workout-domain.md), [`docs/07`](../07-data-model.md), [`docs/08`](../08-sync-protocol.md), [`docs/09`](../09-ai-coach.md), [`docs/15`](../15-decisions-risks.md).  
**Quy tắc ưu tiên khi mâu thuẫn (README):** `docs/15` → `docs/03` → `contracts/openapi.yaml` → `db/001_initial.sql` → các docs khác.

Báo cáo này thực hiện checklist trong [`agents/06-contract-review-agent.md`](../../agents/06-contract-review-agent.md). Theo AGENTS.md mục 7 (*contracts first*), chỉ những chỗ **không mơ hồ** theo thứ tự ưu tiên mới được sửa, và sửa đồng bộ trên mọi artifact trong cùng commit. Những gì cần phán đoán sản phẩm/kiến trúc được liệt kê ở mục 5 kèm các phương án, **không** tự quyết.

## 1. Kết quả kiểm tra tự động

### 1.1 `tools/validate_handoff.py`
Môi trường: Python 3 venv ngoài repo (không commit), `pyyaml 6.0.3`, `jsonschema 4.26.0` + extra `format-nongpl` (để `FormatChecker` kiểm tra thật `date-time` theo RFC 3339).

| Lần chạy | Kết quả |
|---|---|
| Trước khi sửa (Windows) | Crash `UnicodeDecodeError: 'charmap' codec can't decode byte 0x90` vì `read_text()` không chỉ định encoding |
| Sau khi sửa | `PASS: JSON, local links, fixture IDs, OpenAPI references, sync payload schema and fixture wire schemas` (exit 0) |

Kiểm tra bổ sung (script tạm ngoài repo, không commit):
- `python -m openapi_spec_validator contracts/openapi.yaml` → `OK` (OpenAPI 3.1 hợp lệ).
- `FormatChecker` có `date-time` khi cài `jsonschema[format-nongpl]`; mutation có `clientChangedAt: "not-a-date"` bị từ chối.
- `setIndex: 101` bị JSON Schema từ chối; `repMax: 501` bị từ chối; `CreatePlanRequest.title = ""` bị OpenAPI từ chối; `SyncPushRequest` 101 mutations bị từ chối.
- `fixtures/exercise_catalog.json` so với `db/002_dev_catalog_seed.sql`: 6/6 bài trùng khớp `id`, `slug`, `name`, `type`, `equipment`, `cues`; `catalogVersion = 1`.

### 1.2 DDL trên PostgreSQL 16 thật (Docker)
Lệnh đã chạy (từ thư mục gốc repo):

```bash
docker run -d --name cali-c0-pg -e POSTGRES_PASSWORD=c0local -e POSTGRES_DB=cali -p 55432:5432 postgres:16
docker exec cali-c0-pg psql -U postgres -d cali -tAc "select version()"
# PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2) on x86_64-pc-linux-gnu, ...
docker exec -i cali-c0-pg psql -U postgres -d cali -v ON_ERROR_STOP=1 -q < db/001_initial.sql
# exit=0, không lỗi
docker exec -i cali-c0-pg psql -U postgres -d cali -v ON_ERROR_STOP=1 < db/002_dev_catalog_seed.sql
# INSERT 0 6   (exit=0)
docker exec -i cali-c0-pg psql -U postgres -d cali -v ON_ERROR_STOP=1 < db/002_dev_catalog_seed.sql
# INSERT 0 0   (exit=0, seed idempotent)
docker exec cali-c0-pg psql -U postgres -d cali -c '\dt' -c 'SELECT count(*) FROM exercise_catalog'
# 17 tables; exercise_catalog = 6, exercise_media = 0
docker rm -f cali-c0-pg
```

DDL ở trên là bản **sau** các sửa đổi C0 (mục 4). Baseline `fba7d06:db/001_initial.sql` cũng được áp dụng riêng trên một container mới cùng tên/cổng (`git show fba7d06:db/001_initial.sql` → file tạm ngoài repo → `psql -v ON_ERROR_STOP=1`): exit 0, sau đó `002` → `INSERT 0 6`; container đã xóa. Baseline không có lỗi DDL; sửa đổi C0 chỉ thêm CHECK/comment. 17 bảng: `ai_analyses`, `ai_jobs`, `ai_recommendations`, `devices`, `exercise_catalog`, `exercise_executions`, `exercise_media`, `planned_exercises`, `planned_workouts`, `set_results`, `sync_change_log`, `sync_mutations`, `training_plans`, `user_sync_state`, `users`, `workout_notes`, `workout_sessions`.

Smoke test ràng buộc (mỗi lệnh INSERT độc lập, `ON_ERROR_STOP 0`):

| Ca kiểm tra | Kết quả |
|---|---|
| Session `active` thứ hai cùng user | `ux_session_one_active_per_user` từ chối |
| `finished_at < started_at` | `workout_sessions_check` từ chối |
| `status='completed', phase='exercising'`, `timezone='Not/AZone'` | **Được chấp nhận** → xem D8, D9 |
| `set_index = 101` | `set_results_set_index_check` từ chối |
| `prescribed_snapshot = '[]'` | `set_results_prescribed_snapshot_check` từ chối (mới, F5) |
| `rpe = 11` | `set_results_rpe_check` từ chối |
| Set thứ hai cùng `(execution_id, set_index)` | `set_results_execution_id_set_index_key` từ chối |
| `note_text` 10001 ký tự | `workout_notes_note_text_check` từ chối (mới, F6) |
| `sync_mutations.entity_type = 'ai_analysis'` | `sync_mutations_entity_type_check` từ chối (mới, F7) |
| `sync_mutations.status = 'duplicate'` | `sync_mutations_status_check` từ chối (đúng thiết kế, xem D6) |
| `sync_change_log.entity_type = 'exercise_catalog'` | `sync_change_log_entity_type_check` từ chối (mới, F7) |
| `sync_change_log.entity_type = 'ai_recommendation'` | Chấp nhận |
| `training_plans.title = ''` | `training_plans_title_check` từ chối |

## 2. Bảng ánh xạ entity

Quy ước đặt tên: wire (OpenAPI/JSON Schema) dùng `camelCase`, SQL dùng `snake_case`, ánh xạ 1-1 theo cột (ví dụ `plannedWorkoutId` ↔ `planned_workout_id`, `phaseDeadlineAt` ↔ `phase_deadline_at`). Mọi bảng user-owned có `user_id`, `version`, `updated_at`, `deleted_at` phía server; các cột này không nằm trong payload (version đi qua envelope `baseVersion`/`serverVersion`, tombstone qua `delete_payload.deletedAt`).

| Entity (sync) | OpenAPI schema | JSON Schema `$defs` | SQL table | Ghi chú cột |
|---|---|---|---|---|
| `training_plan` | `TrainingPlan` (= `CreatePlanRequest` + `revision`, `version`, `status`, `parentPlanId`) | `training_plan_payload` | `training_plans` | `title` 1..120, `revision`≥1, `status` `active\|archived`, `parent_plan_id` |
| `planned_workout` | `PlannedWorkout` (nested trong plan) | `planned_workout_payload` | `planned_workouts` | `planId`↔`plan_id`, `weekday` 1..7, `orderIndex`↔`order_index`, `title` (D12) |
| `planned_exercise` | `PlannedExercise` + `PlannedTarget` | `planned_exercise_payload` + `target` | `planned_exercises` | `setCount` 1..20, `restSeconds` 0..3600, `target` jsonb object |
| `workout_session` | — (chỉ qua sync) | `workout_session_payload` | `workout_sessions` | `localDate`+`timezone`; `startedAt`, `finishedAt`, `phaseStartedAt`, `phaseDeadlineAt` UTC; `currentExecutionId`, `currentSetIndex` |
| `exercise_execution` | — (chỉ qua sync) | `exercise_execution_payload` | `exercise_executions` | `sessionId`, `plannedExerciseId?`, `exerciseId`, `orderIndex`, `prescribedSnapshot` |
| `set_result` | — (chỉ qua sync) | `set_result_payload` | `set_results` | `setIndex` 1..100, `status`, `actualReps/HoldMs/WorkMs/RestMs`, `rpe` 1..10, `note`, `confirmedAt`, `revision` |
| `workout_note` | — (chỉ qua sync) | `workout_note_payload` | `workout_notes` | `noteText`↔`note_text` ≤10000, `createdAt` |
| tombstone (mọi entity trên) | `SyncMutation.action=delete` | `delete_payload` (`id`, `deletedAt`) | `<table>.deleted_at` | soft delete, feed phát `operation=delete` |
| mutation envelope | `SyncMutation`, `SyncPushRequest` | `mutation_common` + `*_mutation` | `sync_mutations` | `mutationId` PK cùng `user_id`; `baseVersion`≥0; `deviceId`↔`device_id` |
| receipt | `SyncMutationResult`, `MutationError` | — | `sync_mutations.status`, `.receipt` | `duplicate` không lưu (D6) |
| change feed | `SyncChange`, `SyncPullResponse` | — (D7) | `sync_change_log`, `user_sync_state` | `changeId` opaque ← `seq`; `serverVersion`≥1 |
| `ai_analysis` (server-owned) | `Analysis`, `AnalysisOutput`, `AnalysisReceipt` | — | `ai_analyses`, `ai_jobs` | `sessionVersion`↔`session_version`; `result` jsonb |
| `ai_recommendation` (server-owned) | `AnalysisRecommendation`, `RecommendationDecision*` | — | `ai_recommendations` | `proposedTarget`↔`proposed_target`; `exerciseId` (D11) |
| exercise catalog | `Exercise`, `ExerciseMedia`, `ExercisePage` | — | `exercise_catalog`, `exercise_media` | `type`↔`exercise_type`, `catalogVersion`↔`catalog_version`, media `storage_key` không lộ ra wire |
| user / device | `UserProfile`, `SyncPushRequest.deviceId` | — | `users`, `devices` | `devices.device_name`, `last_seen_at` |

### 2.1 Các điểm đã xác nhận nhất quán
- `ExerciseType` = `static_hold, reps, timed_reps, interval, skill_attempt` (OpenAPI, JSON Schema `target.kind`, SQL CHECK, fixtures).
- Session `status` `active|completed|abandoned` và `phase` (9 giá trị) trùng giữa JSON Schema, SQL và docs/03 (dưới dạng snake_case).
- `set_result.status` `completed|failed|skipped`; `action` `upsert|delete`; `SyncMutationResult.status` `applied|duplicate|conflict|rejected`.
- Giới hạn: `set_count` 1..20, `rest_seconds` 0..3600, `rpe` 1..10, push `maxItems: 100`, pull `limit` ≤100 (mặc định 100), `baseVersion`≥0, `serverVersion`≥1.
- `SyncEntityType` (7 giá trị) = các nhánh `oneOf` của JSON Schema = CHECK mới của `sync_mutations.entity_type`; `ChangeEntityType` (9 giá trị) = docs/07 §2 = CHECK mới của `sync_change_log.entity_type`.
- Thời gian: event time là `format: date-time` / `timestamptz` (UTC); ngày tập là `localDate` (`format: date`) + `timezone` riêng, đúng checklist.
- Idempotency: `PRIMARY KEY (user_id, mutation_id)`, cursor qua `user_sync_state` row lock, `UNIQUE (execution_id, set_index)`, `revision` cho sửa set.
- Quyết định recommendation `accepted` bắt buộc `expectedPlanVersion` + `targetPlanId` (OpenAPI `if/then`).
- Fixtures `workout_plan.json` khớp OpenAPI `TrainingPlan`; `sync_push.json` khớp `SyncPushRequest` và JSON Schema payload.

## 3. Tổng hợp mâu thuẫn

| ID | Mức độ | Mô tả ngắn | Trạng thái |
|---|---|---|---|
| F1 | Medium | Validator crash trên Windows, quét nhầm worktree/venv lồng nhau, không kiểm tra `date-time`, không kiểm tra fixture với OpenAPI | **Fixed** |
| F2 | Medium | JSON Schema `target` thiếu `maximum` mà OpenAPI `PlannedTarget` có | **Fixed** |
| F3 | Medium | JSON Schema `setIndex` không có max; SQL `set_index BETWEEN 1 AND 100` | **Fixed** |
| F4 | Medium | OpenAPI `CreatePlanRequest.title` thiếu `minLength: 1` (SQL và JSON Schema đều yêu cầu ≥1) | **Fixed** |
| F5 | Low | SQL `set_results.prescribed_snapshot` thiếu CHECK object (bảng `exercise_executions` có) | **Fixed** |
| F6 | Low | SQL `workout_notes.note_text` không giới hạn; JSON Schema `maxLength: 10000` | **Fixed** |
| F7 | Medium | SQL `entity_type` của `sync_mutations`/`sync_change_log` là text tự do | **Fixed** |
| F8 | Medium | Ví dụ payload docs/08 §3 thiếu field bắt buộc `prescribedSnapshot`, `confirmedAt` | **Fixed** |
| F9 | Medium | Tên cột trong docs/07 §1/§3 lệch so với SQL | **Fixed** |
| D1 | High | docs/03 §2 dùng tên khái niệm khác tên wire | Needs ADR/decision |
| D2 | High | Field có trong docs/03 nhưng không có trong contract nào | Needs ADR/decision |
| D3 | High | `prescribedSnapshot` là object tự do, không ràng buộc snapshot target + catalog version | Needs ADR/decision |
| D4 | Medium | docs/03: INTERVAL `restSeconds > 0`; contract cho phép 0 | Needs ADR/decision |
| D5 | Medium | `repMin ≤ repMax`, `target.kind == exercise type` không biểu diễn được trong schema | Needs ADR/decision |
| D6 | High | Receipt `conflict` lưu theo `mutationId` chặn retry dependency conflict; `MutationError.code` không có enum | Needs ADR/decision |
| D7 | Medium | Shape `SyncChange.payload` khi pull không được đặc tả | Needs ADR/decision |
| D8 | Medium | Không ràng buộc nhất quán `status` ↔ `phase` | Needs ADR/decision |
| D9 | Low | `date-time` cho phép mọi offset (không chỉ `Z`); IANA `timezone` không được validate | Needs ADR/decision |
| D10 | Medium | `UNIQUE (execution_id, set_index)` không tính soft delete | Needs ADR/decision |
| D11 | Medium | `AnalysisRecommendation.exerciseId` bắt buộc ở OpenAPI, nullable ở SQL | Needs ADR/decision |
| D12 | Low | `planned_workout.title` bắt buộc ở JSON Schema, optional ở OpenAPI, `DEFAULT ''` ở SQL | Needs ADR/decision |
| D13 | Medium | Shape `fixtures/exercise_catalog.json` khác OpenAPI `Exercise`/`ExerciseMedia` | Needs ADR/decision |
| D14 | Low | Sơ đồ mermaid docs/03 thiếu transition abandon/skip mà bảng command cho phép | Needs ADR/decision |
| D15 | Medium | Envelope mutation không từ chối field lạ dù schema mô tả "reject unknown fields" | Needs ADR/decision |
| D16 | Medium | Không phát hiện tái sử dụng `mutationId` với payload khác | Needs ADR/decision |
| D17 | Medium | docs/09 §6 ví dụ output AI lệch OpenAPI (`exerciseId` slug, `proposedTarget` thiếu `kind`, action ngoài enum) | Needs ADR/decision |
| D18 | Low | Các điểm nhỏ: `set_result.note` không giới hạn độ dài; `sync_mutations.device_id` không FK; `ExerciseMedia.license` optional ở wire nhưng NOT NULL ở SQL | Needs ADR/decision |

## 4. Chi tiết — Fixed

**F1 — `tools/validate_handoff.py`.**
- Mọi `read_text()` dùng `encoding='utf-8'` (trước đây crash trên Windows với cp1252).
- Thêm `repo_files()` bỏ qua thư mục bắt đầu bằng `.` (ví dụ `.git`, `.claude/worktrees/*`) và `node_modules`, `venv`, `bin`, `obj`, `DerivedData`; tránh validate nhầm bản sao repo của agent khác hoặc venv.
- Validate `fixtures/workout_plan.json` với OpenAPI `TrainingPlan` và `fixtures/sync_push.json` với `SyncPushRequest` (OpenAPI 3.1 schema = JSON Schema 2020-12, resolve `$ref` nội bộ qua `referencing`).
- Docstring ghi rõ CI cần `jsonschema[format-nongpl]`; nếu thiếu extra này `FormatChecker` **bỏ qua im lặng** `date-time`.
- Thêm `.github/workflows/handoff.yml` (push/PR trên `contracts/**`, `db/**`, `docs/**`, `fixtures/**`, `tools/**`).

**F2 — Giới hạn `target`.** `contracts/entity-payloads.schema.json` `$defs.target`: thêm `repMin/repMax ≤ 500`, `timeSeconds ≤ 3600`, `workSeconds ≤ 3600`, interval `restSeconds ≤ 3600`, `attempts ≤ 100`, trùng OpenAPI `PlannedTarget` (OpenAPI xếp trên JSON Schema theo thứ tự ưu tiên; JSON Schema lỏng hơn sẽ cho sync push lưu target mà REST API từ chối).

**F3 — `setIndex`.** `set_result_payload.setIndex` thêm `maximum: 100` theo SQL `CHECK (set_index BETWEEN 1 AND 100)`; nếu không, giá trị hợp lệ theo schema sẽ thành lỗi 500 ở DB.

**F4 — `CreatePlanRequest.title`.** `contracts/openapi.yaml` thêm `minLength: 1` (SQL `length(title) BETWEEN 1 AND 120`, JSON Schema `minLength: 1`). Áp dụng luôn cho `TrainingPlan` qua `allOf`.

**F5 — `set_results.prescribed_snapshot`.** `db/001_initial.sql` thêm `CHECK (jsonb_typeof(prescribed_snapshot) = 'object')`, giống `exercise_executions` và JSON Schema `type: object`.

**F6 — `workout_notes.note_text`.** `db/001_initial.sql` thêm `CHECK (length(note_text) <= 10000)` theo JSON Schema `maxLength: 10000`.

**F7 — `entity_type`.** `db/001_initial.sql`:
- `sync_mutations.entity_type IN (...)` đúng 7 giá trị `SyncEntityType` (client chỉ được push entity cho phép; docs/08 §5 cấm client sửa AI records).
- `sync_change_log.entity_type IN (...)` đúng 9 giá trị `ChangeEntityType`.
- Comment giải thích vì sao `sync_mutations.status` không có `duplicate` (đó là trạng thái trả về khi replay receipt đã lưu).

**F8 — docs/08 §3.** Ví dụ mutation `set_result` thêm `prescribedSnapshot` và `confirmedAt` (đều `required` trong `set_result_payload`). Ví dụ cũ sẽ bị server từ chối nếu agent copy nguyên văn.

**F9 — docs/07.** Bảng §1 và invariant §3 đổi theo tên cột thật trong `db/001_initial.sql`:

| docs/07 cũ | SQL / docs/07 mới |
|---|---|
| `devices.name`, `last_seen` | `device_name`, `last_seen_at` |
| `exercise_catalog.type`, `version` | `exercise_type`, `catalog_version` |
| `exercise_media.file_key`, `SHA256` | `storage_key`, `sha256` (+ `content_version`) |
| `planned_workouts.sequence` | `order_index` |
| `planned_exercises.workout_id`, `rest` | `planned_workout_id`, `rest_seconds` (+ `order_index`, `set_count`) |
| `workout_sessions` "single active per client profile" | một session active mỗi user (`ux_session_one_active_per_user`) |
| `workout_notes.text` | `note_text` |
| `sync_mutations.receipt_json`, `result` | `receipt`, `status` |
| `ai_analyses.session_revision`, `model` | `session_version`, `model_provider`, `model_name` |
| `ai_recommendations.delta` | `proposed_target` |
| `ai_jobs.kind`, `entity_id`, `lease` | `analysis_id`, `available_at`, `leased_until` |
| `finished_at_utc`, `started_at_utc` | `finished_at`, `started_at` (`timestamptz`, UTC) |
| `soft_deleted_at` | `deleted_at` |

Lý do sửa: docs/07 đứng sau `db/001_initial.sql` trong thứ tự ưu tiên, và docs/07 §6 yêu cầu "avoid undefined field names". "Per client profile" mâu thuẫn trực tiếp với partial unique index và comment MVP trong SQL.

## 5. Chi tiết — Needs ADR/decision

**D1 — Tên khái niệm docs/03 §2 khác tên wire.** docs/03 dùng `localDay`, `startedAtUtc`, `finishedAtUtc`, `phaseDeadlineUtc`, `exerciseCatalogId`, `sequence`/`ordering`/`order`, `confirmedAtUtc`, `WorkoutNote.text` và viết tắt `REST`/`COMPLETE`. Contract dùng `localDate`, `startedAt`, `finishedAt`, `phaseDeadlineAt`, `exerciseId`, `orderIndex`, `confirmedAt`, `noteText`, `resting`/`completed`. Theo thứ tự ưu tiên docs/03 thắng OpenAPI, nhưng đổi tên wire là breaking change cho mọi artifact.
- (a) ADR tuyên bố docs/03 §2 là mô hình khái niệm, tên chuẩn là tên wire; thêm bảng ánh xạ vào docs/03. *(khuyến nghị — không breaking)*
- (b) Đổi tên wire/SQL theo docs/03.

**D2 — Field chỉ có ở docs/03.** `TrainingPlan.startDate`, `weeks`; `WorkoutSession.planRevisionId`, `revision`; `PlannedExercise.cuesSnapshot`; `ExerciseExecution.setCount`; `WorkoutNote.revision`; cờ "subjective pain flag" của journal (docs/09 cũng cần `painReported`); `pausedAt`/`accumulatedElapsed` cho Pause; `reason` của AbandonSession/SkipSet. Lựa chọn: (a) thêm vào OpenAPI + JSON Schema + SQL + fixtures (cần quyết định từng field là MVP hay không); (b) đánh dấu docs/03 là post-MVP; (c) kết hợp. Tối thiểu cần quyết định pain flag và pause, vì safety rule (docs/09 §5) và timer (docs/03) phụ thuộc vào chúng.

**D3 — Shape `prescribedSnapshot`.** Invariant docs/03 yêu cầu snapshot target + catalog version, nhưng `exercise_execution_payload.prescribedSnapshot` và `set_result_payload.prescribedSnapshot` là `{"type":"object"}`; snapshot trong fixture không có `catalogVersion`. Lựa chọn: (a) định nghĩa `$defs.prescribed_snapshot` = `target` + `setCount` + `restSeconds` + `catalogVersion` (bắt buộc), cập nhật OpenAPI/fixtures/SQL CHECK; (b) chỉ yêu cầu `target` (`$ref target`) và lưu `catalogVersion` thành cột riêng; (c) giữ tự do, ghi rõ server không đảm bảo.

**D4 — INTERVAL `restSeconds`.** docs/03 viết "workSeconds/restSeconds > 0", contract cho phép `restSeconds: 0`. docs/03 có ưu tiên cao hơn nhưng interval nghỉ 0 (EMOM/liên tục) có thể là chủ ý sản phẩm. Lựa chọn: (a) `minimum: 1` trên mọi artifact; (b) sửa docs/03 thành `restSeconds ≥ 0`.

**D5 — Ràng buộc chéo field.** `repMin ≤ repMax` và `target.kind` phải trùng `exercise_catalog.exercise_type` không biểu diễn được bằng JSON Schema thuần (cần dữ liệu/so sánh). Lựa chọn: (a) validator nghiệp vụ trong backend + Swift domain với test chung từ fixtures; (b) thêm SQL CHECK cho `repMin ≤ repMax` trên `target` jsonb và trigger cho kind. Cần chỉ định owner (backend-agent/ios-agent) và bộ fixture âm.

**D6 — Receipt và mã lỗi sync.**
- docs/08 cho phép retry dependency conflict với **cùng** `mutationId` sau khi parent được ack, nhưng nếu server lưu receipt `conflict` dưới `PRIMARY KEY (user_id, mutation_id)` thì lần retry sẽ nhận lại receipt cũ (replay). Lựa chọn: (a) không lưu receipt cho conflict có thể retry (chỉ lưu `applied`/`rejected`/version conflict); (b) cho phép ghi đè receipt `conflict` có `retryable=true`; (c) client sinh mutationId mới cho retry dependency (trái docs/08 hiện tại).
- `MutationError.code` không có enum. Đề xuất enum tối thiểu `dependency_missing`, `version_conflict`, `validation_failed`, `forbidden_entity`, `cross_user_reference`, kèm `retryable: boolean`, cập nhật OpenAPI + docs/08.
- `sync_mutations.status` thiếu `duplicate` là **nhất quán** (đã ghi comment trong SQL), không cần sửa.

**D7 — Payload của pull.** `SyncChange.payload` là `additionalProperties: true` cho cả 9 entity type, kể cả `ai_analysis`/`ai_recommendation`. Lựa chọn: (a) pull payload = cùng `*_payload` của JSON Schema (+ `ai_*` dùng `Analysis`/`AnalysisRecommendation`), thêm discriminator theo `entityType`; (b) định nghĩa DTO pull riêng (có `version`, `updatedAt`). Thiếu đặc tả này iOS và backend sẽ tự đặt tên field.

**D8 — `status` ↔ `phase`.** DB chấp nhận `status='completed', phase='exercising'` (smoke test). Bất biến hợp lý: `completed ⇔ phase=completed`, `abandoned ⇔ phase=abandoned`, `active ⇒ phase ∉ {completed, abandoned}`. Lựa chọn: (a) SQL CHECK + JSON Schema `if/then` + test; (b) chỉ enforce trong domain service. Cần xác nhận với docs/03 trước khi khóa (ví dụ `reviewing_summary` khi `active`, đã có trong docs/07 §3).

**D9 — Định dạng thời gian và timezone.** `format: date-time` chấp nhận `+07:00`, không bắt buộc `Z`; `timezone` chỉ là `string` và SQL chấp nhận `Not/AZone`. Lựa chọn: (a) bắt buộc hậu tố `Z` bằng `pattern` + normalize ở server; (b) chấp nhận mọi offset, server chuyển UTC (ghi rõ trong docs/08); IANA: validate ở backend bằng tz database (không làm được bằng CHECK đơn giản).

**D10 — Unique set khi soft delete.** `UNIQUE (execution_id, set_index)` vẫn giữ hàng `deleted_at IS NOT NULL`, nên xóa rồi ghi lại set cùng index bằng ID mới sẽ lỗi. docs/07 §3 yêu cầu "update same ID". Lựa chọn: (a) giữ nguyên, quy định client phải "undelete" cùng ID; (b) đổi sang partial unique index `WHERE deleted_at IS NULL`.

**D11 — `AnalysisRecommendation.exerciseId`.** OpenAPI bắt buộc (uuid), SQL `ai_recommendations.exercise_id` nullable. Action `needs_more_data` có thể không gắn với bài nào. Lựa chọn: (a) OpenAPI `type: [string, 'null']`; (b) SQL `NOT NULL` và luôn gắn bài.

**D12 — `planned_workout.title`.** JSON Schema `required`, OpenAPI `PlannedWorkout` optional, SQL `NOT NULL DEFAULT ''`. Lựa chọn: (a) optional ở JSON Schema (server dùng `''`); (b) required + `minLength: 1` ở mọi nơi.

**D13 — Fixture catalog vs `Exercise`.** `fixtures/exercise_catalog.json` có `media` là object các đường dẫn file và `catalogVersion` chỉ ở top-level; OpenAPI `Exercise` yêu cầu `catalogVersion` mỗi item và `media` là mảng `ExerciseMedia` (`id`, `kind`, `contentVersion`, `mimeType`, `sha256`). Lựa chọn: (a) coi fixture là manifest bundle offline (định dạng riêng của iOS, ghi rõ trong docs/10) và thêm schema cho nó; (b) đổi fixture theo `ExercisePage`. Validator hiện **không** kiểm tra file này với OpenAPI vì lý do đó.

**D14 — Sơ đồ state machine docs/03.** Mermaid thiếu `pre_countdown/exercising → abandoned` và các transition skip, trong khi bảng command cho phép AbandonSession từ mọi session active. Cần chủ sở hữu docs/03 cập nhật sơ đồ (không đổi hành vi); để lại vì docs/03 có ưu tiên cao và là tài liệu domain của ios-agent.

**D15 — Field lạ ở envelope.** `description` của JSON Schema ghi "reject unknown fields", payload có `additionalProperties: false` nhưng `mutation_common`/`SyncMutation` thì không (`SyncMutation.payload` còn là `additionalProperties: true`). Lựa chọn: (a) `unevaluatedProperties: false` trên các `*_mutation` và `SyncMutation` (breaking cho client gửi thêm field); (b) cho phép field lạ ở envelope, chỉ chặn ở payload.

**D16 — Tái sử dụng `mutationId`.** docs/08 cấm client đổi payload sau khi gửi, nhưng `sync_mutations` không lưu hash payload nên server không phát hiện được cùng `mutationId` với payload khác (sẽ trả `duplicate` sai). Lựa chọn: (a) thêm cột `payload_sha256` và trả `rejected` (`code=mutation_id_reused`); (b) chấp nhận rủi ro, chỉ log.

**D17 — Ví dụ output AI docs/09 §6.** `exerciseId: "tuck-planche"` (slug) so với OpenAPI `format: uuid`; `proposedTarget: {"holdSeconds":12}` thiếu `kind` so với `PlannedTarget`; thiếu `decision` (OpenAPI bắt buộc); docs/09 §5 nhắc `maintain_or_reduce_and_seek_professional_if_persistent` không có trong enum `action`. Có thể output thô của LLM khác DTO lưu trữ (server gán `decision`, map slug → id), nên cần quyết định: (a) LLM output = `AnalysisOutput` nguyên văn → sửa docs/09; (b) định nghĩa schema LLM output riêng + bước map, ghi trong docs/09. Đồng thời quyết định pain rule dùng action `reduce` + `safetyFlags` hay thêm action mới.

**D18 — Điểm nhỏ.** `set_result.note` không có `maxLength` ở JSON Schema lẫn SQL (đề xuất 1000 hoặc 10000 như note); `sync_mutations.device_id` không FK tới `devices` (thiết bị chưa đăng ký có thể push); `ExerciseMedia.license` optional ở wire nhưng `NOT NULL` ở SQL (vô hại, có thể đưa vào `required`).

## 6. Test đề xuất để chống drift
- CI `handoff.yml`: validator với `jsonschema[format-nongpl]` (đã thêm).
- Backend (B0+): áp dụng `db/001` + `db/002` vào PostgreSQL 16 trong integration test; smoke test ràng buộc ở mục 1.2 thành test tự động.
- Contract test chung: mọi fixture trong `fixtures/` validate với cả JSON Schema payload lẫn OpenAPI; thêm fixture âm cho F2–F7 và cho D5/D8 sau khi có quyết định.
- iOS (I1a): mã hóa/giải mã `set_result_payload` từ `fixtures/sync_push.json` và so khớp key.

## 7. Chưa xác minh được
- Chưa có code backend/Swift để kiểm tra conformance thực tế; workflow CI chưa chạy trên GitHub (chỉ chạy validator cục bộ).
- `fixtures/exercise_catalog.json` không được validate với OpenAPI (xem D13).
- Smoke test ràng buộc chỉ chạy thủ công một lần, chưa thành test tự động.

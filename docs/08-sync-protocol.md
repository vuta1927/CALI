# Offline Sync Protocol v1 — Outbox + Cursor Feed

## 1. Guarantees and non-guarantees
- App accepts writes offline and preserves them transactionally.
- Retry is **at least once** on network; backend provides **effectively-once per `mutationId`** with stored receipt.
- Pull is cursor-based monotonic feed; per-user ordering by server-assigned sequence; pagination stable.
- Sync occurs on app foreground, local write and available background opportunities; **no guarantee instant sync on reconnection while app is suspended**.
- No guaranteed hard-real-time multi-device presence or simultaneous editing.

## 2. Local write transaction
1. Validate command and session state.
2. Insert/update local business record.
3. Insert local `sync_outbox(mutation_id UUID,entity_id,base_version,action,payload)` in same transaction.
4. Commit, reflect UI success, launch best-effort sync.
If DB transaction fails, do not display successful completion.

## 3. Push
`POST /v1/sync/push` max 100 mutations; respect created ordering per same entity; batches can include independent entities. Each mutation:
```json
{
  "mutationId":"UUID",
  "entityType":"set_result",
  "entityId":"UUID",
  "action":"upsert",
  "baseVersion":0,
  "clientChangedAt":"2026-11-07T10:00:00Z",
  "payload":{"id":"UUID", "executionId":"UUID", "setIndex":1, "status":"completed", "prescribedSnapshot":{"target":{"kind":"static_hold","holdSeconds":12},"setCount":4,"restSeconds":90,"catalogVersion":1}, "actualHoldMs":12000, "confirmedAt":"2026-11-07T10:00:00Z"}
}
```
Dependency ordering: send parent records first (`training_plan → planned_workout → planned_exercise`; `training_plan → plan_activation`; `training_plan → plan_phase → plan_goal` (CON-005; mục tiêu được mở khoá sau một mục tiêu khác thì gửi sau mục tiêu đó); `workout_session → exercise_execution → set_result`). Server processes each batch in supplied order. If parent is missing, return an explicit retryable dependency conflict rather than silently creating an orphan. For multiple local changes on the **same entity**, serialize the outbox: do not send mutation #2 until #1 is acknowledged; before first send of #2, rebase `baseVersion` to the newly acknowledged server version and keep #2’s mutation ID stable throughout retries. Client must never alter a mutation payload once an HTTP attempt has started.

Server responds per mutation: `applied|duplicate|conflict|rejected`, `serverVersion`, `serverEntity?`, `error?`. `duplicate` receipt is accepted and mark outbox ACK; `conflict` persists unresolved and does not silently overwrite; dependency conflicts may be retried after missing parents are acknowledged, whereas version conflicts require user resolution. Network failure: retry same mutation UUID, never generate new UUID for same committed action.

The envelope and every payload are closed objects, so an unknown field anywhere → HTTP 400 for the batch (ADR-030).

**Chạy bộ (CON-004).** `set_result` nhận thêm `distanceMeters` (mét, 0..1000000), `durationSeconds` (giây, 0..86400) và `source` (chỉ `manual`; `healthkit` bị từ chối tới slice Apple Health, ADR-043). Cả ba đều không bắt buộc nên client v1 không phải đổi. `planned_exercise.target` có thêm kind `distance` và `duration`. Pace không có trên wire: client tự tính từ `durationSeconds / distanceMeters`; payload gửi trường pace bị từ chối như mọi trường lạ. Ví dụ đầy đủ (chỉ là mẫu): `fixtures/samples/running_sync_push.sample.json`.

**Receipts and error codes (ADR-021).** `error` = `{code, message, retryable, details?}`.

| `code` | `status` | `retryable` | Receipt persisted? | Client action |
|---|---|---|---|---|
| `dependency_missing` | conflict | true | **no** | keep the outbox row; resend the same `mutationId` after the parent is acked |
| `version_conflict` | conflict | false | yes | surface the conflict (§5); `serverEntity` is returned |
| `validation_failed` | rejected | false | yes | mark rejected; a client bug or business-rule violation (ADR-020); `details.field` names the field |
| `forbidden_entity` | rejected | false | **no** (ADR-069) | mark rejected (entity type not writable by devices); a later server that accepts the type applies the same `mutationId` |
| `cross_user_reference` | rejected | false | yes | mark rejected |
| `mutation_id_reused` | rejected | false | **no** (the original receipt is unchanged) | client bug: a payload changed after a send attempt |
| `active_plan_limit` | rejected | false | yes | CON-003, BR-2: activation làm số giáo án được theo trong một ngày vượt giới hạn server (mặc định 3). Đánh dấu rejected, hoàn tác activation cục bộ và báo người dùng chọn giáo án để tạm dừng; không tự gửi lại |
| `plan_count_limit` | rejected | false | yes | CON-003, BR-8: vượt giới hạn server (mặc định 50) giáo án chưa xoá. Đánh dấu rejected và gợi ý xoá bớt giáo án cũ |
| `pinned_goal_limit` | rejected | false | yes | CON-005, ADR-048: lineage đã có `pinned_goal_limit` (mặc định 3) mục tiêu ghim chưa xoá. Đánh dấu rejected, bỏ ghim cục bộ và báo người dùng bỏ ghim mục tiêu khác; `details.field` = `pinned` |
| `goal_unlock_cycle` | rejected | false | yes | CON-005: `unlockAfterGoalId` tạo vòng mở khoá. Đánh dấu rejected và khôi phục chuỗi mở khoá cũ; `details.field` = `unlockAfterGoalId` |

**Nhiều giáo án (CON-003).** `training_plan` có thêm `lineageId`, `kind`, `eventDate`, `eventName`, `primaryDiscipline`, `endedAt`, `endReason`, `endNote`, `archivedAt`, đều không bắt buộc trên wire (server suy `lineageId` từ `parentPlanId`). `status` nay là trạng thái phiên bản `current|superseded`; giá trị v1 `active|archived` bị JSON Schema từ chối (breaking, ADR-056). Entity mới `plan_activation` `{id, planLineageId, fromDate, toDate?, timezone, endReason?}`, đẩy sau `training_plan` gốc của lineage; lineage chưa có trên server ⇒ `dependency_missing`. Trạng thái người dùng thấy không có trên wire. Hai thiết bị offline cùng bắt đầu giáo án (BR-2): server áp dụng theo thứ tự nhận, mỗi mutation trong savepoint riêng (ADR-069); mutation đến sau mà vượt I2 nhận `active_plan_limit`, cùng một lineage chồng ngày (I1) nhận `validation_failed` với field `fromDate`. Ví dụ (chỉ là mẫu): `fixtures/samples/plan_activation_sync_push.sample.json`.

**Mục tiêu và giai đoạn (CON-005).** Hai entity mới: `plan_phase` `{id, planId, orderIndex, name, weeks, description?}` thuộc một phiên bản giáo án, và `plan_goal` `{id, planLineageId, title, indicatorId, exerciseId?, baseline?, target, scopePhaseId?, unlockAfterGoalId?, status, achievedAt?, pinned, note?}` thuộc lineage. `target` là `{value}` hoặc `{min, max}`. `current` không có trên wire và bị từ chối như mọi trường lạ; client tự tính. `status=achieved` bắt buộc có `achievedAt` (lúc người dùng xác nhận); `active|reached|missed` không được có `achievedAt`. Server không bao giờ tự đổi `status` hay tạo `achieved`. Đổi `indicatorId` hoặc `exerciseId` của mục tiêu đã có ⇒ `validation_failed` (đề xuất ADR-057); chỉ số chưa biết hoặc đang tắt, bài tập không khớp `measurementTypes` ⇒ `validation_failed`. `scopePhaseId`/`unlockAfterGoalId` thuộc lineage khác ⇒ `validation_failed`; chưa có trên server ⇒ `dependency_missing`. Danh mục `IndicatorDefinition` là dữ liệu chỉ đọc, không đi qua sync push; CON-008 sẽ trả nó trong `GET /v1/criteria-config` (đề xuất ADR-058). Ví dụ (chỉ là mẫu): `fixtures/samples/plan_goals_sync_push.sample.json`.

**Môn tập và bài tạ (CON-006).** `planned_exercise.target` và `prescribedSnapshot.target` có thêm dạng `{kind: load, reps, loadKg}`; `set_result` có thêm `actualLoadKg` (kg, 0..1000, không bắt buộc trên wire). Payload v1 vẫn hợp lệ. Server trả `validation_failed` khi: `actualLoadKg` nằm trên set không phải `load` (`load_fields_on_non_load_set`), set `completed` loại load thiếu `actualLoadKg` (`completed_load_set_without_load`), kg có hơn 2 chữ số thập phân (`load_with_three_decimals`, bị từ chối chứ không làm tròn, ADR-062) hoặc target `load` trên bài không phải loại `load` (`load_target_on_reps_exercise`). `discipline`, `measurementType` và `focusTags` chỉ có trong catalog (server-owned, không đi qua sync); catalog bundle phải có `measurementType` khớp `type` (ADR-060), vector ở `fixtures/validation/catalog_rejections.json`. Ví dụ (chỉ là mẫu): `fixtures/samples/load_sync_push.sample.json`.

**Số đo cơ thể (CON-007).** Entity mới `body_measurement` `{id, kind, value, measuredAt}`, không phụ thuộc entity nào khác. `kind` chỉ nhận `weight`; `value` là kg, 20..500. Không có trường đơn vị: payload có `unit` bị từ chối như mọi trường lạ (ADR-063). Server trả `validation_failed` khi `value` có hơn 2 chữ số thập phân (`body_weight_with_three_decimals`, field `value`, bị từ chối chứ không làm tròn) hoặc `measuredAt` sau `clientChangedAt` (`body_measured_at_in_the_future`, field `measuredAt`). Một ngày được nhiều lần đo, mỗi lần một entity. Đây là dữ liệu nhạy cảm: server không ghi `value` vào log, không đưa vào đầu vào AI (ADR-064). Ví dụ (chỉ là mẫu): `fixtures/samples/body_measurement_sync_push.sample.json`.

**Tiêu chí set (CON-008).** `set_result` có thêm `criteriaVersion` và `criteria`, không bắt buộc trên wire nhưng phải đi cùng nhau (schema `dependentRequired`); payload cũ không có hai trường này vẫn hợp lệ. `criteria` là map theo id tiêu chí, tối đa 20 khoá, giá trị là token, số, boolean hoặc danh sách token (không có văn bản tự do). Các khoá đã có trường riêng `rpe`, `pain`, `holdSec`, `reps`, `loadKg` bị schema từ chối (ADR-045, ADR-067). Server trả `validation_failed` khi: `criteriaVersion` chưa được công bố (`criteria_unknown_version`, field `criteriaVersion`), khoá không có hoặc đang tắt trong phiên bản đó (`criteria_key_not_in_version`), giá trị `choice`/`chips` không thuộc `options` (`criteria_choice_value_not_in_options`, `criteria_chips_value_not_in_options`) hoặc giá trị sai kiểu hay ngoài `min..max` (`criteria_value_type_mismatch`), các trường hợp này đều có field `criteria`. Bản thân cấu hình tiêu chí và danh mục chỉ số là dữ liệu chỉ đọc, không đi qua sync push hay pull: client lấy bằng `GET /v1/criteria-config` với một ETag `"c{criteriaVersion}.i{indicatorSetVersion}"` và `If-None-Match` (304 khi không đổi, ADR-066); app đóng gói phiên bản 1 để dùng offline ngay lần mở đầu. Ví dụ (chỉ là mẫu): `fixtures/samples/criteria_sync_push.sample.json`.

**Nghỉ chuyển bài (CON-011).** `planned_workout` có thêm `restBetweenExercisesSeconds` (số nguyên 0..3600 hoặc `null`, không bắt buộc): thời gian nghỉ sau set cuối của một bài trước khi sang bài kế tiếp trong cùng buổi. Thiếu trường hoặc `null` nghĩa là client dùng mặc định 60 s; server lưu `NULL`, không tự điền 60. Payload cũ không có trường này vẫn hợp lệ; ngoài 0..3600 là `validation_failed` (field `restBetweenExercisesSeconds`). Nghỉ giữa các set vẫn là `planned_exercise.restSeconds`. Pull trả trường này trong payload `planned_workout` (giá trị hoặc `null`; bản ghi cũ trong change log có thể không có trường, client đọc như `null`). Ví dụ (chỉ là mẫu): `fixtures/samples/rest_between_exercises_sync_push.sample.json`. **Tương thích:** upsert `planned_workout` là thay thế toàn bộ, nên client cũ không gửi khoá này sẽ đặt lại giá trị về `NULL` khi sửa buổi; iOS hỗ trợ trường này ở IOS-022.

**Payload fingerprint (ADR-031).** The server stores `payload_sha256`. This is the SHA-256 (lowercase hex) of the server canonical JSON of `{entityType, entityId, action, baseVersion, payload}`: object keys sorted ordinally, no whitespace, decimals at their smallest scale (`12.50` = `12.5`), the same form as `Idempotency-Key` hashing (ADR-068, ADR-069; not RFC 8785). Only the server computes it. `clientChangedAt` is excluded, so a resend with a new `clientChangedAt` is still a `duplicate`. A repeated `mutationId` with the same hash replays the stored receipt as `duplicate`. A different hash → `mutation_id_reused`.

**Batch and transaction (ADR-069).** One push is one database transaction; each mutation runs in its own savepoint, in batch order, so a rejected or conflicting mutation does not undo the others. A malformed batch or envelope (invalid JSON, 0 or more than 100 mutations, a missing or unknown envelope field) is HTTP 400 `validation_failed` for the whole request and nothing is written. An `entityType` the server does not accept is not an envelope error: that mutation gets `forbidden_entity` and the rest of the batch is processed. Other HTTP errors: 401, 404 `user_not_found`, 413 (body over 1 MiB), 415 (not JSON), 429.

**Device registration (ADR-033).** The first push from a `deviceId` upserts the caller's `devices` row in the same transaction and refreshes `last_seen_at`. If the `deviceId` is already registered to another user, the server returns HTTP 409 Problem `device_owner_mismatch` and applies nothing. The client should then generate a new device id (for example after a restore onto another account).

**Times (ADR-024).** `date-time` fields accept any RFC 3339 offset. The server normalizes to UTC and always returns `...Z`. `timezone` must be an IANA id known to the server tz database; otherwise `validation_failed`.

## 4. Pull
`GET /v1/sync/pull?cursor=<opaque>&limit=100`; response `{ changes:[{changeId,entityType,entityId,operation,serverVersion,payload}],nextCursor,hasMore }`. For cursor safety, server assigns per-user `change_seq` only after acquiring/updating a row in `user_sync_state` inside the same transaction as business write and change-log append; a global `BIGSERIAL` alone is not commit-order safe. Server includes server-owned AI records and catalog metadata updates via separate versioned catalog endpoint (not feed for MVP). Client applies page and saves `nextCursor` **in one local transaction**; if interrupted, replay safe via idempotent upsert. Do not advance cursor before rows committed.

**Cursor, `changeId` and errors (ADR-070).** The feed is the user's own change history: one row per version, including changes the pulling device pushed, so applying a page is an idempotent upsert keyed by `(entityType, entityId)` guarded by `serverVersion`. `cursor`, `nextCursor` and every `changeId` are the same opaque token: `seq` and `userId` signed with HMAC-SHA256 (76 characters, key `Sync:CursorSigningKey`). A `changeId` passed as `cursor` resumes right after that change. An empty page returns the cursor position unchanged. Omit `cursor` for the initial sync: it reads the whole feed from the start and is never rejected for age. Errors: **400** for a malformed, altered, foreign-key or other-user cursor, a `limit` outside 1..100 or a repeated parameter; **410** `cursor_expired` when the cursor is ahead of the feed, points at a change that is no longer in the log, or is older than `Sync:ChangeLogRetentionDays` (180). A client that saved a cursor and later gets 400 for it should treat it like 410 (the cursor only stops verifying when the signing key changed; IOS-007). Responses are `Cache-Control: no-store`.

**Pull payload shapes (ADR-022).** `payload` is discriminated by `entityType` + `operation` (see `x-payload-schemas` on `SyncChange` in OpenAPI):

| entityType | operation | payload |
|---|---|---|
| device-writable entities (`training_plan` … `workout_note`) | upsert | the same `<entity>_payload` schema as push (`contracts/entity-payloads.schema.json`) |
| `ai_analysis` | upsert | OpenAPI `Analysis` |
| `ai_recommendation` | upsert | OpenAPI `AnalysisRecommendation` + `analysisId` |
| any | delete | `{id, deletedAt}` |

The entity version is always `serverVersion` on the change, never a payload field.

## 5. Conflict policy matrix
| Entity | Concurrent edits | Policy |
|---|---|---|
| set_result | same ID different version | **reject + surface**; current user chooses local/server or edits as newer revision, preserving audit |
| workout_session | active on two devices | server conflict, prompt choose device; no auto union of competing phase timelines |
| training_plan | concurrent revision | fork/duplicate plan or explicit choose, preserve both variants |
| plan_activation | cùng activation, khác version (BR-3) | `version_conflict` như entity khác; client giải quyết theo docs/19 BR-3 (kết thúc thắng tạm dừng). Khác activation, cùng lineage chồng ngày ⇒ `validation_failed` (I1) |
| plan_goal / plan_phase | cùng ID, khác version (CON-005) | `version_conflict`, không LWW. Hai thiết bị cùng ghim mục tiêu thứ `pinned_goal_limit`: mutation nhận trước thắng, mutation sau nhận `pinned_goal_limit`. `achieved` không bao giờ được hợp nhất tự động |
| body_measurement | cùng ID, khác version (CON-007) | `version_conflict`, không LWW; người dùng chọn giá trị. Hai lần đo khác ID không bao giờ là xung đột |
| workout_note | simultaneous edits | keep conflicting copies in conflict inbox; no destructive LWW |
| local media cache | different versions | higher approved contentVersion wins, verified by checksum |
| ai_analysis/recommendation | client attempts edit | server-owned; reject unless decision endpoint |

## 6. Guest → account migration
- Create guest-scoped local dataset. Upon Sign in with Apple: ask to attach local workouts to account.
- Keep client UUIDs; push guest entities as new to authenticated user, map local account scope, do not coalesce by title/date.
- If user has cloud data: pull to local, flag only true UUID conflicts, retain local unsynced rows until ack.
- On sign-out: stop sync immediately, revoke tokens, allow keep/delete guest-local data choice; avoid data leakage between accounts.
- Session tokens (BE-005, ADR-071): `POST /v1/auth/apple` returns an access token (15 minutes) and a single-use refresh token. The client must send refreshes one at a time and keep only the newest refresh token, because presenting a spent one (including a retry after a lost response) revokes the whole session and the user signs in with Apple again. A sync pull or push that answers 401 means the access token expired: refresh once, then retry the same request. There is no server-side sign-out endpoint yet; sign-out today means the client forgets its tokens (the refresh token stays valid until it expires).

## 7. Deletes and retention
- Every delete writes a tombstone with `deletedAt`, never hard-delete while unsynced.
- Server retains tombstones for 180 days initial policy; if device offline longer, require full resync not silent stale resurrection. Pull enforces this as **410** `cursor_expired` (ADR-070). A log-compaction job (`TODO(OPS-001)`, not built yet) may delete only rows older than the window that a newer row of the same entity supersedes, and old tombstones; it must keep the newest row of every live entity because the full resync reads from `seq` 0.
- Full resync keeps unsynced local outbox separate, resets pull cursor only after user identity confirmed and full snapshot loaded.

## 8. Retry and diagnostic states
`pending -> sending -> acked | conflicted | rejected | pending(nextAttempt)`.
- Exponential backoff with jitter, cap 1h; 429 honors Retry-After.
- Network online indicator isn't proof that API is reachable.
- Show “Đã lưu trên máy · Chờ đồng bộ” vs “Đã đồng bộ” vs “Cần xử lý xung đột”.
- Measure: outbox age, pending count, duplicate receipt count, sync rejection rate, per-batch duration.

## 9. Test vectors
- Push same mutation 10x ⇒ one canonical server row and consistent receipt.
- Kill after local commit before HTTP send ⇒ queued persists.
- HTTP 200 received then app killed before ACK write ⇒ retry duplicate accepted.
- Pull page applied but cursor not saved (simulated crash) ⇒ replay safe.
- Update with wrong `baseVersion` ⇒ conflict, no overwrite.
- Payload trong `fixtures/validation/schema_rejections.json` (source `healthkit`, thời gian > 24 giờ, quãng đường > 1000 km, có trường pace, tạ âm hoặc > 1000 kg…) ⇒ không qua JSON Schema; `tools/validate_handoff.py` kiểm tra mỗi case vẫn bị từ chối. Tương tự, mỗi case trong `fixtures/validation/catalog_rejections.json` phải bị `catalog-bundle.schema.json` từ chối (CON-006).
- 2 devices change plan simultaneously ⇒ fork/explicit resolution.
- Guest-to-user merge ⇒ no data loss, no duplicate by date.
- Same `mutationId`, different payload ⇒ `rejected`/`mutation_id_reused`, original receipt and row unchanged.
- Child pushed before parent ⇒ `conflict`/`dependency_missing` (retryable, no receipt); resend after parent ⇒ `applied`.
- `deviceId` of another user ⇒ 409 `device_owner_mismatch`, nothing applied.
- Unknown envelope field ⇒ 400.
- `fixtures/validation/business_rules.json` cases ⇒ `rejected` with the listed `code` (`validation_failed`, `active_plan_limit`, `plan_count_limit`, `pinned_goal_limit`, `goal_unlock_cycle`) and field; `given` mô tả trạng thái server cần có trước.
- Hai thiết bị offline, mỗi bên bắt đầu một giáo án khác khi user đã theo 2 giáo án ⇒ mutation nhận trước `applied`, mutation sau `rejected`/`active_plan_limit` (đã kiểm ở mức SQL bằng hai giao dịch đồng thời trong `PlanLineageActivationMigrationTests`).

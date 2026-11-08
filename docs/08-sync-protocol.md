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
Dependency ordering: send parent records first (`training_plan → planned_workout → planned_exercise`; `training_plan → plan_activation`; `workout_session → exercise_execution → set_result`). Server processes each batch in supplied order. If parent is missing, return an explicit retryable dependency conflict rather than silently creating an orphan. For multiple local changes on the **same entity**, serialize the outbox: do not send mutation #2 until #1 is acknowledged; before first send of #2, rebase `baseVersion` to the newly acknowledged server version and keep #2’s mutation ID stable throughout retries. Client must never alter a mutation payload once an HTTP attempt has started.

Server responds per mutation: `applied|duplicate|conflict|rejected`, `serverVersion`, `serverEntity?`, `error?`. `duplicate` receipt is accepted and mark outbox ACK; `conflict` persists unresolved and does not silently overwrite; dependency conflicts may be retried after missing parents are acknowledged, whereas version conflicts require user resolution. Network failure: retry same mutation UUID, never generate new UUID for same committed action.

The envelope and every payload are closed objects, so an unknown field anywhere → HTTP 400 for the batch (ADR-030).

**Chạy bộ (CON-004).** `set_result` nhận thêm `distanceMeters` (mét, 0..1000000), `durationSeconds` (giây, 0..86400) và `source` (chỉ `manual`; `healthkit` bị từ chối tới slice Apple Health, ADR-043). Cả ba đều không bắt buộc nên client v1 không phải đổi. `planned_exercise.target` có thêm kind `distance` và `duration`. Pace không có trên wire: client tự tính từ `durationSeconds / distanceMeters`; payload gửi trường pace bị từ chối như mọi trường lạ. Ví dụ đầy đủ (chỉ là mẫu): `fixtures/samples/running_sync_push.sample.json`.

**Receipts and error codes (ADR-021).** `error` = `{code, message, retryable, details?}`.

| `code` | `status` | `retryable` | Receipt persisted? | Client action |
|---|---|---|---|---|
| `dependency_missing` | conflict | true | **no** | keep the outbox row; resend the same `mutationId` after the parent is acked |
| `version_conflict` | conflict | false | yes | surface the conflict (§5); `serverEntity` is returned |
| `validation_failed` | rejected | false | yes | mark rejected; a client bug or business-rule violation (ADR-020); `details.field` names the field |
| `forbidden_entity` | rejected | false | yes | mark rejected (server-owned entity type) |
| `cross_user_reference` | rejected | false | yes | mark rejected |
| `mutation_id_reused` | rejected | false | **no** (the original receipt is unchanged) | client bug: a payload changed after a send attempt |
| `active_plan_limit` | rejected | false | yes | CON-003, BR-2: activation làm số giáo án được theo trong một ngày vượt giới hạn server (mặc định 3). Đánh dấu rejected, hoàn tác activation cục bộ và báo người dùng chọn giáo án để tạm dừng; không tự gửi lại |
| `plan_count_limit` | rejected | false | yes | CON-003, BR-8: vượt giới hạn server (mặc định 50) giáo án chưa xoá. Đánh dấu rejected và gợi ý xoá bớt giáo án cũ |

**Nhiều giáo án (CON-003).** `training_plan` có thêm `lineageId`, `kind`, `eventDate`, `eventName`, `primaryDiscipline`, `endedAt`, `endReason`, `endNote`, `archivedAt`, đều không bắt buộc trên wire (server suy `lineageId` từ `parentPlanId`). `status` nay là trạng thái phiên bản `current|superseded`; giá trị v1 `active|archived` bị JSON Schema từ chối (breaking, ADR-056). Entity mới `plan_activation` `{id, planLineageId, fromDate, toDate?, timezone, endReason?}`, đẩy sau `training_plan` gốc của lineage; lineage chưa có trên server ⇒ `dependency_missing`. Trạng thái người dùng thấy không có trên wire. Hai thiết bị offline cùng bắt đầu giáo án (BR-2): server áp dụng theo thứ tự nhận trong giao dịch riêng của mỗi mutation; mutation đến sau mà vượt I2 nhận `active_plan_limit`, cùng một lineage chồng ngày (I1) nhận `validation_failed` với field `fromDate`. Ví dụ (chỉ là mẫu): `fixtures/samples/plan_activation_sync_push.sample.json`.

**Môn tập và bài tạ (CON-006).** `planned_exercise.target` và `prescribedSnapshot.target` có thêm dạng `{kind: load, reps, loadKg}`; `set_result` có thêm `actualLoadKg` (kg, 0..1000, không bắt buộc trên wire). Payload v1 vẫn hợp lệ. Server trả `validation_failed` khi: `actualLoadKg` nằm trên set không phải `load` (`load_fields_on_non_load_set`), set `completed` loại load thiếu `actualLoadKg` (`completed_load_set_without_load`), kg có hơn 2 chữ số thập phân (`load_with_three_decimals`, bị từ chối chứ không làm tròn, ADR-062) hoặc target `load` trên bài không phải loại `load` (`load_target_on_reps_exercise`). `discipline`, `measurementType` và `focusTags` chỉ có trong catalog (server-owned, không đi qua sync); catalog bundle phải có `measurementType` khớp `type` (ADR-060), vector ở `fixtures/validation/catalog_rejections.json`. Ví dụ (chỉ là mẫu): `fixtures/samples/load_sync_push.sample.json`.

**Payload fingerprint (ADR-031).** The server stores `payload_sha256`. This is the SHA-256 (lowercase hex) of the RFC 8785 (JCS) canonical JSON of `{entityType, entityId, action, baseVersion, payload}`. `clientChangedAt` is excluded. A repeated `mutationId` with the same hash replays the stored receipt as `duplicate`. A different hash → `mutation_id_reused`.

**Device registration (ADR-033).** The first push from a `deviceId` upserts the caller's `devices` row in the same transaction and refreshes `last_seen_at`. If the `deviceId` is already registered to another user, the server returns HTTP 409 Problem `device_owner_mismatch` and applies nothing. The client should then generate a new device id (for example after a restore onto another account).

**Times (ADR-024).** `date-time` fields accept any RFC 3339 offset. The server normalizes to UTC and always returns `...Z`. `timezone` must be an IANA id known to the server tz database; otherwise `validation_failed`.

## 4. Pull
`GET /v1/sync/pull?cursor=<opaque>&limit=100`; response `{ changes:[{changeId,entityType,entityId,operation,serverVersion,payload}],nextCursor,hasMore }`. For cursor safety, server assigns per-user `change_seq` only after acquiring/updating a row in `user_sync_state` inside the same transaction as business write and change-log append; a global `BIGSERIAL` alone is not commit-order safe. Server includes server-owned AI records and catalog metadata updates via separate versioned catalog endpoint (not feed for MVP). Client applies page and saves `nextCursor` **in one local transaction**; if interrupted, replay safe via idempotent upsert. Do not advance cursor before rows committed.

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
| workout_note | simultaneous edits | keep conflicting copies in conflict inbox; no destructive LWW |
| local media cache | different versions | higher approved contentVersion wins, verified by checksum |
| ai_analysis/recommendation | client attempts edit | server-owned; reject unless decision endpoint |

## 6. Guest → account migration
- Create guest-scoped local dataset. Upon Sign in with Apple: ask to attach local workouts to account.
- Keep client UUIDs; push guest entities as new to authenticated user, map local account scope, do not coalesce by title/date.
- If user has cloud data: pull to local, flag only true UUID conflicts, retain local unsynced rows until ack.
- On sign-out: stop sync immediately, revoke tokens, allow keep/delete guest-local data choice; avoid data leakage between accounts.

## 7. Deletes and retention
- Every delete writes a tombstone with `deletedAt`, never hard-delete while unsynced.
- Server retains tombstones for 180 days initial policy; if device offline longer, require full resync not silent stale resurrection.
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
- `fixtures/validation/business_rules.json` cases ⇒ `rejected` with the listed `code` (`validation_failed`, `active_plan_limit`, `plan_count_limit`) and field; `given` mô tả trạng thái server cần có trước.
- Hai thiết bị offline, mỗi bên bắt đầu một giáo án khác khi user đã theo 2 giáo án ⇒ mutation nhận trước `applied`, mutation sau `rejected`/`active_plan_limit` (đã kiểm ở mức SQL bằng hai giao dịch đồng thời trong `PlanLineageActivationMigrationTests`).

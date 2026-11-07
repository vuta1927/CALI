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
  "payload":{"id":"UUID", "executionId":"UUID", "setIndex":1, "status":"completed", "actualHoldMs":12000}
}
```
Dependency ordering: send parent records first (`training_plan → planned_workout → planned_exercise`; `workout_session → exercise_execution → set_result`). Server processes each batch in supplied order. If parent is missing, return an explicit retryable dependency conflict rather than silently creating an orphan. For multiple local changes on the **same entity**, serialize the outbox: do not send mutation #2 until #1 is acknowledged; before first send of #2, rebase `baseVersion` to the newly acknowledged server version and keep #2’s mutation ID stable throughout retries. Client must never alter a mutation payload once an HTTP attempt has started.

Server responds per mutation: `applied|duplicate|conflict|rejected`, `serverVersion`, `serverEntity?`, `error?`. `duplicate` receipt is accepted and mark outbox ACK; `conflict` persists unresolved and does not silently overwrite; dependency conflicts may be retried after missing parents are acknowledged, whereas version conflicts require user resolution. Network failure: retry same mutation UUID, never generate new UUID for same committed action.

## 4. Pull
`GET /v1/sync/pull?cursor=<opaque>&limit=100`; response `{ changes:[{changeId,entityType,entityId,operation,serverVersion,payload}],nextCursor,hasMore }`. For cursor safety, server assigns per-user `change_seq` only after acquiring/updating a row in `user_sync_state` inside the same transaction as business write and change-log append; a global `BIGSERIAL` alone is not commit-order safe. Server includes server-owned AI records and catalog metadata updates via separate versioned catalog endpoint (not feed for MVP). Client applies page and saves `nextCursor` **in one local transaction**; if interrupted, replay safe via idempotent upsert. Do not advance cursor before rows committed.

## 5. Conflict policy matrix
| Entity | Concurrent edits | Policy |
|---|---|---|
| set_result | same ID different version | **reject + surface**; current user chooses local/server or edits as newer revision, preserving audit |
| workout_session | active on two devices | server conflict, prompt choose device; no auto union of competing phase timelines |
| training_plan | concurrent revision | fork/duplicate plan or explicit choose, preserve both variants |
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
- 2 devices change plan simultaneously ⇒ fork/explicit resolution.
- Guest-to-user merge ⇒ no data loss, no duplicate by date.

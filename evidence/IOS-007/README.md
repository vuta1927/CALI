# IOS-007 evidence (slice 1 push, slice 2 pull, slice 3 content and conflicts)

Date: 2026-11-10. Simulator iPhone 15 (unsigned). No backend: fake `SyncAPI` and `URLProtocol` stubs only.

| Check | Result |
| --- | --- |
| CaliCore `swift test` | 89 tests, 0 failures |
| Payloads vs `contracts/entity-payloads.schema.json` (required, closed keys, enums) | `SyncPayloadConformanceTests` |
| Engine: ack, duplicate, offline + backoff, crash while `sending`, dependency_missing, version_conflict, rejected, rebase, 401, 429 Retry-After, whole-batch 400 split, device_owner_mismatch, 100-per-batch cap | `OutboxSyncEngineTests` (16) |
| HTTP: bearer, decimal payload numbers, 401 refresh once, status mapping | `URLSessionSyncAPITests` (6) |
| App test run | simulator 72 tests, 1 skipped (Keychain, needs signed build), 0 failures; iPhone 15: 72 of 72, 0 skipped, 0 failures (slices 1 and 2) |
| Pull: initial/resume/empty page, own-write echo, replay, stale version, tombstone, 410 (once, twice), page rollback, pull skipped after failed push | `PullSyncTests` (10) + 2 in `URLSessionSyncAPITests` |
| CaliCore after slice 2 | 101 tests, 0 failures |
| Content push: parents-first, schema conformance for all 7 content payloads, no re-queue when unchanged, hard-delete tombstones, dirty cleared only on matching ack, seeded rows queued at first sync | `ContentOutboxTests` (6) |
| Content apply and decisions: children-first page, edit in flight blocks, stale dropped, delete, unfit stays, exact weight, goal decode, use server / keep local / retry / dismiss, engine reports applied | `ContentApplyTests` (13) |
| CaliCore after slice 3 | 119 tests, 0 failures; app 72 on the simulator; iPhone 15: app 72 of 72, 0 skipped, 0 failures (slices 1 to 3) |
| Real test server (2026-11-10, dev JWT, host not recorded here; catalog seeded with the 9 fixture exercises) | Pull `200` in the contract shape. Session path: create, execution, terminal upsert all acked. Two devices: A reads the catalog (9), creates a plan, trains one set and pushes plan, workout, planned exercise, session, execution and set (all acked); B starts empty, reads the catalog, pulls once and gets A's plan with workout, exercise and target intact; A then deletes the plan and the delete is acked. Also found: the `currentExecutionId` deadlock (fixed) and that the server refuses a reused `mutationId` with another payload (`mutation_id_reused`), which the fixed fixture ids in a test triggered. Activation, phase, goal and body weight: A pushes a plan with an activation and a phase, a `best_hold_seconds` goal and a weight (all acked); B pulls all four intact; A deletes them. Conflict: A and B edit the same plan from one server version; A is acked, B's stale edit is `conflicted` and nothing is overwritten | `LiveServerTests` (opt-in, 4 tests) |
| Not covered | real server (TODO: run docs/08 §9 vectors against BE-004 when reachable), pull, content entities |

# Prompt: Backend Agent — ASP.NET Core + PostgreSQL + Sync

**Mission:** Provide secure authenticated canonical storage, idempotent sync, catalog API and AI job infrastructure.

Read: `AGENTS.md`, `docs/06-backend-architecture.md`, `docs/07-data-model.md`, `docs/08-sync-protocol.md`, `docs/11-security-observability.md`, `contracts/openapi.yaml`, `db/001_initial.sql`.

## Implement in order
1. Scaffold modular-monolith .NET 10 API + Worker; migrations + disposable Postgres integration test.
2. Verify Apple token securely (signature/audience/issuer/expiry/nonce), API JWT/rotated refresh token; per-user authorization.
3. Catalog/Plan endpoints matching OpenAPI. Use typed DTOs and validation.
4. `/sync/push`: transact entity write + permanent `(userId,mutationId)` receipt + change event; no duplicate; return per mutation statuses.
5. `/sync/pull`: user-scoped opaque cursor; allocate **per-user commit-serialized change sequence using `user_sync_state` row locking**; page stable; expire cursor policy.
6. AI jobs queue with leasing, retries, status API, recommendation decision creating new plan revision.

## Do not
- Assume global `BIGSERIAL` means commit-ordered cursor; sequence allocation before concurrent commits can skip records.
- Use the client-provided `userId` as authority.
- Return 200 for unsupported entity/action without validation.
- Send provider secrets or AI system prompts to mobile.

## Required evidence
Migrations up/down (or forward-only procedure), multi-user IDOR tests, duplicate mutation replay, 2 concurrent mutators ordering test, plan conflict test, contract test with OpenAPI and proof data from SQL.

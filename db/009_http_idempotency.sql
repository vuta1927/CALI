-- B1 (BE-002) HTTP idempotency for direct create endpoints (docs/06, docs/07; AGENTS rule 5;
-- ADR-031, ADR-049; ADR-068).
-- New numbered migration (ADR-049): db/001..008 are never edited. Depends on db/001 (users).
-- Backward compatible: adds one table and one index; no existing column or constraint changes.
--   * One row per (user, Idempotency-Key) for a request that SUCCEEDED. Failed requests roll back
--     and store nothing, so retrying a failed request simply runs it again.
--   * request_sha256 = SHA-256 (lowercase hex) of the canonical, normalized request (ADR-068).
--     Same key + same operation + same hash => the stored response is replayed. Same key with a
--     different hash or operation => 409 `idempotency_key_reused`.
--   * response_body is the exact response document returned the first time (replayed as-is).
--   * Keys are scoped per user: another user's key never matches (no cross-user lookup).
-- Sync push keeps its own receipts in sync_mutations (ADR-031); this table is only for HTTP.

CREATE TABLE http_idempotency_keys (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    idempotency_key uuid NOT NULL,
    operation text NOT NULL,
    request_sha256 char(64) NOT NULL,
    status_code integer NOT NULL,
    response_body jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, idempotency_key),
    -- OpenAPI operationId of the endpoint; extend the list when another endpoint adopts the header.
    CONSTRAINT ck_http_idempotency_keys_operation CHECK (operation IN ('createPlan')),
    CONSTRAINT ck_http_idempotency_keys_request_sha256 CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    -- Only successful results are stored.
    CONSTRAINT ck_http_idempotency_keys_status_code CHECK (status_code BETWEEN 200 AND 299),
    CONSTRAINT ck_http_idempotency_keys_response_body CHECK (jsonb_typeof(response_body) = 'object')
);
-- Retention (deleting old keys) is an operations job, not part of this slice.
CREATE INDEX idx_http_idempotency_keys_created ON http_idempotency_keys(created_at);

-- GET /v1/plans keyset pagination: ORDER BY created_at, id per user over live revisions (docs/06).
CREATE INDEX idx_training_plans_user_created ON training_plans(user_id, created_at, id) WHERE deleted_at IS NULL;
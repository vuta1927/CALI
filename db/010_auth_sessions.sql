-- B4 (BE-005) Sign in with Apple sessions (docs/06, docs/08 section 6, docs/11 section 2; ADR-071).
-- New numbered migration (ADR-049): db/001..009 are never edited. Depends on db/001 (users).
-- Backward compatible: adds three tables; users.apple_subject (UNIQUE, db/001) is reused as is.
--
--   * auth_apple_nonces: one row per nonce already used for a sign-in, kept until the identity token it came
--     with has expired. A second sign-in with the same nonce is refused (replay of a stolen identity token).
--     Only the SHA-256 of the raw nonce is stored.
--   * auth_refresh_families: one row per sign-in. A refresh token family dies together: when a token that was
--     already rotated is presented again, the whole family is revoked (reuse detection).
--   * auth_refresh_tokens: the chain of tokens of a family. Only the SHA-256 of the opaque token is stored.
--     Rotation marks the presented token used and inserts the next one in one transaction, and a partial
--     unique index guarantees a family never holds two unused tokens.
--
-- Retention (deleting expired and revoked families, tokens and nonces) is an operations job
-- (TODO(OPS-001): remove when the retention job lands; until then rows only accumulate, they never grant access
-- after expires_at / revoked_at).

CREATE TABLE auth_apple_nonces (
    nonce_sha256 bytea PRIMARY KEY,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_auth_apple_nonces_sha CHECK (octet_length(nonce_sha256) = 32)
);
CREATE INDEX idx_auth_apple_nonces_expires ON auth_apple_nonces(expires_at);

CREATE TABLE auth_refresh_families (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- Informational binding, not an FK: devices are registered by the first sync push (ADR-033).
    device_id uuid,
    created_at timestamptz NOT NULL DEFAULT now(),
    -- Absolute end of the session; rotation never extends a token past it.
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    revoked_reason text,
    CONSTRAINT ck_auth_refresh_families_lifetime CHECK (expires_at > created_at),
    CONSTRAINT ck_auth_refresh_families_revoked CHECK ((revoked_at IS NULL) = (revoked_reason IS NULL)),
    CONSTRAINT ck_auth_refresh_families_reason CHECK (revoked_reason IS NULL OR revoked_reason IN ('reuse', 'user_unavailable'))
);
CREATE INDEX idx_auth_refresh_families_user ON auth_refresh_families(user_id);

CREATE TABLE auth_refresh_tokens (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id uuid NOT NULL REFERENCES auth_refresh_families(id) ON DELETE CASCADE,
    token_sha256 bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    -- Set when the token has been exchanged for its successor. Presenting a used token again is reuse.
    used_at timestamptz,
    CONSTRAINT ck_auth_refresh_tokens_sha CHECK (octet_length(token_sha256) = 32),
    CONSTRAINT ck_auth_refresh_tokens_lifetime CHECK (expires_at > created_at)
);
CREATE INDEX idx_auth_refresh_tokens_family ON auth_refresh_tokens(family_id);
-- At most one live (unused) token per family: the head of the chain.
CREATE UNIQUE INDEX uq_auth_refresh_tokens_family_head ON auth_refresh_tokens(family_id) WHERE used_at IS NULL;

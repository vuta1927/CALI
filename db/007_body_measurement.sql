-- CON-007 Body measurement (docs/07 §1-§3, docs/09 §3, docs/11 §2/§4, docs/18 §8; ADR-046, ADR-049;
-- ADR-063, ADR-064, ADR-065).
-- New numbered migration (ADR-049): db/001..006 are never edited. Depends on db/005 (sync entity CHECKs).
-- Backward compatible: adds one table and one device-writable sync entity type; no existing row changes.
--   * body_measurements holds user-entered body data. v1 kinds: 'weight' only, kilograms (ADR-046,
--     ADR-063). No unit column: the unit is fixed by the kind.
--   * Sensitive data (docs/11): never part of AI input (ADR-064), never on the Lock Screen,
--     Live Activity or notifications. CON-007 stores no AI consent; that needs a later audited opt-in.
--   * No body indicator is seeded in indicator_definitions (ADR-065, deferred).
-- Cross-field rules (measuredAt not after clientChangedAt) are enforced by backend sync + CaliDomain
-- (ADR-020), not here.

-- 1. Body measurements (one row per measurement; several per day are allowed; soft delete).
CREATE TABLE body_measurements (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind text NOT NULL,
    value numeric NOT NULL,
    measured_at timestamptz NOT NULL,
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    CONSTRAINT ck_body_measurements_kind CHECK (kind IN ('weight')),
    -- weight: kilograms, 20..500, at most 2 decimals; excess decimals are rejected, never rounded (ADR-063).
    CONSTRAINT ck_body_measurements_value CHECK (value >= 20 AND value <= 500 AND value = round(value, 2))
);

-- 2. Indexes: sync pull by user + recency; per-kind history (charts, latest value) of live rows.
CREATE INDEX idx_body_measurements_user_update ON body_measurements(user_id, updated_at DESC);
CREATE INDEX idx_body_measurements_user_kind_measured
    ON body_measurements(user_id, kind, measured_at DESC) WHERE deleted_at IS NULL;

-- 3. Sync entity types (named constraints, last redefined by db/005): add 'body_measurement'.
ALTER TABLE sync_mutations DROP CONSTRAINT ck_sync_mutations_entity_type;
ALTER TABLE sync_mutations ADD CONSTRAINT ck_sync_mutations_entity_type CHECK (entity_type IN (
    'training_plan','planned_workout','planned_exercise','workout_session','exercise_execution',
    'set_result','workout_note','plan_activation','plan_phase','plan_goal','body_measurement'));
ALTER TABLE sync_change_log DROP CONSTRAINT ck_sync_change_log_entity_type;
ALTER TABLE sync_change_log ADD CONSTRAINT ck_sync_change_log_entity_type CHECK (entity_type IN (
    'training_plan','planned_workout','planned_exercise','workout_session','exercise_execution',
    'set_result','workout_note','plan_activation','plan_phase','plan_goal','body_measurement',
    'ai_analysis','ai_recommendation'));

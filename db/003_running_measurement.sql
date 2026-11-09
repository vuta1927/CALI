-- CON-004 Running measurement (docs/19 §4.1, §10; ADR-043, ADR-049, ADR-055).
-- New numbered migration (ADR-049): db/001 and db/002 are never edited.
-- Backward compatible: existing rows and v1 payloads stay valid.
--   * exercise_type gains 'distance' and 'duration' (running exercises).
--   * set_results gains distance_meters, duration_seconds and source.
--   * Pace is derived (duration_seconds / distance_meters) and is never stored.
-- Running prescriptions live in planned_exercises.target (jsonb) as kinds 'distance' and
-- 'duration'; their shape is validated by contracts/entity-payloads.schema.json, not here.

-- 1. Catalog exercise types. The inline CHECK in 001 has the default name
--    exercise_catalog_exercise_type_check; replace it with a named constraint.
ALTER TABLE exercise_catalog DROP CONSTRAINT exercise_catalog_exercise_type_check;
ALTER TABLE exercise_catalog
    ADD CONSTRAINT ck_exercise_catalog_exercise_type
    CHECK (exercise_type IN ('static_hold','reps','timed_reps','interval','skill_attempt','distance','duration'));

-- 2. Running results. One set of a running exercise = one segment (docs/19 §4.1).
--    Distance is stored in metres (ADR-055: km only in the UI, metres in storage).
--    Upper bounds mirror contracts/entity-payloads.schema.json (set_result_payload).
ALTER TABLE set_results
    ADD COLUMN distance_meters int,
    ADD COLUMN duration_seconds int,
    -- ADR-043: 'healthkit' is reserved for the post-MVP Apple Health slice and is NOT accepted yet.
    -- Widening this CHECK to ('manual','healthkit') is a later, explicit migration.
    ADD COLUMN source text NOT NULL DEFAULT 'manual';

ALTER TABLE set_results
    ADD CONSTRAINT ck_set_results_distance_meters CHECK (distance_meters BETWEEN 0 AND 1000000),
    ADD CONSTRAINT ck_set_results_duration_seconds CHECK (duration_seconds BETWEEN 0 AND 86400),
    ADD CONSTRAINT ck_set_results_source CHECK (source IN ('manual'));

-- CON-006 Exercise discipline + load (docs/18 §4, §8; ADR-046, ADR-049, ADR-060, ADR-061, ADR-062).
-- New numbered migration (ADR-049): db/001..004 are never edited. Independent of db/005.
-- Backward compatible: existing rows and v1 payloads stay valid.
--   * exercise_type gains 'load' (gym-style weight x reps, ADR-062).
--   * exercise_catalog gains discipline (NOT NULL, backfilled) and focus_tags (jsonb array).
--   * measurementType is NOT stored: it is a fixed function of exercise_type (ADR-060).
--   * set_results gains actual_load_kg (kg only, ADR-046). Volume (reps x kg) is derived and
--     never stored.
-- Load prescriptions live in planned_exercises.target (jsonb) as kind 'load'
-- {reps, loadKg}; their shape is validated by contracts/entity-payloads.schema.json, and the
-- cross-field rules (actualLoadKg only for a load target, ...) by backend sync + CaliDomain
-- (ADR-020), not here.

-- 1. Catalog exercise types (named constraint from db/003).
ALTER TABLE exercise_catalog DROP CONSTRAINT ck_exercise_catalog_exercise_type;
ALTER TABLE exercise_catalog
    ADD CONSTRAINT ck_exercise_catalog_exercise_type
    CHECK (exercise_type IN ('static_hold','reps','timed_reps','interval','skill_attempt','distance','duration','load'));

-- 2. Default discipline of an exercise type (ADR-061). Same mapping as the db/004
--    primary_discipline backfill, extended with load -> gym. Used for the backfill and for
--    inserts that do not name a discipline (catalog tooling written before CON-006).
--    It is only a default: a weighted pull-up is a legitimate calisthenics + load row.
CREATE FUNCTION cali_default_discipline(exercise_type text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN exercise_type IN ('distance','duration') THEN 'running'
        WHEN exercise_type = 'load' THEN 'gym'
        ELSE 'calisthenics'
    END
$$;

-- 3. Discipline and focus tags.
--    discipline reuses the OpenAPI Discipline vocabulary (calisthenics|gym|running);
--    'mixed' is a plan-level value only (PrimaryDiscipline) and never valid for an exercise.
ALTER TABLE exercise_catalog
    ADD COLUMN discipline text,
    -- Free slugs such as 'push' or 'core' (docs/18 §4); no fixed vocabulary yet (ADR-061).
    ADD COLUMN focus_tags jsonb NOT NULL DEFAULT '[]'::jsonb;

UPDATE exercise_catalog SET discipline = cali_default_discipline(exercise_type);

ALTER TABLE exercise_catalog
    ALTER COLUMN discipline SET NOT NULL,
    ADD CONSTRAINT ck_exercise_catalog_discipline CHECK (discipline IN ('calisthenics','gym','running')),
    ADD CONSTRAINT ck_exercise_catalog_focus_tags CHECK (jsonb_typeof(focus_tags) = 'array');

-- 4. Inserts that omit discipline get the type default instead of failing NOT NULL.
CREATE FUNCTION exercise_catalog_default_discipline() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.discipline IS NULL THEN
        NEW.discipline := cali_default_discipline(NEW.exercise_type);
    END IF;
    RETURN NEW;
END
$$;

CREATE TRIGGER trg_exercise_catalog_default_discipline
BEFORE INSERT ON exercise_catalog
FOR EACH ROW EXECUTE FUNCTION exercise_catalog_default_discipline();

-- 5. Load results. Kilograms only (ADR-046: lb is a display conversion, never stored).
--    Bounds mirror contracts/entity-payloads.schema.json (set_result_payload.actualLoadKg).
--    At most 2 decimals (ADR-062): a value with more is REJECTED, never silently rounded,
--    so the stored value always equals what the client confirmed. The check compares values
--    (57.500 is accepted as 57.5), not the textual scale.
ALTER TABLE set_results
    ADD COLUMN actual_load_kg numeric;

ALTER TABLE set_results
    ADD CONSTRAINT ck_set_results_actual_load_kg
    CHECK (actual_load_kg >= 0 AND actual_load_kg <= 1000 AND actual_load_kg = round(actual_load_kg, 2));

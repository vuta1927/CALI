-- CON-003 Plan lineage + activation (docs/19 §4, §4.4, BR-1, BR-2, BR-8, BR-10, §10;
-- docs/19 D1 limit of 3; ADR-034, ADR-035, ADR-036, ADR-040, ADR-041, ADR-049, ADR-056).
-- New numbered migration (ADR-049): db/001..003 are never edited.
--   * training_plans: lineage_id, kind, event_date, event_name, primary_discipline,
--     ended_at, end_reason, end_note, archived_at. status becomes the REVISION status
--     (current | superseded); the user-facing plan status is computed (docs/19 §4.2).
--   * plan_activations: periods during which a plan lineage is followed.
--       I1  activations of the same lineage never overlap  -> exclusion constraint (23P01).
--       I2  per day, live lineages with an activation <= server_settings.active_plan_limit
--           -> trigger, serialised per user with an advisory lock (SQLSTATE CA001,
--              MutationError code active_plan_limit, not retried).
--   * <= server_settings.plan_count_limit (50) non-deleted plans per user (ADR-041, BR-8)
--     -> trigger (SQLSTATE CA002, MutationError code plan_count_limit).
--   * BR-10 backfill of existing rows.
-- Sync push must run in READ COMMITTED (default): the triggers re-read after taking the
-- per-user advisory lock, so a concurrent activation committed first is always counted.

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- 1. Server-side limits (D1 "configurable on the server"). Changing a value takes effect on
--    the next command; existing rows are never rewritten.
CREATE TABLE server_settings (
    key text PRIMARY KEY,
    int_value int NOT NULL CHECK (int_value >= 1),
    updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO server_settings (key, int_value) VALUES
    ('active_plan_limit', 3),   -- docs/19 D1 (PO decision)
    ('plan_count_limit', 50);   -- docs/19 D9 / ADR-041

-- A missing row is a deployment error: fail closed instead of silently disabling a limit.
CREATE FUNCTION cali_setting_int(setting_key text) RETURNS int
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v int;
BEGIN
    SELECT int_value INTO v FROM server_settings WHERE key = setting_key;
    IF v IS NULL THEN
        RAISE EXCEPTION 'server setting % is missing', setting_key USING ERRCODE = 'CA000';
    END IF;
    RETURN v;
END $$;

-- 2. training_plans: new columns (nullable first, backfilled below).
ALTER TABLE training_plans
    ADD COLUMN lineage_id uuid,
    ADD COLUMN kind text NOT NULL DEFAULT 'weekly',
    ADD COLUMN event_date date,
    ADD COLUMN event_name text,
    -- v1 plans contain only calisthenics exercises; v1 clients do not send this field.
    ADD COLUMN primary_discipline text NOT NULL DEFAULT 'calisthenics',
    ADD COLUMN ended_at timestamptz,
    ADD COLUMN end_reason text,
    ADD COLUMN end_note text,
    ADD COLUMN archived_at timestamptz;

-- The inline CHECK from 001 has the default name training_plans_status_check.
ALTER TABLE training_plans DROP CONSTRAINT training_plans_status_check;
ALTER TABLE training_plans ALTER COLUMN status DROP DEFAULT;

-- 3. BR-10 backfill.
-- 3a. lineage_id = root of the parent_plan_id chain ("AI revisions are one plan").
WITH RECURSIVE chain AS (
    SELECT id, user_id, id AS root_id
    FROM training_plans
    WHERE parent_plan_id IS NULL
    UNION ALL
    SELECT child.id, child.user_id, chain.root_id
    FROM training_plans child
    JOIN chain ON child.parent_plan_id = chain.id AND child.user_id = chain.user_id
)
UPDATE training_plans p SET lineage_id = chain.root_id
FROM chain WHERE chain.id = p.id;
-- Defensive: a broken chain (should not exist because of the FK) becomes its own lineage.
UPDATE training_plans SET lineage_id = id WHERE lineage_id IS NULL;

-- 3b. v1 'archived' -> archived_at (on the lineage's newest revision, see 3c).
--     Remember which lineages were 'active' in v1 before the status is rewritten.
CREATE TEMP TABLE con003_v1_active_lineage AS
SELECT DISTINCT ON (lineage_id) lineage_id, user_id, id AS plan_id, status AS v1_status, created_at, updated_at
FROM training_plans
WHERE deleted_at IS NULL
ORDER BY lineage_id, revision DESC, updated_at DESC, id;

-- 3c. Revision status: the newest live revision of each lineage is current, all others
--     superseded. A lineage whose revisions are all deleted keeps its newest revision as
--     the (deleted) current one.
WITH ranked AS (
    SELECT id,
           row_number() OVER (PARTITION BY lineage_id
                              ORDER BY (deleted_at IS NULL) DESC, revision DESC, updated_at DESC, id) AS rn
    FROM training_plans
)
UPDATE training_plans p
SET status = CASE WHEN ranked.rn = 1 THEN 'current' ELSE 'superseded' END
FROM ranked WHERE ranked.id = p.id;

UPDATE training_plans p SET archived_at = l.updated_at
FROM con003_v1_active_lineage l
WHERE p.id = l.plan_id AND l.v1_status = 'archived';

-- 3d. primary_discipline: running exercise types (db/003) map to 'running'. A plan whose
--     exercises span several disciplines becomes 'mixed'. Every other v1 exercise type is
--     calisthenics (the only discipline in the catalog today).
WITH disciplines AS (
    SELECT pw.plan_id,
           count(DISTINCT CASE WHEN ec.exercise_type IN ('distance','duration') THEN 'running'
                               ELSE 'calisthenics' END) AS n,
           min(CASE WHEN ec.exercise_type IN ('distance','duration') THEN 'running'
                    ELSE 'calisthenics' END) AS only_one
    FROM planned_workouts pw
    JOIN planned_exercises pe ON pe.planned_workout_id = pw.id AND pe.deleted_at IS NULL
    JOIN exercise_catalog ec ON ec.id = pe.exercise_id
    WHERE pw.deleted_at IS NULL
    GROUP BY pw.plan_id
)
UPDATE training_plans p
SET primary_discipline = CASE WHEN d.n > 1 THEN 'mixed' ELSE d.only_one END
FROM disciplines d WHERE d.plan_id = p.id;

ALTER TABLE training_plans
    ALTER COLUMN lineage_id SET NOT NULL,
    ALTER COLUMN status SET DEFAULT 'current',
    ADD CONSTRAINT ck_training_plans_status CHECK (status IN ('current','superseded')),
    ADD CONSTRAINT ck_training_plans_kind CHECK (kind IN ('weekly','event')),
    -- ADR-035: an event plan needs its event date.
    ADD CONSTRAINT ck_training_plans_event_date CHECK (kind <> 'event' OR event_date IS NOT NULL),
    ADD CONSTRAINT ck_training_plans_event_name CHECK (length(event_name) BETWEEN 1 AND 120),
    ADD CONSTRAINT ck_training_plans_primary_discipline
        CHECK (primary_discipline IN ('calisthenics','running','gym','mixed')),
    ADD CONSTRAINT ck_training_plans_end_reason CHECK (end_reason IN ('completed','stopped')),
    -- An ended plan has a reason; reason and note only exist on an ended plan (docs/19 §4.3).
    ADD CONSTRAINT ck_training_plans_ended CHECK ((ended_at IS NULL) = (end_reason IS NULL)),
    ADD CONSTRAINT ck_training_plans_end_note CHECK (
        end_note IS NULL OR (ended_at IS NOT NULL AND length(end_note) <= 500));

-- ADR-036: one current, non-deleted revision per plan lineage.
CREATE UNIQUE INDEX ux_training_plans_one_current_per_lineage
    ON training_plans(user_id, lineage_id) WHERE status = 'current' AND deleted_at IS NULL;
CREATE INDEX idx_training_plans_lineage ON training_plans(user_id, lineage_id);

-- 4. lineage_id default and consistency for new revisions. v1 clients do not send
--    lineageId: a revision inherits its parent's lineage, a root plan starts its own.
CREATE FUNCTION training_plans_lineage() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    parent_lineage uuid;
BEGIN
    IF NEW.parent_plan_id IS NOT NULL THEN
        SELECT lineage_id INTO parent_lineage
        FROM training_plans WHERE id = NEW.parent_plan_id AND user_id = NEW.user_id;
    END IF;
    IF NEW.lineage_id IS NULL THEN
        NEW.lineage_id := COALESCE(parent_lineage, NEW.id);
    ELSIF parent_lineage IS NOT NULL AND parent_lineage <> NEW.lineage_id THEN
        RAISE EXCEPTION 'training_plan % has lineage % but its parent is in lineage %',
                NEW.id, NEW.lineage_id, parent_lineage
            USING ERRCODE = 'check_violation', CONSTRAINT = 'ck_training_plans_lineage_parent';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_training_plans_lineage
    BEFORE INSERT OR UPDATE OF lineage_id, parent_plan_id ON training_plans
    FOR EACH ROW EXECUTE FUNCTION training_plans_lineage();

-- 5. ADR-041 / BR-8: at most plan_count_limit non-deleted plans (lineages) per user.
--    A plan is non-deleted while its current revision is not deleted. Only commands that
--    add a live lineage are checked, so lowering the limit never blocks edits of existing plans.
CREATE FUNCTION training_plans_count_limit() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    live_plans int;
    plan_limit int;
BEGIN
    IF NEW.status <> 'current' OR NEW.deleted_at IS NOT NULL THEN
        RETURN NULL;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status = 'current' AND OLD.deleted_at IS NULL
       AND OLD.lineage_id = NEW.lineage_id THEN
        RETURN NULL;
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('plan_count:' || NEW.user_id::text, 0));
    plan_limit := cali_setting_int('plan_count_limit');
    SELECT count(DISTINCT lineage_id) INTO live_plans
    FROM training_plans
    WHERE user_id = NEW.user_id AND status = 'current' AND deleted_at IS NULL;
    IF live_plans > plan_limit THEN
        RAISE EXCEPTION 'plan_count_limit'
            USING ERRCODE = 'CA002',
                  DETAIL = format('user has %s non-deleted plans, limit is %s', live_plans, plan_limit);
    END IF;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_training_plans_count_limit
    AFTER INSERT OR UPDATE OF status, deleted_at, lineage_id ON training_plans
    FOR EACH ROW EXECUTE FUNCTION training_plans_count_limit();

-- 6. plan_activations (docs/19 §4, BR-1: local dates plus the IANA time zone they refer to).
--    to_date NULL = open-ended. end_reason records which lifecycle command closed it
--    (docs/19 §4.3): paused | completed | stopped | deleted.
CREATE TABLE plan_activations (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plan_lineage_id uuid NOT NULL,
    from_date date NOT NULL,
    to_date date,
    timezone text NOT NULL CHECK (length(timezone) BETWEEN 1 AND 64),
    end_reason text,
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    CONSTRAINT ck_plan_activations_dates CHECK (to_date IS NULL OR to_date >= from_date),
    CONSTRAINT ck_plan_activations_end_reason CHECK (end_reason IN ('paused','completed','stopped','deleted')),
    CONSTRAINT ck_plan_activations_end_reason_needs_to_date CHECK (end_reason IS NULL OR to_date IS NOT NULL),
    -- I1: activations of the same plan never overlap (inclusive local-date ranges).
    CONSTRAINT ex_plan_activations_no_overlap EXCLUDE USING gist (
        user_id WITH =,
        plan_lineage_id WITH =,
        daterange(from_date, COALESCE(to_date, 'infinity'::date), '[]') WITH &&
    ) WHERE (deleted_at IS NULL)
);
CREATE INDEX idx_plan_activations_user_lineage ON plan_activations(user_id, plan_lineage_id);
CREATE INDEX idx_plan_activations_user_update ON plan_activations(user_id, updated_at DESC);

-- 7. Lineage reference (no FK target exists for a lineage) and I2.
--    A lineage counts toward I2 while its current revision is neither deleted (ADR-040) nor
--    ended; this is the computed status of docs/19 §4.2, so a soft-deleted plan frees its slot
--    even before the client's closing activation update arrives.
CREATE FUNCTION plan_activations_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    active_limit int;
    worst_day date;
    worst_count int;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM training_plans
                   WHERE user_id = NEW.user_id AND lineage_id = NEW.plan_lineage_id) THEN
        RAISE EXCEPTION 'plan_activation % references unknown plan lineage %', NEW.id, NEW.plan_lineage_id
            USING ERRCODE = 'foreign_key_violation', CONSTRAINT = 'fk_plan_activations_lineage';
    END IF;
    IF NEW.deleted_at IS NOT NULL THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.deleted_at IS NULL
       AND OLD.plan_lineage_id = NEW.plan_lineage_id
       AND NEW.from_date >= OLD.from_date
       AND COALESCE(NEW.to_date, 'infinity'::date) <= COALESCE(OLD.to_date, 'infinity'::date) THEN
        RETURN NEW; -- shrinking or closing an activation can never break I2
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('plan_activation:' || NEW.user_id::text, 0));
    active_limit := cali_setting_int('active_plan_limit');

    -- The number of covering lineages can only rise at the start of an activation, so it is
    -- enough to check NEW.from_date and every live from_date inside NEW's range.
    WITH live AS (
        SELECT a.plan_lineage_id, a.from_date, COALESCE(a.to_date, 'infinity'::date) AS to_date
        FROM plan_activations a
        WHERE a.user_id = NEW.user_id AND a.deleted_at IS NULL AND a.id <> NEW.id
          AND EXISTS (SELECT 1 FROM training_plans p
                      WHERE p.user_id = a.user_id AND p.lineage_id = a.plan_lineage_id
                        AND p.status = 'current' AND p.deleted_at IS NULL AND p.ended_at IS NULL)
        UNION ALL
        SELECT NEW.plan_lineage_id, NEW.from_date, COALESCE(NEW.to_date, 'infinity'::date)
    ),
    candidate_days AS (
        SELECT from_date AS day FROM live
        WHERE from_date BETWEEN NEW.from_date AND COALESCE(NEW.to_date, 'infinity'::date)
    )
    SELECT d.day, count(DISTINCT l.plan_lineage_id) INTO worst_day, worst_count
    FROM candidate_days d
    JOIN live l ON d.day BETWEEN l.from_date AND l.to_date
    GROUP BY d.day
    ORDER BY count(DISTINCT l.plan_lineage_id) DESC, d.day
    LIMIT 1;

    IF worst_count > active_limit THEN
        RAISE EXCEPTION 'active_plan_limit'
            USING ERRCODE = 'CA001',
                  DETAIL = format('%s plans would be followed on %s, limit is %s', worst_count, worst_day, active_limit);
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_plan_activations_guard
    BEFORE INSERT OR UPDATE ON plan_activations
    FOR EACH ROW EXECUTE FUNCTION plan_activations_guard();

-- 8. Sync entity types gain plan_activation (OpenAPI SyncEntityType / ChangeEntityType).
--    The inline CHECKs from 001 have default names; replace them with named constraints.
ALTER TABLE sync_mutations DROP CONSTRAINT sync_mutations_entity_type_check;
ALTER TABLE sync_mutations ADD CONSTRAINT ck_sync_mutations_entity_type CHECK (entity_type IN (
    'training_plan','planned_workout','planned_exercise','workout_session','exercise_execution',
    'set_result','workout_note','plan_activation'));
ALTER TABLE sync_change_log DROP CONSTRAINT sync_change_log_entity_type_check;
ALTER TABLE sync_change_log ADD CONSTRAINT ck_sync_change_log_entity_type CHECK (entity_type IN (
    'training_plan','planned_workout','planned_exercise','workout_session','exercise_execution',
    'set_result','workout_note','plan_activation','ai_analysis','ai_recommendation'));

-- 9. BR-10: a lineage that was 'active' in v1 (and is not deleted) is "being followed".
--    fromDate = local date of its first workout session, else of the plan's creation, in the
--    user's time zone. The ADR-041 "no past start date" rule applies to new commands only.
--    At most active_plan_limit lineages per user (most recently updated first); others stay
--    without activation (computed status draft) and the user can start them again.
--    No backend sync implementation exists yet, so no change-log rows are appended here;
--    clients migrate their local snapshot themselves (IOS-011, BR-10).
WITH candidates AS (
    SELECT l.lineage_id, l.user_id, u.timezone,
           COALESCE(
               (SELECT min(ws.local_date)
                FROM workout_sessions ws
                JOIN planned_workouts pw ON pw.id = ws.planned_workout_id
                JOIN training_plans p ON p.id = pw.plan_id
                WHERE p.lineage_id = l.lineage_id AND ws.user_id = l.user_id AND ws.deleted_at IS NULL),
               (SELECT min(p.created_at AT TIME ZONE u.timezone)::date
                FROM training_plans p WHERE p.lineage_id = l.lineage_id)
           ) AS from_date,
           row_number() OVER (PARTITION BY l.user_id ORDER BY l.updated_at DESC, l.lineage_id) AS rn
    FROM con003_v1_active_lineage l
    JOIN users u ON u.id = l.user_id
    WHERE l.v1_status = 'active'
)
INSERT INTO plan_activations (id, user_id, plan_lineage_id, from_date, timezone)
SELECT gen_random_uuid(), user_id, lineage_id, from_date, timezone
FROM candidates
WHERE rn <= cali_setting_int('active_plan_limit');

DROP TABLE con003_v1_active_lineage;

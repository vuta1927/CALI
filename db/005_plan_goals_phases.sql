-- CON-005 Plan goals, phases and indicator definitions (docs/18 §6.1-§6.5, §8; docs/19 §4,
-- MP-03; ADR-044, ADR-047, ADR-048, ADR-049, ADR-051, ADR-053; proposed ADR-057, ADR-058, ADR-059).
-- New numbered migration (ADR-049): db/001..004 are never edited.
--   * indicator_definitions: server/portal-owned, versioned catalogue of goal indicators
--     (label, unit, step, applicable measurement types, aggregation max|sum, kind). Clients only
--     read it; it is delivered together with criteria_config (CON-008, ADR-058).
--   * plan_phases: ordered phases {name, weeks, description} of ONE plan revision (docs/19 §4:
--     phases belong to the revision, an AI proposal may change them).
--   * plan_goals: many small goals per plan LINEAGE (docs/19 §4: goals are not copied per revision).
--       - unlock_after_goal_id chains never form a cycle (docs/18 §6.3)
--         -> trigger (SQLSTATE CA004, MutationError code goal_unlock_cycle).
--       - <= server_settings.pinned_goal_limit (3, ADR-048) pinned non-deleted goals per lineage
--         (docs/18 §6.4) -> trigger (SQLSTATE CA003, MutationError code pinned_goal_limit).
--       - status 'achieved' needs achieved_at. The server never writes status: "achieved" is
--         always a user confirmation sent by the client (docs/18 §6.2, AGENTS rules 3 and 5).
--       - plan_lineage_id, indicator_id and exercise_id are immutable (ADR-047, ADR-057).
--   * plan_audit_events: append-only audit of every plan_goal / plan_phase write (ADR-059).
--   * Backfill of training_plan.goal: documented no-op (section 7).
-- Sync push must run in READ COMMITTED (default): the goal trigger re-reads after taking the
-- per-user advisory lock, so a concurrent pin or unlock edit committed first is always seen.

-- 1. Server-side limit for pinned goals (ADR-048: temporary default, kept configurable).
INSERT INTO server_settings (key, int_value) VALUES
    ('pinned_goal_limit', 3);   -- docs/18 §6.4 / ADR-048

-- 2. indicator_definitions (docs/18 §6.1, ADR-051). id is a stable slug and is never reused or
--    deleted (retire with enabled = false). kind, unit and aggregation are immutable because
--    existing goal targets are expressed in them; label, step, measurement types and enabled
--    may change and bump version.
CREATE TABLE indicator_definitions (
    id text PRIMARY KEY,
    version int NOT NULL DEFAULT 1 CHECK (version >= 1),
    kind text NOT NULL,
    label text NOT NULL,
    unit text NOT NULL,
    step numeric(12,3) NOT NULL,
    aggregation text NOT NULL,
    measurement_types text[] NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_indicator_definitions_id CHECK (id ~ '^[a-z][a-z0-9_]{0,63}$'),
    CONSTRAINT ck_indicator_definitions_kind
        CHECK (kind IN ('performance','adherence','volume','milestone','body')),
    CONSTRAINT ck_indicator_definitions_label CHECK (length(label) BETWEEN 1 AND 120),
    CONSTRAINT ck_indicator_definitions_unit CHECK (length(unit) <= 16),
    CONSTRAINT ck_indicator_definitions_step CHECK (step > 0),
    CONSTRAINT ck_indicator_definitions_aggregation CHECK (aggregation IN ('max','sum')),
    -- Measurement types of docs/18 §4 and docs/19 §4.1 (load arrives with CON-006).
    CONSTRAINT ck_indicator_definitions_measurement_types
        CHECK (measurement_types <@ ARRAY['hold','reps','load','distance','duration']::text[]),
    -- Exercise-based kinds pick an exercise filtered by measurement type (docs/18 §6.1);
    -- adherence and body indicators are not tied to an exercise.
    CONSTRAINT ck_indicator_definitions_measurement_types_kind
        CHECK ((kind IN ('adherence','body')) = (cardinality(measurement_types) = 0))
);

CREATE FUNCTION indicator_definitions_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'indicator_definition % cannot be deleted; set enabled = false', OLD.id
            USING ERRCODE = 'restrict_violation', CONSTRAINT = 'ck_indicator_definitions_never_deleted';
    END IF;
    IF NEW.id <> OLD.id OR NEW.kind <> OLD.kind OR NEW.unit <> OLD.unit
       OR NEW.aggregation <> OLD.aggregation THEN
        RAISE EXCEPTION 'indicator_definition %: id, kind, unit and aggregation are immutable', OLD.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'ck_indicator_definitions_immutable';
    END IF;
    IF (NEW.label, NEW.step, NEW.measurement_types, NEW.enabled)
       IS DISTINCT FROM (OLD.label, OLD.step, OLD.measurement_types, OLD.enabled) THEN
        NEW.version := OLD.version + 1;
        NEW.updated_at := now();
    ELSE
        NEW.version := OLD.version;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_indicator_definitions_guard
    BEFORE UPDATE OR DELETE ON indicator_definitions
    FOR EACH ROW EXECUTE FUNCTION indicator_definitions_guard();

-- Default set v1: exercise-based indicators whose aggregation is unambiguous (docs/18 §6.1,
-- §6.6). Adherence (ratio), body (CON-007), load (CON-006) and running pace (lower is better)
-- are left to later slices; the portal adds them (ADR-051).
INSERT INTO indicator_definitions (id, kind, label, unit, step, aggregation, measurement_types) VALUES
    ('best_hold_seconds',         'performance', 'Giữ lâu nhất',              'giây', 1, 'max', ARRAY['hold']),
    ('best_set_reps',             'performance', 'Set tốt nhất',              'lần',  1, 'max', ARRAY['reps']),
    ('milestone_hold_seconds',    'milestone',   'Lần đầu giữ được',          'giây', 1, 'max', ARRAY['hold']),
    ('milestone_reps',            'milestone',   'Lần đầu làm được',          'lần',  1, 'max', ARRAY['reps']),
    ('weekly_total_reps',         'volume',      'Tổng lần / tuần',           'lần',  1, 'sum', ARRAY['reps']),
    ('weekly_total_hold_seconds', 'volume',      'Tổng thời gian giữ / tuần', 'giây', 1, 'sum', ARRAY['hold']);

-- 3. plan_phases (docs/18 §6.5). Labels "Tuần a-b" and done / current / upcoming are computed,
--    never stored. A phase belongs to one revision: cloning a revision (MP-03, AI proposal)
--    creates new phase ids (ADR-057). order_index ties are broken by id.
CREATE TABLE plan_phases (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plan_id uuid NOT NULL,
    order_index int NOT NULL,
    name text NOT NULL,
    weeks int NOT NULL,
    description text,
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    CONSTRAINT ck_plan_phases_order_index CHECK (order_index >= 0),
    CONSTRAINT ck_plan_phases_name CHECK (length(name) BETWEEN 1 AND 120),
    CONSTRAINT ck_plan_phases_weeks CHECK (weeks BETWEEN 1 AND 52),
    CONSTRAINT ck_plan_phases_description CHECK (description IS NULL OR length(description) <= 500),
    CONSTRAINT fk_plan_phases_plan FOREIGN KEY (plan_id, user_id) REFERENCES training_plans(id, user_id)
);
CREATE INDEX idx_plan_phases_plan ON plan_phases(user_id, plan_id, order_index);
CREATE INDEX idx_plan_phases_user_update ON plan_phases(user_id, updated_at DESC);

CREATE FUNCTION plan_phases_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.plan_id <> OLD.plan_id THEN
        RAISE EXCEPTION 'plan_phase % cannot move to another plan revision', OLD.id
            USING ERRCODE = 'check_violation', CONSTRAINT = 'ck_plan_phases_plan_immutable';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_plan_phases_guard
    BEFORE UPDATE OF plan_id ON plan_phases
    FOR EACH ROW EXECUTE FUNCTION plan_phases_guard();

-- 4. plan_goals (docs/18 §6.1-§6.4). current is always computed on the device from saved
--    set results and is never stored (docs/18 §6.1). baseline is the client's snapshot: the
--    server never computes it (ADR-044). target is either target_value or {target_min,
--    target_max} (body goals use a range). scope_phase_id NULL = scope 'plan'.
CREATE TABLE plan_goals (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plan_lineage_id uuid NOT NULL,
    title text NOT NULL,
    indicator_id text NOT NULL CONSTRAINT fk_plan_goals_indicator REFERENCES indicator_definitions(id),
    exercise_id uuid CONSTRAINT fk_plan_goals_exercise REFERENCES exercise_catalog(id),
    baseline numeric(12,3),
    target_value numeric(12,3),
    target_min numeric(12,3),
    target_max numeric(12,3),
    scope_phase_id uuid,
    unlock_after_goal_id uuid,
    status text NOT NULL DEFAULT 'active',
    achieved_at timestamptz,
    pinned boolean NOT NULL DEFAULT false,
    note text,
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    CONSTRAINT ck_plan_goals_title CHECK (length(title) BETWEEN 1 AND 120),
    CONSTRAINT ck_plan_goals_values CHECK (
        (baseline IS NULL OR baseline >= 0) AND (target_value IS NULL OR target_value >= 0)
        AND (target_min IS NULL OR target_min >= 0) AND (target_max IS NULL OR target_max >= 0)),
    CONSTRAINT ck_plan_goals_target CHECK (
        (target_value IS NOT NULL AND target_min IS NULL AND target_max IS NULL)
        OR (target_value IS NULL AND target_min IS NOT NULL AND target_max IS NOT NULL
            AND target_min <= target_max)),
    CONSTRAINT ck_plan_goals_status
        CHECK (status IN ('active','reached','achieved','missed','archived')),
    -- "Achieved" is a user confirmation with its time (docs/18 §6.2). An archived goal keeps
    -- the achievedAt it had; no other status carries one.
    CONSTRAINT ck_plan_goals_achieved_at CHECK (
        (status <> 'achieved' OR achieved_at IS NOT NULL)
        AND (achieved_at IS NULL OR status IN ('achieved','archived'))),
    CONSTRAINT ck_plan_goals_note CHECK (note IS NULL OR length(note) <= 500),
    CONSTRAINT ck_plan_goals_unlock_not_self CHECK (unlock_after_goal_id IS NULL OR unlock_after_goal_id <> id),
    CONSTRAINT fk_plan_goals_scope_phase FOREIGN KEY (scope_phase_id, user_id)
        REFERENCES plan_phases(id, user_id),
    CONSTRAINT fk_plan_goals_unlock_after FOREIGN KEY (unlock_after_goal_id, user_id)
        REFERENCES plan_goals(id, user_id)
);
CREATE INDEX idx_plan_goals_lineage ON plan_goals(user_id, plan_lineage_id);
CREATE INDEX idx_plan_goals_unlock_after ON plan_goals(user_id, unlock_after_goal_id)
    WHERE unlock_after_goal_id IS NOT NULL;
CREATE INDEX idx_plan_goals_user_update ON plan_goals(user_id, updated_at DESC);

-- 5. Goal guard: lineage reference, immutable fields, same-lineage scope / unlock references,
--    no unlock cycle (CA004) and the pinned limit (CA003). Serialised per user with an advisory
--    lock so two concurrent pushes cannot each add the 3rd pin or close a cycle from both ends.
--    A scope phase that is soft-deleted is accepted: the client shows the goal as scope 'plan'
--    (docs/18 §6.5). The unlock graph includes soft-deleted goals so a restore cannot close a
--    cycle; the client clears unlockAfter on dependents when it deletes a goal.
CREATE FUNCTION plan_goals_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    other_lineage uuid;
    has_cycle boolean;
    pin_limit int;
    pinned_count int;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.plan_lineage_id <> OLD.plan_lineage_id THEN
            RAISE EXCEPTION 'plan_goal % cannot move to another plan', OLD.id
                USING ERRCODE = 'check_violation', CONSTRAINT = 'ck_plan_goals_lineage_immutable';
        END IF;
        -- ADR-047 / ADR-057: changing the exercise or the indicator archives the goal and
        -- creates a new one, so progress history keeps its meaning.
        IF NEW.indicator_id <> OLD.indicator_id THEN
            RAISE EXCEPTION 'plan_goal %: indicator_id is immutable', OLD.id
                USING ERRCODE = 'check_violation', CONSTRAINT = 'ck_plan_goals_indicator_immutable';
        END IF;
        IF NEW.exercise_id IS DISTINCT FROM OLD.exercise_id THEN
            RAISE EXCEPTION 'plan_goal %: exercise_id is immutable', OLD.id
                USING ERRCODE = 'check_violation', CONSTRAINT = 'ck_plan_goals_exercise_immutable';
        END IF;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM training_plans
                   WHERE user_id = NEW.user_id AND lineage_id = NEW.plan_lineage_id) THEN
        RAISE EXCEPTION 'plan_goal % references unknown plan lineage %', NEW.id, NEW.plan_lineage_id
            USING ERRCODE = 'foreign_key_violation', CONSTRAINT = 'fk_plan_goals_lineage';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('plan_goal:' || NEW.user_id::text, 0));

    -- A missing phase or goal is reported by the composite FKs (dependency_missing).
    IF NEW.scope_phase_id IS NOT NULL THEN
        SELECT p.lineage_id INTO other_lineage
        FROM plan_phases ph
        JOIN training_plans p ON p.id = ph.plan_id AND p.user_id = ph.user_id
        WHERE ph.id = NEW.scope_phase_id AND ph.user_id = NEW.user_id;
        IF FOUND AND other_lineage <> NEW.plan_lineage_id THEN
            RAISE EXCEPTION 'plan_goal % is scoped to phase % of another plan', NEW.id, NEW.scope_phase_id
                USING ERRCODE = 'check_violation', CONSTRAINT = 'ck_plan_goals_scope_same_lineage';
        END IF;
    END IF;

    IF NEW.unlock_after_goal_id IS NOT NULL THEN
        SELECT plan_lineage_id INTO other_lineage
        FROM plan_goals WHERE id = NEW.unlock_after_goal_id AND user_id = NEW.user_id;
        IF FOUND AND other_lineage <> NEW.plan_lineage_id THEN
            RAISE EXCEPTION 'plan_goal % unlocks after goal % of another plan', NEW.id, NEW.unlock_after_goal_id
                USING ERRCODE = 'check_violation', CONSTRAINT = 'ck_plan_goals_unlock_same_lineage';
        END IF;

        IF TG_OP = 'INSERT' OR NEW.unlock_after_goal_id IS DISTINCT FROM OLD.unlock_after_goal_id THEN
            -- Walk the chain from the new predecessor using stored rows (NEW replaces its own
            -- stored row); reaching NEW.id means the edit closes a cycle. UNION stops on repeats.
            WITH RECURSIVE chain(goal_id) AS (
                SELECT NEW.unlock_after_goal_id
                UNION
                SELECT g.unlock_after_goal_id
                FROM chain c
                JOIN plan_goals g ON g.id = c.goal_id AND g.user_id = NEW.user_id
                WHERE g.id <> NEW.id AND g.unlock_after_goal_id IS NOT NULL
            )
            SELECT EXISTS (SELECT 1 FROM chain WHERE goal_id = NEW.id) INTO has_cycle;
            IF has_cycle THEN
                RAISE EXCEPTION 'goal_unlock_cycle'
                    USING ERRCODE = 'CA004',
                          DETAIL = format('plan_goal %s unlocking after %s would form a cycle',
                                          NEW.id, NEW.unlock_after_goal_id);
            END IF;
        END IF;
    END IF;

    -- Only a write that adds a pin is checked, so lowering the limit never blocks other edits.
    IF NEW.pinned AND NEW.deleted_at IS NULL
       AND (TG_OP = 'INSERT' OR NOT OLD.pinned OR OLD.deleted_at IS NOT NULL) THEN
        pin_limit := cali_setting_int('pinned_goal_limit');
        SELECT count(*) INTO pinned_count
        FROM plan_goals
        WHERE user_id = NEW.user_id AND plan_lineage_id = NEW.plan_lineage_id
          AND pinned AND deleted_at IS NULL AND id <> NEW.id;
        IF pinned_count >= pin_limit THEN
            RAISE EXCEPTION 'pinned_goal_limit'
                USING ERRCODE = 'CA003',
                      DETAIL = format('plan lineage %s already has %s pinned goals, limit is %s',
                                      NEW.plan_lineage_id, pinned_count, pin_limit);
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_plan_goals_guard
    BEFORE INSERT OR UPDATE ON plan_goals
    FOR EACH ROW EXECUTE FUNCTION plan_goals_guard();

-- 6. Audit (docs/18 §8 "có audit"; ADR-059). Every insert and every real change of a goal or
--    phase appends the old and new row. mutation_id is taken from the transaction setting
--    cali.mutation_id when the sync handler sets it (SET LOCAL); otherwise NULL. The table is
--    append-only; rows disappear only with the owning user (account deletion, ON DELETE CASCADE).
--    The user-facing change log (MP-14) and a retention policy are later slices.
CREATE TABLE plan_audit_events (
    id bigserial PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    entity_type text NOT NULL,
    entity_id uuid NOT NULL,
    entity_version bigint NOT NULL,
    operation text NOT NULL,
    old_row jsonb,
    new_row jsonb NOT NULL,
    mutation_id uuid,
    changed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_plan_audit_events_entity_type CHECK (entity_type IN ('plan_goal','plan_phase')),
    CONSTRAINT ck_plan_audit_events_operation CHECK (operation IN ('insert','update','delete','restore')),
    CONSTRAINT ck_plan_audit_events_old_row CHECK ((operation = 'insert') = (old_row IS NULL))
);
CREATE INDEX idx_plan_audit_events_entity ON plan_audit_events(user_id, entity_type, entity_id, id);

CREATE FUNCTION plan_audit_capture() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    op text;
    raw_mutation text := current_setting('cali.mutation_id', true);
BEGIN
    IF TG_OP = 'INSERT' THEN
        op := 'insert';
    ELSIF OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL THEN
        op := 'delete';
    ELSIF OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL THEN
        op := 'restore';
    ELSE
        op := 'update';
    END IF;
    INSERT INTO plan_audit_events (user_id, entity_type, entity_id, entity_version, operation,
                                   old_row, new_row, mutation_id)
    VALUES (NEW.user_id, TG_ARGV[0], NEW.id, NEW.version, op,
            CASE WHEN TG_OP = 'UPDATE' THEN to_jsonb(OLD) END,
            to_jsonb(NEW),
            CASE WHEN raw_mutation ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                 THEN raw_mutation::uuid END);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_plan_goals_audit_insert
    AFTER INSERT ON plan_goals
    FOR EACH ROW EXECUTE FUNCTION plan_audit_capture('plan_goal');
CREATE TRIGGER trg_plan_goals_audit_update
    AFTER UPDATE ON plan_goals
    FOR EACH ROW WHEN (OLD.* IS DISTINCT FROM NEW.*) EXECUTE FUNCTION plan_audit_capture('plan_goal');
CREATE TRIGGER trg_plan_phases_audit_insert
    AFTER INSERT ON plan_phases
    FOR EACH ROW EXECUTE FUNCTION plan_audit_capture('plan_phase');
CREATE TRIGGER trg_plan_phases_audit_update
    AFTER UPDATE ON plan_phases
    FOR EACH ROW WHEN (OLD.* IS DISTINCT FROM NEW.*) EXECUTE FUNCTION plan_audit_capture('plan_phase');

CREATE FUNCTION plan_audit_events_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND NOT EXISTS (SELECT 1 FROM users WHERE id = OLD.user_id) THEN
        RETURN OLD; -- cascade from account deletion
    END IF;
    RAISE EXCEPTION 'plan_audit_events is append-only'
        USING ERRCODE = 'restrict_violation', CONSTRAINT = 'ck_plan_audit_events_append_only';
END $$;

CREATE TRIGGER trg_plan_audit_events_append_only
    BEFORE UPDATE OR DELETE ON plan_audit_events
    FOR EACH ROW EXECUTE FUNCTION plan_audit_events_append_only();

-- 7. Backfill of the single training_plan.goal (docs/18 §8 "thay cho training_plan.goal đơn"):
--    no migration 001..004 ever created a goal column on training_plans and no wire payload
--    carries one, so there is nothing to copy. Intentionally no statement here; a plan without
--    goals is valid.

-- 8. Sync entity types gain plan_goal and plan_phase (OpenAPI SyncEntityType / ChangeEntityType).
ALTER TABLE sync_mutations DROP CONSTRAINT ck_sync_mutations_entity_type;
ALTER TABLE sync_mutations ADD CONSTRAINT ck_sync_mutations_entity_type CHECK (entity_type IN (
    'training_plan','planned_workout','planned_exercise','workout_session','exercise_execution',
    'set_result','workout_note','plan_activation','plan_phase','plan_goal'));
ALTER TABLE sync_change_log DROP CONSTRAINT ck_sync_change_log_entity_type;
ALTER TABLE sync_change_log ADD CONSTRAINT ck_sync_change_log_entity_type CHECK (entity_type IN (
    'training_plan','planned_workout','planned_exercise','workout_session','exercise_execution',
    'set_result','workout_note','plan_activation','plan_phase','plan_goal',
    'ai_analysis','ai_recommendation'));

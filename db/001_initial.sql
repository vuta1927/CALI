-- CALI PostgreSQL baseline migration v1.0
-- Intended for PostgreSQL 16+. Review via real Postgres migration test before release.
-- All timestamps are UTC timestamptz. Client UUIDs preserve offline identity.
-- Sync feed sequence must be allocated PER USER WITH ROW LOCK, not sequence nextval.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    apple_subject text UNIQUE,
    display_name text,
    timezone text NOT NULL DEFAULT 'Asia/Bangkok',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE devices (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_name text,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id)
);
CREATE INDEX idx_devices_owner ON devices(user_id);

CREATE TABLE exercise_catalog (
    id uuid PRIMARY KEY,
    slug text NOT NULL UNIQUE,
    name text NOT NULL,
    exercise_type text NOT NULL CHECK (exercise_type IN ('static_hold','reps','timed_reps','interval','skill_attempt')),
    equipment jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(equipment) = 'array'),
    cues jsonb NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(cues) = 'array'),
    catalog_version int NOT NULL DEFAULT 1 CHECK (catalog_version >= 1),
    is_published boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE exercise_media (
    id uuid PRIMARY KEY,
    exercise_id uuid NOT NULL REFERENCES exercise_catalog(id) ON DELETE CASCADE,
    kind text NOT NULL CHECK (kind IN ('thumbnail','poster','preview','tutorial','correct','incorrect')),
    content_version int NOT NULL CHECK (content_version >= 1),
    storage_key text NOT NULL,
    mime_type text NOT NULL,
    sha256 char(64) NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    size_bytes bigint CHECK (size_bytes >= 0),
    duration_ms bigint CHECK (duration_ms >= 0),
    license text NOT NULL,
    attribution text,
    is_public boolean NOT NULL DEFAULT false,
    reviewed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (exercise_id, kind, content_version)
);
CREATE INDEX idx_exercise_media_exercise ON exercise_media(exercise_id);

CREATE TABLE training_plans (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    title text NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
    revision int NOT NULL DEFAULT 1 CHECK (revision >= 1),
    parent_plan_id uuid,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','archived')),
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    FOREIGN KEY (parent_plan_id, user_id) REFERENCES training_plans(id, user_id)
);
CREATE INDEX idx_plans_user_update ON training_plans(user_id, updated_at DESC);

CREATE TABLE planned_workouts (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    plan_id uuid NOT NULL,
    weekday int NOT NULL CHECK (weekday BETWEEN 1 AND 7),
    title text NOT NULL DEFAULT '',
    order_index int NOT NULL DEFAULT 0 CHECK (order_index >= 0),
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    FOREIGN KEY (plan_id, user_id) REFERENCES training_plans(id, user_id)
);
CREATE INDEX idx_workouts_plan_order ON planned_workouts(plan_id, weekday, order_index);

CREATE TABLE planned_exercises (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    planned_workout_id uuid NOT NULL,
    exercise_id uuid NOT NULL REFERENCES exercise_catalog(id),
    order_index int NOT NULL CHECK (order_index >= 0),
    set_count int NOT NULL CHECK (set_count BETWEEN 1 AND 20),
    target jsonb NOT NULL CHECK (jsonb_typeof(target) = 'object'),
    rest_seconds int NOT NULL CHECK (rest_seconds BETWEEN 0 AND 3600),
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    FOREIGN KEY (planned_workout_id, user_id) REFERENCES planned_workouts(id, user_id)
);
CREATE INDEX idx_exercises_workout_order ON planned_exercises(planned_workout_id, order_index);

CREATE TABLE workout_sessions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    planned_workout_id uuid,
    local_date date NOT NULL,
    timezone text NOT NULL,
    status text NOT NULL CHECK (status IN ('active','completed','abandoned')),
    phase text NOT NULL CHECK (phase IN ('ready','pre_countdown','exercising','awaiting_result','resting','paused','reviewing_summary','completed','abandoned')),
    started_at timestamptz NOT NULL,
    finished_at timestamptz,
    phase_started_at timestamptz,
    phase_deadline_at timestamptz,
    current_execution_id uuid,
    current_set_index int CHECK (current_set_index >= 1),
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    FOREIGN KEY (planned_workout_id, user_id) REFERENCES planned_workouts(id, user_id),
    CHECK (finished_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX idx_sessions_user_start ON workout_sessions(user_id, started_at DESC);
-- One active session per user for MVP. If multi-device simultaneous workouts are
-- supported later, replace this policy with device-owned active session model.
CREATE UNIQUE INDEX ux_session_one_active_per_user
    ON workout_sessions(user_id) WHERE status = 'active' AND deleted_at IS NULL;

CREATE TABLE exercise_executions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id uuid NOT NULL,
    planned_exercise_id uuid,
    exercise_id uuid NOT NULL REFERENCES exercise_catalog(id),
    order_index int NOT NULL CHECK (order_index >= 0),
    prescribed_snapshot jsonb NOT NULL CHECK (jsonb_typeof(prescribed_snapshot) = 'object'),
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    FOREIGN KEY (session_id, user_id) REFERENCES workout_sessions(id, user_id),
    FOREIGN KEY (planned_exercise_id, user_id) REFERENCES planned_exercises(id, user_id)
);
CREATE INDEX idx_executions_session ON exercise_executions(session_id, order_index);

ALTER TABLE workout_sessions
    ADD CONSTRAINT fk_session_current_execution
    FOREIGN KEY (current_execution_id, user_id) REFERENCES exercise_executions(id, user_id)
    DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE set_results (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    execution_id uuid NOT NULL,
    set_index int NOT NULL CHECK (set_index BETWEEN 1 AND 100),
    status text NOT NULL CHECK (status IN ('completed','failed','skipped')),
    prescribed_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
    actual_reps int CHECK (actual_reps >= 0),
    actual_hold_ms bigint CHECK (actual_hold_ms >= 0),
    actual_work_ms bigint CHECK (actual_work_ms >= 0),
    actual_rest_ms bigint CHECK (actual_rest_ms >= 0),
    rpe int CHECK (rpe BETWEEN 1 AND 10),
    note text,
    confirmed_at timestamptz NOT NULL,
    revision int NOT NULL DEFAULT 1 CHECK (revision >= 1),
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    UNIQUE (execution_id, set_index),
    FOREIGN KEY (execution_id, user_id) REFERENCES exercise_executions(id, user_id)
);
CREATE INDEX idx_set_results_execution ON set_results(execution_id, set_index);

CREATE TABLE workout_notes (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id uuid NOT NULL,
    note_text text NOT NULL,
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (id, user_id),
    FOREIGN KEY (session_id, user_id) REFERENCES workout_sessions(id, user_id)
);

-- Do NOT use a global PostgreSQL sequence to allocate cursor events: transaction
-- commits may be reordered, resulting in missing updates if cursor overtakes them.
-- In each user-affecting write transaction:
-- 1. INSERT ... ON CONFLICT DO NOTHING into user_sync_state
-- 2. UPDATE user_sync_state SET last_seq = last_seq + 1 WHERE user_id = ...
--    RETURNING last_seq; row lock serializes that user's change writes.
-- 3. INSERT sync_change_log(user_id,seq,...) BEFORE commit.
CREATE TABLE user_sync_state (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    last_seq bigint NOT NULL DEFAULT 0 CHECK (last_seq >= 0)
);
CREATE TABLE sync_mutations (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    mutation_id uuid NOT NULL,
    device_id uuid NOT NULL,
    entity_type text NOT NULL,
    entity_id uuid NOT NULL,
    action text NOT NULL CHECK (action IN ('upsert','delete')),
    base_version bigint NOT NULL CHECK (base_version >= 0),
    status text NOT NULL CHECK (status IN ('applied','conflict','rejected')),
    receipt jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, mutation_id)
);
CREATE INDEX idx_mutations_user_created ON sync_mutations(user_id, created_at DESC);
CREATE TABLE sync_change_log (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    seq bigint NOT NULL CHECK (seq >= 1),
    entity_type text NOT NULL,
    entity_id uuid NOT NULL,
    operation text NOT NULL CHECK (operation IN ('upsert','delete')),
    server_version bigint NOT NULL CHECK (server_version >= 1),
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    changed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, seq)
);
CREATE INDEX idx_change_log_entity ON sync_change_log(user_id, entity_type, entity_id);

CREATE TABLE ai_analyses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id uuid NOT NULL,
    session_version bigint NOT NULL CHECK (session_version >= 1),
    algorithm_version text NOT NULL DEFAULT '1.0',
    status text NOT NULL CHECK (status IN ('queued','running','completed','failed','superseded')),
    model_provider text,
    model_name text,
    result jsonb,
    failure_reason text,
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (session_id, session_version, algorithm_version),
    UNIQUE (id, user_id),
    FOREIGN KEY (session_id, user_id) REFERENCES workout_sessions(id, user_id)
);
CREATE INDEX idx_analyses_user_updated ON ai_analyses(user_id, updated_at DESC);

CREATE TABLE ai_recommendations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    analysis_id uuid NOT NULL,
    plan_id uuid,
    exercise_id uuid REFERENCES exercise_catalog(id),
    action text NOT NULL CHECK (action IN ('maintain','reduce','increase_hold','increase_reps','change_progression','needs_more_data')),
    proposed_target jsonb,
    rationale text NOT NULL,
    decision text NOT NULL DEFAULT 'proposed' CHECK (decision IN ('proposed','accepted','rejected','superseded')),
    decided_at timestamptz,
    resulting_plan_id uuid,
    version bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (id, user_id),
    FOREIGN KEY (analysis_id, user_id) REFERENCES ai_analyses(id, user_id),
    FOREIGN KEY (plan_id, user_id) REFERENCES training_plans(id, user_id),
    FOREIGN KEY (resulting_plan_id, user_id) REFERENCES training_plans(id, user_id)
);
CREATE INDEX idx_recommendations_analysis ON ai_recommendations(analysis_id);

CREATE TABLE ai_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    analysis_id uuid NOT NULL UNIQUE,
    state text NOT NULL DEFAULT 'queued' CHECK (state IN ('queued','running','completed','failed')),
    attempts int NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    leased_until timestamptz,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (analysis_id, user_id) REFERENCES ai_analyses(id, user_id)
);
CREATE INDEX idx_ai_jobs_available ON ai_jobs(state, available_at);

-- Recommended later migrations / services:
-- 1. Server immutable audit table for edited set revisions + plan decision history.
-- 2. User data export/delete endpoints and retention policy.
-- 3. Composite per-user consistency validation for sync payload references.
-- 4. Media signed URL + ingestion workflow.

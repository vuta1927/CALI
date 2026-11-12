-- CON-011 Per-workout transition rest (docs/07, docs/08; ADR-079).
-- New numbered migration (ADR-049): db/001..011 are never edited.
-- Backward compatible: adds one nullable column; existing rows stay NULL.
--   * planned_workouts.rest_between_exercises_seconds: rest after the last set of one exercise and
--     before the first set of the next exercise in the same workout. NULL means "client default"
--     (60 s, decided by the client, not stored). Between-set rest stays planned_exercises.rest_seconds.
-- Sync payload field: planned_workout_payload.restBetweenExercisesSeconds (optional, nullable).

ALTER TABLE planned_workouts
    ADD COLUMN rest_between_exercises_seconds integer NULL,
    ADD CONSTRAINT ck_planned_workouts_rest_between_exercises
        CHECK (rest_between_exercises_seconds BETWEEN 0 AND 3600);

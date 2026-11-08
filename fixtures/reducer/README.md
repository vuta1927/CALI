# Reducer conformance vectors (CON-002) — READY FOR REVIEW

> **Status: ready for review (2026-11-08); CON-002 is NOT approved yet.** These vectors encode the `CaliDomain` reducer's
> current interpretation of `docs/03-workout-domain.md`. Where docs/03 was ambiguous the
> chosen behavior is listed as an open CON-002 question in the I1a PR. Do not treat these files as
> a frozen contract until CON-002 is approved; changes to them require the same review as a
> contract change (AGENTS.md "Contracts first").

Each `*.json` file is one scenario, replayed step by step against a fresh (nil) session by
`ios/Packages/CaliDomain/Tests/CaliDomainTests/ReducerFixtureTests.swift`. They are deliberately
language-neutral so a future backend or tooling implementation can run the same vectors.

## Coverage (ready-for-review set, 2026-11-08)

All files were re-read against `docs/03-workout-domain.md` §4 and ADR-016..033 (docs/15); no
disagreement between the vectors, the reducer and docs/03 was found, so no reducer change was made.

| File | Covers |
|---|---|
| `happy_path_static_hold.json` | Static hold 12 s x2, 90 s rest: countdown, deadline reconcile, confirm, rest expiry, manual stop, summary, explicit finish. |
| `deadline_while_suspended.json` | Edge #3 / ADR-009: hold deadline passes while locked; no suggested actual and no set result until the user confirms. |
| `rest_extend_never_autostarts.json` | Edge #5: repeated +30 s extensions; rest expiring while locked leads to READY, never EXERCISING. |
| `pause_resume.json` | PAUSED has no moving deadline; resume recomputes from frozen remainder. |
| `pause_resume_edge_cases.json` | Pause/resume rejected in every other phase; reps target without deadline; multi-cycle measured time; 0.5 s remainder; no SkipSet while PAUSED. |
| `skip_set.json` | SkipSet from READY/EXERCISING/AWAITING_RESULT, no rest after a skip, next exercise and summary, rejected in PAUSED/RESTING, duplicate/mismatch/over-long reason, finish with skipped sets. |
| `abandon_and_terminal.json` | Abandon from PRE_COUNTDOWN; a terminal session rejects commands, reconcile is a no-op, a new session may follow. |
| `abandon_from_every_phase.json` | Abandon from READY, PRE_COUNTDOWN, EXERCISING, PAUSED, AWAITING_RESULT, RESTING, REVIEWING_SUMMARY (ADR-029); rejected when abandoned/completed or reason too long. |
| `duplicate_confirm.json` | Edge #1: double tap / widget race; a second resolution of the same set is rejected and never double-counts. |
| `illegal_transitions.json` | Representative rejections; a rejected command never changes state or revision. |
| `clock_jump_during_rest.json` | Edge #4: wall clock changed during rest; transitions withheld with `clock_jump_detected` until acknowledged. |
| `stale_session_recovery.json` | Edge #7: app killed mid-set, reopened 7 h later; recovery prompt, nothing auto-completed. |
| `load_reps.json` | CON-006 / ADR-062: load target 5 x 60 kg, no deadline, confirm requires `actualReps` + `actualLoadKg` (max 2 decimals, rejected not rounded), lighter set recorded as given. |

## Format

```jsonc
{
  "name": "happy_path_static_hold",
  "description": "…",
  "steps": [
    {
      "now": "2026-11-07T08:00:05Z",              // injected wall-clock time (UTC ISO-8601, optional .SSS)
      "command": { "type": "start_set", "commandId": "…", "countdownSeconds": 3 },
      // OR, instead of "command":
      "reconcile": { "previousNow": "…", "monotonicElapsed": 3.5, "acknowledgeClockJump": false },
      "expect": {
        "error": "invalid_transition",           // DomainError code; absent ⇒ command must succeed
        "phase": "pre_countdown", "status": "active", "revision": 2,
        "events": ["phase_changed", "deadline_changed"],   // exact, ordered event codes
        "signals": ["clock_jump_detected"],                // reconcile signal codes
        "currentExecutionIndex": 0, "currentSetIndex": 1,
        "confirmedSetCount": 0, "skippedSetCount": 0,
        "phaseDeadlineAt": "2026-11-07T08:00:08Z",          // explicit null ⇒ must be nil
        "pendingMeasuredElapsedMs": 12000,
        "pendingSuggestedActualMs": null                    // explicit null ⇒ no suggestion
      }
    }
  ]
}
```

Rules:

- Absent `expect` keys are not checked. After a rejected command the state checks apply to the
  unchanged prior state (rejections must never mutate state or `revision`).
- Commands use the flat `type`-discriminated form of `CaliDomain.Command`. All defaults
  (`countdownSeconds`, `seconds`, `status`) are written explicitly so vectors do not depend on
  Swift defaults.
- Every step also asserts `SessionState.invariantViolations == []`.
- `commandId` dedupe (returning the stored transition for a replayed command) is **not** part of
  the pure reducer; it belongs to CaliCore's command journal. A replayed command here is expected
  to be rejected (e.g. `duplicate_set_resolution`).

## Running

The test resolves this directory relative to its own source path, so mount the **repo root**
(mounting only the package directory would hide `fixtures/`):

```sh
docker run --rm -v "$PWD:/src" -w /src/ios/Packages/CaliDomain swift:6.2-noble swift test
```

Alternatively set `CALI_REDUCER_FIXTURES_DIR` to an absolute path. A missing directory fails the
test suite loudly; it is never skipped.

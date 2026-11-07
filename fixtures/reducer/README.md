# Reducer conformance vectors (CON-002) — DRAFT

> **Status: DRAFT, pending POC-002 review.** These vectors encode the `CaliDomain` reducer's
> current interpretation of `docs/03-workout-domain.md`. Where docs/03 was ambiguous the
> chosen behavior is listed as an open CON-002 question in the I1a PR. Do not treat these files as
> a frozen contract until CON-002 is approved; changes to them require the same review as a
> contract change (AGENTS.md "Contracts first").

Each `*.json` file is one scenario, replayed step by step against a fresh (nil) session by
`ios/Packages/CaliDomain/Tests/CaliDomainTests/ReducerFixtureTests.swift`. They are deliberately
language-neutral so a future backend or tooling implementation can run the same vectors.

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

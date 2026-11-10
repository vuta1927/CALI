# IOS-004h evidence: player hardening on CaliCore

Date: 2026-11-10. No code, API or contract change; tests and a measurement only.

## Automated
- App: 69 tests, 0 failures on the iPhone 15 (signed build, commit `df63dc2` plus these tests), none skipped; on the unsigned simulator 1 is skipped (Keychain). 7 new in `PlayerHardeningTests`:
  - T-01 poster (placeholder symbol), target and four sets, no network.
  - T-03 the hold target passes: phase `awaitingResult`, no set result, no outbox mutation; the answer the user gives is what is stored (ADR-009).
  - T-04 double confirm: one set result, one `set_result` mutation.
  - T-06 full workout offline: 3 set results, 3 `set_result` + 2 `workout_session` mutations, all `pending`.
  - Rest +30 s moves the deadline by exactly 30 s.
  - Abandon keeps the confirmed set, the session is in history as abandoned, a new workout can start.
  - Confirm-set budget.
- Domain and coordinator coverage already exists from IOS-001 (`testT04...`, `testT09...`, `EdgeCaseTests`).

## Measurement: confirm-set local write (docs/14, < 100 ms p95)
On-disk WAL database, 60 consecutive confirms:
- iPhone 15: p50 5.1 ms, p95 5.5 ms, max 5.6 ms (budget < 100 ms p95: met).
- Simulator: p50 5.7 ms, p95 6.0 ms, max 34 ms.

## Not covered
- Manual device matrix for the player (lock/unlock, screen off, flight mode, force quit) and device evidence (screen recording, Diagnostics export) per docs/16. The measurement above is the automated test on the device, not a hands-on session.
- An earlier device run was cut short when the iPhone went offline; this run is the complete one.
- T-02, T-05, T-11, T-12 belong to IOS-005h (Live Activity, notifications).

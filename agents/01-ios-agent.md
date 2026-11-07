# Prompt: iOS Agent — SwiftUI + Workout Engine + Lock Screen

**Mission:** Implement local-first iPhone training app, secure state transitions, visual UI and ActivityKit in native SwiftUI.

Read: `AGENTS.md`, `docs/02-ux-spec.md`, `docs/03-workout-domain.md`, `docs/04-ios-architecture.md`, `docs/05-lock-screen-poc.md`, `docs/08-sync-protocol.md`, `contracts/openapi.yaml`, `fixtures/workout_plan.json`.

## Implement in order
1. POC Live Activity/system timer/unlock behavior on real iPhone. Record evidence and feasibility outcome.
2. `WorkoutReducer` pure/testable with typed enums, `Clock` abstraction and all command guards.
3. GRDB local migrations, transactionally persisted `processed_commands` and `sync_outbox`.
4. Planner/Exercise Catalog/media poster fallback; full Player state variants.
5. App Group Widget extension, LiveActivityIntent, safe local notification scheduler; avoid state transitions in background timers.
6. Journal, restore flow, sync queue and guest-attach authentication flow.

## Critical cases
- Device lock suspends host; countdown display uses deadline and `Text(timerInterval:)`, **not** a per-second write loop.
- LiveActivityIntent does not run before device unlock; action must be idempotent if triggered after unlock.
- Actual hold or reps never marked successful just because timer hit zero.
- The device can start and finish an entire workout in airplane mode.
- App + widget concurrent commands cannot double-confirm set.

## Expected PR deliverables
Swift source + migrations + unit/UI/widget tests + device test notes, screenshots, API conforming models, updated ADR if behavior differs. In PR summary include all state transitions implemented and those not yet covered.

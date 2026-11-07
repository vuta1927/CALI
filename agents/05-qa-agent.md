# Prompt: QA Agent — Cross-platform, Offline and Device Acceptance

**Mission:** Prove data never disappears, timers don't fabricate results, sync is idempotent and Lock Screen UX complies with iOS.

Read: `docs/12-qa-acceptance.md`, `docs/03-workout-domain.md`, `docs/05-lock-screen-poc.md`, `docs/08-sync-protocol.md`, `tests/acceptance.feature`.

## First actions
1. Translate each Gherkin scenario to automated tests where possible.
2. Build a clock-injected reducer test harness and network fault proxy for sync.
3. Prepare device matrix and evidence template for Lock Screen.
4. Define baseline screenshots for player/rest/preview at normal and large text sizes.

## Mandatory evidence
- 10x mutation retry → one set result on server.
- kill process after local write → no data loss.
- no internet → full workout + journal.
- clock/timezone shift → no invented actual result.
- actual locked phone interaction requires authentication/unlock.
- AI safety test blocks escalation with a pain flag; no direct plan changes.

## DoD
Report status by test ID (pass/fail/blocked), reproduction instructions, device/iOS version, logs without PII, release recommendation.

# IOS-008 evidence (Sign in with Apple client, guest attach)

Date: 2026-11-10. Fake tokens and `URLProtocol` stubs only: no Apple account, no backend. `TODO(BE-004-APPLE)`.

| Check | Result |
| --- | --- |
| CaliCore `swift test` | 134 tests, 0 failures (15 in `AuthTests`) |
| Nonce: lowercase hex SHA-256, random 43 chars, Apple gets the hash and the API the raw string, one use | `AuthTests`, `AuthServiceTests` |
| Tokens/session never print their secrets | `AuthTests.testTokensNeverPrintTheirSecrets` |
| Refresh: relaunch + near expiry, fresh token not refreshed, 6 concurrent callers = 1 request, 401 ends the session, offline keeps it, sign-out during a refresh does not bring the session back | `AuthTests` |
| HTTP: bodies (`identityToken`, `nonce`, `deviceId`), no Authorization header, 401/429/503 mapping | `AuthTests.testHttpBodiesAndStatusMapping` |
| Account scope: first sign-in asks, same account resumes, another account refused, keep-on-device parks outbox as `guest_local` and clears `dirty`, attach keeps UUIDs, delete wipes outbox/versions/cursor/inbox/body/goals/history | `AuthTests` |
| App: no server address, scopes empty, first sign-in asks and sync waits, interrupted sign-in asks again, other account refused with tokens dropped, sentences, sync configured only after the answer, `stopAndWait` | `AuthServiceTests` (10) |
| Simulator app tests | 83 tests, 2 skipped (Keychain), 0 failures; Release build compiles |
| iPhone 15 (signed) | app 83 of 83, 0 skipped, 0 failures (Keychain round trip ran on the real Keychain) |
| Not covered | real Apple identity token and entitlement, real `/v1/auth/*` responses, T-16 (QA-002) |

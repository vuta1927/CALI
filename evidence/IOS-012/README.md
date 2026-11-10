# IOS-012 evidence: Diagnostics screen (dev build)

Date: 2026-11-10. No API/contract change.

## Automated
- CaliCore: 64 tests, 0 failures (2 new in `DiagnosticsTests`: redactor removes JWT, Bearer and key=value secrets and keeps ordinary text; the snapshot counts rows, dirty and outbox states, redacts the outbox error, and the rendered report holds neither the body weight, a note nor a token).
- App: 62 tests, 0 failures on the iPhone 15 (signed build, commit `4e6b5c8`), none skipped, so `DiagnosticsFlowTests.testTokenRoundTripsThroughTheKeychainAndClears` ran against the real Keychain. On the unsigned simulator (`CODE_SIGNING_ALLOWED=NO`) the same test is skipped, because that build has no Keychain entitlement; the other 61 pass there. App installed on the device.
- Release build succeeds (the screen and the credential store are compiled out). `validate_ios_project_config.py` requires `#if DEBUG` in `Features/Diagnostics`; all three validators ok.

## Screenshot (simulator, DEBUG `-uiScenario diagnostics`)
- `diagnostics.png`: API dev block, app info, migrations.

## Not covered
- Manual checks on the device: Export through the share sheet, the pending notification and Live Activity sections during a real session, `OSLogStore` content.

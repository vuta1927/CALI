# IOS-012 evidence: Diagnostics screen (dev build)

Date: 2026-11-10. No API/contract change.

## Automated
- CaliCore: 64 tests, 0 failures (2 new in `DiagnosticsTests`: redactor removes JWT, Bearer and key=value secrets and keeps ordinary text; the snapshot counts rows, dirty and outbox states, redacts the outbox error, and the rendered report holds neither the body weight, a note nor a token).
- App (simulator): 62 tests, 61 pass, 1 skipped. `DiagnosticsFlowTests.testTokenRoundTripsThroughTheKeychainAndClears` needs the Keychain entitlement, which the unsigned simulator build (`CODE_SIGNING_ALLOWED=NO`) does not have; it is skipped there and must run on a signed device build. The store-level test (no weight or audit text in the report) passes.
- Release build succeeds (the screen and the credential store are compiled out). `validate_ios_project_config.py` requires `#if DEBUG` in `Features/Diagnostics`; all three validators ok.

## Screenshot (simulator, DEBUG `-uiScenario diagnostics`)
- `diagnostics.png`: API dev block, app info, migrations.

## Not covered (iPhone 15 was offline when this was run)
- Device build/test/install and therefore the Keychain test on a signed build.
- Export from the share sheet, notifications and Live Activity sections with a real session, `OSLogStore` content on the device.
- Rerun: `device18.sh`-style `build-for-testing`, `test-without-building`, `devicectl install` once the iPhone is reachable.

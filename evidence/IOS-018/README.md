# IOS-018 evidence: body weight

Date: 2026-11-10. No API/contract change (CON-007, ADR-063..065).

## Automated
- CaliDomain: 115 tests, 0 failures (5 new in `BodyMeasurementTests`: range 20..500 inclusive, three decimals refused, future time refused, entries order and soft delete, JSON keys equal the contract).
- CaliCore: 62 tests, 0 failures (3 new in `BodyMeasurementStoreTests`: exact decimal round trip, edit and soft delete leave a dirty row, the database CHECKs refuse 3 decimals, out of range and other kinds). `CoordinatorTests` migration list now includes `v4_body_measurements`.
- App: 60 tests, 0 failures (6 new in `BodyMeasurementFlowTests`: idempotent save and no value in the audit row, several per day and edit, refused values save nothing, soft delete survives a relaunch, kg regardless of the load unit, no share setting).
- Validators: `validate_ios_project_config.py` now also fails when body measurement code appears in `CaliActivityWidget`, `Shared` or `CaliApp/Services`. All three validators ok.

## Screenshots (simulator, DEBUG `-uiScenario body`)
- `list.png`: latest value with signed change, trend, list with edit and delete.
- `editor.png`: add sheet (`-uiOpenEditor YES`): kg field with ±0,1, date/time limited to now, one "Lưu".

## Not covered
- Sync of `body_measurement` (no iOS sync layer yet); the `body` indicator (ADR-065).
- Manual device matrix: no Lock Screen, widget, Live Activity or notification path touched; the guard above keeps it that way.

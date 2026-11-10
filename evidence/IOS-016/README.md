# IOS-016 evidence: gym load + dynamic set form

Date: 2026-11-09. No API/contract change (CON-006, CON-008 already accepted).

## Automated
- CaliDomain: 110 tests, 0 failures (8 new in `CriteriaTests`: fixture equality with `fixtures/criteria_config.json`, applicability, value validation, size limits, confirm with criteria, JSON shape, config fallback, weight unit).
- CaliCore: 50 tests, 0 failures (2 new in `CriteriaPersistenceTests`: criteria/load/pain round trip, old settings JSON decodes as kg).
- App (`CriteriaFormTests`, 5 new): fields per discipline, save with config version, unknown option refused, previousSet prefill, kg/lb display. Simulator pass; iPhone 15 `test-without-building` and install succeeded.
- Validators: `validate_coami_ui_copy.py`, `validate_ios_project_config.py`, `validate_handoff.py` all ok.

## Screenshots (simulator, DEBUG in-memory scenarios)
- `gym.png`: load set, kg input, status card, "Kỹ thuật" criterion.
- `hold.png`: static hold, calisthenics criteria (no RPE).

## Not covered
- Manual device matrix (lock screen etc.): this slice does not touch Lock Screen paths.
- Config download/ETag cache: `TODO(IOS-007)`.

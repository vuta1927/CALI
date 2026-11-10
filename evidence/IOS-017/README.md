# IOS-017 evidence: history week/month + cross-plan summary

Date: 2026-11-10. No API/contract change.

## Automated
- CaliCore: 59 tests, 0 failures (9 new in `HistoryStatsTests`: same-elapsed-days comparison without today, whole previous period, first period / not enough days, month clamped to a shorter previous month, day states, the docs/19 §8 scenario 5/7 · 71% · 18,5 km · 3/3 + 2/4, adherence ignores days not yet due, sets and km kept separate, free sessions as extra).
- App: 54 tests, 0 failures on simulator and iPhone 15 (4 new in `HistoryFlowTests`: missed/today from a followed plan, week card across plans, filter keeps a deleted plan labelled, ended plans show their past only when asked). `GoalFlowTests` adherence test fixed to not depend on the weekday.
- Validators: `validate_coami_ui_copy.py`, `validate_ios_project_config.py`, `validate_handoff.py` ok. App installed on the device.

## Screenshots (simulator, DEBUG `-uiScenario history`, store started 10 days ago)
- `history-week.png`: filter chips, week strip (Mon missed dashed, Tue done), tiles, comparison line.
- `history-list.png`: today's run with 8,25 km, two dashed "Bỏ lỡ" rows (one per plan), "Theo lịch: 0/8 buổi".
- `profile-week.png`: "Tuần này" card, per-plan lines, "thêm 1 buổi ngoài lịch".

## Not covered
- Sessions in the past cannot be recorded (sessions take the current time), so the screenshots show missed days from the schedule but one session, today's.
- Manual device matrix: no Lock Screen path touched.

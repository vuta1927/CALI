# Lock Screen + Live Activity POC — blocking feasibility gate

## 1. Product acceptance bounded by iOS
Lock Screen supports **glanceable exercise/phase/set + countdown**, local reminder, deep link into exact workout. Interactive Live Activity controls are possible, **but buttons/toggles do not execute on a locked device until user authenticates and unlocks** (Apple's documented behavior). It is not acceptable to claim truly hands-free complete/start on an authenticated locked phone in MVP.

## 2. Apple constraints to implement, not fight
- Live Activity max active **8h**, can remain visible up to **4h more** on Lock Screen (12h overall); always end upon session finish.
- ActivityKit isn't a background worker; dynamic time display can advance from system date formatting, but business transitions cannot rely on background ticks.
- `Text(timerInterval:pauseTime:countsDown:showsHours:)` or equivalent supported timer format should display countdown without per-second Activity update.
- Interactive Live Activity via `LiveActivityIntent` (one key action favored); locked-device interaction requires unlock.
- Notification delivery is best-effort and subject to permissions/Focus; not hard real-time.
- Live Activity and WidgetKit do not support playing loop video: show tiny poster/illustration if feasible, no heavy assets.
- `ActivityAttributes` + `ContentState` should include *small snapshot only*: `sessionId`, `exerciseShortName`, `phase`, `setIndex`, `setCount`, `targetSeconds`, `phaseStartUtc`, `phaseEndUtc`, `pausedTimeUtc?`, `revision`.

## 3. Proposed Lock Screen phases
| State | Main line | Timer | Action (if available and authenticated) |
|---|---|---|---|
| READY | `Tuck Planche • Set 2/4` | target hold | Open / Start |
| PRE_COUNTDOWN | `Sẵn sàng` | 00:03 | Open |
| EXERCISING | `Tuck Planche • đang giữ` | to target deadline | Stop / Confirm (do not assume done) |
| AWAITING_RESULT | `Xác nhận set` | no running timer | Open details |
| RESTING | `Nghỉ • Set 2/4 xong` | to rest deadline | `+30s` or Open, depending POC |
| PAUSED | `Đã tạm dừng` | remaining frozen | Resume |
| REVIEWING_SUMMARY | `Sẵn sàng tổng kết` | no countdown | Open summary |
| COMPLETED | `Buổi tập hoàn thành` | total duration | Open summary; end Activity |

## 4. POC tasks
1. Create minimal SwiftUI app + Widget extension + App Group + entitlements/config for `NSSupportsLiveActivities`.
2. Start Live Activity from app: `Tuck Planche 12s`, rest `90s`, display on lock screen and Dynamic Island on supported phones.
3. Use system-rendered timer to verify time display after 30s auto lock, screen-off, airplane mode, app suspended.
4. Add one `LiveActivityIntent` button; log behavior while **still locked vs after Face ID/passcode unlock**; no claims before evidence.
5. Confirm command saved transactionally by shared repository; double-tap and race test from app/widget.
6. Schedule local notifications at hold deadline and rest 10s warning/end; test disabled permission, Focus, silent and battery saver.
7. Force quit/kill, reopen: restore session, detect expired deadline without marking set complete, sync Live Activity if running.
8. Check security: shared SQLite and images accessible under intended data protection class in locked context; document file protection trade-off.

## 5. Physical-device test matrix
| Case | Expected | Evidence |
|---|---|---|
| iPhone with Dynamic Island, screen auto-lock | Timer visually progresses when awakened | screen record/photos + timestamps |
| iPhone without Dynamic Island | Lock Screen Live Activity appears | device screenshot |
| No Wi-Fi/mobile | countdown + local log still works | airplane mode test log |
| Screen locked + tap widget action | authentication/unlock required before execution | video and device state |
| Notification denied | foreground timer and workout still usable | screenshot |
| User changes system time | app reconciles, no ghost completed set | unit + manual log |
| 8h+ simulated long session | app fallbacks if Activity expires | lifecycle test |
| Force quit while in rest | no loss of durable set, no double transition | DB inspection |

## 6. Go/no-go decision
**GO** when: Live Activity can glanceably display phase+timer on real supported devices; transition via authorized user action is reliable; session is durable without network; app remains usable without Activity. **NO-GO** if product requirement insists on unauthenticated interaction while screen locked; redesign UX around glance + unlock, not a prohibited workaround.

## 7. Primary sources
- https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- https://developer.apple.com/documentation/swiftui/text/init%28timerinterval%3Apausetime%3Acountsdown%3Ashowshours%3A%29
- https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app
- https://developer.apple.com/documentation/xcode/configuring-app-groups

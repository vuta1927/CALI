# Non-functional Requirements / Operations

## 1. Availability expectations
- **Workout client** available offline for core flows; server outage should not block training.
- AI is noncritical asynchronous enhancement; `pending/failed` UI states are normal.
- Background sync and notification delivery are OS best-effort, not hard availability SLOs.

## 2. Suggested pilot targets (to validate, not guaranteed)
| Metric | Initial objective |
|---|---|
| local command durability | >=99.99% operations acknowledged to user have committed local DB |
| app crash-free sessions | >=99.5% |
| home initial usable render | <2s p95 on specified pilot devices |
| confirm-set local write | <100ms p95 |
| sync push 100 mutations | <2s p95 at pilot load |
| sync delayed after app opened online | <30s p95 under healthy network/server |
| AI completion | <60s p95 under normal provider conditions |
| media pinned today | 100% posters fallback, preview downloads best effort |

## 3. Device, accessibility and battery
- Test iOS 18+; small iPhone and Dynamic Island model; 30s auto-lock, Low Power Mode, Focus, Silent Mode, no permissions.
- Avoid per-second DB writes or frequent Live Activity state updates; render timer from deadlines.
- Preload only next workout media; energy/bandwidth friendly Wi-Fi option.
- Verify WCAG-style text contrast, VoiceOver, Dynamic Type and one-hand touch target >=44pt.

## 4. Observability & rollback
- Sentry/Crashlytics optional SDK after privacy review; OSLog local and OpenTelemetry backend recommended.
- Alert on elevated sync rejection/AI worker backlog; dashboards for queue age, API status, crash rate.
- Postgres PITR/backups with periodic restore drill; object storage versioning for licensed media.
- Feature flags: AI, Live Activity, background media prefetch, sync advanced conflict UI; rollback without deleting local sessions.

## 5. Release workflow
`PR -> unit/contract -> staging integration -> TestFlight internal -> real-device scenario suite -> privacy/permissions review -> phased pilot -> release`. Track schema compatibility during client rollouts. Backend accepts API version v1 until deliberate sunsetting; migration backward compatibility for offline clients that return after weeks.

## 6. Open platform decisions
Lock Screen behavior, entitlement conditions and background scheduling must be validated on actual device; ADR update may change supported iOS minimum or design. No background task approach should claim always-on execution absent Apple-approved specific mode.

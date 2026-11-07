# ADR Baseline, Assumptions and Risks

## Accepted baseline decisions
| ADR | Decision | Rationale | Revisit trigger |
|---|---|---|---|
| ADR-001 | Native SwiftUI iOS | seamless WidgetKit/ActivityKit, timers, media | Android scope emerges |
| ADR-002 | GRDB/SQLite local (App Group) | explicit transactional outbox and command dedupe | POC shows locked access issue |
| ADR-003 | Offline writes local first | ensure session never depends on network | none |
| ADR-004 | ASP.NET Core 10 LTS + PostgreSQL | durable backend, familiar stack | organizational hosting constraint |
| ADR-005 | REST push/pull sync + cursor | simple, auditable, idempotent | high real-time collaboration requirement |
| ADR-006 | One server job queue in Postgres | avoid premature broker complexity | high-volume AI jobs |
| ADR-007 | AI has no direct write permissions to plan | safety, explicit consent | none |
| ADR-008 | Video only foreground app; poster for Lock Screen | WidgetKit/ActivityKit constraints | platform APIs materially change |
| ADR-009 | Actual completion needs explicit confirmation | no false logs when timer expires | validated sensor measurement later |
| ADR-010 | iOS deployment target initially 18+ | manageable QA surface, interactive Live Activities | device market/compatibility analysis |

## Assumptions requiring validation before public release
- Apple Developer Team ID, Bundle ID, App Group ID, signing and deployment target must be supplied by project owner; files use placeholders, **not production credentials**.
- Brand/app name `CALI` is working title only; legal availability not checked.
- Media licensing and content review before production; demo placeholders not final assets.
- Training heuristics need review by appropriately qualified trainer, especially Iron Cross and high tendon load.
- Product privacy policy, data deletion/export, consent wording, backend region/data residency not yet finalized.
- User appetite for Sign in with Apple, automatic media cache sizes and reminder timing needs usability testing.

## Risk register
| ID | Risk | Impact | Mitigation / owner |
|---|---|---|---|
| R-01 | User expects controls on locked phone without unlock | High | POC early, clarify OS limitation, alternate notification/deep link; Product/iOS |
| R-02 | Background timer state silently wrong | Critical | deadline-based render, explicit confirmation, reconciliation tests; iOS/QA |
| R-03 | Widget and app write race / DB locked | High | App Group SQLite transaction/serial access, dedupe and concurrency tests; iOS |
| R-04 | Reconnect background sync not immediate | Medium | foreground sync, BGTask best effort, honest status badges; iOS |
| R-05 | Duplicate/overwritten workout history | Critical | outbox idempotency, optimistic versions, server receipts and tests; BE |
| R-06 | AI unsafe suggestion or hallucination | High | deterministic guardrails, structured JSON, approval, evals; AI |
| R-07 | Media rights invalid / form inaccurate | High | licensed content process and technique review; Content |
| R-08 | iOS Data Protection blocks widget action on lock state | High | POC & privacy-minded shared storage policy; iOS/Security |
| R-09 | Offline devices resume after tombstones expired | Medium | full resync policy and stale-device UX; BE/iOS |
| R-10 | Clock tampering/time drift affects actual hold | Medium | monotonic while foreground, recorded actual editable, reconciliation; iOS |

## Open questions to resolve without blocking first POC
- Supported iOS versions and iPhone device mix.
- Exact branding and language support for v1.
- Account deletion SLA/data hosting region, whether guest data encryption beyond iOS file protection is needed.
- Precise AI model/vendor and cost budget; prompt schema is provider-independent.
- Media acquisition pipeline and consent for any future camera analysis.

## Documented Apple platform facts
- Interactive widget/Live Activity controls require auth/unlock on locked device: https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- Live Activities active up to 8h, retained on Lock Screen up to 4 additional hours: https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Notification delivery is best effort: https://developer.apple.com/documentation/usernotifications
- Background tasks scheduled by system, not real-time: https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler

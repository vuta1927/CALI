# AGENTS.md — Working agreement for AI coding agents

## Product non-negotiables
1. **Offline-first**: all workout commands persist locally first; no BE/LLM dependency during workout.
2. **Visual-first**: exercise identity visible by high-quality thumbnail/poster; text labels are supplemental, not a substitute.
3. **Safe timer semantics**: keep event deadlines, never infer that a user *completed* a set merely because countdown reached zero while device slept.
4. **Lock Screen compliance**: locked-device buttons/toggles require authentication/unlock; do not promise bypass. Show countdown read-only; use local notifications for reminders.
5. **No silent AI edits**: suggestions have approval workflow and audit trail.
6. **Privacy and ownership**: users own workout logs; no API keys in iOS binary, no upload of video of users in MVP.
7. **Contracts first**: changes affecting API/schema/domain require synchronized updates to OpenAPI, SQL, docs and tests.

## Branch ownership
- `ios-agent`: iOS app, widget extension, local schema/migrations, intents, media cache; may modify `docs/04`, `docs/05`, UX implementation details; **does not change API without contract PR**.
- `backend-agent`: .NET API, PostgreSQL, auth, sync processing, AI job queue; owns OpenAPI/SQL implementation; coordinates schema changes.
- `ai-agent`: structured LLM pipeline, policy/rules, deterministic analytics, evaluation fixtures; **cannot grant medical advice**.
- `design-agent`: SwiftUI design tokens/components, prototypes, Exercise Catalog media spec, localization.
- `qa-agent`: tests, automation, nonfunctional checks, acceptance matrix, POC evidence.
- `integrator-agent`: resolves interfaces, CI, release gates, cross-platform E2E and ADRs.

## Execution protocol
1. Read README + relevant docs + assigned prompt, then post a short plan with touched paths and expected tests.
2. Choose **one small vertical slice**; open PR with linked backlog IDs.
3. No mock data masquerading as production data; mark temporary stubs with `TODO(ISSUE-ID)` and expiry condition.
4. Generate typed API clients from OpenAPI or keep strict conformance tests.
5. For state-changing commands always capture `commandId` UUID, validate preconditions, persist transactionally and make repeat calls safe.
6. Protect secrets; use env variables/Keychain; redact logs.
7. Provide automated evidence + manual device matrix for iOS Lock Screen changes.
8. After each PR update issue status, `CHANGELOG.md`, ADR if architecture changed, and relevant tests.

## Quality gates
- **Build**: iOS app + widget extension (configured signing), backend build, no compiler errors.
- **Unit**: deterministic workout domain, sync retry/conflicts, AI safety rules.
- **Integration**: auth, REST pagination, migrations, idempotent push, cursor pull, agent job status.
- **Device**: real iPhone, lock/unlock, screen off, permission denied, flight mode, forced termination, clock/timezone change.
- **Accessibility**: Dynamic Type, VoiceOver, high contrast, reduce motion, tap target >=44×44pt.
- **Performance**: SLO in NFR doc, record measurements rather than claim completion.

## Shared glossary
`plan` = chương trình dài hạn; `planned_workout` = buổi theo lịch; `session` = lần tập thực tế; `execution` = một bài trong một session; `set_result` = kết quả set; `hold` = giữ tư thế; `reps` = số lần; `rest` = thời gian nghỉ; `command` = hành động người dùng; `mutation` = thay đổi local chờ sync; `analysis` = đánh giá AI; `recommendation` = đề xuất cần phê duyệt.

## Safety-critical rules for this repo
- A notification is an advisory; may be late/missed, never execute user-confirmation transitions in notification-delivery callback.
- During suspension, timer display may advance using system date formatting; application **domain state is only reconciled on next executable callback**.
- Device may change wall-clock/time zone; use monotonic clock in-process, persist UTC deadline and detect large clock jumps; prompt reconciliation instead of overwriting recorded duration.
- Widget and host share minimal state via App Group and a single command service with transactional DB access; test concurrency.

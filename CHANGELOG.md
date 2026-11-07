# Changelog

## Unreleased
- Added `docs/16-implementation-plan.md`: detailed iOS + backend implementation plan for a Windows + iPhone + GitHub Actions (zero-cost) setup; proposes ADR-011..015.
- C0/CON-001: contract review report (`docs/reviews/CON-001-contract-review.md`), `handoff.yml` CI, validator UTF-8/worktree/OpenAPI-fixture checks; aligned JSON Schema/OpenAPI/SQL limits and `entity_type` CHECKs; docs/07 + docs/08 naming/example fixes. 18 items flagged for ADR/decision.
- B0: backend foundation — .NET 10 solution (Api, Worker, DevToken CLI), DbUp migrations from `db/*.sql` (dev seed only in Development), JWT auth with Development-only dev tokens, ProblemDetails with `code`/`traceId`, `/health/live` + `/health/ready`, rate-limit policies, `GET /v1/me`, `docker-compose.yml` (postgres:16.15), `backend.yml` CI. 69 tests passing locally.
- I1a: `CaliDomain` Swift package — pure deterministic workout reducer, reconcile with clock-jump/stale-session signals, Clock/FakeClock; draft CON-002 reducer fixtures in `fixtures/reducer/`; `swift-domain.yml` Linux CI. 72 tests passing (Docker `swift:6.2-noble`).
- I0: XcodeGen iOS project (CaliApp + CaliActivityWidget Live Activity extension + CaliAppTests, iOS 18 / Swift 6) and on-demand macOS workflow producing an unsigned .ipa for Sideloadly; guide in `ios/README.md`. Build and device install **not yet verified**.

## 1.0.0 — 2026-11-07
- Initial agent handoff package including PRD, UX, workout domain, iOS/Live Activity feasibility, BE, data, sync, AI, media, security, QA, delivery backlog, ADRs.
- Added OpenAPI 3.1, PostgreSQL baseline migration, JSON fixtures, Gherkin acceptance and role-specific agent prompts.
- No application source code is included. Implementation and real iPhone POC remain required.

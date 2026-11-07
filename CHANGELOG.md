# Changelog

## Unreleased
- Added `docs/16-implementation-plan.md`: detailed iOS + backend implementation plan for a Windows + iPhone + GitHub Actions (zero-cost) setup; proposes ADR-011..015.
- C0/CON-001: contract review report (`docs/reviews/CON-001-contract-review.md`), `handoff.yml` CI, validator UTF-8/worktree/OpenAPI-fixture checks; aligned JSON Schema/OpenAPI/SQL limits and `entity_type` CHECKs; docs/07 + docs/08 naming/example fixes. 18 items flagged for ADR/decision.
- B0: backend foundation — .NET 10 solution (Api, Worker, DevToken CLI), DbUp migrations from `db/*.sql` (dev seed only in Development), JWT auth with Development-only dev tokens, ProblemDetails with `code`/`traceId`, `/health/live` + `/health/ready`, rate-limit policies, `GET /v1/me`, `docker-compose.yml` (postgres:16.15), `backend.yml` CI. 69 tests passing locally.
- I1a: `CaliDomain` Swift package — pure deterministic workout reducer, reconcile with clock-jump/stale-session signals, Clock/FakeClock; draft CON-002 reducer fixtures in `fixtures/reducer/`; `swift-domain.yml` Linux CI. 72 tests passing (Docker `swift:6.2-noble`).
- CON-001 decisions: resolved D1–D18 as ADR-016..033 (`docs/15`). Contracts: typed `prescribedSnapshot`; closed mutation envelope; session `pausedAt`/`accumulatedExerciseMs`/`abandonReason` + status↔phase rules; set_result `skipReason`/`painReported`/`note` ≤1000; interval `restSeconds ≥ 1`; `MutationError` code enum + `retryable`; pull payload shapes; nullable `AnalysisRecommendation.exerciseId`; required `ExerciseMedia.license`; `/health/*` and `/v1/me` 404 in OpenAPI; push 409 `device_owner_mismatch`. SQL (`db/001` edited in place, no deployed DB; run `docker compose down -v`): CHECKs for the above, partial unique live set index, `payload_sha256`, device FK. New `contracts/catalog-bundle.schema.json` and `fixtures/validation/business_rules.json`, both checked by the validator. Docs 03/07/08/09/10 updated.
- I0: XcodeGen iOS project (CaliApp + CaliActivityWidget Live Activity extension + CaliAppTests, iOS 18 / Swift 6) and on-demand macOS workflow producing an unsigned .ipa for Sideloadly; guide in `ios/README.md`. Build and device install **not yet verified**.

## 1.0.0 — 2026-11-07
- Initial agent handoff package including PRD, UX, workout domain, iOS/Live Activity feasibility, BE, data, sync, AI, media, security, QA, delivery backlog, ADRs.
- Added OpenAPI 3.1, PostgreSQL baseline migration, JSON fixtures, Gherkin acceptance and role-specific agent prompts.
- No application source code is included. Implementation and real iPhone POC remain required.

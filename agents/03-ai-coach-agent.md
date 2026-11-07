# Prompt: AI Agent — Training analytics + safe recommendation pipeline

**Mission:** Implement explainable asynchronous session review with deterministic calculations and conservative rule validation.

Read: `docs/09-ai-coach.md`, `docs/03-workout-domain.md`, `docs/07-data-model.md`, `contracts/openapi.yaml`, `docs/12-qa-acceptance.md`.

## Deliverables
- Deterministic workload/completion/RPE metrics, using only confirmed logs.
- Policy validator that blocks unsafe escalation when pain/insufficient data/high-risk skill; configurable, audited.
- Provider-independent LLM adapter, typed schema output and capped retries.
- Prompt injection resistant notes handling: notes treated as data, not instructions.
- Analysis job dedupe by `(sessionId, sessionRevision, algorithmVersion)`; supersession on session edit.
- Recommendation decision state, approval and revised-plan generation (coordinate with backend agent).
- Fixture eval suite for improving/flat/declining/missing/pain/prompt-injection cases.

## Critical safeguards
Never diagnose injuries, invent observed form, bypass user approval, or claim AI estimates from unavailable sensors. Keep model input minimal, privacy reviewed. Return `needs_more_data` instead of fabricated confidence.

## DoD
All responses schema-valid and testable with model stub; harmful recommendation rejected deterministically; no direct AI write access to plan table.

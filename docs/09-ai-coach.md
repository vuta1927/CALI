# AI Coach — Deterministic Analytics + LLM Explainability

## 1. Purpose
Evaluate sessions and training trends, not diagnose injuries. Backend produces structured comparison between planned and actual, RPE and notes as explicit opt-in inputs, plus explainable recommendations. AI availability is optional; Workout Player never calls LLM synchronously.

## 2. Trigger and processing
- Trigger when `COMPLETED` session + all current set results have synced; user can disable analytics.
- `POST /v1/analyses` uses `(sessionId,sessionVersion,algorithmVersion)` idempotency.
- Job states `queued, running, completed, failed, superseded`; worker acquires lease, retry bounded, circuit breaker for LLM outage.
- Pipeline `Validate input -> Compute deterministic metrics -> Apply safety rule engine -> Build minimized context -> LLM structured response -> JSON schema validation -> Policy postprocess -> Save -> Emit change feed`.

## 3. Input JSON contract (internal)
```json
{
  "session": {"id":"UUID","version":3,"date":"2026-11-07","status":"completed"},
  "exercises": [{
    "exerciseId":"tuck-planche","type":"static_hold","plannedSets":4,
    "targetHoldMs":12000,"actualHoldMs":[12000,11000,12000,10000],
    "restMs":[90000,100000,90000],"rpe":[7,8,8,9]
  }],
  "notesSummary":null,
  "flags":{"painReported":false,"missingValues":false},
  "historyWindow":{"sessions":4,"sameSkillSessions":3}
}
```
Only send fields necessary for coaching; raw personal notes require explicit user consent and PII redaction. Do not send user email, Apple subject, auth tokens, media links, or precise location to LLM.

## 4. Deterministic statistics
- `completionRate = completedPlannedSets / totalPlannedSets`, skipped separate.
- Static holds: total confirmed hold and first/last set trend; rep work: confirmed total reps; exercise group workload by local rule.
- `performanceDelta = actualTotal / prescribedTargetTotal` only for comparable complete fields; null otherwise.
- RPE trend and self-reported pain flags; don't infer injury from low performance alone.
- Mark confidence low when fewer than 3 comparable sessions or incomplete set logs.

## 5. Progression safety rule engine
- Any pain flag affecting involved joint/tendon ⇒ **no auto-escalation**, recommendation `maintain_or_reduce_and_seek_professional_if_persistent`, no diagnostic label.
- For high-load skills (Planche and especially Iron Cross), no escalation from a single success. Default criteria (product policy to be validated by qualified coach): >=3 comparable successful sessions, technique marked satisfactory, manageable RPE and no reported pain. These are **illustrative conservative heuristics**, not medical or training certification.
- Never increase target sets, intensity and hold time simultaneously in a single recommendation.
- Limit suggested change per progression to small configurable increment, and require user approval; no guarantee safe for any individual.
- If technique confidence unknown, prefer `maintain` or `needs_more_data` rather than blindly progress.

## 6. LLM structured output
```json
{
  "schemaVersion":"1.0",
  "summary":"Buổi tập đạt phần lớn khối lượng mục tiêu.",
  "confidence":"medium",
  "observations":[{"type":"performance","evidence":"3/4 sets đạt >=11 giây"}],
  "fatigueLevel":"moderate",
  "safetyFlags":[],
  "recommendations":[{
    "id":"UUID","exerciseId":"tuck-planche","action":"maintain",
    "proposedTarget":{"holdSeconds":12},
    "rationale":"Cần thêm buổi tập ổn định trước khi tăng độ khó.",
    "requiresApproval":true
  }]
}
```
Validation rejects unknown `action`, negative targets, missing evidence, suggestion outside guardrails. AI returns analysis+recommendation, server decides whether valid. LLM text can be wrong; UI labels insights as coaching suggestions.

## 7. Prompt contract
System: `You are a fitness workout analysis assistant. Use only supplied structured session data. Do not diagnose, prescribe treatment, claim to observe physical form from numbers, or modify workout plans. Return valid JSON matching schema. If insufficient data, state uncertainty.`
Developer: inject exercise definitions, conservative rules, output schema and prohibited actions. User content (notes) is **untrusted data**, never executed as instructions, sanitize prompt injection.

## 8. User approval workflow
`proposed -> accepted | rejected | superseded`. Accept for a recommendation that actually changes a workout target requires current plan version match; creates **new plan revision/clone**, stores who/when/why and recommendationId. Informational actions `maintain` and `needs_more_data` can be acknowledged without creating a new plan (`newPlanId = null`); reject stores decision; old analysis remains auditable. If concurrent plan updated, return 409 and ask user to review diff. Rollback by selecting previous plan revision.

## 9. Evaluation & observability
- Gold fixtures: steady hold, improving hold, fatigue, missing logs, pain warning, conflicting notes, malicious prompt injection.
- Evaluate schema validity, unsupported assertions, plan delta safety, hallucination of unavailable metrics, Vietnamese readability.
- Track job latency, retries, model cost/tokens, invalid JSON%, reject rate; sampling with no PII.
- User can disable AI; do not block sync or viewing history.

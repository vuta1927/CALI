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

**Số đo cơ thể (CON-007, ADR-064).** `body_measurement` (cân nặng) **không bao giờ** nằm trong đầu vào AI: không có trường cân nặng hay chỉ số cơ thể trong JSON trên, `AnalysisRequest` chỉ có `{sessionId, sessionVersion}` (contract test `Body_data_is_never_part_of_ai_input`). Hiện chưa lưu đồng ý (consent) nào cho việc này. Nếu sau pilot cần dùng, đó là một slice riêng: opt-in tách biệt, mặc định tắt, có audit trail, và AI vẫn không được đưa lời khuyên y tế hay ăn kiêng (§5).

## 4. Deterministic statistics
- `completionRate = completedPlannedSets / totalPlannedSets`, skipped separate.
- Static holds: total confirmed hold and first/last set trend; rep work: confirmed total reps; exercise group workload by local rule.
- `performanceDelta = actualTotal / prescribedTargetTotal` only for comparable complete fields; null otherwise.
- RPE trend and self-reported pain flags; don't infer injury from low performance alone.
- Mark confidence low when fewer than 3 comparable sessions or incomplete set logs.

## 5. Progression safety rule engine
- Any pain flag (`set_result.painReported`) affecting an involved joint/tendon ⇒ **no auto-escalation**. The recommendation uses action `reduce` or `maintain`, adds `"pain_reported"` to `safetyFlags`, and its rationale advises seeking a qualified professional if pain persists. There is no diagnostic label and no extra action value (ADR-032).
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
    "exerciseSlug":"tuck-planche","action":"maintain",
    "proposedTarget":{"holdSeconds":12},
    "rationale":"Cần thêm buổi tập ổn định trước khi tăng độ khó.",
    "requiresApproval":true
  }]
}
```
Validation rejects unknown `action`, negative targets, missing evidence, suggestion outside guardrails. AI returns analysis+recommendation, server decides whether valid. LLM text can be wrong; UI labels insights as coaching suggestions.

### 6.1 LLM output → API `AnalysisOutput` mapping (ADR-032)
The schema above is the **LLM output schema**. It is internal, slug-based, and its targets have no `kind`. It is not the API shape. After JSON-schema validation, the server maps each recommendation:
1. `exerciseSlug` → catalog uuid `exerciseId`. An unknown slug drops the recommendation and is logged; a missing slug means a session-level recommendation with `exerciseId: null` (ADR-026).
2. `proposedTarget` → a full OpenAPI `PlannedTarget`, with `kind` taken from the catalog exercise type. No target change → `null`.
3. The server assigns `id` (uuid), `decision: "proposed"` and `requiresApproval: true`.
4. Policy rules (§5) run on the mapped result and may downgrade an action or add `safetyFlags`.

The stored and returned shape is OpenAPI `AnalysisOutput` / `AnalysisRecommendation`. Example of the mapped recommendation:
```json
{"id":"UUID","exerciseId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1","action":"maintain",
 "proposedTarget":{"kind":"static_hold","holdSeconds":12},
 "rationale":"Cần thêm buổi tập ổn định trước khi tăng độ khó.","requiresApproval":true,"decision":"proposed"}
```

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

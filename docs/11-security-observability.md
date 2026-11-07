# Security, Privacy and Observability

## 1. Threat model shortlist
- Stolen device/backup leaking workout notes and tokens.
- Forged/expired Apple identity token; unauthorized user access.
- Replay/mutation duplication and IDOR on set records/AI analyses.
- Prompt injection from freeform workout notes.
- Unsanctioned media CDN URLs and malicious assets.
- AI provider credentials leaking to client; excessive vendor data disclosure.

## 2. Controls
- Sign in with Apple token validation: issuer, audience, signature via current JWKS, expiry, nonce; map verified `sub` to user; issue short-lived API JWT + rotated refresh token.
- Backend accepts authenticated user ID only from validated token; all queries scoped, rate limited, action authorization enforced server-side. Validate `entityId` foreign keys belong to same user.
- HTTPS TLS; no disabled certificate validation in release; ATS enforced.
- iOS Keychain for refresh/access tokens (where stored); appropriate file protection for local DB. Locked widget extension access must be security-tested; design minimum shared data.
- Outbox mutation IDs + server receipt; optimistic versions; no arbitrary table/entity names accepted by API.
- Application secrets in server secret manager; LLM calls server-side only. Sanitize notes and bound prompt sizes.
- Consent/setting for cloud sync and AI; user can use offline guest.
- Privacy-preserving logs with pseudonymous IDs, no freeform notes or token/PII log payloads.

## 3. Observability
Common correlation: `traceId`, `mutationId`, `sessionId` (UUID only, no name). Metrics:
- Mobile: crash-free sessions, DB errors, queued outbox count/age, media cache hit, ActivityKit errors, notification permission ratio.
- Server: API p50/p95 latency, push per-status counts, pull cursor lag, 5xx, DB transaction retries, worker queue age.
- AI: job success, schema invalid rate, provider latency/cost, safety filter reject %, user acceptance %.

## 4. User data behavior
- On app lock screen display no sensitive free-form notes, pain reports, account identifiers.
- Export, account deletion and retention policy to be finalized before public launch; pilot phase documentation must still describe handling.
- Version and keep provenance of AI-generated recommendations, including source session revision and accepted plan revision.

## 5. Security verification
Auth integration, token replay, request boundary tests, per-user IDOR tests, malformed JSON, oversized batch, prompt-injection fixtures, expired media links, sensitive-log scan, secret scanner in CI.

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
  - Implemented in BE-005 (ADR-071): RS256 only; nonce = lowercase hex SHA-256 of the raw nonce the app sends, and a nonce works once; refresh tokens are opaque, stored only as SHA-256, single use, and a reused one revokes its whole session; every refusal is one generic 401 and the reason is logged as a code only (never a token, nonce or Apple `sub`); access tokens are not checked against the database, so a revoked session lives at most one access-token lifetime (15 minutes). Secrets: `Auth__AccessTokenSigningKey` (new). CI runs gitleaks and `dotnet list package --vulnerable --include-transitive` (`security.yml`).
- Backend accepts authenticated user ID only from validated token; all queries scoped, rate limited, action authorization enforced server-side. Validate `entityId` foreign keys belong to same user.
- HTTPS TLS; no disabled certificate validation in release; ATS enforced.
- iOS Keychain for refresh/access tokens (where stored); appropriate file protection for local DB. Locked widget extension access must be security-tested; design minimum shared data.
- Outbox mutation IDs + server receipt; optimistic versions; no arbitrary table/entity names accepted by API.
- Application secrets in server secret manager; LLM calls server-side only. Sanitize notes and bound prompt sizes.
- Consent/setting for cloud sync and AI; user can use offline guest.
- Privacy-preserving logs with pseudonymous IDs, no freeform notes or token/PII log payloads.
- Số đo cơ thể (`body_measurement`, CON-007) là dữ liệu nhạy cảm: không ghi `value` vào log, metric hay trace (chỉ ID và entity type); không gửi cho nhà cung cấp AI (docs/09 §3, ADR-064).
- Cấu hình tiêu chí (`criteria_config_versions`) và `indicator_definitions` là nội dung của bên phát hành (CON-008): thiết bị chỉ đọc, chỉ portal được ghi (ADR-051, portal làm sau pilot), không có đường ghi nào từ app hay API. `GET /v1/criteria-config` công khai, không cần đăng nhập vì không chứa dữ liệu người dùng (PO chốt 2026-11-09). Bắt buộc có rate limit riêng cho endpoint ẩn danh, chia theo IP client (429 + `Retry-After`, cấu hình trong `RateLimiting`); sau reverse proxy phải cấu hình `ForwardedHeaders` với proxy tin cậy, nếu không mọi request có chung một IP. Response `Cache-Control: public, max-age=300` và ETag/304 để CDN hoặc reverse proxy trả lặp mà không chạm API. Rate limit ở tầng ứng dụng chỉ chặn một client gửi quá nhiều; tấn công phân tán (DDoS) phải chặn ở edge/CDN trước khi tới API (ADR-066). Map `set_result.criteria` chỉ chứa token đóng, số, boolean, không có văn bản tự do, nên không phải làm sạch như ghi chú. Tiêu chí `pain` chỉ ghi lại cho người dùng xem, không dùng để chẩn đoán.
- Media công khai (BE-006, ADR-072): file nằm trong object store S3-tương thích, không trong PostgreSQL. API chỉ cấp URL presigned GET hết hạn sau 15 phút (cấu hình 60..3600 giây) cho media `is_public` đã `reviewed_at`; URL chứa chữ ký và access key id, không chứa secret, và tên bucket cùng `storage_key` nằm trong path nên khoá phải mờ. Credential của API trên bucket chỉ cần quyền đọc; `Media__Storage__SecretAccessKey` là secret (biến môi trường hoặc user-secrets, không commit, không log, thông báo lỗi cấu hình chỉ nêu tên khoá). Ngoài Development endpoint bắt buộc `https`. Response catalog là `no-store` vì body chứa URL hết hạn; endpoint catalog vẫn ẩn danh và bị rate limit theo IP. Không có binary iOS nào giữ credential của store.

## 3. Observability
- Voice pack (CON-010, ADR-077): `GET /v1/voice-pack` ẩn danh vì chỉ chứa nội dung bên phát hành; rate limit theo IP như catalog. Credential vbee (`Tts__Vbee__AppId`, `Tts__Vbee__Token`) chỉ có trên server/job BE-007, là secret (không commit, không log, lỗi cấu hình chỉ nêu tên khoá); app không bao giờ gọi vbee. Job chỉ gửi văn bản trong kịch bản đã duyệt, không bao giờ gửi dữ liệu người dùng (tên, ghi chú, số đo).
Common correlation: `traceId`, `mutationId`, `sessionId` (UUID only, no name). Metrics:
- Mobile: crash-free sessions, DB errors, queued outbox count/age, media cache hit, ActivityKit errors, notification permission ratio.
- Server: API p50/p95 latency, push per-status counts, pull cursor lag, 5xx, DB transaction retries, worker queue age.
- AI: job success, schema invalid rate, provider latency/cost, safety filter reject %, user acceptance %.

## 4. User data behavior
- On app lock screen display no sensitive free-form notes, pain reports, account identifiers.
- Số đo cơ thể (CON-007) không hiện trên Lock Screen, widget, Live Activity hay nội dung thông báo; không chia sẻ qua App Group cho widget (ADR-064). Dùng số đo cơ thể làm đầu vào AI chỉ có thể là một opt-in riêng, mặc định tắt, có audit, sau pilot.
- Export, account deletion and retention policy to be finalized before public launch; pilot phase documentation must still describe handling.
- Version and keep provenance of AI-generated recommendations, including source session revision and accepted plan revision.

## 5. Security verification
Auth integration, token replay, request boundary tests, per-user IDOR tests, malformed JSON, oversized batch, prompt-injection fixtures, expired media links, sensitive-log scan, secret scanner in CI.

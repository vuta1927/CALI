# CALI — Calisthenics Training Companion

**Bộ tài liệu bàn giao cho coding agents — v1.0 (2026-11-07)**  
Ngôn ngữ: Tiếng Việt (tên kỹ thuật, API và định danh giữ tiếng Anh).  
Trạng thái: **Implementation-ready baseline**, còn các quyết định cần xác minh trong `docs/15-decisions-risks.md`.

## Mục tiêu
Ứng dụng iOS **visual-first, offline-first** để lên lịch Calisthenics, hướng dẫn bằng hình/video, điều khiển set–rep–hold–rest, hiển thị trạng thái tập trên Lock Screen/Dynamic Island trong giới hạn iOS, lưu nhật ký, đồng bộ về ASP.NET Core và nhận đánh giá/đề xuất từ AI Coach.

## Đọc theo thứ tự

1. [`HANDOFF.md`](HANDOFF.md): hướng dẫn bắt đầu và prompt cho Orchestrator Agent.
2. [`AGENTS.md`](AGENTS.md): nguyên tắc làm việc, phân chia vai trò, tiêu chí merge.
3. [`docs/01-product-prd.md`](docs/01-product-prd.md): sản phẩm, phạm vi, user stories, acceptance.
4. [`docs/02-ux-spec.md`](docs/02-ux-spec.md): sitemap, chi tiết từng màn, visual-first và accessibility.
5. [`docs/03-workout-domain.md`](docs/03-workout-domain.md): domain model, state machine, hành vi timer.
6. [`docs/04-ios-architecture.md`](docs/04-ios-architecture.md): SwiftUI modules và lưu local.
7. [`docs/05-lock-screen-poc.md`](docs/05-lock-screen-poc.md): POC bắt buộc, giới hạn nền tảng.
8. [`docs/06-backend-architecture.md`](docs/06-backend-architecture.md): .NET API và jobs.
9. [`docs/07-data-model.md`](docs/07-data-model.md): logical schema, invariant, migration.
10. [`docs/08-sync-protocol.md`](docs/08-sync-protocol.md): push/pull, idempotency, conflict.
11. [`docs/09-ai-coach.md`](docs/09-ai-coach.md): dữ liệu vào, rules, JSON đầu ra, guardrails.
12. [`docs/10-media-library.md`](docs/10-media-library.md): hình/video, offline cache, quyền sử dụng.
13. [`docs/11-security-observability.md`](docs/11-security-observability.md): auth, bảo vệ dữ liệu, telemetry.
14. [`docs/12-qa-acceptance.md`](docs/12-qa-acceptance.md): test matrix, acceptance.
15. [`docs/13-delivery-backlog.md`](docs/13-delivery-backlog.md): epics, tasks có dependency, DoD.
16. [`docs/14-nfr-and-operations.md`](docs/14-nfr-and-operations.md): NFR/SLO, release, vận hành.
17. [`docs/15-decisions-risks.md`](docs/15-decisions-risks.md): ADR, giả định và rủi ro.
18. [`docs/16-implementation-plan.md`](docs/16-implementation-plan.md): kế hoạch triển khai chi tiết iOS + backend, môi trường dev không tốn phí.
19. [`docs/reviews/CON-001-contract-review.md`](docs/reviews/CON-001-contract-review.md): kết quả rà soát contract (C0), các điểm cần ADR.
20. [`backend/README.md`](backend/README.md): chạy backend local, test, dev token.
21. [`ios/README.md`](ios/README.md): build iOS qua GitHub Actions và sideload bằng Sideloadly.

## Tham chiếu UI
- [`references/ui_concept_reference.png`](references/ui_concept_reference.png): mockup minh họa đã trao đổi; **không phải bản giao diện pixel-perfect hay nguồn thiết kế có thể chỉnh sửa**. Thông số thực thi vẫn theo `docs/02-ux-spec.md`.

## Đầu vào máy đọc được
- [`contracts/openapi.yaml`](contracts/openapi.yaml): OpenAPI 3.1, API contract baseline.
- [`contracts/entity-payloads.schema.json`](contracts/entity-payloads.schema.json): JSON Schema xác thực payload cho từng entity khi sync.
- [`contracts/backlog.csv`](contracts/backlog.csv): bảng giao việc có thể import vào task tracker.
- [`db/001_initial.sql`](db/001_initial.sql): PostgreSQL DDL baseline (có indexes/constraints).
- [`db/002_dev_catalog_seed.sql`](db/002_dev_catalog_seed.sql): 6 bài tập mẫu (development-only, không publish).
- [`fixtures/workout_plan.json`](fixtures/workout_plan.json): giáo án thử với static, reps, rest.
- [`fixtures/exercise_catalog.json`](fixtures/exercise_catalog.json): catalog 6 bài mẫu, đường dẫn media là placeholder **không có tệp thật**.
- [`fixtures/sync_push.json`](fixtures/sync_push.json): ví dụ outbox push.
- [`tests/acceptance.feature`](tests/acceptance.feature): Gherkin scenarios trọng yếu.
- [`agents/`](agents/): prompt giao việc cho từng agent.
- [`tools/validate_handoff.py`](tools/validate_handoff.py): script kiểm tra liên kết/spec/fixtures (`python3 tools/validate_handoff.py`).
- [`tools/export_backlog.py`](tools/export_backlog.py): xuất lại CSV sau khi sửa backlog.

## Quy tắc ưu tiên khi tài liệu mâu thuẫn
`docs/15-decisions-risks.md` (ADR đã chốt) → `docs/03-workout-domain.md` (domain invariants) → `contracts/openapi.yaml` (wire contract) → `db/001_initial.sql` (physical schema) → các tài liệu khác. Khi phát hiện mâu thuẫn **không tự suy đoán**: tạo ADR issue và cập nhật tất cả artifact liên quan trong cùng PR.

## MVP và giới hạn
- **MVP**: iOS native SwiftUI, exercise catalog có poster/video, planner tuần, player, manual reps + hold/rest timers, journal, local SQLite/GRDB, Live Activity + notifications, sync .NET/PostgreSQL, AI review async có duyệt.
- **Không MVP**: camera tự đếm rep, Apple Watch native app, social/community, live video trên Lock Screen, video bắt buộc hoạt động khi chưa tải, AI tự động đổi giáo án không xin phép.
- **Cực kỳ quan trọng**: Live Activity có thể hiển thị timer trên Lock Screen nhưng **nút/toggle không thể thực thi khi iPhone vẫn khóa**; người dùng phải xác thực/mở khóa (theo tài liệu Apple). Không đặt yêu cầu “hoàn thành set mà không unlock” thành acceptance criterion.
- Không mặc định notification đúng từng giây hoặc background sync được chạy ngay khi có mạng: đều best-effort của iOS.

## Definition of Done toàn dự án
- Chạy trên **iPhone thật** với các ca offline/khóa máy; simulator chỉ là test bổ trợ.
- Từ clean checkout có lệnh build/test được tài liệu hóa cho iOS/backend, không lộ secrets.
- Các state transition từ app, widget intent, notification action đều gọi cùng domain command, được kiểm thử và ghi durable trước UI success.
- API có contract tests; sync idempotent; migrations reproducible; accessibility và dark mode được kiểm tra.
- AI chỉ tạo recommendation, không tự cập nhật plan; có thể tắt AI mà workout vẫn dùng được.

## Nguồn quy chiếu nền tảng (kiểm chứng 2026-11-07)
- [Apple — Adding interactivity to widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities)
- [Apple — Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)
- [Apple — SwiftUI Text(timerInterval:)](https://developer.apple.com/documentation/swiftui/text/init%28timerinterval%3Apausetime%3Acountsdown%3Ashowshours%3A%29)
- [Apple — Scheduling local notifications](https://developer.apple.com/documentation/usernotifications/scheduling-a-notification-locally-from-your-app)
- [Apple — BGTaskScheduler](https://developer.apple.com/documentation/backgroundtasks/bgtaskscheduler)
- [Apple — App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)
- [Microsoft — .NET Support Policy](https://dotnet.microsoft.com/en-us/platform/support/policy)

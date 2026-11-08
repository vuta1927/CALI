# CaliCore

Gói Swift thuần (Foundation + GRDB + CaliDomain), không dùng UIKit/ActivityKit/AppIntents, nên build và test được trên Linux. Gói này là phần không phụ thuộc nền tảng của **POC-002** (docs/20 phase 0) và là nền cho IOS-001 sau khi có GO.

## Thành phần

| File | Vai trò |
|---|---|
| `CaliDatabase.swift` | Mở `DatabasePool` (WAL, `busyMode = .timeout(5)`, khoá ngoại bật). Migration `v1` gồm `local_session_state` (partial unique index: tối đa 1 phiên `active`), `set_results`, `sync_outbox` và `processed_commands`. UUID lưu dạng TEXT chữ thường. |
| `WorkoutCoordinator.swift` | **Single writer** (ADR-013). `handle(command)` chạy mỗi lệnh trong một transaction `BEGIN IMMEDIATE`, theo pipeline docs/03 §6: dedupe `commandId` → load → reduce → lưu state (kèm revision mong đợi) → `set_results` → outbox → `processed_commands` → COMMIT. Side effect (thông báo, Live Activity) do app làm **sau** COMMIT. |
| `CommandIdentity.swift` | UUID tất định (RFC 9562 version 8, băm FNV-1a 2×64 bit, không phải băm mật mã). `commandId` của nút Live Activity lấy từ (session, revision đã render, action), nên chạm đôi chỉ áp dụng một lần. `setResultId` lấy từ (session, execution, setIndex). |

Các kết quả coordinator trả về cho nút màn khoá:
- `stale_view`: snapshot cũ hơn state đang lưu.
- `needs_app`: xác nhận cần mở app, ví dụ bài reps hoặc chưa có gợi ý thời lượng.
- `no_session`: không có phiên.
- `already_resolved`: set đã có kết quả với một `commandId` khác.

Coordinator **không bao giờ** tự suy ra là set đã hoàn thành chỉ vì đồng hồ đếm về 0.

## Phiên bản phụ thuộc

GRDB được ghim **chính xác `7.12.0`**, cả ở `Package.swift` lẫn ở `packages.GRDB.exactVersion` trong `ios/project.yml`. Khi nâng cấp phải sửa đồng thời cả hai.

## Chạy test trên Linux (Docker, từ thư mục gốc repo, PowerShell)

```powershell
docker run --rm -v "${PWD}:/src" -w /src/ios/Packages/CaliCore swift:6.2-noble bash -c "apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && swift test --build-path /tmp/build"
```

- Image `swift:6.2-noble` không có sẵn `sqlite3.h`, nên GRDB trên Linux cần `libsqlite3-dev`.
- `--build-path /tmp/build` giữ thư mục build trong container. Cách này tránh ghi `.build/` vào ổ Windows được mount, nơi build chậm và hay lỗi quyền.
- Gói chưa nằm trong CI Linux `.github/workflows/swift-domain.yml`; workflow đó chỉ chạy CaliDomain. Muốn thêm job thì cần cài `libsqlite3-dev` trên runner.

## Giới hạn hiện tại (POC)

- App chỉ dùng gói này qua màn **Cá nhân → POC thiết bị** (`ios/CaliApp/POC`), với một DB riêng `Application Support/POC/poc-002.sqlite`. `LocalStore` vẫn là store chính cho tới IOS-001.
- Khi phiên đã tồn tại được cập nhật, `sync_outbox.base_version` hiện là `nil`, vì POC chưa biết version server đã xác nhận: `TODO(IOS-001)`. Payload trong outbox cũng chưa được ánh xạ sang `contracts/entity-payloads.schema.json`.
- `handle` không tự gọi `reconcile`. App tự gọi `reconcile` ở tick foreground, tức là trong một callback thực thi được.

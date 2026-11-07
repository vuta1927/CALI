# CALI iOS — build không cần Mac (I0)

Thư mục này chứa app iOS native (SwiftUI, iOS 18+, Swift 6). Không có Mac, nên:

- Xcode project được **sinh từ `project.yml` bằng XcodeGen** (ADR-011) — không commit `.xcodeproj`.
- App chỉ được build trên **GitHub Actions macOS runner** (`.github/workflows/ios-build.yml`), cho ra file **`.ipa` chưa ký**.
- Trên Windows, **Sideloadly** ký lại `.ipa` bằng Apple ID miễn phí và cài lên iPhone qua USB.

Xem bối cảnh ở `docs/16-implementation-plan.md` §1 (ngân sách phút macOS, vòng lặp sideload) và §10 (rủi ro P-01).

## Cấu trúc

| Đường dẫn | Nội dung |
|---|---|
| `project.yml` | XcodeGen spec: targets `CaliApp`, `CaliActivityWidget` (WidgetKit extension, nhúng vào app), `CaliAppTests` |
| `Config/*.xcconfig` | Bundle ID, `DEVELOPMENT_TEAM`, version. Chỉ placeholder `com.example`, Team rỗng — **không commit ID thật** |
| `CaliApp/` | POC SwiftUI hoàn chỉnh: 5 tab, workout player, mock catalog/plan/history/AI, lưu JSON local và side effects notification/Live Activity |
| `CaliActivityWidget/` | Live Activity (Lock Screen + Dynamic Island), chỉ render — không đọc DB, chưa có nút/intent (ADR-013) |
| `Shared/WorkoutAttributes.swift` | `ActivityAttributes` + `ContentState` (docs/05 §2), biên dịch vào cả app và extension |
| `CaliAppTests/` | Unit test XCTest (chạy trên Simulator, chỉ khi bật thủ công) |

`ios/Packages/CaliDomain` được link trực tiếp vào app. Workout player gửi command qua
`WorkoutReducer` và gọi reconcile; countdown hết giờ chỉ chuyển sang bước nhập kết quả,
không tự ghi nhận người dùng đã hoàn thành set.

## UI POC trên mock data

Commit `606030e` cung cấp lát cắt UI/UX chạy hoàn toàn local, chưa kết nối backend:

- 5 tab: **Hôm nay**, **Giáo án**, **Bài tập**, **Lịch sử**, **Cá nhân**.
- Workout player toàn màn hình: ready → pre-countdown → active → xác nhận kết quả → rest → summary; có pause, skip kèm lý do, +30 giây nghỉ, abandon và cảnh báo clock jump/recovery.
- Dữ liệu đang tập được persist atomically vào `Application Support/cali-poc.json`; app có thể khôi phục session active sau khi mở lại.
- Đề xuất AI là mẫu cố định, chỉ thay đổi giáo án sau khi người dùng accept/reject và luôn tạo audit entry.
- Catalog/plan/history/AI mẫu đều được gắn nhãn **Dữ liệu mẫu**. Poster dùng SF Symbol và nhãn **PLACEHOLDER**, không giả làm media production.
- TODO còn lại: thay JSON bằng GRDB/outbox (`POC-003`), thay poster bằng media catalog (`POC-002`), kiểm chứng Live Activity và hành vi lock/unlock trên iPhone thật (`POC-001/002`).

Archive unsigned của POC đã build thành công trên GitHub Actions với Xcode 16.4 ở commit
`606030e` (run `42384088704`). Việc sideload và device matrix trên iPhone thật vẫn chưa được xác minh.

## Quản lý bài tập và giáo án (IOS-009 / MED-002)

Tab **Bài tập** → **+** để thêm; mở chi tiết → **Sửa** để đổi thông tin, ảnh/video.
Media nhận link HTTPS hoặc chọn từ Thư viện ảnh/Tệp. Tệp được sao chép vào
Application Support để dùng offline, không gửi lên server. Link trang video có nút mở
bằng trình duyệt; phát trong app cần URL video tương thích AVPlayer.

Tab **Giáo án** → menu **…** để sửa tên/xóa; chạm ngày nghỉ để thêm buổi.
Mỗi buổi có menu sửa/xóa, editor có chọn ngày, thêm/bớt/sắp xếp bài và mục tiêu.
Xóa giáo án giữ lịch sử và buổi đang tập; màn hình trống cho phép tạo lại.

Chi tiết lưu trữ, phạm vi contract và checklist thiết bị: [docs/17](../docs/17-content-editing.md).

## CI build như thế nào

Workflow `ios-build` (runner `macos-15`) chỉ chạy khi:

1. **Chạy tay** (`workflow_dispatch`) — tab *Actions* → *ios-build* → *Run workflow*. Tùy chọn:
   - `run_tests` (mặc định `false`): chạy thêm job unit test trên Simulator — tốn thêm phút macOS.
   - `bundle_prefix` (mặc định `com.example`): prefix bundle ID **chỉ cho lần build này** (ví dụ `com.tenban`), dùng khi Sideloadly báo App ID không khả dụng. Không commit prefix cá nhân vào repo.
2. **Pull request có label `ios-build`** (build lại mỗi khi push thêm commit vào PR đó).
3. **Push lên `main`** có thay đổi trong `ios/**` hoặc file workflow.

Các bước: chọn Xcode (ưu tiên `XCODE_VERSION` trong workflow, không có thì dùng mặc định của image) → `brew install xcodegen` → `xcodegen generate --spec ios/project.yml` → `xcodebuild archive` (Debug, `iphoneos`, `CODE_SIGNING_ALLOWED=NO`, `CALI_BUILD_SHA=<commit>`) → kiểm tra `PlugIns/CaliActivityWidget.appex` có trong app → đóng gói `Payload/CaliApp.app` thành `CaliApp-unsigned-<shortsha>.ipa` → upload artifact (giữ 7 ngày).

**Theo dõi phút:** cuối mỗi job có bước *Record job duration* in thời điểm bắt đầu/kết thúc và số giây vào *Job summary*. GitHub làm tròn lên theo phút cho mỗi job và nhân hệ số 10 cho macOS ở repo private. Ghi số đo thực tế vào bảng theo dõi ở docs/16 §8, không ước lượng trước.

**Khi build lỗi:** đọc phần "errors/warnings" trong log bước *Archive*; log đầy đủ được upload thành artifact `xcodebuild-archive-log-<run_id>`.

## Tải artifact

- Web: *Actions* → chọn run → mục **Artifacts** → `CaliApp-unsigned-<shortsha>` → tải về file `.zip` → giải nén ra `CaliApp-unsigned-<shortsha>.ipa`.
- Hoặc dùng GitHub CLI: `gh run download <run-id> -n CaliApp-unsigned-<shortsha>`.

Mở app sau khi cài, dòng *Build* phải trùng commit SHA của run (đó là bằng chứng đang chạy đúng bản build).

## Cài lên iPhone bằng Sideloadly (Windows)

### Chuẩn bị một lần

1. Cài **iTunes** và **iCloud** bản tải trực tiếp từ website Apple (bản *win64 installer*), **không dùng bản Microsoft Store** — Sideloadly cần driver/thư viện của bản cài từ web. Nếu đã có bản Store, gỡ ra trước.
2. Cài **Sideloadly** từ `sideloadly.io`.
3. Cắm iPhone bằng cáp USB, mở khóa máy, chọn **Trust This Computer / Tin cậy máy tính này**. Kiểm tra iTunes nhận được máy.
4. Bật **Developer Mode** trên iPhone: *Settings → Privacy & Security → Developer Mode* → bật → khởi động lại → xác nhận *Turn On*. (Mục này có thể chỉ xuất hiện sau lần đầu sideload một app.)

### Mỗi lần cài

1. Mở Sideloadly, kéo file `.ipa` vào ô IPA.
2. Chọn iPhone trong danh sách thiết bị.
3. Nhập Apple ID (nên dùng Apple ID phụ dành cho dev), nhấn **Start**, nhập mật khẩu và mã 2FA khi được hỏi.
4. Lần đầu: trên iPhone vào *Settings → General → VPN & Device Management* → mục **Developer App** mang Apple ID của bạn → **Trust**. Cần có mạng để Apple xác minh.
5. Mở app CALI: thấy chữ "CALI", version và build SHA là đạt DoD của I0.

Cài lại cùng bundle ID sẽ ghi đè bản cũ và thường giữ dữ liệu app; xóa app thì mất dữ liệu local.

## Giới hạn của Apple ID miễn phí

| Giới hạn | Ảnh hưởng tới CALI |
|---|---|
| Chứng chỉ/profile hết hạn sau **7 ngày** | App không mở được nữa → cài lại bằng Sideloadly (dùng lại artifact gần nhất nếu còn, artifact chỉ giữ 7 ngày) |
| Tối đa **3 app sideload** đang hoạt động trên một thiết bị | App có extension có thể chiếm nhiều hơn một suất — để trống chỗ |
| Giới hạn số **App ID mới** đăng ký trong 7 ngày (khoảng 10) | **Mỗi extension là một App ID riêng**: CALI dùng 2 (`<prefix>.cali` và `<prefix>.cali.widget`). Đổi `bundle_prefix` nhiều lần sẽ nhanh hết hạn mức |
| Không có App Groups (nhiều khả năng), Push, Sign in with Apple, TestFlight | Đúng với ADR-013: widget chỉ render, không chia sẻ DB. Kiểm chứng App Groups ở POC-001 |

## Nếu Sideloadly không ký được widget extension (rủi ro P-01)

Đây là điều I0 cần chứng minh sớm. Nếu lỗi, **ghi lại đầy đủ** vào `evidence/I0/` (hoặc issue) trước khi thử cách khác:

- Phiên bản Sideloadly, Windows, iTunes/iCloud (bản web hay Store).
- Model iPhone và phiên bản iOS.
- Tên artifact/commit SHA của `.ipa` và link run CI.
- **Toàn bộ log của Sideloadly** (copy text) và nguyên văn thông báo lỗi; ảnh chụp màn hình.
- Bundle ID đã dùng (`com.example` hay prefix khác) và lỗi có nhắc tới App ID, provisioning profile, entitlement hay `CaliActivityWidget.appex` không.
- Kết quả: cài thất bại hoàn toàn / cài được nhưng không mở / mở được.

Hướng xử lý theo docs/16: thử đổi `bundle_prefix` (nếu lỗi là App ID đã bị dùng), thử AltStore, hoặc tạm cài app không có extension để tiếp tục phần app của POC; nếu vẫn không được thì cân nhắc mua tài khoản Apple Developer sớm hơn.

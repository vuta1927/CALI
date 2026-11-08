# POC-001 — Countdown trên Lock Screen / Dynamic Island, thông báo, hành vi khi khoá

> **Trạng thái:** code đã sẵn sàng nhưng chưa build trên macOS và chưa chạy trên iPhone. Mọi bảng kết quả dưới đây đang **để trống có chủ đích**. Chỉ người kiểm thử điền, dựa trên quan sát thật kèm video, ảnh hoặc log. Không điền suy đoán.

Tham chiếu:
- docs/05 §4–§6, docs/16 §5 (POC-001), docs/20 phase 0.
- docs/12: T-02, T-05, T-11, T-12.
- ADR-013: single writer trong process app, không cần App Group.

## 1. Thông tin lần chạy

| Trường | Giá trị |
|---|---|
| Người kiểm thử | |
| Ngày giờ bắt đầu (UTC) | |
| Model iPhone (Cài đặt → Cài đặt chung → Giới thiệu) | |
| Có Dynamic Island? | |
| Phiên bản iOS | |
| Build (màn POC, dòng "Build": version (build) · SHA) | |
| GitHub Actions run id của `.ipa` | |
| Cách ký / cài (Sideloadly + free account / Apple Developer) | |
| Khoá máy bằng (Face ID / Touch ID / passcode) | |
| Thời gian tự khoá (Cài đặt → Màn hình & Độ sáng) | |

## 2. Code POC này gồm gì

- **Lối vào:** Cá nhân → mục "Nhà phát triển" → **POC thiết bị (POC-001/002)**, file `ios/CaliApp/POC/POCDeviceGateView.swift`. Màn này không thay đổi UI hay `LocalStore` của buổi tập thường.
- **Phiên POC:**
  - Bài "Plank (POC)": giữ 15 giây × 3 set, nghỉ 60 giây, đếm ngược 3 giây.
  - Dùng DB riêng `Application Support/POC/poc-002.sqlite` (xem POC-002).
- **Live Activity:**
  - Gắn cờ `deviceGatePOC = true`.
  - Đồng hồ do hệ thống vẽ (`Text(timerInterval:)`) từ deadline UTC đã lưu. App không cập nhật Activity mỗi giây, chỉ khi đổi phase.
- **Nút trên màn khoá / Dynamic Island:** `POCLiveActivityIntent`.
  - `+30s` khi đang nghỉ.
  - `Xong set` khi chờ xác nhận.
  - Intent khai báo `authenticationPolicy = .requiresAuthentication`.
  - Lớp thứ hai là **guard** trong app (mặc định bật): nếu `isProtectedDataAvailable == false` thì từ chối và **không ghi DB**.
  - COAMI **không hứa** thao tác được khi máy đang khoá (docs/05 §1).
- **Thông báo:** id `cali.poc.phase-deadline`, đặt tại deadline hết giờ giữ và hết giờ nghỉ. Thông báo chỉ để nhắc và không bao giờ tự ghi kết quả.
  - Chưa có cảnh báo "còn 10 giây" (docs/16 §5). Đây là khoảng trống đã biết.
- **App Group:** màn POC hiện dòng `App Group: available(group.<bundle id>)` hoặc `unavailable(...)`. ADR-013 không cần App Group; dòng này chỉ để ghi lại hiện trạng.
- **Nhật ký bằng chứng:**
  - File `Application Support/POC/poc-events.jsonl`, xuất bằng nút **Xuất nhật ký (poc-events.jsonl)**.
  - Mỗi dòng có `event`, `at` (UTC), `monotonicNs`, `timeZone`.
  - Cũng ghi vào unified log, subsystem `cali.poc`; xem bằng Console.app nếu có máy Mac.

**Cảnh báo:** **không chạy buổi tập thường cùng lúc với phiên POC**. Khi đó `AppStore` huỷ thông báo và Live Activity của buổi tập thường. Live Activity POC đã được lọc riêng, nhưng kết quả dễ bị nhiễu.

## 3. Chuẩn bị

1. Cài `.ipa` đã ký lên iPhone. Mở app → Cá nhân → POC thiết bị.
2. Khi được hỏi, cho phép thông báo. Kiểm tra dòng `Live Activities: bật` (nếu tắt: Cài đặt → COAMI → Live Activities).
3. Chụp màn hình phần **Môi trường**: Build, iOS, DB, App Group, Thông báo, Live Activities, Protected data, guard.
4. Bấm **Xoá nhật ký** để mỗi lần chạy có log sạch.
5. Bật quay màn hình (Trung tâm điều khiển). Với thao tác trên màn khoá, nên quay bằng một máy khác để thấy cả Face ID hoặc passcode.

## 4. Các bước kiểm thử

Mỗi ca ghi: thời điểm UTC, video hoặc ảnh, và các dòng log liên quan (tên `event`).

| Mã | Ca (tham chiếu) | Các bước | Kỳ vọng |
|---|---|---|---|
| P1-01 | Tự khoá, hold (T-02, docs/05 §5 dòng 1) | Bắt đầu phiên POC → hết đếm ngược → set đang giữ. Ở giây thứ 4 bấm nút sườn để khoá. Ở giây thứ 10 đánh thức màn hình (chưa mở khoá). | Đồng hồ trên Lock Screen vẫn chạy và khớp thời gian thật. Sau khi mở khoá, set **không** tự được xác nhận: `set_results` không tăng, phase là `exercising` hoặc `awaiting_result`. |
| P1-02 | Tắt màn hình, nghỉ | Xác nhận set 1 trong app → đang nghỉ 60s → khoá máy và để màn hình tắt khoảng 30 giây → đánh thức. | Đồng hồ nghỉ còn khoảng 30 giây, khớp thời gian thật. |
| P1-03 | Dynamic Island / không có DI (docs/05 §5 dòng 1–2) | Khi đang nghỉ, về Home Screen. | Có Dynamic Island: compact/expanded hiện phase và đồng hồ, bản mở rộng có nút `+30s`. Không có DI: Live Activity hiện trên Lock Screen. |
| P1-04 | Chế độ máy bay (docs/05 §5 dòng 3) | Bật chế độ máy bay → chạy một set và một lần nghỉ trọn vẹn, có khoá máy. | Đồng hồ, thông báo và log vẫn hoạt động. Không có lỗi mạng. |
| P1-05 | Chạm khi **đang khoá**, guard BẬT (T-11, docs/05 §5 dòng 4) | Đang nghỉ → khoá máy, **chờ ít nhất 15 giây** (cần passcode để protected data tắt) → đánh thức nhưng **không mở khoá** → bấm `+30s` trên Live Activity. | Ghi lại đúng những gì iOS làm: có đòi Face ID/passcode không? `perform` có chạy trước khi mở khoá không? Nếu nó chạy khi đang khoá, log phải có `intent_received` với `protectedDataAvailable=false`, rồi `intent_refused_locked`, và deadline không đổi. Sau khi mở khoá: deadline +30s (`intent_handled`, `status=applied`), hoặc người dùng phải bấm lại. |
| P1-06 | Chạm khi **đang khoá**, guard TẮT | Tắt toggle "Chặn chạm khi máy khoá (guard)" → lặp lại P1-05. | Đây là quan sát quyết định về `authenticationPolicy`: iOS có chặn tới khi xác thực không? Nếu `intent_handled` xuất hiện khi `protectedDataAvailable=false` thì ghi rõ, kèm video. **Bật lại guard sau ca này.** |
| P1-07 | `Xong set` trên màn khoá | Giữ app mở tới hết 15s của set (phase `awaiting_result`, dòng "Gợi ý (ms)" có số) → khoá máy → bấm `Xong set` (đã mở khoá và chưa mở khoá, mỗi kiểu một lần). | Có xác thực: `intent_handled`, `status=applied`, `set_results` +1, phase `resting`. Nếu chưa có gợi ý: `errorCode=needs_app`, không ghi gì. |
| P1-08 | Thông báo tại deadline | Đang giữ hoặc nghỉ → về Home Screen rồi khoá máy, chờ tới deadline. | Thông báo "POC: hết thời gian mục tiêu" hoặc "POC: hết giờ nghỉ" đến gần deadline. Ghi độ trễ (giây) so với `deadlineUtc` trong `notification_scheduled`. Thông báo không làm đổi state. |
| P1-09 | Từ chối thông báo (T-12, docs/05 §5 dòng 5) | Cài đặt → COAMI → Thông báo → tắt → quay lại màn POC (dòng Thông báo = `denied`) → chạy hết một lần nghỉ trong foreground. | Đồng hồ trong app vẫn chạy; phiên vẫn dùng được. Không có thông báo và không có lỗi chặn. |
| P1-10 | +30s rồi về foreground (T-05) | Đang nghỉ → bấm `+30s` trên Live Activity (đã mở khoá) → mở app. | Deadline mới = cũ + 30s. Log có **một** `notification_scheduled` mới với deadline mới. Chỉ có một thông báo khi hết giờ, không trùng. |
| P1-11 | Focus / Im lặng | Bật Focus (ví dụ Không làm phiền) hoặc gạt Im lặng → chờ deadline. | Ghi lại thông báo có hiện, có âm thanh hay không. Đây là hành vi best-effort, chỉ quan sát. |
| P1-12 | Tắt Live Activities | Cài đặt → COAMI → tắt Live Activities → mở màn POC, bắt đầu phiên mới. | Log có `live_activity_disabled`. Phiên trong app vẫn chạy đầy đủ (tiêu chí GO: "app vẫn dùng được khi không có Activity"). |
| P1-13 | App Group | Đọc dòng App Group trên màn POC. | Ghi `available` hoặc `unavailable` cùng loại tài khoản ký. project.yml hiện không khai báo App Group, nên `unavailable` là bình thường. |
| P1-14 | Phiên dài > 8h (docs/05 §5 dòng 7) | Không làm trong đợt này. Ghi "chưa kiểm thử". | — |

## 5. Bảng kết quả (để trống tới khi chạy thật)

| Mã | Thời điểm (UTC) | Kết quả (Đạt / Không đạt / Ghi chú) | Quan sát thực tế | Bằng chứng (tên file video/ảnh, dòng log) |
|---|---|---|---|---|
| P1-01 | | | | |
| P1-02 | | | | |
| P1-03 | | | | |
| P1-04 | | | | |
| P1-05 | | | | |
| P1-06 | | | | |
| P1-07 | | | | |
| P1-08 | | | | |
| P1-09 | | | | |
| P1-10 | | | | |
| P1-11 | | | | |
| P1-12 | | | | |
| P1-13 | | | | |
| P1-14 | | | | |

Đặt file bằng chứng cạnh README này: `P1-05-locked-tap.mov`, `poc-events-<ngày>.jsonl`, ...

## 6. Tiêu chí GO / NO-GO (docs/05 §6)

> **GO** when: Live Activity can glanceably display phase+timer on real supported devices; transition via authorized user action is reliable; session is durable without network; app remains usable without Activity. **NO-GO** if product requirement insists on unauthenticated interaction while screen locked; redesign UX around glance + unlock, not a prohibited workaround.

| Tiêu chí | Ca liên quan | Đạt? |
|---|---|---|
| Live Activity hiện phase + đồng hồ trên thiết bị thật | P1-01, P1-02, P1-03 | |
| Chuyển trạng thái bằng thao tác **đã xác thực** hoạt động ổn định | P1-05, P1-07, P1-10 (và POC-002) | |
| Phiên bền vững khi không có mạng | P1-04 (và POC-002) | |
| App vẫn dùng được khi không có Activity hoặc thông báo | P1-09, P1-12 | |
| Không có yêu cầu thao tác chưa xác thực khi khoá máy (NO-GO nếu có) | P1-05, P1-06 | |

Kết luận (PO / người kiểm thử ký): ______

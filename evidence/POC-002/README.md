# POC-002: Lệnh bền vững và single writer (GRDB + WorkoutCoordinator + LiveActivityIntent)

> **Trạng thái:** code đã sẵn sàng, nhưng chưa build trên macOS và chưa chạy trên iPhone.
> - Phần thuần Swift (`ios/Packages/CaliCore`) đã có test tự động trên Linux (xem §2).
> - Phần trên thiết bị: mọi bảng kết quả dưới đây **cố ý để trống**. Người kiểm thử chỉ điền từ quan sát thật. Không điền suy đoán.

Tham chiếu:
- docs/03 §6 (pipeline `handle`)
- docs/16 §5 (POC-002)
- docs/05 §4 bước 5 và 7, §6
- docs/12: T-04, T-09, T-17
- ADR-013

## 1. Thông tin lần chạy

| Trường | Giá trị |
|---|---|
| Người kiểm thử | |
| Ngày giờ bắt đầu (UTC) | |
| Model iPhone | |
| Phiên bản iOS | |
| Build (màn POC, dòng "Build") | |
| GitHub Actions run id của `.ipa` | |
| Cách ký / cài | |
| Khoá máy bằng (Face ID / Touch ID / passcode) | |

## 2. Thiết kế đang được kiểm chứng

**Cơ sở dữ liệu:**
- Một DB GRDB 7.12.0 (ghim chính xác) trong container app, không dùng App Group: `Application Support/POC/poc-002.sqlite`, chế độ WAL, busy timeout 5 giây.
- Các bảng: `local_session_state`, `set_results`, `sync_outbox`, `processed_commands`.

**`WorkoutCoordinator.handle(command)`:**
- Chạy trong một transaction `BEGIN IMMEDIATE`: dedupe `commandId` → load → reduce → lưu state → `set_results` → outbox → `processed_commands` → COMMIT.
- Side effect (thông báo, Live Activity) chạy **sau** COMMIT.
- Gửi lại cùng `commandId` trả về kết quả cũ (`replayed=true`) và không ghi thêm gì.

**Nút trên màn khoá:**
- Nút gọi `POCLiveActivityIntent`. iOS chạy intent trong **process app**.
- Intent gọi **cùng** `POCRuntime.shared.coordinator` mà màn POC dùng. Widget extension không mở DB.
- `commandId` tất định theo (session, revision đang hiển thị, action). Vì vậy hai lần chạm trên cùng một snapshot chỉ áp dụng một lần.

**Mã từ chối:**
| Mã | Ý nghĩa |
|---|---|
| `stale_view` | Snapshot đã cũ |
| `needs_app` | Cần mở app để xác nhận |
| `no_session` | Không có phiên |
| `already_resolved` | Set đã có kết quả từ một lệnh khác |

**Test tự động trên Linux** (Docker `swift:6.2-noble`, xem `ios/Packages/CaliCore/README.md`):
- 19/19 test CaliCore đạt.
- Phạm vi: dedupe, chạm đôi cùng hoặc khác `commandId`, ghi đồng thời từ hai connection, mở lại DB sau khi "kill", `stale_view`, `needs_app`.
- Kết quả này **không** thay thế bằng chứng trên iPhone.

**Cảnh báo:** **không chạy buổi tập thường cùng lúc với phiên POC.** `AppStore` của buổi tập thường dùng `LocalStore` và có thông báo riêng.

## 3. Cách đọc bằng chứng

- **Phần "Cơ sở dữ liệu" trên màn POC** hiện số dòng của `local_session_state`, `set_results`, `sync_outbox`, `processed_commands`, cùng 20 outcome gần nhất (kind · status · errorCode · revision · commandId).
- **Nhật ký** `poc-events.jsonl` (nút **Xuất nhật ký**). Các event chính:

| Event | Ý nghĩa |
|---|---|
| `command_handled` | `source=app`, lệnh từ màn POC |
| `intent_received` | Có `renderedRevision`, `protectedDataAvailable`, `appState`, `guard` |
| `intent_handled` | Có `commandId`, `status`, `replayed`, `errorCode`, `setResultIds` |
| `intent_refused_locked` | Guard từ chối chạm khi máy khoá |
| `double_tap_same_command_id` | Báo cáo của test chạm đôi cùng `commandId` |
| `double_confirm_different_command_ids` | Báo cáo của test chạm đôi khác `commandId` |
| `runtime_opened` | Mỗi lần process mở DB, nên đánh dấu được lần khởi động lại |
| `reconciled` | Coordinator đối soát lại state |
| `clock_jump_detected` | Phát hiện đổi giờ |
| `clock_jump_acknowledged` | Người dùng đã xác nhận đổi giờ |

- Trước mỗi ca, chụp phần "Cơ sở dữ liệu". Sau ca, chụp lại để so số dòng.

## 4. Các bước kiểm thử

Chuẩn bị: mở Cá nhân → POC thiết bị → **Xoá nhật ký** → **Bắt đầu phiên POC (Plank giữ 15s × 3, nghỉ 60s)**.

| Mã | Ca (tham chiếu) | Các bước | Kỳ vọng |
|---|---|---|---|
| P2-01 | Chạm đôi trong app, cùng `commandId` (T-04) | 1. Đưa phiên tới đúng phase:<br>• Phase `resting`: xác nhận một set rồi chờ.<br>• Phase `awaiting_result`: giữ app mở tới hết 15 giây, phải có "Gợi ý (ms)".<br>2. Bấm **Chạm đôi, cùng commandId (mô phỏng nút màn khoá)**. | • Đúng 1 `applied` và 1 `replayed=true`.<br>• `set_results` tăng tối đa 1.<br>• `processed_commands` +1.<br>• Event `double_tap_same_command_id` có `setResultsTotal` khớp. |
| P2-02 | Hai lần xác nhận khác `commandId` (T-04) | Ở phase `awaiting_result`, bấm **Chạm đôi xác nhận, khác commandId**. | • 1 `applied` và 1 `already_resolved` hoặc `rejected`.<br>• Chỉ 1 `set_result` mới.<br>• Outbox chỉ có 1 mutation `set_result` mới. |
| P2-03 | Chạm đôi **từ màn khoá** khi app đang chạy nền (yêu cầu docs/16) | 1. Ở phase `awaiting_result` có gợi ý, về Home Screen. App vẫn chạy nền, không kill.<br>2. Khoá máy, mở khoá bằng Face ID nhưng vẫn ở Lock Screen.<br>3. Bấm `Xong set` hai lần thật nhanh.<br>4. Lặp lại với `+30s` khi đang nghỉ. | • Hai lần chạm trên **cùng snapshot** cùng `renderedRevision`: 1 `applied` và 1 `replayed`.<br>• Nếu lần chạm thứ hai đến **sau khi** Live Activity đã vẽ revision mới, `renderedRevision` của nó khác. Với `Xong set`, nút không còn hiện (phase đã thành `resting`). Với `+30s`, đó là một lệnh hợp lệ thứ hai: ghi rõ như vậy, không tính là trùng.<br>• Luôn chỉ 1 `set_result` cho mỗi set. |
| P2-04 | Chạm từ Activity và từ app gần như đồng thời (docs/16) | 1. Ở phase `awaiting_result`, app chạy nền, bấm `Xong set` trên Dynamic Island hoặc Lock Screen (đã mở khoá).<br>2. Ngay lập tức mở app và bấm **Xác nhận set (trong app)**. | • Chỉ 1 `set_result`.<br>• Lệnh đến sau bị `rejected`: phase đã đổi, hoặc `already_resolved`.<br>• Không lỗi DB, không treo. |
| P2-05 | Kill sau khi xác nhận (T-09, docs/05 §5 dòng 8) | 1. Xác nhận một set (trong app hoặc màn khoá) và chụp phần "Cơ sở dữ liệu".<br>2. Vuốt tắt app trong app switcher.<br>3. Mở lại app vào màn POC. | • Có `runtime_opened` mới.<br>• Phase, revision và số dòng giống trước khi kill.<br>• Không set trùng, không mất set. |
| P2-06 | Kill trong lúc nghỉ hoặc giữ, mở lại sau deadline (docs/05 §4 bước 7) | 1. Khi đang **giữ**, kill app.<br>2. Chờ quá 15 giây rồi mở lại màn POC.<br>3. Lặp lại khi đang **nghỉ**: chờ quá 60 giây rồi mở lại. | • Giữ: phase `awaiting_result`, "Gợi ý (ms)" = `–` vì đối soát trễ, `set_results` **không** tăng. Phiên không tự ghi set hoàn thành.<br>• Nghỉ: chuyển sang chuẩn bị set tiếp, không thêm `set_result`.<br>• Live Activity được đồng bộ lại hoặc kết thúc đúng. |
| P2-07 | Intent khi app đã bị kill | 1. Ở phase `resting`, kill app. Live Activity vẫn hiện.<br>2. Mở khoá, bấm `+30s` trên Lock Screen. | Ghi lại iOS có khởi chạy app nền để chạy intent không. Nếu có: `runtime_opened` rồi `intent_received` (với `appState`) rồi `intent_handled`, và deadline +30s. Nếu không: ghi là không chạy. Docs/16 yêu cầu kiểm tra khi app suspend hoặc bị kill. |
| P2-08 | Lùi giờ hệ thống (T-17, docs/05 §5 dòng 6) | 1. Đang nghỉ, màn POC mở.<br>2. Cài đặt → Cài đặt chung → Ngày & Giờ → tắt "Đặt tự động" → lùi 10 phút.<br>3. Quay lại app. | • Mục "Đồng hồ" xuất hiện, log có `clock_jump_detected`.<br>• Thời lượng đã ghi không đổi, không có set ma.<br>• Sau khi bấm **Xác nhận đổi giờ và đối soát**: `clock_jump_acknowledged`, phiên chạy tiếp.<br>• **Bật lại "Đặt tự động" sau ca này.** |
| P2-09 | Đổi múi giờ | Đang nghỉ, đổi múi giờ (ví dụ sang Asia/Tokyo) rồi quay lại app. | • "Hạn (UTC)" không đổi.<br>• Trường `timeZone` trong log đổi theo.<br>• Không có chuyển phase sai. |
| P2-10 | Không mạng (docs/05 §6) | Bật chế độ máy bay, chạy trọn phiên 3 set tới **Hoàn thành buổi**. | • `set_results` = 3.<br>• Outbox có các mutation tương ứng, chưa gửi đi (chưa có sync).<br>• Không có lỗi. |
| P2-11 | Kiểm tra DB tổng (DoD docs/16) | Sau P2-10, chụp phần "Cơ sở dữ liệu" và xuất log. | • Mỗi lệnh `applied` có 1 dòng `processed_commands`.<br>• Mỗi set đã xác nhận có đúng 1 `set_result` và 1 mutation `set_result` trong outbox. |

## 5. Bảng kết quả (để trống tới khi chạy thật)

| Mã | Thời điểm (UTC) | Kết quả (Đạt / Không đạt / Ghi chú) | Số dòng trước → sau (state / set_results / outbox / processed) | Bằng chứng (video, ảnh, dòng log) |
|---|---|---|---|---|
| P2-01 | | | | |
| P2-02 | | | | |
| P2-03 | | | | |
| P2-04 | | | | |
| P2-05 | | | | |
| P2-06 | | | | |
| P2-07 | | | | |
| P2-08 | | | | |
| P2-09 | | | | |
| P2-10 | | | | |
| P2-11 | | | | |

## 6. Tiêu chí GO / NO-GO (docs/05 §6)

> **GO** when: Live Activity can glanceably display phase+timer on real supported devices; transition via authorized user action is reliable; session is durable without network; app remains usable without Activity. **NO-GO** if product requirement insists on unauthenticated interaction while screen locked; redesign UX around glance + unlock, not a prohibited workaround.

| Tiêu chí | Ca liên quan | Đạt? |
|---|---|---|
| Chuyển trạng thái bằng thao tác đã xác thực hoạt động ổn định, không trùng | P2-01 … P2-04, P2-07 | |
| Phiên bền vững: kill, không mạng, đổi giờ | P2-05, P2-06, P2-08 … P2-11 | |
| Single writer trong process app là đủ, không cần App Group (ADR-013) | P2-03, P2-04, P2-07 | |
| Không suy ra set hoàn thành từ đồng hồ | P2-06, P2-08 | |

Nếu **GO**: trong cùng PR, ADR-013 chuyển Accepted kèm bằng chứng, đồng thời sửa ADR-002, docs/04 và docs/05 (docs/20 phase 0). Nếu **NO-GO**: mở lại ADR-013.

Kết luận (PO / người kiểm thử ký): ______

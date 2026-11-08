# 19. Nhiều giáo án (Multi-plan): phân tích yêu cầu và đặc tả

> **Trạng thái:** Đề xuất của BA, PO đã chốt các quyết định chính ở §3; mockup đã dựng (§7). D2–D9 và các câu hỏi §11.1–11.3 **đã chốt** bằng ADR-034..044 (Accepted 2026-11-08, PO-002) trong [docs/15](15-decisions-risks.md); §11.4–11.6 **đã chốt** bằng ADR-053..055. Chỉ có tài liệu: chưa đổi OpenAPI, SQL, payload sync hay code (AGENTS rule 7, xem §10).
> **Yêu cầu gốc (2026-11-08):** "Cho phép tạo nhiều giáo án", PO làm rõ bằng ví dụ: **giáo án tập Calisthenics, giáo án chạy giải, giáo án tập Gym**. Người dùng theo **song song** nhiều giáo án, mỗi giáo án phục vụ một mục đích riêng. Lịch sử **giữ nguyên là tab riêng** (đã chốt cùng ngày, docs/02 §3.1).
> **Liên quan:** [docs/18](18-plan-module.md) (mục tiêu, lộ trình, tiến bộ, đa môn §4), [docs/02 §3.1](02-ux-spec.md) (Lịch sử), [docs/07 §4](07-data-model.md) (chính sách phiên bản giáo án), [docs/08](08-sync-protocol.md) (xung đột).

## 1. Hiện trạng (có bằng chứng)
| Nơi | Hiện có | Hệ quả với yêu cầu |
|-----|---------|--------------------|
| `db/001_initial.sql:59-73` | `training_plans` cho phép nhiều dòng trên một user. Có `status active\|archived`, `revision`, `parent_plan_id`. **Không có** ngày bắt đầu, ngày sự kiện, môn chính. | Lưu nhiều giáo án thì làm được ngay. Chưa có lịch theo giáo án, chưa có giáo án hướng tới ngày thi. |
| docs/07 §4 | Chấp nhận đề xuất AI sẽ **nhân bản sang plan ID mới** (`parent_plan_id`, `revision+1`). | Nhiều dòng `training_plans` hiện mang nghĩa *nhiều phiên bản của cùng một giáo án*. Phải tách khái niệm này với *nhiều giáo án*, nếu không danh sách giáo án sẽ hiện cả phiên bản cũ. |
| docs/03 §2 `TrainingPlan(id, title, revision, startDate, weeks, status)` | Domain có `startDate`, `weeks`. | OpenAPI, entity-payloads và SQL **không có** hai trường này: contract đang lệch domain. |
| docs/18 §4 | `discipline` chỉ có `calisthenics`, `gym`. `measurementType` chỉ có `hold`, `reps`, `load`. | **Chạy bộ chưa đo được**: cần môn `running` và kiểu đo quãng đường / thời gian / pace. |
| `workout_sessions.planned_workout_id` (nullable), `ux_session_one_active_per_user` | Buổi tập trỏ tới buổi theo lịch. Mỗi user chỉ có **một buổi đang tập**. | Từ buổi tập truy được ra giáo án. Một ngày có thể có nhiều buổi của nhiều giáo án, nhưng tập lần lượt. |
| iOS `AppStore.swift:13`, `Models.swift:71-77` | App giữ **một** `plan`. Hôm nay lấy `workout(on:)` từ plan đó. | Phải đổi sang danh sách giáo án, Hôm nay gộp nhiều giáo án, migrate snapshot cục bộ. |
| docs/18 và mockup | Mọi màn ngầm hiểu là "giáo án hiện tại". | Phải phân biệt "các giáo án đang theo" với "giáo án đang xem". |

**Khoảng trống cần đặc tả:**
- (a) Phân biệt **giáo án** với **phiên bản**.
- (b) **Vòng đời** của giáo án và **giới hạn số giáo án theo song song**.
- (c) **Gộp lịch** của nhiều giáo án vào Hôm nay, Lịch sử, nhắc lịch.
- (d) Giáo án **hướng tới ngày sự kiện** (chạy giải).
- (e) **Môn chạy bộ** và cách đo.

## 2. Mục tiêu và ngoài phạm vi
**Câu chuyện người dùng:**
- US-1: Tôi tập Calisthenics 3 buổi/tuần và **cùng lúc** theo giáo án chạy chuẩn bị giải 21 km. Tôi muốn hai giáo án tách riêng, mỗi cái có lộ trình, mục tiêu và tiến bộ của nó.
- US-2: Mở Hôm nay, tôi muốn thấy **mọi buổi hôm nay của tất cả giáo án**, biết buổi nào thuộc giáo án nào.
- US-3: Giáo án chạy giải có **ngày thi**. Tôi muốn lộ trình đếm ngược tới ngày đó, và biết còn bao nhiêu tuần.
- US-4: Tôi muốn nhìn **cả tuần của tôi** qua mọi giáo án để thấy ngày nào dồn nhiều buổi.
- US-5: Sau giải, tôi muốn kết thúc giáo án chạy mà giáo án Gym và Calisthenics vẫn chạy bình thường.
- US-6: Tôi muốn **tạm dừng một giáo án** (ví dụ Gym khi đi công tác) mà không ảnh hưởng giáo án khác và không bị tính buổi bỏ lỡ.
- US-7: Tôi muốn **lặp lại** một chu kỳ đã tập (nhân bản rồi chỉnh), tiến bộ mỗi chu kỳ tính riêng.

**Ngoài phạm vi lần này:**
- Ghi chạy bằng **GPS** trong app hoặc **nhập từ Apple Health / đồng hồ**. ✅ Đã chốt 2026-11-08: MVP **nhập tay** quãng đường và thời gian; tích hợp Apple Health làm sau. Mô hình dữ liệu để chỗ cho nguồn dữ liệu (`source = manual`, sau này thêm `healthkit`) để không phải đổi lại.
- **Tự xếp lại lịch** khi các giáo án trùng ngày. App chỉ hiển thị, người dùng tự quyết.
- Mọi lời khuyên về tải tập, chấn thương, dinh dưỡng giữa các giáo án (không đưa lời khuyên y tế).
- Chia sẻ giáo án giữa người dùng. Thư viện mẫu do portal quản lý. AI tự tạo giáo án (AI chỉ đề xuất, AGENTS rule 5).

## 3. Quyết định cần PO chốt (kèm đề xuất)
| # | Câu hỏi | Đề xuất | Lý do |
|---|---------|---------|-------|
| D1 | Bao nhiêu giáo án **đang theo** cùng lúc? | ✅ **Đã chốt 2026-11-08: tối đa 3** (cấu hình được ở server). Thực tế ít người theo nhiều hơn. | Đủ cho ví dụ Calisthenics + chạy + Gym. Giới hạn giữ Hôm nay gọn và nằm trong giới hạn 64 thông báo chờ của iOS. |
| D2 | Một giáo án có **môn chính** không? | **Có:** `primaryDiscipline` (calisthenics / running / gym / mixed) để chọn icon, màu nhấn, mẫu và bộ lọc. Bài trong giáo án vẫn mang `discipline` riêng (docs/18 §4 giữ nguyên). | Người dùng nhận ra giáo án ngay. Không cấm giáo án hỗn hợp. [ADR-034](15-decisions-risks.md) (Accepted) |
| D3 | Có loại giáo án **hướng tới sự kiện** không? | **Có hai loại:** *Theo tuần* (mặc định, chọn ngày bắt đầu) và *Hướng tới sự kiện* (nhập ngày sự kiện, ngày bắt đầu = ngày sự kiện − số tuần lộ trình, hiện "Còn x tuần"). [ADR-035](15-decisions-risks.md) (Accepted) | Đáp ứng US-3. Giai đoạn giảm tải trước giải chỉ là một giai đoạn bình thường (docs/18 §6.5). |
| D4 | Người dùng có thấy "phiên bản" không? | **Không.** Chỉ thấy *giáo án*. Phiên bản xem được ở Nhật ký thay đổi. [ADR-036](15-decisions-risks.md) (Accepted) | Tránh danh sách bị lặp. |
| D5 | Trùng ngày giữa các giáo án? | **Cho phép.** Màn "Tuần của tôi" đánh dấu ngày có ≥ 2 buổi, chỉ để thông tin, không chặn và không tự dời lịch. [ADR-037](15-decisions-risks.md) (Accepted) | Không đưa lời khuyên tập luyện. Người dùng tự xếp. |
| D6 | Hết lộ trình / qua ngày sự kiện thì sao? | **Không tự kết thúc.** Hiện thẻ "Đã hết lộ trình" (hoặc "Đã qua ngày thi") với Kết thúc / Kéo dài / Lặp lại. Giáo án sự kiện có thêm "Ghi kết quả thi". [ADR-038](15-decisions-risks.md) (Accepted) | Không im lặng đổi trạng thái (AGENTS rule 3, 5). |
| D7 | Tuần hiện tại khi có tạm dừng? | Giáo án *Theo tuần*: tính theo **số ngày đã thực sự theo** (quay lại tiếp đúng tuần đang dở). Giáo án *Sự kiện*: tính theo **lịch tới ngày sự kiện** (tạm dừng không lùi ngày thi, các tuần bị nghỉ coi như đã qua). [ADR-039](15-decisions-risks.md) (Accepted) | Ngày thi cố định, còn giáo án theo tuần thì linh hoạt. |
| D8 | Xoá hay lưu trữ? | Ưu tiên **Lưu trữ**. **Xoá** là xoá mềm và **không bao giờ** xoá buổi tập hay set. [ADR-040](15-decisions-risks.md) (Accepted) | Người dùng sở hữu nhật ký tập (AGENTS rule 6). |
| D9 | Giới hạn tổng số giáo án? Ngày bắt đầu ở quá khứ? | Tối đa **50** giáo án chưa xoá. Ngày bắt đầu **không** ở quá khứ. [ADR-041](15-decisions-risks.md) (Accepted) | Ngày quá khứ sinh buổi "bỏ lỡ" giả. |

## 4. Mô hình khái niệm
```text
Plan (giáo án người dùng thấy)
 ├─ kind: weekly | event        eventDate? (khi kind = event)      primaryDiscipline
 ├─ 1..n PlanRevision     (phiên bản; mới nhất = hiện hành)   → PlannedWorkout → PlannedExercise, Phase[]
 ├─ 0..n PlanActivation   { id, planId, fromDate, toDate?, timezone, endReason? }   (khoảng thời gian được theo)
 ├─ 0..n Goal             (docs/18 §6.1, gắn với Plan, không nhân theo phiên bản)
 └─ endedAt?, endReason? (completed | stopped), archivedAt?, deletedAt?
WorkoutSession → plannedWorkoutId → PlanRevision → Plan
```
- **Giai đoạn** thuộc phiên bản (AI có thể đề xuất đổi). **Mục tiêu** thuộc giáo án (mang trạng thái và tiến độ).
- **Lịch của ngày D** = hợp các buổi của **mọi** giáo án có activation chứa D. Mỗi buổi luôn biết nó thuộc giáo án nào.

### 4.1 Môn chạy bộ (mở rộng docs/18 §4)
| `measurementType` | Ô đo ở P6 | Mục tiêu hiển thị | KPI chính |
|-------------------|-----------|-------------------|-----------|
| `distance` | Quãng đường (km, 2 số lẻ) + Thời gian (h:mm:ss); **pace tự tính** | `8 km chạy nhẹ`, `5 × 1 km @ 4:50/km` | Quãng đường tuần, pace tốt nhất trên cự ly |
| `duration` | Thời gian (h:mm:ss) | `40 phút chạy nhẹ` | Tổng thời gian tuần |

- `discipline` thêm `running`. Bộ tiêu chí nhập set (docs/18 §5) áp dụng được cho `running` qua `appliesTo.disciplines`, ví dụ mức cảm nhận, địa hình, giày.
- Một **set** của bài chạy = một **đoạn** (một lần chạy liên tục hoặc một lặp interval). Nghỉ giữa các lặp dùng `rest_seconds` như hiện nay.
- Mục tiêu (docs/18 §6.1) dùng được với chạy: `performance` (pace 5 km ≤ 25:00), `volume` (30 km/tuần), `milestone` (hoàn thành 21 km), `adherence`.
- Pace là giá trị tính ra, không lưu. Hiển thị theo locale `vi` (`4:50/km`, `8,25 km`).

### 4.2 Trạng thái là **giá trị tính ra**, không lưu
Tính từ `PlanActivation`, `endedAt`, `archivedAt`, `deletedAt`, để hai thiết bị offline không cùng ghi đè một cột.

| Trạng thái | Nhãn | Điều kiện |
|-----------|------|-----------|
| `draft` | Nháp | Chưa có activation nào, chưa kết thúc |
| `scheduled` | Bắt đầu từ dd/mm | Có activation với `fromDate` > hôm nay |
| `active` | Đang theo | Có activation chứa hôm nay |
| `paused` | Tạm dừng | Đã có activation, không còn activation mở, chưa kết thúc |
| `ended` | Đã kết thúc · Hoàn thành / Dừng sớm | `endedAt` có giá trị |
| `archived` | Lưu trữ | `archivedAt` có giá trị. Khi khôi phục, trở về trạng thái tính ra ở trên |

`scheduled` và `active` cùng tính vào giới hạn D1.

### 4.3 Chuyển trạng thái
| Từ | Hành động | Kết quả | Tác động |
|----|-----------|---------|----------|
| draft / paused | **Bắt đầu theo** / **Tiếp tục** | scheduled hoặc active | Mở activation. Giáo án *Sự kiện*: ngày bắt đầu tính từ ngày sự kiện (xem MP-04). Nếu đã đủ 3 giáo án đang theo: hỏi chọn một giáo án để *Tạm dừng* hoặc *Kết thúc*. Các giáo án khác **không bị ảnh hưởng**. Đặt lịch nhắc của giáo án này. |
| active / scheduled | **Tạm dừng** | paused | Đóng activation ở ngày hôm qua, hoặc huỷ nếu chưa tới ngày bắt đầu. Huỷ lịch nhắc của giáo án này. |
| active / paused | **Kết thúc** (lý do + ghi chú ≤ 500 ký tự, không bắt buộc) | ended | Đóng activation. Mục tiêu còn `active` chuyển `missed` (docs/18 §6.2), không chuyển sang giáo án khác ([ADR-053](15-decisions-risks.md)). |
| active + hết lộ trình | **Kéo dài** | active | Thêm tuần hoặc giai đoạn, tạo phiên bản mới. Giáo án *Sự kiện* đã qua ngày thi thì Kéo dài đổi thành *Theo tuần*. |
| bất kỳ | **Nhân bản** / **Lặp lại** | Giáo án mới, draft | Xem MP-03. Giáo án gốc giữ nguyên. |
| khác active / scheduled | **Lưu trữ** / **Khôi phục** | archived / trạng thái tính ra | — |
| bất kỳ | **Xoá** (xác nhận) | đã xoá (tombstone) | Đóng activation nếu có. Buổi tập vẫn còn trong Lịch sử. |

**Chặn:** không được tạm dừng, kết thúc hay xoá **giáo án đang có buổi tập dở**. Các giáo án khác vẫn thao tác được bình thường. Bắt đầu một buổi mới khi đang có buổi dở (của bất kỳ giáo án nào) bị chặn như hiện nay (`ux_session_one_active_per_user`).

### 4.4 Bất biến
- **I1** Các activation **của cùng một giáo án** không chồng lấn.
- **I2** Tại mỗi ngày, số giáo án có activation chứa ngày đó **≤ giới hạn D1**.
- **I3** Không thao tác nào trên giáo án được sửa hoặc xoá `workout_session` hay `set_result`. Buổi tập giữ `prescribedSnapshot`.
- **I4** **Buổi bỏ lỡ tính theo từng giáo án.** Buổi theo lịch của giáo án P vào ngày D là bỏ lỡ khi D đã qua, D nằm trong activation của P, và không có buổi hoàn thành nào trỏ tới buổi theo lịch đó (hoặc tới buổi khác của P trong cùng ngày). Buổi của giáo án khác **không bù** cho P. Ngày ngoài activation của P thì không có buổi bỏ lỡ của P.
- **I5** Mọi thao tác vòng đời là command có `commandId` UUID, idempotent và ghi Nhật ký thay đổi.

## 5. Yêu cầu chức năng
| ID | Yêu cầu |
|----|---------|
| **MP-01** Danh sách giáo án | Nhóm: **Đang theo** (≤ 3, kể cả hẹn bắt đầu), Nháp, Tạm dừng, Đã kết thúc; Lưu trữ thu gọn ở cuối. Mỗi thẻ: **poster ghép 3 bài** (visual-first), icon môn chính, tên, chip trạng thái (chữ + icon), "Tuần x/y" hoặc "Còn x tuần tới ngày thi", số buổi đã tập. Nút "+" (Tạo giáo án) trên thanh điều hướng. Đây là màn đầu tiên khi mở tab Giáo án. |
| **MP-02** Tạo giáo án | Cách tạo: **Trống**, **Nhân bản**, **Từ mẫu** (mẫu đi kèm app, mỗi môn có ít nhất một mẫu). Nhập: tên (1–120 ký tự), môn chính, loại (*Theo tuần* / *Hướng tới sự kiện* + tên sự kiện, ngày sự kiện, cự ly nếu là chạy). Lưu → mở Tổng quan ở trạng thái Nháp. **Không** tự bắt đầu. |
| **MP-03** Nhân bản / Lặp lại | **Sao chép:** loại, môn chính, giai đoạn, buổi tập theo thứ, bài và mức đích, định nghĩa mục tiêu (trạng thái đặt lại `active`, mốc ban đầu tính lại). Giáo án sự kiện: **xoá ngày sự kiện**, bắt người dùng nhập lại. **Không sao chép:** buổi tập, set, nhật ký, đề xuất AI, activation. |
| **MP-04** Bắt đầu theo | *Theo tuần*: chọn ngày bắt đầu (mặc định thứ Hai tới, cho phép hôm nay, không cho quá khứ). *Sự kiện*: ngày bắt đầu = ngày sự kiện − số tuần. Nếu ngày đó đã qua, hiện "Còn 9 tuần, lộ trình 12 tuần" và cho chọn **Bắt đầu từ tuần 4** hoặc **Sửa lộ trình**. Giáo án không có buổi nào thì không bắt đầu được. Đã đủ 3 giáo án đang theo: sheet chọn giáo án cần tạm dừng / kết thúc. Trước khi xác nhận, hiện xem trước **Tuần của tôi** với giáo án mới (MP-06). |
| **MP-05** Tạm dừng / Tiếp tục | Theo từng giáo án. Tuần hiện tại theo D7. Hôm nay vẫn hiện buổi của các giáo án còn đang theo. |
| **MP-06** Tuần của tôi | Màn xem 7 ngày gộp mọi giáo án đang theo. Mỗi ngày liệt kê buổi kèm icon và màu nhấn của giáo án. Ngày có ≥ 2 buổi có nhãn "2 buổi". Chỉ để xem; muốn đổi thì vào Sửa lộ trình của từng giáo án. Mở từ Hôm nay và từ sheet Bắt đầu theo. |
| **MP-07** Hết lộ trình / sau ngày thi | Thẻ "Đã hết lộ trình" hoặc "Đã qua ngày thi" ở Tổng quan và Hôm nay, với Kết thúc / Kéo dài / Lặp lại; giáo án sự kiện có thêm **Ghi kết quả thi** (thời gian chính thức, tạo một buổi `distance` gắn với buổi theo lịch của ngày thi, đánh dấu mục tiêu milestone nếu người dùng xác nhận). Từ lúc hết lộ trình tới khi người dùng chọn: không sinh buổi theo lịch, không tính bỏ lỡ. |
| **MP-08** Tab Giáo án | Bấm tab luôn mở **MP-01 danh sách giáo án** (màn gốc của tab, có thanh tab; nút "+" trên thanh điều hướng để tạo giáo án). Bấm một thẻ giáo án đang theo thì mở **chi tiết giáo án**: tiêu đề là tên giáo án, nút quay lại "Giáo án", phân đoạn Tổng quan / Lộ trình / Tiến bộ của giáo án đó. Không còn hàng chip chuyển giáo án. Giáo án không đang theo mở từ MP-01, có banner trạng thái và nút chính (Bắt đầu theo / Tiếp tục / Lặp lại). *Đã kết thúc* và *Lưu trữ* **chỉ xem**, muốn sửa thì "Nhân bản để sửa". |
| **MP-09** Hôm nay | Liệt kê **mọi buổi hôm nay** của các giáo án đang theo, sắp theo giờ nhắc rồi theo thứ tự giáo án. Mỗi thẻ có chip giáo án. Buổi xong có dấu hoàn thành, buổi còn lại vẫn bắt đầu được. Có lối vào **Tuần của tôi**. Trạng thái rỗng: "Hôm nay không có buổi nào" (kèm buổi gần nhất sắp tới); "Chưa theo giáo án nào" + *Chọn giáo án* / *Tạo giáo án*. Giáo án sự kiện hiện dòng "Còn x ngày tới [tên sự kiện]". |
| **MP-10** Lịch sử | Vẫn là tab riêng. Mỗi buổi có chip giáo án (tên hiện tại; đã xoá thì "X (đã xoá)"). **Thêm chip lọc theo giáo án** (Tất cả + từng giáo án), vì nay nhiều giáo án chạy song song. Dải trạng thái 7 ngày: một ngày là *hoàn thành* khi mọi buổi theo lịch đã xong, *một phần* khi xong một số, *bỏ lỡ* khi không xong buổi nào (I4). Tổng kết kỳ: số buổi, thời lượng; thêm **tổng km** khi có buổi chạy. |
| **MP-11** Tiến bộ & mục tiêu | Theo **từng giáo án**, chỉ tính các buổi thuộc giáo án đó. Giáo án kết thúc thì số liệu đóng băng. Màn Tiến bộ của giáo án chạy có KPI quãng đường tuần, pace tốt nhất theo cự ly, buổi dài nhất. Chuyên cần tính theo giáo án. Tổng hợp qua mọi giáo án: xem MP-15. |
| **MP-12** Đề xuất AI | Phân tích và đề xuất **theo từng giáo án đang theo**; mỗi đề xuất gắn một giáo án và chỉ sửa giáo án đó. Đề xuất đang chờ của giáo án rời trạng thái đang theo → `superseded`, ghi audit, không tự áp dụng. AI không đưa lời khuyên y tế hay tải tập xuyên giáo án. |
| **MP-13** Nhắc lịch | Mỗi buổi có giờ nhắc riêng. Vì iOS giữ tối đa 64 thông báo chờ, app chỉ đặt các nhắc gần nhất qua **mọi** giáo án và đặt lại khi mở app. Nhiều buổi cùng giờ thì gộp thành một thông báo ("2 buổi lúc 6:00"). Thông báo chỉ là nhắc nhở, không bao giờ chuyển trạng thái. |
| **MP-14** Nhật ký thay đổi | Ghi: tạo, nhân bản, bắt đầu, tạm dừng, tiếp tục, kết thúc, kéo dài, ghi kết quả thi, lưu trữ, khôi phục, xoá — kèm tên giáo án. |
| **MP-15** Tổng hợp qua mọi giáo án | ✅ Đã chốt 2026-11-08. **Nơi hiển thị:** thẻ "Tuần này" ở **Cá nhân**, và tổng kết kỳ của **Lịch sử** khi bộ lọc là *Tất cả*. **Chỉ số:** số buổi hoàn thành / buổi theo lịch, tổng thời gian tập, tổng km (khi có buổi chạy), **chuyên cần chung** = buổi hoàn thành ÷ buổi theo lịch của mọi giáo án trong kỳ (chỉ tính những ngày giáo án đó đang theo, I4), kèm phần tách theo từng giáo án (icon + tên + x/y buổi). So sánh với kỳ trước theo cùng quy tắc docs/02 §3.1. **Không** cộng các chỉ số khác đơn vị (giây giữ, số lần, kg) qua các môn, và không chấm điểm hay xếp hạng giáo án. Giá trị tính ra từ buổi tập, không lưu. |

## 6. Quy tắc nghiệp vụ và tình huống biên
| # | Tình huống | Quy tắc |
|---|-----------|---------|
| BR-1 | Đổi múi giờ hoặc đồng hồ nhảy | Activation và ngày sự kiện lưu **ngày theo giờ địa phương** kèm `timezone`. Đồng hồ nhảy chỉ đổi "hôm nay", không sửa activation. |
| BR-2 | Hai thiết bị offline cùng bắt đầu giáo án, tổng vượt giới hạn D1 | Server xử lý theo thứ tự nhận; lệnh làm vượt giới hạn bị từ chối với lỗi `active_plan_limit` (không retry). Giáo án đó trở về trạng thái trước; client hiện "Đã đủ 3 giáo án đang theo, chọn giáo án cần tạm dừng". Không đụng tới buổi tập. Thêm vào docs/08. |
| BR-3 | Hai thiết bị cùng thao tác trên **một** giáo án (ví dụ một bên tạm dừng, một bên kết thúc) | Theo `version` như các entity khác (docs/08). Kết thúc thắng tạm dừng vì là trạng thái cuối. |
| BR-4 | Cùng ngày có buổi Calisthenics và buổi chạy | Hôm nay hiện cả hai. Tập lần lượt (một buổi đang tập tại một thời điểm). Buổi nào không tập thì bỏ lỡ của giáo án đó (I4). |
| BR-5 | Buổi tập giáo án A đến qua sync sau khi A đã tạm dừng | Vẫn thuộc A theo `plannedWorkoutId`, không gán lại. |
| BR-6 | Ngày sự kiện bị đổi | Cho sửa khi giáo án chưa kết thúc; tạo phiên bản mới; ngày bắt đầu và tuần hiện tại tính lại; buổi đã tập giữ nguyên. Nếu ngày mới làm activation bắt đầu ở quá khứ thì không lùi activation, chỉ đổi tuần hiện tại. |
| BR-7 | Trùng tên giáo án | Cho phép. Phân biệt bằng môn, trạng thái, khoảng ngày. |
| BR-8 | Vượt 50 giáo án | Chặn tạo mới, gợi ý xoá bớt giáo án cũ. |
| BR-9 | Sửa giáo án đang theo | Như hiện nay: sửa trên bản nháp rồi Lưu. Buổi đã ghi không đổi (I3). |
| BR-10 | Migrate dữ liệu hiện có | Giáo án duy nhất hiện có → *Đang theo*, `kind = weekly`, `primaryDiscipline` suy từ bài (một môn → môn đó, nhiều môn → `mixed`), `fromDate` = ngày buổi tập đầu tiên hoặc ngày tạo. Đã đánh dấu xoá → đã xoá. Các phiên bản AI tạo gộp chung một giáo án theo chuỗi `parent_plan_id`. |

## 7. Khung UX (đã dựng trong mockup `docs/design/mockups/plan-module.html`, mục "Nhiều giáo án")
- **Hôm nay:** danh sách buổi của mọi giáo án, chip giáo án trên mỗi thẻ, dòng đếm ngược ngày thi, lối vào Tuần của tôi.
- **Tab Giáo án:** hàng chip giáo án đang theo + "Tất cả"; Tổng quan / Lộ trình / Tiến bộ giữ nguyên.
- **Màn mới:** Danh sách giáo án; Tạo giáo án (cách tạo → môn → loại → tên); Bắt đầu theo (ngày, xử lý giới hạn, xem trước tuần); Tuần của tôi; P6 cho bài chạy (km + thời gian → pace); Ghi kết quả thi.
- **Màu nhấn theo giáo án** chỉ là phụ: luôn đi kèm icon môn và tên (không truyền đạt chỉ bằng màu). Poster vẫn là nhận diện chính của bài.
- Giữ quy ước: một nút **Lưu**, không hiện trạng thái lưu hay đồng bộ.
- **VoiceOver:** "Buổi Chạy dài 14 km, giáo án Chạy bán marathon, còn 23 ngày tới giải".

## 8. Tiêu chí chấp nhận
```gherkin
Feature: Nhiều giáo án song song

  Scenario: Theo song song giáo án Calisthenics và giáo án chạy
    Given tôi đang theo "Calisthenics" có buổi vào thứ Hai, Tư, Sáu
    When tôi tạo "Chạy bán marathon" loại sự kiện, ngày thi 2027-02-14, lộ trình 12 tuần, và Bắt đầu theo
    Then cả hai giáo án ở trạng thái Đang theo
    And Hôm nay thứ Tư hiện buổi của cả hai, mỗi thẻ có chip giáo án
    And Tổng quan "Chạy bán marathon" hiện số tuần còn lại tới ngày thi

  Scenario: Giới hạn số giáo án đang theo
    Given tôi đang theo 3 giáo án
    When tôi Bắt đầu theo giáo án thứ tư
    Then app yêu cầu chọn một giáo án để Tạm dừng hoặc Kết thúc
    And các giáo án không được chọn giữ nguyên trạng thái

  Scenario: Bỏ lỡ tính theo từng giáo án
    Given thứ Tư có buổi Calisthenics và buổi chạy
    When tôi chỉ hoàn thành buổi Calisthenics và ngày thứ Tư qua đi
    Then Lịch sử ghi buổi chạy thứ Tư là bỏ lỡ
    And dải 7 ngày hiện thứ Tư là "một phần"
    And Chuyên cần của "Calisthenics" không bị giảm

  Scenario: Tạm dừng một giáo án không ảnh hưởng giáo án khác
    Given tôi đang theo "Gym" và "Calisthenics"
    When tôi Tạm dừng "Gym" trong 10 ngày rồi Tiếp tục
    Then 10 ngày đó không có buổi Gym bỏ lỡ
    And "Gym" tiếp tục từ tuần đang dở
    And lịch và nhắc của "Calisthenics" không đổi

  Scenario: Giáo án sự kiện bắt đầu muộn
    Given hôm nay còn 9 tuần tới ngày thi và lộ trình có 12 tuần
    When tôi Bắt đầu theo
    Then app đề nghị "Bắt đầu từ tuần 4" hoặc "Sửa lộ trình"

  Scenario: Qua ngày thi không tự kết thúc
    Given ngày thi của "Chạy bán marathon" đã qua
    Then Tổng quan hiện "Đã qua ngày thi" với Ghi kết quả thi, Kết thúc, Kéo dài, Lặp lại
    And trạng thái vẫn là Đang theo cho tới khi tôi chọn
    And không có buổi theo lịch mới của giáo án này

  Scenario: Nhập kết quả buổi chạy
    Given buổi "5 × 1 km" của giáo án chạy
    When tôi nhập đoạn 1 là 1,00 km trong 4:52
    Then app hiển thị pace 4:52/km và chỉ lưu quãng đường, thời gian

  Scenario: Tổng hợp tuần qua mọi giáo án
    Given tuần này "Calisthenics" có 3 buổi theo lịch, tôi xong 3
    And "Chạy bán marathon" có 4 buổi theo lịch, tôi xong 2 với tổng 18,5 km
    When tôi mở Cá nhân
    Then thẻ "Tuần này" hiện 5/7 buổi, chuyên cần chung 71%, 18,5 km
    And phần tách hiện "Calisthenics 3/3" và "Chạy bán marathon 2/4"

  Scenario: Xoá giáo án giữ lịch sử
    Given "Gym" có 12 buổi đã tập
    When tôi xoá "Gym" và xác nhận
    Then Lịch sử vẫn hiện 12 buổi với nhãn "Gym (đã xoá)"

  Scenario: Hai thiết bị offline vượt giới hạn
    Given tôi đang theo 2 giáo án
    And thiết bị 1 bắt đầu "B", thiết bị 2 bắt đầu "C" khi cả hai offline
    When thiết bị 1 đồng bộ trước rồi tới thiết bị 2
    Then "B" Đang theo, lệnh của thiết bị 2 bị từ chối với active_plan_limit
    And thiết bị 2 yêu cầu chọn giáo án cần tạm dừng
```

## 9. Thay đổi so với docs/18
- §4: thêm `discipline = running`, `measurementType = distance | duration` (§4.1 ở trên).
- §6.5, §6.6: "giáo án hiện tại" đổi thành "giáo án đang xem"; tuần hiện tại theo D7.
- Lọc theo môn ở Tiến bộ vẫn giữ cho giáo án `mixed`.

## 10. Tác động contract và code (làm trước khi code, AGENTS rule 7)
| Thay đổi | Artifact |
|----------|----------|
| `training_plans`: thêm `lineage_id`, `kind` (`weekly\|event`), `event_date`, `event_name`, `primary_discipline`, `ended_at`, `end_reason`, `archived_at`. Đổi nghĩa `status` thành trạng thái **phiên bản** (`current\|superseded`). | SQL, entity-payloads, OpenAPI `TrainingPlan`, docs/07 §4 |
| Entity mới `plan_activation` (`plan_lineage_id`, `from_date`, `to_date?`, `timezone`, `end_reason?`, `version`). Server kiểm tra I1 (exclusion constraint theo giáo án) và I2 (kiểm tra số lượng trong transaction). Mã lỗi mới `active_plan_limit` trong `MutationError`. | SQL, entity-payloads, OpenAPI, docs/07, docs/08 |
| `discipline` thêm `running`; `measurementType` thêm `distance`, `duration`; `set_result` thêm `distanceMeters`, `durationSeconds` (pace không lưu) và `source` (`manual`; `healthkit` dành cho sau); `target` của `planned_exercise` cho bài chạy. | OpenAPI, SQL CHECK, catalog-bundle schema, entity-payloads, docs/03, `fixtures/validation/business_rules.json` |
| Domain `TrainingPlan`: bỏ `startDate`, `weeks` lưu cứng, thay bằng giá trị tính từ activation, lộ trình, ngày sự kiện. Command vòng đời có `commandId`. | docs/03, CaliDomain hoặc tầng app, fixtures |
| Đề xuất AI gắn `planLineageId`, `superseded` khi giáo án rời trạng thái đang theo. | docs/09, OpenAPI recommendation |
| iOS: `plans: [WorkoutPlan]`, Hôm nay gộp nhiều giáo án, chip giáo án, Tuần của tôi, P6 bài chạy, lập lịch nhắc ưu tiên gần nhất (≤ 64). Migrate snapshot (BR-10). Test: chuyển trạng thái, I1/I2, bỏ lỡ theo giáo án, tuần hiện tại có tạm dừng (cả hai loại), pace, migrate. | `ios/`, `CaliAppTests` |
| Mockup: các màn ở §7. | `docs/design/mockups/plan-module.html` |

**Đề xuất chia slice:** ADR (D1–D9) → **CON-0xx Plan lineage + activation** → **CON-0xx Running measurement** (có thể song song) → **IOS-0xx Multi-plan local** → **IOS-0xx Running entry** → cập nhật mockup (có thể làm song song với ADR để kiểm chứng UX).

## 11. Câu hỏi mở
**Đã trả lời (2026-11-08):** giới hạn 3 giáo án đang theo là đủ (D1); ghi chạy nhập tay ở MVP, Apple Health làm sau (§2); có tổng hợp qua mọi giáo án (MP-15).

1. Có cho 2 giáo án đang theo **cùng môn** (ví dụ 2 giáo án Gym) không? Đề xuất: cho phép, không chặn. → [ADR-042](15-decisions-risks.md) (Accepted)
2. Khi tích hợp Apple Health: buổi chạy nhập từ Health tự gắn vào buổi theo lịch cùng ngày, hay người dùng xác nhận từng buổi? (Đề xuất: người dùng xác nhận, theo tinh thần không im lặng ghi kết quả.) → [ADR-043](15-decisions-risks.md) (Accepted)
3. Khi nhân bản, mốc ban đầu của mục tiêu lấy từ thành tích tốt nhất của giáo án trước hay đo lại? → [ADR-044](15-decisions-risks.md) (Accepted), lấy theo MP-03 ("mốc ban đầu tính lại"); PO đã xác nhận.
4. Kết thúc giáo án có cho chuyển mục tiêu chưa đạt sang giáo án khác không? **Không.** → [ADR-053](15-decisions-risks.md) (Accepted)
5. Có cần nhập bù buổi tập trong quá khứ (liên quan D9)? **Có thể nhập bù**; chỉ gắn vào buổi theo lịch khi người dùng chọn, ngày bắt đầu giáo án vẫn không ở quá khứ. → [ADR-054](15-decisions-risks.md) (Accepted)
6. Đơn vị: chỉ km, hay cho chọn dặm? **Chỉ km** (pace phút/km); lưu trữ vẫn là mét (`distanceMeters`, §10). → [ADR-055](15-decisions-risks.md) (Accepted)

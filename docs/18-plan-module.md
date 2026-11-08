# 18. Module Giáo án (Plan module): mục tiêu, lộ trình, tiến bộ, nhập kết quả set

> **Trạng thái:** Đề xuất thiết kế (UX + domain). Mockup tương tác: [`docs/design/mockups/plan-module.html`](design/mockups/plan-module.html).
> **Phạm vi lần này:** chỉ tài liệu và mockup. Chưa đổi OpenAPI, SQL hay payload sync. Khi triển khai, xem mục 8 để biết phần contract cần làm trước (AGENTS rule 7).
> **Ngày:** 2026-11-08 · Dữ liệu trong mockup là **dữ liệu mẫu**.
> **PO-002 (2026-11-08):** câu hỏi §9.1, 9.2, 9.5, 9.6 **đã chốt** bằng ADR-045..048 (Accepted; ADR-048 là mặc định tạm) trong [docs/15](15-decisions-risks.md). §9.3, 9.4, 9.7 **đã chốt** bằng ADR-050..052.
> **Nhiều giáo án:** xem [docs/19](19-multi-plan.md). Người dùng có thể theo song song nhiều giáo án (Calisthenics, chạy giải, Gym). Khi được chốt: "giáo án hiện tại" trong tài liệu này đổi thành "giáo án đang xem", tuần hiện tại tính theo docs/19 D7 (§6.5, §6.6), và §4 thêm môn `running` với kiểu đo `distance` / `duration`.

## 1. Mục tiêu sản phẩm
- Người dùng thấy rõ **đích đến** (nhiều mục tiêu nhỏ đo được), **đang ở đâu** (tuần / giai đoạn) và **tiến bộ ra sao** (KPI ghim: đã tiến bộ bao nhiêu so với lúc bắt đầu giáo án). Không phải đọc chữ dài.
- Dùng được cho **nhiều môn**: Calisthenics và Gym ngay từ đầu, và thêm môn khác mà không phải sửa màn hình.
- Người dùng **tự sửa** mục tiêu và lộ trình. AI chỉ đề xuất, và đề xuất chỉ áp dụng khi người dùng chấp nhận (AGENTS rule 5).
- Màn **nhập kết quả set (P6)** được dựng từ **bộ tiêu chí cấu hình động**. Bộ tiêu chí sẽ do **portal web quản trị** quản lý.

## 2. Danh sách màn (theo mockup)
| # | Màn | Nội dung chính | Sửa được |
|---|-----|----------------|----------|
| 1 | Tổng quan | Tối đa 3 mục tiêu đã ghim (poster, hiện tại / đích, thanh tiến độ), tuần X/Y, giai đoạn hiện tại, lịch tuần | "Tất cả mục tiêu" → màn 7 |
| 2 | Lộ trình | Dải tuần (tự co khi > 8 tuần), timeline giai đoạn; mỗi giai đoạn hiện "Mục tiêu giai đoạn", giai đoạn cuối hiện "Đo lại mục tiêu cả giáo án" | "Sửa": tên, số tuần, đổi thứ tự, xoá, thêm giai đoạn |
| 3 | Tiến bộ | KPI ghim: lúc bắt đầu → hiện tại, chênh lệch và % (§6.6), thẻ Chuyên cần từ đầu giáo án, lọc theo môn (Tất cả / Calisthenics / Gym), nhóm sinh tự động từ dữ liệu bài | Ghim / bỏ ghim KPI |
| 4 | Chi tiết tiến bộ | Chọn chỉ số (giây, lần, kg, tổng khối lượng), lúc bắt đầu → hiện tại, biểu đồ toàn giáo án có đường mục tiêu / mốc ban đầu, mục tiêu liên quan, lịch sử buổi | — |
| 5 | Chi tiết buổi | Danh sách bài có poster, mức đích theo cách đo | — |
| 6 | Nhập kết quả set (P6) | Ô đo chính theo loại bài và các tiêu chí theo cấu hình | Giá trị set |
| 7 | Mục tiêu | Danh sách: đã ghim, chờ xác nhận, đang theo đuổi, thang kỹ năng, chưa đạt, đã đạt / lưu trữ. Trình sửa: chọn loại → chỉ số → bài (lưới poster) → mức đích → phạm vi | Thêm, sửa, ghim, xác nhận, gia hạn, lưu trữ |

## 3. Nguyên tắc UX bắt buộc
1. **Visual-first:** mọi chỗ chọn hoặc nhận diện bài tập đều dùng poster. Bài của mục tiêu được chọn từ **lưới poster**, không chọn từ danh sách chữ. Chữ chỉ bổ sung.
2. **Chỉ có "Lưu":** không có nút, chip hay trạng thái nào kiểu "lưu trên máy", "chưa đồng bộ" hay "đã đồng bộ". Lưu cục bộ trước rồi đồng bộ sau là việc app tự làm (offline-first, AGENTS rule 1). Lỗi đồng bộ kéo dài xử lý ở tầng hệ thống (docs/06, docs/11), không đưa vào luồng nhập liệu.
3. **Không tự hoàn thành set:** hết giờ không có nghĩa là xong set. Set chỉ được ghi khi người dùng bấm Lưu (AGENTS rule 3).
4. **Không lời khuyên y tế:** tiêu chí "Đau bất thường" chỉ được ghi lại. COAMI không chẩn đoán.
5. **Mỗi màn chỉ có một nút Lưu chính**, đặt ở thanh cố định đáy, không cuộn theo nội dung. Có thêm "Huỷ" để bỏ bản nháp.
6. **Tất cả tiêu chí đánh giá đều tùy chọn.** Giá trị đo được điền sẵn bằng mục tiêu của set để người dùng chỉ cần chỉnh khi khác.
7. Tap target ≥ 44×44pt (stepper, nút đổi thứ tự, ô chọn poster).

## 4. Đa môn và cách đo
Mỗi bài tập (`exercise`) có thêm hai thuộc tính:

| Thuộc tính | Giá trị ví dụ | Ý nghĩa |
|-----------|---------------|---------|
| `discipline` | `calisthenics`, `gym` (mở rộng được) | Lọc màn Tiến bộ, chọn bộ tiêu chí áp dụng |
| `measurementType` | `hold`, `reps`, `load` | Quyết định ô đo chính ở P6 và đơn vị mục tiêu |

| `measurementType` | Ô đo ở P6 | Mục tiêu hiển thị | KPI chính |
|-------------------|-----------|-------------------|-----------|
| `hold` | Thời gian giữ (giây) | `4 × 12 giây` | Giây giữ tốt nhất |
| `reps` | Số lần | `3 × 8–10 lần` | Số lần tốt nhất |
| `load` | Mức tạ (kg, bước 2,5) + Số lần | `3 × 5 lần @ 60 kg` | Mức tạ × số lần, tổng khối lượng |

Số thập phân hiển thị theo locale `vi` (dùng dấu phẩy, ví dụ `57,5 kg`).

## 5. Bộ tiêu chí nhập set cấu hình động
### 5.1 Mô hình
Màn P6 không hard-code tiêu chí. App nhận một **bộ cấu hình có phiên bản** và render theo kiểu của từng tiêu chí:

```json
{
  "version": 3,
  "publishedAt": "2026-11-08",
  "supportedTypes": ["number", "choice", "scale", "chips", "toggle"],
  "measures": {
    "hold": [{"id": "holdSec", "type": "number", "unit": "giây", "step": 1, "min": 0}],
    "reps": [{"id": "reps", "type": "number", "unit": "lần", "step": 1, "min": 0}],
    "load": [{"id": "loadKg", "type": "number", "unit": "kg", "step": 2.5, "min": 0},
             {"id": "reps", "type": "number", "unit": "lần", "step": 1, "min": 0}]
  },
  "criteria": [
    {"id": "technique", "type": "choice", "appliesTo": {"disciplines": ["*"]}, "options": ["poor", "ok", "good"]},
    {"id": "rpe", "type": "scale", "min": 6, "max": 10, "appliesTo": {"disciplines": ["gym"]}},
    {"id": "condition", "type": "chips", "prefill": "previousSet", "splitsTrend": true, "appliesTo": {"disciplines": ["calisthenics"]}},
    {"id": "equipment", "type": "chips", "prefill": "previousSet", "splitsTrend": true, "appliesTo": {"disciplines": ["gym"]}},
    {"id": "pain", "type": "toggle", "appliesTo": {"disciplines": ["*"]}}
  ]
}
```
Bản đầy đủ, có nhãn, gợi ý và icon, nằm trong mockup (panel "Xem cấu hình đang dùng (JSON)").

### 5.2 Ngữ nghĩa các trường
| Trường | Ý nghĩa |
|--------|---------|
| `id` | Khoá ổn định, **không tái sử dụng** sau khi đã có dữ liệu. Đổi nhãn được, đổi nghĩa thì phải tạo id mới. |
| `type` | Một trong `supportedTypes`. Mỗi kiểu có một renderer. Kiểu mà client không biết thì **bỏ qua tiêu chí đó**, không làm vỡ màn hình. |
| `appliesTo.disciplines` | `*` = mọi môn. |
| `appliesTo.exerciseIds` | Tuỳ chọn, có từ v1 ([ADR-050](15-decisions-risks.md)). Có thì tiêu chí chỉ hiện cho các bài trong danh sách (vẫn phải khớp môn). Id không có trong catalog thì bỏ qua; bài tập cá nhân chỉ nhận tiêu chí theo môn. `measurementTypes` để sau. |
| `options[].v` | Giá trị lưu. `label` chỉ dùng để hiển thị và đổi được. |
| `prefill: previousSet` | Điền sẵn bằng giá trị của set trước trong cùng bài. |
| `splitsTrend` | Khi giá trị đổi so với set hoặc buổi trước, điểm trên biểu đồ Tiến bộ được tách chuỗi để không so sánh khập khiễng. |
| `required` | Mặc định `false`. Xem quy tắc 3.6. |
| `enabled` | Portal bật hoặc tắt tiêu chí mà không xoá dữ liệu cũ. |

### 5.3 Quy tắc phiên bản và offline
- App **cache bộ cấu hình cuối cùng** và dùng nó khi offline. Lần cài đầu dùng bộ đóng gói sẵn trong app.
- Mỗi `set_result` lưu `criteriaVersion` cùng các giá trị theo `id`. Lịch sử luôn được đọc đúng theo phiên bản tại thời điểm ghi.
- Bộ cấu hình mới chỉ áp dụng cho **set ghi sau đó**. Buổi đang tập giữ nguyên phiên bản đã dùng lúc bắt đầu buổi.
- Tắt hoặc gỡ một tiêu chí không xoá giá trị đã ghi.

### 5.4 Portal web quản trị (tương lai)
Phạm vi ([ADR-051](15-decisions-risks.md)): bộ tiêu chí, `indicator_definition`, danh mục bài tập và media catalog. Media phải qua kiểm tra giấy phép theo docs/10 trước khi xuất bản. Yêu cầu chung:
- CRUD tiêu chí, kiểm tra `type` / `options` hợp lệ.
- Xem trước giao diện P6 theo từng môn và cách đo.
- Xuất bản thành phiên bản mới (immutable), có thể rollback, và có nhật ký thay đổi (ai sửa gì, lúc nào).
- Phân quyền admin.

Portal **không** được thêm tiêu chí có tính chẩn đoán y tế hoặc tự động kết luận thay người dùng.

## 6. Mục tiêu, lộ trình và tiến bộ
### 6.1 Nhiều mục tiêu nhỏ
Một giáo án có **nhiều mục tiêu nhỏ** thay vì một mục tiêu lớn gắn cứng vào một bài. Mỗi mục tiêu đo bằng **đúng một chỉ số**:

```text
Goal { id, title, indicatorId, exerciseId?, baseline?, current?, target | {min,max},
       scope: 'plan' | phaseId, unlockAfter?: goalId,
       status: active | reached | achieved | missed | archived,
       achievedAt?, pinned, note? }
```

| Loại (`kind`) | Ví dụ chỉ số | Cách tính `current` |
|---------------|--------------|---------------------|
| `performance` (Thành tích) | Giữ lâu nhất (giây), Set tốt nhất (lần), Mức tạ × 5 lần (kg) | Giá trị tốt nhất của bài trong phạm vi |
| `adherence` (Chuyên cần) | Tỉ lệ đi tập (%) | Buổi đã tập / buổi theo lịch tới hôm nay, theo lịch sau lần dời gần nhất ([ADR-052](15-decisions-risks.md)) |
| `volume` (Khối lượng) | Tổng lần / tuần, Tổng khối lượng / tuần | Tổng của tuần hiện tại |
| `milestone` (Cột mốc kỹ năng) | Lần đầu giữ được / làm được | Lần đầu đạt mức đích |
| `body` (Số đo cơ thể) | Cân nặng TB 7 ngày | Người dùng tự nhập; đích là khoảng `{min,max}` |

- Danh mục **loại** và **chỉ số** (`IndicatorDefinition`: nhãn, đơn vị, bước, loại bài áp dụng, cách gộp) là cấu hình có phiên bản do portal quản lý, giống bộ tiêu chí ở §5. Mục tiêu chỉ lưu `indicatorId`.
- `current` luôn **tính từ set_result đã lưu** (hoặc số đo đã nhập), không cho sửa tay.
- Bài cho chỉ số `performance` / `volume` / `milestone` được chọn từ **lưới poster**, lọc theo `measurementType` phù hợp với chỉ số.

### 6.2 Trạng thái và xác nhận
- `active` → `reached` khi `current` chạm đích. App **không tự đánh dấu đạt**: người dùng bấm "Xác nhận đạt" (→ `achieved`, ghi `achievedAt`) hoặc "Chưa, giữ tiếp" (giữ `active`). Cùng tinh thần AGENTS rule 3 và 5.
- Hết phạm vi (giai đoạn hoặc giáo án) mà chưa đạt → `missed`. Người dùng chọn "Gia hạn" (chuyển sang phạm vi kế tiếp) hoặc "Lưu trữ". `missed` hiển thị trung tính, không dùng màu đỏ.
- `archived` có thể khôi phục. Không xoá lịch sử set khi xoá hay lưu trữ mục tiêu.

### 6.3 Thang kỹ năng
Chuỗi mục tiêu nối bằng `unlockAfter` (ví dụ Push-up 20 lần → Tuck Planche 20 giây → Adv. Tuck Planche 10 giây). Mục tiêu bị khoá hiện mờ kèm chip "Chưa mở" và dòng "Mở khi đạt …" và không tính vào số mục tiêu đang theo đuổi. Không cho tạo vòng lặp.

### 6.4 Giới hạn hiển thị và riêng tư
- Tổng quan chỉ hiện **tối đa 3 mục tiêu ghim**. Ghim mục tiêu thứ 4 thì phải bỏ ghim một mục tiêu khác.
- Từ **6 mục tiêu đang theo đuổi** hiện gợi ý mềm "nên tập trung ít mục tiêu hơn"; không chặn.
- Mục tiêu `body` có tuỳ chọn ẩn khỏi Tổng quan và Tiến bộ. COAMI **không** đưa lời khuyên ăn uống hay y tế dựa trên số đo.

### 6.5 Lộ trình
- **Giai đoạn:** danh sách có thứ tự `{name, weeks, description}`. Nhãn "Tuần a–b" và trạng thái xong / đang tập / sắp tới được **tính ra** từ thứ tự, số tuần và tuần hiện tại, không lưu. Thời lượng giáo án = tổng số tuần các giai đoạn.
- **Tuần hiện tại:** tính từ ngày bắt đầu giáo án (khoá theo ngày lịch, có xử lý đổi múi giờ theo AGENTS). Không lưu như một con số cứng.
- Sửa thực hiện trên **bản nháp**. "Lưu" áp dụng ngay và ghi vào **Nhật ký thay đổi**. "Huỷ" bỏ bản nháp.
- Xoá giai đoạn đang tập, hoặc rút số tuần khiến tuần hiện tại vượt quá tổng, thì hiện xác nhận. Mục tiêu có `scope` là giai đoạn bị xoá chuyển về `plan`. Không bao giờ xoá set đã ghi.
- Đề xuất AI thay đổi lộ trình hoặc mục tiêu vẫn đi qua luồng chấp nhận / từ chối hiện có (AIReviewView).

### 6.6 Tiến bộ so với lúc bắt đầu giáo án
Màn Tiến bộ chỉ trả lời hai câu: **đã tiến bộ bao nhiêu** và **tiến bộ thế nào**. Màn này không có bộ chọn khoảng thời gian; luôn tính trong giáo án hiện tại, từ tuần 1 đến hôm nay.

- **Gộp theo tuần:** mỗi tuần là một điểm. Chỉ số "tốt nhất" (giữ lâu nhất, set tốt nhất, mức tạ) lấy **max** trong tuần. Chỉ số "tổng" (tổng lần, tổng khối lượng, tổng thời gian giữ) lấy **sum**. Cách gộp nằm trong `IndicatorDefinition`.
- **Mốc so sánh:** giá trị của tuần đầu tiên có dữ liệu cùng điều kiện. Chỉ hiện chênh lệch khi có ít nhất 2 tuần so sánh được; nếu mới có 1 tuần thì ghi "chưa đủ dữ liệu để so".
- **Giá trị hiện tại:** chỉ số "tốt nhất" lấy **tốt nhất đến nay**. Chỉ số "tổng" lấy **tuần gần nhất có dữ liệu**, vì cộng dồn cả giáo án không phản ánh tiến bộ.
- **Đã tiến bộ bao nhiêu:** hiện cặp `Tuần a: x → Tuần b: y`, chênh lệch tuyệt đối và % (ví dụ `+3 giây (+25%) so với lúc bắt đầu`). Bằng nhau ghi "Chưa đổi". Giảm thì chỉ ghi số, không tô đỏ và không kèm lời khuyên.
- **Đổi điều kiện tập** (tiêu chí `splitsTrend`, ví dụ bỏ dây trợ lực): mốc tính lại từ tuần đổi điều kiện, nhãn ghi "kể từ khi đổi điều kiện". Biểu đồ đứt nét tại tuần đổi, kèm ghi chú lý do.
- **Tiến bộ thế nào:** biểu đồ toàn giáo án (T1 → tuần cuối). Tuần chưa tới để trống và tô mờ "Sắp tới". Tuần không có dữ liệu để trống, không nội suy, không nối qua. Có đường mục tiêu (nếu có mục tiêu liên quan) và mốc ban đầu.
- **Chuyên cần từ đầu giáo án:** mỗi tuần một cột, đánh dấu tuần hiện tại, ghi tổng buổi đã tập / đã lên lịch. Buổi bỏ lỡ chỉ đếm số, **không dùng màu đỏ**. Buổi hôm nay chưa tính.
- Tính toán chạy cục bộ trên dữ liệu đã lưu (offline-first), không cần backend.

> **Đề xuất cho tab Lịch sử (ngoài phạm vi module này):** các chế độ xem theo khoảng thời gian (tuần / tháng / 3 tháng / tuỳ chọn) gồm so với kỳ trước, lịch chuyên cần theo ngày và dữ liệu giáo án trước nằm ở Lịch sử. Lý do: đó là việc tra cứu quá khứ, không phải đo tiến bộ. Đặc tả riêng khi thiết kế lại tab Lịch sử (UX-10). **Cập nhật:** đã thiết kế chế độ Tuần / Tháng, xem docs/02 §3.1. Khoảng 3 tháng / tuỳ chọn để sau.
## 7. Khả năng tiếp cận
- Các nút chọn có `aria-pressed` / `accessibilityAddTraits(.isSelected)`.
- Stepper có nhãn "Giảm / Tăng <tên tiêu chí>".
- Poster trong lưới chọn có nhãn tên bài.
- Màu không phải kênh duy nhất: trạng thái giai đoạn có chip chữ, tiêu chí đang chọn có dấu ✓.

## 8. Tác động contract (phải làm trước khi code, AGENTS rule 7)
Hiện trạng: `set_result` đã có `actualReps`, `actualHoldMs`, `rpe`, `painReported`, `note`. Prescription có các kind `static_hold`, `reps`, `timed_reps`, `interval`, `skill_attempt`.

| Thay đổi cần | Artifact |
|--------------|----------|
| `exercise.discipline`, `exercise.measurementType` | OpenAPI, `db/`, catalog-bundle schema, docs/03 |
| Prescription kind mới `load` (`reps`, `loadKg`) | entity-payloads schema, CaliDomain, reducer fixtures |
| `set_result.actualLoadKg` (decimal, ≥ 0) | entity-payloads, SQL, OpenAPI |
| `set_result.criteriaVersion` + `criteria` (map `id → value`, có giới hạn kích thước) | entity-payloads, SQL (JSONB), validator |
| Tài nguyên `criteria_config` (đọc: `GET /v1/criteria-config`, ETag; ghi: chỉ portal) | OpenAPI, backend, docs/11 (quyền admin) |
| Entity `plan_goal` (§6.1: `indicatorId`, `exerciseId?`, `baseline`, `target` hoặc `min/max`, `scope`, `unlockAfter`, `status`, `achievedAt`, `pinned`), sửa được, có audit; thay cho `training_plan.goal` đơn | entity-payloads, SQL, sync, docs/03 |
| Cấu hình `indicator_definition` (nhãn, đơn vị, bước, loại bài áp dụng, cách gộp max/sum), có phiên bản, đọc kèm `criteria_config` | OpenAPI, backend, portal |
| `plan_phase[]` sửa được, có audit | entity-payloads, SQL, docs/03 |
| Entity `body_measurement` (`kind`, `value`, `measuredAt`), dữ liệu nhạy cảm, không gửi cho AI nếu người dùng không bật | entity-payloads, SQL, docs/09, docs/11 |
| `exercise.focusTags` để sinh nhóm trên màn Tiến bộ | catalog-bundle schema, OpenAPI |
| UX-02 trong docs/02: bỏ "unsynced marker" khỏi luồng lưu | docs/02 (đã cập nhật cùng tài liệu này) |

Đề xuất tách thành các slice: **CON-0xx Plan goals (goal + indicator + phases)** → **CON-0xx Body measurement** → **CON-0xx Discipline + load** → **CON-0xx Criteria config**. Mỗi slice gồm ADR, contract, fixtures và test.

## 9. Câu hỏi mở
1. `rpe` hiện là cột riêng (1–10). Có chuyển thành một tiêu chí cấu hình hay giữ cột riêng vì AI và analytics dùng nhiều? *Đề xuất: giữ cột riêng; trong cấu hình chỉ điều khiển việc hiển thị.* → [ADR-045](15-decisions-risks.md) (Accepted)
2. Đơn vị tạ: chỉ kg, hay cho phép lb theo cài đặt người dùng? *Đề xuất: lưu kg, hiển thị theo cài đặt.* → [ADR-046](15-decisions-risks.md) (Accepted)
3. Tiêu chí có nên áp theo từng bài (`exerciseIds`) ngay từ phiên bản đầu không? **Có.** → [ADR-050](15-decisions-risks.md) (Accepted)
4. Phạm vi của portal: chỉ tiêu chí, hay cả danh mục bài tập và media? **Tất cả.** → [ADR-051](15-decisions-risks.md) (Accepted)
5. Đổi bài hoặc chỉ số của một mục tiêu đã có tiến độ: sửa tại chỗ hay lưu trữ mục tiêu cũ và tạo mới? *Đề xuất: chỉ cho sửa tên và mức đích; đổi bài / chỉ số thì tạo mục tiêu mới để giữ lịch sử.* → [ADR-047](15-decisions-risks.md) (Accepted)
6. Ngưỡng 3 mục tiêu ghim và cách lấy "hiện tại" cho chỉ số tổng (tuần gần nhất) cần kiểm chứng bằng usability test. → [ADR-048](15-decisions-risks.md) (Accepted): giữ giá trị hiện tại làm mặc định tạm.
7. Mục tiêu `adherence` tính theo lịch đã lên tại thời điểm nào khi người dùng dời buổi tập? **Ngay sau khi dời**: buổi tính ở ngày mới, ngày cũ không tính bỏ lỡ. → [ADR-052](15-decisions-risks.md) (Accepted)

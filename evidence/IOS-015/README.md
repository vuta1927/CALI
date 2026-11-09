# IOS-015 — Mục tiêu, lộ trình, tiến bộ (evidence)

Ngày: 2026-11-09 · nhánh `feature/ios-001-calicore-grdb`

## Tự động
- CaliDomain `swift test`: 102/102. `GoalsTests` (9): 6 chỉ số db/005 và ánh xạ measurementType; validation theo contract (tên, mức đích, achievedAt, chỉ số không hợp bài); ghim tối đa 3 mỗi lineage; thang kỹ năng khoá tới khi xác nhận, chặn vòng lặp; khoảng tuần giai đoạn; tiến bộ (tuần trống để trống, cần 2 tuần mới so); giá trị hiện tại theo loại và phạm vi; round-trip `target {min,max}`.
- CaliCore `swift test`: 48/48. `GoalStoreTests`: giai đoạn và mục tiêu đọc/ghi, xoá mềm; giai đoạn sai (53 tuần) rollback cả thay đổi. Migration `v3_goals` idempotent.
- App XCTest: 45/45 trên simulator iPhone 17 và trên iPhone 15 thật (app đã cài). `GoalFlowTests`:
  - chạm mức đích chỉ chuyển "Chờ xác nhận", không có achievedAt; "Chưa, giữ tiếp" / "Xác nhận đạt" (bỏ ghim, audit); lặp commandId an toàn
  - ghim thứ 4 bị từ chối; đổi chỉ số bị từ chối (ADR-047); chỉ số giữ không nhận bài đếm lần
  - lộ trình đặt độ dài (7 tuần), nhãn "Tuần 1–4"/"Tuần 5–7", audit "Sửa lộ trình"; mục tiêu của giai đoạn bị xoá chuyển sang cả giáo án
  - kết thúc giáo án → "Chưa đạt"; lưu trữ / khôi phục
  - tiến bộ và bám lịch lấy từ set đã lưu; một tuần dữ liệu → "Chưa đủ dữ liệu để so"
- Validators `validate_coami_ui_copy.py`, `validate_ios_project_config.py`, `validate_handoff.py`: ok.

## Ảnh simulator (`-uiScenario overview|goals|roadmap|progress`, store trong bộ nhớ)
- `overview.png`: banner chạm mức đích, Tuần 1/8 · Nền tảng, 2 mục tiêu ghim.
- `goals.png`: "Chờ xác nhận" với "Chưa, giữ tiếp" / "Xác nhận đạt".
- `roadmap.png`: 3 giai đoạn, khoảng tuần tự tính.
- `progress.png`: bám lịch theo tuần, thành tích theo bài.

## Thiết bị (cần làm tay)
- Dynamic Type lớn nhất, VoiceOver trên thẻ mục tiêu và cột bám lịch, đổi múi giờ: chưa chạy.

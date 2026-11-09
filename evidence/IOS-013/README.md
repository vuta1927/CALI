# IOS-013 — Nhiều giáo án local (evidence)

Ngày: 2026-11-09 · nhánh `feature/ios-001-calicore-grdb`

## Tự động
- CaliCore `swift test` (macOS): 43/43. Mới: lưu `end_reason` của activation, activation bị bỏ khỏi danh sách thì bị huỷ (không xoá cứng), mở lại activation xoá `end_reason`, nhiều giáo án round-trip theo thứ tự tạo, lịch sử vẫn gắn giáo án khi buổi đã bị xoá.
- App XCTest: 35/35 trên simulator iPhone 17 (iOS 27.2) và trên iPhone 15 thật. `PlanLifecycleTests` (11):
  - tạo giáo án idempotent (id = commandId), lưu ở trạng thái Nháp; nhân bản dùng id mới, không chép activation
  - giáo án sự kiện cần ngày sự kiện từ hôm nay
  - bắt đầu cần ít nhất một buổi và ngày từ hôm nay
  - giáo án thứ 4 bị từ chối (I2); kèm lựa chọn tạm dừng giáo án khác thì thành công trong cùng một lệnh, lặp lệnh không ghi thêm
  - tạm dừng đóng activation ở hôm qua; tạm dừng ngay ngày bắt đầu thì huỷ lần bắt đầu đó; tiếp tục không chồng activation (I1); mở lại app giữ nguyên
  - kết thúc lưu lý do và ghi chú (≤ 500 ký tự), sau đó chỉ xem được và không còn buổi theo lịch
  - lưu trữ chỉ khi không còn đang theo
  - kéo dài giáo án sự kiện đã qua ngày: chuyển thành theo tuần, revision + 1
  - lịch gộp nhiều giáo án; buổi hoàn thành chỉ tính cho đúng giáo án của nó (I4)
- `ContentEditingTests`: xoá giáo án bị chặn khi đang tập buổi của giáo án đó; sau đó xoá mềm vẫn giữ buổi tập và lịch sử (nhãn "(đã xoá)").

## Ảnh simulator
- `plans-list.png`: MP-01, nhóm Đang theo 1/3.
- `today.png`: MP-09, buổi hôm nay và liên kết "Tuần của tôi".

## Chưa làm / thủ công
- Ảnh MP-02/04/06/07/08 chưa chụp; cần thao tác tay trên máy.
- Ma trận thiết bị (đổi múi giờ, đổi giờ hệ thống quanh nửa đêm) chưa chạy.

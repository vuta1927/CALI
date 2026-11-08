# Mockups

Mockup HTML tương tác để thống nhất UX trước khi code SwiftUI. Mỗi file là một trang độc lập, không cần build. Mọi số liệu trong mockup đều là **dữ liệu mẫu**.

| File | Nội dung | Tài liệu đặc tả |
|------|----------|-----------------|
| [`plan-module.html`](plan-module.html) | Module Giáo án: tổng quan, lộ trình (sửa được), tiến bộ đa môn, chi tiết, buổi tập, **P6 nhập kết quả set theo cấu hình động**, nhiều mục tiêu nhỏ, tiến bộ so với lúc bắt đầu giáo án. **Toàn bộ app**: Chào mừng, Hôm nay, Bài tập (tìm/lọc, chi tiết, sửa bài), Sửa buổi tập, Lịch sử theo buổi tập (xem theo **tuần / tháng**, lịch tháng lọc theo ngày, tổng kết kỳ) + chi tiết buổi, Cá nhân, Đề xuất AI, Nhật ký thay đổi, Player (sẵn sàng/đếm ngược/đang tập/tạm dừng/nghỉ/tổng kết/kết thúc), Lock Screen; tab bar bấm được, panel chọn biến thể màn. **Nhiều giáo án**: danh sách giáo án (đang theo / nháp / đã kết thúc / lưu trữ), tạo giáo án (theo tuần hoặc hướng tới ngày giải), bắt đầu theo (giới hạn 3 giáo án, bắt đầu muộn), Tuần của tôi, ghi kết quả chạy (km + thời gian → pace), kết quả giải; Hôm nay gộp nhiều giáo án, Tổng quan/Tiến bộ đổi theo giáo án, Lịch sử lọc theo giáo án, tổng hợp chéo ở Cá nhân | [`docs/18-plan-module.md`](../../18-plan-module.md), [`docs/19-multi-plan.md`](../../19-multi-plan.md) |
| [`archive/plan-module-v1-original.html`](archive/plan-module-v1-original.html) | Bản mockup gốc ban đầu, giữ lại để đối chiếu. **Không dùng làm chuẩn.** | — |

## Cách xem
- Mở file trực tiếp trong trình duyệt (Chrome / Safari / Edge).
- Panel bên trái dùng để chuyển màn, đọc ghi chú thiết kế và **giả lập portal**: đổi bài (hold / reps / load), bật hoặc tắt từng tiêu chí, xem JSON cấu hình.
- Nếu công cụ tự động chặn `file://`, chạy một static server bất kỳ trong thư mục này, ví dụ `npx serve .`.

## Quy ước
- Bám component của app (Components.swift): caliCard, TagChip, FilterChip, StatTile, LinearProgress, PosterView.
- Màu: **bảng màu cam** (kiểu Strava), dùng chung cho mockup và `Theme.swift` của app: `--accent` / `caliAccent` #FC4C02 cho nền và đồ hoạ, `--accent-ink` / `caliAccentInk` cho chữ màu cam (đạt 4.5:1), chữ tối `caliOnAccent` #1A1206 trên nền cam. Icon app và brand assets cũng đã sang cam (bản teal lưu ở `brand/archive/teal-v1/`).
- Visual-first: bài tập luôn có poster. Poster `PLACEHOLDER` là ảnh tạm.
- Chỉ dùng nút "Lưu". Không hiển thị trạng thái lưu máy hay đồng bộ.
- Bản cũ chuyển vào `archive/`, không xoá.

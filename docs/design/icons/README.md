# COAMI – App Icon Package v1

Nguồn thiết kế: `glowing_glass_coami_app_icon.png`. Các PNG được resize theo kích thước vuông, RGB, không alpha.

- `COAMI_AppIcon_1024.png`: ảnh nguồn cho App Store / Xcode asset catalog.
- `COAMI_AppIcon_512.png`: bản preview lớn.
- `COAMI_AppIcon_180.png`, `120.png`, `60.png`: bản preview theo kích thước phổ biến.

## Lưu ý production

Bản thiết kế gốc đã chứa khung icon bo góc và nền sáng phía ngoài; đây là artwork tham chiếu được chuẩn hóa kích thước, **chưa phải artwork full-bleed đúng chuẩn thiết kế iOS**. Khi đưa vào App Store/Xcode, nên xuất lại nguồn thiết kế không bo góc sẵn, không có viền trắng, để hệ điều hành tự áp dụng mặt nạ góc. Nếu dùng file này trực tiếp, biểu tượng có thể bị tạo hiệu ứng bo góc hai lần hoặc hiện viền sáng.

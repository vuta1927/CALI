# COAMI – App Icon Package v2 (cam)

v2: toàn bộ PNG trong thư mục này được đổi màu từ bản teal sang bảng màu cam (flame/orange/ember, nền than ấm) bằng cách dịch hue, giữ nguyên hình khối. Bản teal v1 giữ nguyên trong `archive/teal-v1/`.

Nguồn thiết kế: `glowing_glass_coami_app_icon.png`. Các PNG được resize theo kích thước vuông, RGB, không alpha.

- `COAMI_AppIcon_1024.png`: ảnh nguồn cho App Store / Xcode asset catalog.
- `COAMI_AppIcon_1024_FullBleed.png`: bản full-bleed dùng trong iOS asset catalog; giữ artwork kính, thay nền trắng ngoài icon bằng nền tối để không tạo viền trắng trên Home Screen.
- `COAMI_AppIcon_512.png`: bản preview lớn.
- `COAMI_AppIcon_180.png`, `120.png`, `60.png`: bản preview theo kích thước phổ biến.

## Lưu ý production

Bản gốc `COAMI_AppIcon_1024.png` đã chứa khung icon bo góc và nền trắng ngoài; không dùng trực tiếp cho iOS vì có thể hiện viền trắng trên Home Screen. App dùng `COAMI_AppIcon_1024_FullBleed.png`; phần nền tối phủ tới mép ảnh, hệ điều hành tự áp dụng mặt nạ góc.

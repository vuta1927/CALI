# COAMI · Brand assets v1.0

Bộ tài nguyên được dựng từ **brand board màu cam do bạn cung cấp**, ngày 10/11/2026. Mở `07-preview/COAMI-assets-preview.png` để xem nhanh.

## Dùng ngay

- **App icon iOS 1024×1024:** `01-app-icon/png/default/coami-app-icon-default-1024.png` — RGB, sRGB, nền kín, vuông và chưa bo góc.
- **Logo đầy đủ nền trong suốt:** `03-png/logo/coami-logo-orange-transparent-2048w.png`.
- **Logo có tagline gốc:** `03-png/logo-tagline/coami-logo-tagline-orange-transparent-2048w.png`.
- **Biểu tượng thương hiệu:** `03-png/mark/`; **biểu tượng dùng trong app icon:** `03-png/app-symbol/`.
- **Xcode:** thêm `05-integration/ios/COAMIBrand.xcassets` và chọn `COAMIAppIcon` làm App Icons Source.
- **Màu:** `06-colors/coami.tokens.json`, CSS, Swift và bảng màu GPL.
- **Hướng dẫn:** `05-integration/INTEGRATION.md` và `BRAND-GUIDE.md`.

## Cấu trúc

| Thư mục | Nội dung |
|---|---|
| 00-source | Brand board cam nguyên bản, không sửa |
| 01-app-icon | Icon vuông 16–1024 px, các biến thể và lớp rời |
| 02-svg | Đường nét vector: logo, wordmark, mark; có màu và monochrome |
| 03-png | Logo/icon trong suốt, nền sáng/tối, monochrome |
| 04-splash | Logo trong suốt @1x/@2x/@3x và ảnh màn hình xem trước |
| 05-integration | Asset catalog, storyboard tĩnh và hướng dẫn |
| 06-colors | Màu sRGB và design tokens |
| 07-preview | Bảng xem nhanh và ảnh chồng đường nét để kiểm tra |
| 08-quality | Báo cáo kiểm tra và danh sách SHA-256 |

## Nguồn và giới hạn độ chính xác

Nguồn là **PNG 1448×1086**, không có file vector gốc. SVG trong gói là **vector trace từ silhouette của ảnh**, mọi chữ của logo/tagline đã được chuyển thành đường nét; không có ảnh nhúng hay font cần cài. Logo trên cùng và biểu tượng trong ô app icon được trace riêng vì bản thân brand board thể hiện hai biến thể hình khối khác nhau. Tỷ lệ và bố cục tương ứng được giữ theo từng phần của nguồn.

Đường biên được kiểm tra với mặt nạ ở độ phân giải nguồn trong `08-quality/quality-report.json`. Đây là thước đo độ khớp silhouette, **không phải chứng nhận trùng tuyệt đối với master vector chưa có**. Gradient được tái lập theo ảnh; texture, ánh phản chiếu và nhiễu raster nhỏ không được sao chép. Nền ô app icon được mở rộng thành hình vuông kín để iOS tự tạo góc bo. Màu monochrome/flat và các bố cục splash là biến thể sản xuất từ cùng đường nét.

PNG kích thước lớn được render từ các đường nét vector, không tạo thêm chi tiết so với nguồn. Gói chưa được build bằng Xcode hay kiểm tra trên iPhone vì môi trường hiện tại là Windows. Cần kiểm tra giao diện sáng/tối/tinted, màn hình khởi động và upload validation trên máy Mac trước phát hành.

## Trong repo này

- Đây là bộ **v1.0** hiện hành (brand board cam đã duyệt). iOS dùng icon, ảnh launch và màu nền từ `05-integration/ios/COAMIBrand.xcassets` (bản sao nằm trong `ios/CaliApp/Assets.xcassets`).
- Các bản cũ nằm trong `archive/`: `guided-c-v0/` (ứng dụng Guided Companion C màu cam trước đây) và `teal-v1/` (bản teal gốc). Không dùng cho sản phẩm mới.
- `python3 tools/validate_brand_assets.py` kiểm tra checksum của `08-quality/file-manifest.csv`, các SVG và việc asset iOS khớp với bộ này.

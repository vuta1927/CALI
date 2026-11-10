# Tích hợp COAMI

## 1. iOS / Xcode — PNG và Asset Catalog

1. Trên Mac, kéo `ios/COAMIBrand.xcassets` vào project và chọn target ứng dụng.
2. Trong target → General → App Icons and Launch Screen, đặt App Icons Source thành `COAMIAppIcon`. Có thể cần chọn tên này trong Build Settings → Primary App Icon Set Name.
3. Catalog dùng cấu hình single-size 1024×1024: default là PNG RGB kín nền; dark là foreground PNG có alpha; tinted là bản grayscale. Xcode tạo các kích thước còn lại. Kiểm tra các ô Any/Dark/Tinted trong trình sửa asset.
4. Nếu dự án cũ chỉ dùng catalog All Sizes, lấy các kích thước từ `01-app-icon/png/default/` hoặc chuyển catalog sang Single Size. Không nhập lẫn light/default vào cùng một appearance.
5. Không bo góc hoặc thêm canvas trong suốt quanh icon default. Các PNG icon trong gói là hình vuông chưa mask. Xem trước trên simulator và thiết bị, sau đó chạy archive/upload validation.

Bản `light` trong thư mục icon là **biến thể tùy chọn nền sáng**, không được gắn sẵn làm default vì brand board đã chốt icon nền tối.

## 2. Icon Composer / Liquid Glass

`01-app-icon/layers/` gồm các file canvas đồng nhất 1024×1024:

- `coami-C-flat-1024.svg/png`: chữ C phẳng cam.
- `coami-details-white-1024.svg/png`: người và ba cột trắng.
- `coami-foreground-1024.svg/png`: foreground hoàn chỉnh gradient + chi tiết trắng.
- `coami-background-1024.svg/png`: nền tối kín.
- `coami-tinted-1024.svg/png`: grayscale tham khảo.

Trong Icon Composer, dùng **foreground hoàn chỉnh hoặc hai lớp rời C + details**; không chồng cả hai cách cùng lúc. Có thể tạo nền bằng màu ink thay vì nhập nền có glow. Giữ nguyên vị trí/tỷ lệ giữa các lớp. Để hệ thống xử lý Liquid Glass; không cần đắp thêm góc bo hay highlight lên hình gốc.

Gói này **không có file `.icon` được xuất/kiểm nghiệm bằng Icon Composer**. SVG/PNG layer là nguyên liệu để tạo file đó trên Mac; cần xem trước các appearance clear/dark/tinted trước khi thay cấu hình catalog PNG hiện có. Không cam kết mọi appearance đã được kiểm chứng.

## 3. Launch screen và splash

Thêm `ios/COAMILaunchScreen.storyboard` vào target. Trong target → General, chọn `COAMILaunchScreen` làm Launch Screen File. Nếu ứng dụng đang dùng cấu hình `UILaunchScreen` trong Info.plist, chọn một cách cấu hình và bỏ cấu hình trùng sau khi kiểm tra project.

Storyboard là ví dụ UIKit tĩnh, có ảnh `COAMILaunchLogo` và nền `COAMIBackground` thay đổi theo light/dark. Logo giữ tỉ lệ, rộng ưu tiên 280 pt, giới hạn theo lề màn hình. Các image set 1x/2x/3x đã có trong catalog. Không thêm animation, lớp custom hoặc kết nối code vào launch storyboard.

Ảnh toàn màn hình trong `04-splash/previews/` là **bản xem trước**, không nên dùng một ảnh cố định để kéo giãn trên mọi iPhone/iPad. Dùng logo trong suốt + nền native. Màn hình launch nên khớp màn hình đầu tiên của ứng dụng; chỉnh nền/logo theo trải nghiệm thực tế nếu cần. Nếu muốn một splash có animation, thực hiện trong giao diện app sau khi launch kết thúc.

## 4. Web và các ứng dụng khác

SVG trong `02-svg/` có path thực, không font hay ảnh nhúng. Chọn đúng biến thể nền, đặt chiều rộng và để chiều cao tự động:

```html
<img src="/assets/coami-logo-orange-transparent.svg"
     width="280" alt="COAMI" style="height:auto" />
```

Copy `06-colors/coami.css` và đổi đường dẫn theo project. Với PNG, chọn file đủ lớn cho mật độ màn hình: ví dụ hiển thị 280 px trên màn hình 3× cần nguồn tối thiểu 840 px. File trắng monochrome cần nền tối để nhìn rõ. Không dùng app icon có nền vuông thay thế logo nền trong suốt trong header.

## 5. Checklist cho người tích hợp / AI coding agent

- Giữ nguyên source brand board và silhouette; dùng file trong gói, không tự sinh lại logo.
- Dùng đúng master: logo/mark cho thương hiệu, app-symbol cho app icon.
- Giữ aspect ratio; không crop vào hình C hoặc các cột.
- Primary icon: RGB 1024×1024, không alpha, không bo góc.
- Kiểm tra dark/tinted và launch light/dark trên simulator, iPhone và iPad theo phạm vi app.
- Kiểm tra asset name, target membership, cấu hình App Icons Source và Launch Screen File.
- Chạy Xcode build, archive và App Store validation. Gói đã kiểm tra file, **chưa chạy các bước Xcode này**.

## Tham khảo chính thức

Đối chiếu ngày 10/11/2026:

- [Apple — Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [Apple — App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Apple — Specifying your app’s launch screen](https://developer.apple.com/documentation/xcode/specifying-your-apps-launch-screen)

Các nguồn trên hỗ trợ cấu hình single-size, appearance, masking/layers và storyboard launch. Chúng không xác nhận chất lượng riêng của bộ COAMI.

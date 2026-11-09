# IOS-014 — Ghi kết quả chạy (evidence)

Ngày: 2026-11-09 · nhánh `feature/ios-001-calicore-grdb`

## Tự động
- CaliDomain `swift test`: 93/93.
  - `testRunningActuals`: 0 và nil bị từ chối khi hoàn thành; 86401 s và 1000001 m bị từ chối; 86400 s được nhận (pace "24:00:00/km"); `source = manual`; segment `duration` có deadline; set giữ tĩnh không nhận quãng đường.
  - `testRunningPrescriptionRoundTripsWithContractKeys`.
- CaliCore `swift test`: 46/46. `ManualRunningTests`:
  - `recordSession` ghi buổi, set (`source = manual`, pace 4:55/km), lịch sử và audit một lần; lặp lệnh chỉ replay.
  - một bước bị từ chối (hơn 24 giờ) thì không còn gì: không buổi, không outcome, không lịch sử, không audit.
  - `insertMissingExercises` chỉ thêm id mới, giữ bài người dùng đã sửa.
- App XCTest: 40/40 trên simulator iPhone 17 (iOS 27.2) và trên iPhone 15 thật (app đã cài lên máy). `RunningResultTests`:
  - parse km dấu phẩy hoặc dấu chấm, giờ/phút/giây, phút ≥ 60 không hợp lệ, chữ hiển thị pace
  - set chạy qua player: thời gian 0 hoặc hơn 24 giờ không được lưu; giá trị hợp lệ thì lưu và hiện "5 km 25:30 · 5:06/km"
  - kết quả thi: từ chối 0 / hơn 24 giờ / 0 km; lưu một buổi hoàn thành gắn với buổi ngày thi và giáo án; lặp commandId không ghi thêm; giáo án vẫn đang theo
  - trước ngày sự kiện thì bị từ chối
  - database cũ nhận thêm hai bài chạy đi kèm mà không mất bài đã sửa

## Ảnh simulator (`-uiScenario`, store trong bộ nhớ)
- `run.png`: P6 cho chặng 5 km. Km điền sẵn từ mục tiêu; thời gian đo được dưới 1 giây nên không điền sẵn; Lưu bị khoá tới khi có thời gian.
- `race.png`: MP-07, km khoá theo cự ly giải.

## Chưa làm / thủ công
- Ảnh RaceResultCard trong chi tiết giáo án và chi tiết buổi chạy trong Lịch sử chưa chụp.
- Nhập tay trên iPhone thật (bàn phím số thập phân theo vùng `vi`, VoiceOver các ô giờ/phút/giây) chưa kiểm tra.

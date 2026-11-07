# PRD — Calisthenics Training Companion v1.0

## 1. Product vision
Ứng dụng iOS giúp người tập Calisthenics lập lịch, nhận diện bài tập từ ảnh/video, tập có hỗ trợ timer/set/rep/rest, theo dõi trên màn hình khóa, ghi log khi offline, đồng bộ về backend và nhận nhận xét AI theo dữ liệu thực tế.

## 2. Personas và bối cảnh
- **Primary**: người tập độc lập, thường đặt iPhone trên sàn/thảm, tay bận, cần thao tác tối thiểu; tập skill static hold (Planche, L-sit), reps (Pull-up, Dips), chân.
- **Secondary**: người mới, phân biệt động tác thông qua hình/video và chú ý kỹ thuật.
- **Operator/Admin (phase sau)**: quản trị media/catal​og; MVP seed catalog qua backend migration/fixture được kiểm duyệt.

### Persona thử nghiệm v1 (không cứng hóa vào nghiệp vụ)
Buổi T2/T4/T6: Full Planche foundation, Iron Cross foundation (khi có rings), chân; mục tiêu Tuck Planche 10–15s; dữ liệu minh họa dùng fixture, không tự suy diễn khối lượng an toàn.

## 3. Outcomes & KPIs (mục tiêu sản phẩm cần xác nhận sau pilot)
- Người dùng bắt đầu buổi tập trong <=3 thao tác từ Home khi plan có sẵn.
- Xác nhận set trong <=2 thao tác, touch targets >=44pt.
- 100% workout commands hoạt động offline, không mất kết quả khi app bị kill ngay sau khi ghi thành công.
- >95% planned exercises có media poster offline trước buổi tập (goal vận hành, không hard fail nếu cache thiếu).
- Không phát sinh duplicate set hay session sau 10 lần retry cùng mutation.
- Tất cả recommendations cần user approval; không có tự động chỉnh progression.

## 4. Scope MVP
### P0 (phải có trước pilot)
| ID | Requirement | Acceptance điều kiện đạt |
|---|---|---|
| FR-01 | Exercise Catalog có thumbnail, poster, video preview + technique cues | Lọc theo thiết bị, type, progression; mở preview 1 tap; image fallback offline |
| FR-02 | Planner tuần/chu kỳ | Tạo/copy buổi, thêm/xóa/reorder bài, set/rep/hold/rest targets, lưu local |
| FR-03 | Session Player | Start/Pause/Resume/Skip/Confirm Set/Finish/Abandon, không double-submit |
| FR-04 | Static Hold / Rep / Rest | Countdown hold/rest, manual actual reps, save actual hold; advance only on explicit confirmation |
| FR-05 | Reminders | Notification/haptic/audio khi cho phép, nhắc cuối rest; disable/policy UI |
| FR-06 | Visual-first | Poster lớn ở danh sách và player; tap thumbnail xem video; không cần rời session |
| FR-07 | Journal | Log per set, RPE optional 1–10, note, review/history, soft-delete/edit audit |
| FR-08 | Offline local | Không mạng vẫn tạo plan, tập, log, xem media đã tải; queue đồng bộ |
| FR-09 | Lock Screen | Live Activity glanceable timer/phase; thông báo; interactive action theo chính sách khóa máy của iOS |
| FR-10 | Server sync | Push idempotent, pull cursor, conflict handling, guest migration khi đăng nhập |
| FR-11 | AI review | Sau buổi tập đã đồng bộ, tạo analysis async; hiển thị insight + proposed delta; user approve/reject |
| FR-12 | Auth | Guest offline và Sign in with Apple cho sync đa thiết bị; logout không xóa log local trái ý muốn |

### P1 (nâng cao, không ngăn MVP)
- Tìm kiếm tag nâng cao, superset nâng cao; tự thay video góc quay; thống kê progression tuần/chu kỳ; background media prefetch; push khi AI xong.
### Ngoài phạm vi
- Auto rep counting bằng camera, pose correctness bằng AI vision, Apple Watch companion app, social, marketplace, voice recognition, thiết bị đo thông minh.

## 5. Domain rules và quyền sở hữu
- Người dùng có thể hoàn thành thực tế khác planned target; không overwrite planned values.
- `set_result` không tự động ghi successful khi countdown về 0; phải xác nhận actual.
- Có thể chỉnh sửa set log, nhưng giữ revision/audit để AI không chấm bản cũ như mới.
- Chỉ 1 active session mỗi profile/device tại một thời điểm trong MVP; khôi phục thay vì tạo session trùng.
- Không ép người dùng đăng nhập để bắt đầu tập.
- AI recommendation chỉ có trạng thái `proposed`, `accepted`, `rejected`, `superseded`; apply phải tạo plan revision mới, không sửa lịch sử.

## 6. Core user stories
- US-01: Là người tập, tôi nhìn thumbnail là biết bài sắp tập mà không đọc tên.
- US-02: Tôi xem video loop ngắn trước khi bắt đầu/giữa giờ nghỉ ngay cả khi offline.
- US-03: Tôi bấm Start, app tự đếm hold, thông báo khi hết thời gian và chờ tôi xác nhận.
- US-04: Tôi ghi actual rep của Pull-up khi kết thúc set và được nghỉ đúng số giây đã cấu hình.
- US-05: iPhone tự khóa, tôi vẫn nhìn được countdown; thao tác an toàn theo quy định khóa máy.
- US-06: Rớt mạng lúc đang tập, dữ liệu không mất, online lại có sync và không trùng set.
- US-07: Sau buổi tập, tôi xem planned vs actual, thêm note, và nhận phân tích sau khi online.
- US-08: Tôi có thể từ chối đề xuất AI, giữ nguyên giáo án.

## 7. Key journeys
`Onboard guest → Home → Plan/Today → exercise media preview → Start Session → Ready → Countdown → Active Hold/Reps → Confirm Actual → Rest → Next Set/Exercise → Session Summary → Journal → Sync → AI Analysis → Review Suggestion → Approve or Reject`.

## 8. Dependencies & explicit constraints
- Thiết bị có hỗ trợ Live Activities và đã bật quyền; widget buttons on locked device chỉ thực thi sau xác thực/mở khóa (Apple).
- Notification delivery không tuyệt đối chính xác; yêu cầu UX chấp nhận best-effort; active display timer vẫn chính xác theo timestamp khi được render.
- Với camera auto reps chưa thực hiện, label phải là **nhập/ghi rep**, không phải “AI đếm rep”.
- Media bản quyền cần được xác nhận trước phát hành.

## 9. Acceptance của P0 pilot
1. Guest xem được ảnh offline + bắt đầu một buổi gồm Tuck Planche 4×12s/90s, Pull-up 4×8–10/120s.
2. Hoàn thành 2 set, khóa máy giữa rest, đánh thức thấy countdown; mở khóa resume đúng state.
3. Force-quit, mở lại thấy tất cả set đã confirm không mất; không tự ghi thêm set.
4. Airplane mode ghi đủ buổi, mở mạng push idempotent và pull results.
5. AI fail/down không chặn xem summary hay bài tập kế tiếp.
6. Bấm Accept recommendation sinh plan revision mới và có thể rollback bằng cách chọn revision cũ.

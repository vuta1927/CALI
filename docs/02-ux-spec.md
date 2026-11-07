# UX / UI Specification — Visual-first training

**Visual reference:** [`../references/ui_concept_reference.png`](../references/ui_concept_reference.png). Đây là minh họa ý tưởng; bố cục và chữ trong hình do AI dựng, có thể sai tiểu tiết. Mọi requirement chính thức nằm ở tài liệu này.

## Quản lý nội dung cá nhân (IOS-009 / MED-002)
Catalog có nút thêm bài, chi tiết có nút sửa. Form chỉnh tên, kiểu tập, cấp độ,
nhóm cơ, dụng cụ, cue/lỗi và ảnh/video riêng. Cho nhập HTTPS hoặc chọn Photos/Files,
gỡ từng media, hủy không lưu. Kiểu tập của bài đã được dùng phải giữ nguyên;
muốn đổi kiểu thì tạo bài mới để bảo toàn mục tiêu đã ghi.
Giáo án có sửa tên, xóa xác nhận, tạo lại; buổi tập có thêm/sửa ngày/xóa xác nhận.
Xem [quy tắc và acceptance](17-content-editing.md).

## 1. Product UX principles
1. **See, then read**: ảnh poster biểu đạt đúng posture; tên bài được hiển thị nhưng không chiếm vị trí ưu tiên.
2. **1-hand use**: nút lớn, ít thao tác, ưu tiên phía dưới màn hình.
3. **Workout is uninterrupted**: mở video không dừng timer, trừ khi người dùng chủ động Pause.
4. **Offline is normal**: không chặn thao tác; sync badge rõ ràng nhưng không gây lo lắng.
5. **Clear states**: warmup/ready/holding/reps/rest/confirm/paused/completed luôn hiển thị khác nhau.
6. **Safe choices**: không tự động đánh dấu hoàn thành set và không đẩy progression khi chưa xác nhận.

## 2. Information architecture
- Tab **Hôm nay**: upcoming workout, week picker, Start/Resume CTA, sync indicator.
- Tab **Giáo án**: weeks, workout templates, editor, copy and reorder.
- Tab **Bài tập**: visual grid/search/filters, progression detail.
- Tab **Lịch sử**: session list, achievements, per-set details, notes.
- Tab **Cá nhân**: profile/settings, sync, notifications, media storage, privacy.
- **Workout Player** modal immersive full-screen, always resume affordance.
- **AI Coach** accessible from session summary/history; no persistent CTA blocking session.

## 3. Screen-by-screen UI requirements
| Screen ID | Screen | Data shown | Primary action | Empty/error/offline |
|---|---|---|---|---|
| UX-01 | Home/Today | day picker, workout hero poster, exercise cards, duration estimate | Start or Resume | Create sample plan; offline badge |
| UX-02 | Plan editor | weekly calendar, exercises with media, target sets/hold/reps/rest, reorder | Save local | Validation inline; unsynced marker |
| UX-03 | Catalog | thumbnail grid (min ~100pt image), filter: equipment/skill/type | Open exercise | Bundled fallback poster |
| UX-04 | Exercise Preview | video loop, play/pause, cue checklist, variant, media download state | Add to plan / close | Show poster + cues if no video |
| UX-05 | Player Ready | poster, set X/Y, target, previous record, Start | Start countdown | Data from local only |
| UX-06 | Player Active | large timer OR rep prompt, compact visual, Pause/Complete | Complete set | Confirm actual hold/reps |
| UX-07 | Set Result | actual hold/reps, RPE optional, quick note, success/fail/skip reason | Confirm | Autosave draft while editing |
| UX-08 | Rest | huge countdown, next set card thumbnail, technique cue, +30s, Ready | Start next set | Visible timer if video missing |
| UX-09 | Summary | planned vs actual, completed/skipped, notes, sync status | Save/Finish | AI pending state |
| UX-10 | History | cards with photo, date, workout, progression stats | Open details | Offline local history |
| UX-11 | AI Review | summary of insights, uncertainty, recommendation delta, accept/reject | Accept or Reject | Pending/error/retry clear |
| UX-12 | Lock Screen | type, exercise, phase, set X/Y, deadline timer, optional tiny poster | intent action if unlocked | disabled/unauthorized fallback |
| UX-13 | Dynamic Island | tiny phase glyph/time; expanded exercise/set/time | Open player | No image/video requirement |

## 4. Visual design system
- Palette initial: Midnight `#111827`, Surface `#1F2937`, Accent `#34D399`, Text `#F9FAFB`, Secondary `#9CA3AF`, Warning `#FBBF24`, Error `#F87171`.
- Semantic token scheme: `bg.canvas`, `bg.surface`, `text.primary`, `text.secondary`, `accent.action`, `status.rest`, `status.active`, `status.error`. Do not hardcode styling outside token package.
- Minimum touch target: 44×44 pt; clear focus/VoiceOver label; support Dynamic Type, Reduce Motion, high contrast.
- Media cards: 16:9 hero, 1:1 thumbnails in list, consistent camera angle and backgrounds, avoid ambiguous crop.
- Session font: timer >=56pt where layout allows; phase/set >=16pt; secondary technical cues accessible.
- Haptics/audio independently configurable; no mandatory sound; silent-mode and Focus-mode tests.

## 5. Interaction contracts
### Start set
`ready → preCountdown(3s) → exercising`; do not auto-start if app is inactive without explicit input. Countdown can be disabled in Settings.
### End hold
Timer reaches target → notify; while app active show `Target reached` action to **Confirm** actual; if app suspended, do not mark set success. Actual duration should be derived from end confirmation time but editable if user delayed confirming.
### Dynamic rep
Display poster + large `+1/-1` controls while foreground; no automatic sensing; user can enter actual reps after set. A manual tap only updates a draft until Confirm.
### Rest
After Confirm set, start rest with recorded deadline; at 10s remaining optionally local notification; rest reaching 0 changes visible computed countdown but not automatically advance to new active set. `+30s` reschedules reminder atomically.
### Video bottom sheet
Open from preview/player/rest; timer continues; video loop muted by default; download status shown; no auto-play 5 videos simultaneously.
### Final session confirmation
After confirming the final planned set, navigate to `REVIEWING_SUMMARY`; user can add a note then tap `Finish Session`. Only then does session become `COMPLETED` and eligible for AI review.

### Session recovery
On launch show "Tiếp tục buổi tập" and last stable state. Handle expired deadline: display `Đã hết thời gian — xác nhận kết quả` not auto-complete.

## 6. Exercise media taxonomy
Each exercise has: `thumbnail`, `poster`, `previewLoop` (5–15s), optional `tutorial` (30–120s), optional posture images correct/wrong, captions and technique cues. Each media must have attribution/license and content version. Use poster fallback if video unavailable.

## 7. Lock Screen layout priority
1. Exercise/phase icon and set index; 2. remaining time (system-rendered deadline); 3. concise phase label; 4. at most one essential interactive control subject to unlock; 5. deep link to exact session.
- Live Activity cannot host video player.
- Avoid rendering user sensitive journal/health notes on lock screen.
- On always-on display, assume diminished animation and brightness.

## 8. Localization & accessibility
- Vietnamese primary, design keys for English localization; unit labels in seconds/reps; support large text, VoiceOver describing image, visual timer mirrored by accessible text.
- No exclusive color meaning; show state label icon + text.
- Respect reduced motion by replacing animations with static affordances.
- Cache captions/transcript if a tutorial relies on voice.

## 9. Prototyping deliverables for design agent
Figma/SwiftUI prototypes for 13 screens, variants for small/large devices, Dark + accessibility mode; interactive journey with 4×12s Tuck Planche then Pull-up; inspectable components and design tokens, media placeholders visibly labeled.

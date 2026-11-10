# 21. Portal quản trị nội dung (Admin Portal): phân tích nghiệp vụ và đặc tả chức năng

> **Trạng thái:** PO duyệt 2026-11-10 (quyết định ở §10). Chưa có contract, chưa có backlog ID.
> **Căn cứ:** ADR-051 (phạm vi portal), docs/18 §5.4, docs/10 (media), docs/11 (bảo mật), docs/19 (thư viện mẫu),
> `db/001`, `db/005`, `db/006`, `db/008`, `deploy/test-server/catalog/` (seed thử nghiệm 188 bài).
> **Quy tắc:** theo AGENTS rule 7, mọi mục trong tài liệu này phải có OpenAPI, SQL và test đi kèm trước khi code.

## 1. Bối cảnh và vấn đề

Hiện nay mọi nội dung do nhà phát hành sở hữu được đưa vào hệ thống bằng **SQL viết tay hoặc script**:

| Nội dung | Cách cập nhật hôm nay | Hệ quả |
|---|---|---|
| Danh mục bài tập (`exercise_catalog`) | Migration/seed SQL, script `build_catalog_seed.py` | Chỉ dev làm được. Không có ai duyệt, không có nhật ký |
| Media (`exercise_media` + object storage) | `docker cp` + `mc cp` + SQL, `reviewed_at = now()` do script tự gán | **Bước duyệt giấy phép của docs/10 bị bỏ qua.** 43 ảnh `unverified-test-only` đang được phục vụ trên máy test |
| Bộ tiêu chí (`criteria_config_versions`) | Chỉ có v1 seed trong `db/008`. Không có đường ghi nào | Muốn đổi nhãn một tiêu chí cũng phải viết migration |
| Chỉ số (`indicator_definitions`) | Seed trong `db/005` | Như trên. ADR-065 (chỉ số `body`) đang chờ portal |
| Thư viện giáo án mẫu | Đóng cứng trong app (`MockData`) | docs/19 ghi rõ "Thư viện mẫu do portal quản lý" |

Ba rủi ro kinh doanh chính:
1. **Pháp lý:** media CC-BY-SA thiếu ghi công hoặc media không rõ nguồn lọt ra bản phát hành.
2. **An toàn người tập:** hình minh hoạ sai kỹ thuật được xuất bản mà không ai kiểm tra (docs/10 §6).
3. **Tốc độ vận hành:** mỗi thay đổi nội dung nhỏ cần một lần deploy của dev.

## 2. Mục tiêu và phạm vi

### 2.1 Mục tiêu (đo được)
| # | Mục tiêu | Chỉ số đo |
|---|---|---|
| G1 | Người vận hành nội dung (không phải dev) tự thêm/sửa bài tập và media | 0 thay đổi nội dung cần deploy sau khi portal chạy |
| G2 | Không media nào được phát hành khi chưa qua duyệt giấy phép và kỹ thuật | 100% media `is_public` có người duyệt khác người tải lên |
| G3 | Mọi thay đổi truy vết được | 100% thao tác ghi có bản ghi nhật ký (ai, lúc nào, trước/sau) |
| G4 | Phủ hình ảnh cho bài tập (PRD §3: >95% bài trong giáo án có poster offline) | % bài đã xuất bản có đủ poster + thumbnail hợp lệ |
| G5 | Sửa sai nhanh | Rollback một lần xuất bản trong < 5 phút, không cần dev |

### 2.2 Trong phạm vi (ADR-051)
Danh mục bài tập, media catalog, bộ tiêu chí nhập set, định nghĩa chỉ số. Phân quyền, nhật ký, xuất bản có phiên bản, rollback.

### 2.3 Ngoài phạm vi (bản này)
- Xem/sửa **dữ liệu tập của người dùng** (session, set_result, giáo án cá nhân). Người dùng sở hữu log (AGENTS rule 6).
- Thêm tiêu chí có tính chẩn đoán y tế hoặc tự kết luận thay người dùng (docs/18 §5.4).
- Sửa đề xuất AI hoặc can thiệp vào luồng duyệt đề xuất của người dùng (AGENTS rule 5).
- Upload video người dùng (AGENTS rule 6).

Các nhu cầu vận hành khác (hỗ trợ người dùng, quyền riêng tư, AI ops) được ghi ở §9 để lập kế hoạch sau, **không** làm chung đợt đầu.

## 3. Bên liên quan và vai trò

### 3.1 Bên liên quan
| Bên | Quan tâm |
|---|---|
| PO | Nội dung đúng chiến lược sản phẩm, tốc độ cập nhật |
| Người biên tập nội dung | Thao tác nhanh, nhập hàng loạt, ít lỗi |
| Chuyên gia kỹ thuật tập (coach) | Hình và cue đúng kỹ thuật, an toàn |
| Người phụ trách pháp lý/giấy phép | Nguồn gốc, giấy phép, ghi công của từng media |
| Dev / backend-agent | Không phá contract, không phá đồng bộ, không phá dữ liệu cũ |
| Người dùng app (gián tiếp) | Thư viện đầy đủ, hình rõ, không mất bài trong giáo án của mình |

### 3.2 Vai trò (RBAC) và tách nhiệm vụ
Một tài khoản có thể có nhiều vai trò, **trừ** các cặp bị cấm ở cột cuối.

| Vai trò | Được làm | Không được làm |
|---|---|---|
| `viewer` | Xem mọi nội dung, bản nháp, nhật ký | Ghi bất cứ gì |
| `editor` | Tạo/sửa bản nháp bài tập, cue, tag; tải media lên; soạn bộ tiêu chí/chỉ số | Duyệt media do chính mình tải; xuất bản |
| `media_reviewer` | Duyệt/từ chối giấy phép và kỹ thuật của media | Duyệt media do chính mình tải lên (four-eyes) |
| `publisher` | Xuất bản một bản phát hành, rollback | Xuất bản bản phát hành mà chính mình là người sửa duy nhất (bật/tắt bằng cấu hình, mặc định bật) |
| `admin` | Quản lý tài khoản, vai trò, cấu hình portal | Bỏ qua nhật ký; xoá nhật ký |

**Quy tắc BR-RBAC-1:** người duyệt media phải khác người tải media đó lên. Hệ thống chặn, không chỉ cảnh báo.
**Quy tắc BR-RBAC-2:** pilot chỉ có một người vận hành (PO, quyết định 2026-11-10), nên chế độ "một người" **bật** trong pilot. Một tài khoản giữ mọi vai trò. Mỗi lần tự duyệt được ghi rõ vào nhật ký. Báo cáo §5.8 liệt kê các mục tự duyệt để rà lại trước khi phát hành công khai. Chế độ này chỉ `admin` bật/tắt, và việc bật/tắt cũng được ghi nhật ký. Khi có người vận hành thứ hai, tắt chế độ này để BR-RBAC-1 có hiệu lực đầy đủ.

## 4. Ràng buộc nghiệp vụ kế thừa từ hệ thống hiện có

Portal phải tôn trọng những gì DB và app đã giả định. Vi phạm các điểm này sẽ làm hỏng dữ liệu người dùng.

| # | Ràng buộc | Nguồn | Hệ quả cho portal |
|---|---|---|---|
| C1 | `exercise_catalog.id` là khoá ổn định; giáo án của người dùng tham chiếu id này | db/001, sync | **Không bao giờ xoá bài tập.** Chỉ có "ngừng" (xem BR-EX-4) |
| C2 | App merge bài tập theo id; giáo án kéo về **chờ** bài tập chưa có trong catalog | `SyncService.refreshCatalog` | Ẩn hẳn một bài (`is_published=false`) có thể làm giáo án trên thiết bị khác bị treo. Cần trạng thái "ngừng nhưng vẫn phục vụ" |
| C3 | `exercise_media` là bất biến theo `(exercise, kind, content_version)`; `storage_key` không đổi | docs/10 §4, ADR-072 | Thay ảnh = tạo phiên bản media mới. Không ghi đè object |
| C4 | `sha256` chữ thường, client kiểm tra sau khi tải | docs/10 §4 | Server tự tính sha256 khi nhận file, không tin client |
| C5 | Phiên bản bộ tiêu chí đã xuất bản không sửa, không xoá | trigger `ck_criteria_config_versions_immutable` | Rollback = xuất bản bản cũ thành số phiên bản mới |
| C6 | `criteria.id` không tái sử dụng; đổi nghĩa phải tạo id mới; `rpe`, `pain`, `holdSec`, `reps`, `loadKg` có quy tắc riêng | docs/18 §5.2, ADR-045/067 | Editor chặn đổi `type` của id đã xuất bản; chặn dùng id dành riêng |
| C7 | Tối đa 20 tiêu chí, chips ≤ 10 giá trị, giá trị là token đóng | ADR-067 | Validation ở portal trùng với validation ở sync |
| C8 | `indicator_definitions`: `id`, `kind`, `unit`, `aggregation` bất biến; không xoá | trigger db/005 | Form khoá các trường này sau khi xuất bản lần đầu |
| C9 | Tiêu chí và chỉ số được phục vụ chung một ETag `"c{v}.i{v}"` | ADR-066 | Xuất bản một trong hai làm mọi app tải lại cả hai. Gom vào một bản phát hành |
| C10 | `discipline` ∈ calisthenics/gym/running; `measurementType` suy ra từ `exercise_type` | ADR-060/061 | Không cho chọn `mixed` cho bài tập; không có ô `measurementType` riêng |
| C11 | URL ký sẵn hết hạn sau 15 phút; key lộ trong URL | ADR-072 | Key phải mờ (không chứa tên file gốc, email người tải) |
| C12 | Media CC-BY-SA bắt buộc hiện ghi công | Giấy phép | `attribution` bắt buộc với mọi giấy phép không phải CC0 |

## 5. Đặc tả chức năng

Ký hiệu: **PRT-xx** là chức năng; **BR** là quy tắc nghiệp vụ; **AC** là tiêu chí chấp nhận. Độ ưu tiên theo MoSCoW cho đợt pilot của portal.

### 5.1 Đăng nhập và quản lý tài khoản quản trị

| ID | Chức năng | Ưu tiên |
|---|---|---|
| PRT-01 | Đăng nhập bằng OIDC qua **OpenIddict** do backend tự host (authorization code + PKCE cho SPA React, bắt buộc MFA bằng TOTP). Không dùng chung đường đăng nhập Apple của app | Must |
| PRT-02 | `admin` mời, khoá, gán/gỡ vai trò cho tài khoản quản trị | Must |
| PRT-03 | Phiên đăng nhập hết hạn sau thời gian không hoạt động (mặc định 30 phút); đăng xuất mọi phiên | Must |
| PRT-04 | Trang "Tài khoản của tôi": vai trò hiện có, lịch sử đăng nhập gần nhất | Could |

- **BR-AUTH-1:** token của app (thiết bị) **không bao giờ** gọi được API quản trị. API quản trị dùng scheme xác thực và audience riêng.
- **BR-AUTH-2:** tài khoản bị khoá mất quyền ngay ở request kế tiếp, không chờ token hết hạn.
- **AC:** gọi `/admin/...` bằng JWT của app ⇒ 401; tài khoản `viewer` gọi API ghi ⇒ 403 và có dòng nhật ký `denied`.

### 5.2 Danh mục bài tập

| ID | Chức năng | Ưu tiên |
|---|---|---|
| PRT-10 | Danh sách bài tập dạng **lưới thumbnail** (visual-first) và dạng bảng; lọc theo môn, loại, dụng cụ, tag, trạng thái, tình trạng media, giấy phép; tìm theo tên/slug | Must |
| PRT-11 | Tạo bài tập: slug, tên, `exercise_type`, môn, focus tags, dụng cụ, cue (danh sách có thứ tự), lỗi thường gặp | Must |
| PRT-12 | Sửa bài tập dưới dạng **bản nháp**; bản đang phát hành giữ nguyên tới khi xuất bản | Must |
| PRT-13 | So sánh bản nháp với bản đang phát hành (diff theo trường) | Must |
| PRT-14 | Ngừng (deprecate) và khôi phục bài tập | Must |
| PRT-15 | Nhập hàng loạt từ JSON theo định dạng `deploy/test-server/catalog/catalog.json`; xem trước kết quả (thêm/sửa/lỗi) trước khi ghi nháp | Should |
| PRT-16 | Xuất danh mục ra JSON cùng định dạng (để review ngoài, backup, seed máy test) | Should |
| PRT-17 | Quan hệ tiến trình kỹ năng (bài trước/bài sau, ví dụ Tuck → Advanced Tuck Planche) | Could, cần contract mới |
| PRT-18 | Xem trước như trên app: ô thumbnail trong thư viện, trang chi tiết có poster và cue | Should |

Quy tắc:
- **BR-EX-1:** `slug` khớp `^[a-z0-9]+(-[a-z0-9]+)*$`, duy nhất, **khoá sau lần xuất bản đầu**. Id sinh UUIDv5 từ slug (giữ cùng quy ước với script seed) để môi trường test và production cho cùng id.
- **BR-EX-2:** Tên 1–120 ký tự; cue: ít nhất 1, tối đa 8, mỗi cue ≤ 200 ký tự, không chứa lời khuyên y tế.
- **BR-EX-3:** `discipline` mặc định theo `exercise_type` (C10) nhưng sửa được (ví dụ weighted pull-up là calisthenics + load).
- **BR-EX-4 (ngừng bài tập):** bài bị ngừng **vẫn được API trả về** kèm cờ `deprecated`, để giáo án cũ và giáo án đồng bộ từ thiết bị khác vẫn chạy (C2). App ẩn bài này khỏi bộ chọn khi tạo giáo án mới. PO duyệt 2026-11-10. Cần bổ sung trường này vào OpenAPI và app (xem §7).
- **BR-EX-5:** đổi `exercise_type` của bài đã xuất bản bị chặn nếu đổi `measurementType` (ví dụ reps → hold), vì làm sai lịch sử set và mục tiêu của người dùng. Muốn đổi thì tạo bài mới và ngừng bài cũ.
- **BR-EX-6:** mỗi lần xuất bản có thay đổi nội dung một bài thì `catalog_version` của bài đó tăng 1.
- **BR-EX-7:** bài **không thể xuất bản** nếu thiếu: tên, ít nhất 1 cue. Thiếu poster/thumbnail thì **cho xuất bản nhưng cảnh báo** và hiện trên bảng sức khoẻ nội dung (vì app có trạng thái không-media; PRD chỉ đặt mục tiêu 95%, không chặn cứng).
- **AC:** ngừng bài `pull-up` ⇒ `GET /v1/exercises` vẫn trả `pull-up` với `deprecated: true`; giáo án đang có `pull-up` vẫn bắt đầu buổi tập được.

### 5.3 Media

| ID | Chức năng | Ưu tiên |
|---|---|---|
| PRT-20 | Tải lên ảnh/video cho một bài và một `kind` (thumbnail, poster, preview, tutorial, correct, incorrect) | Must |
| PRT-21 | Server tự tính sha256, kích thước, kích thước ảnh, thời lượng video, mime thật (đọc nội dung, không tin đuôi file) | Must |
| PRT-22 | Tự sinh thumbnail 480×480 và poster ≤ 1280 px từ ảnh gốc (cùng logic `build_catalog_seed.py`), người dùng cắt/căn lại được | Should |
| PRT-23 | Phiếu nguồn gốc bắt buộc: giấy phép, tác giả, nguồn (URL hoặc "tự sản xuất"), ghi công, có phải ảnh AI không | Must |
| PRT-24 | Hàng đợi duyệt media: duyệt giấy phép + duyệt kỹ thuật, có checklist, ghi chú, từ chối kèm lý do | Must |
| PRT-25 | Lịch sử phiên bản media của từng bài; đặt lại phiên bản cũ làm phiên bản hiện hành (bằng cách tạo phiên bản mới trỏ cùng object) | Should |
| PRT-26 | Lọc nhanh "media cần thay": `unverified-test-only`, giấy phép trống, chưa duyệt, bị từ chối | Must |
| PRT-27 | Nhập media từ nguồn mở có API (wger) kèm siêu dữ liệu giấy phép tự điền; vẫn phải qua duyệt | Could |

Quy tắc:
- **BR-MD-1:** giới hạn: ảnh ≤ 20 MB, video ≤ 200 MB (trùng docs/10 §3.1); preview loop 5–15 s, không tiếng (docs/10 §1). Định dạng: JPEG/PNG/HEIC (chuyển về JPEG), MP4/H.264 hoặc HEVC.
- **BR-MD-2:** danh sách giấy phép là danh mục đóng do `admin` quản lý: `proprietary-owned`, `CC0-1.0`, `CC-BY-4.0`, `CC-BY-SA-3.0`, `CC-BY-SA-4.0`, `licensed-commercial` (kèm số hợp đồng). `unverified-test-only` **chỉ** tồn tại ở môi trường không phải production; production từ chối giá trị này.
- **BR-MD-3:** `attribution` bắt buộc khi giấy phép khác `CC0-1.0` và `proprietary-owned` (C12).
- **BR-MD-4:** ảnh do AI tạo bị từ chối mặc định (giữ quyết định đã áp với ảnh wger). Muốn cho phép phải có ADR.
- **BR-MD-5:** media chỉ trở thành `is_public = true` khi **cả hai** bước duyệt (giấy phép, kỹ thuật) đạt, bởi người khác người tải (BR-RBAC-1). `reviewed_at` chỉ do hệ thống gán khi duyệt, không nhập tay.
- **BR-MD-6:** storage key mờ theo dạng `media/{mediaId}/v{contentVersion}` (C11); file gốc giữ ở vùng riêng không công khai để sinh lại thumbnail/poster.
- **BR-MD-7:** media bị từ chối không bao giờ được phục vụ; object vẫn giữ 30 ngày để tra soát rồi mới dọn.
- **Checklist duyệt kỹ thuật (gợi ý):** đúng bài và đúng biến thể; tư thế thể hiện đúng điểm phân biệt (ví dụ tuck vs advanced tuck); góc máy và dụng cụ nhất quán; không có người nhận diện được nếu không có giấy đồng ý; không chữ/logo của bên thứ ba.
- **AC:** tài khoản A tải ảnh, A bấm duyệt ⇒ bị chặn; B duyệt giấy phép, C (hoặc B) duyệt kỹ thuật ⇒ ảnh chỉ ra API sau lần xuất bản kế tiếp.

### 5.4 Bộ tiêu chí nhập set (criteria config)

| ID | Chức năng | Ưu tiên |
|---|---|---|
| PRT-30 | Xem phiên bản đang phát hành và lịch sử các phiên bản (JSON + dạng form) | Must |
| PRT-31 | Soạn bản nháp: thêm/sửa/tắt tiêu chí; kiểu `number`, `choice`, `scale`, `chips`, `toggle`; `appliesTo` (môn, loại đo, danh sách bài) | Must |
| PRT-32 | Validation theo C6, C7 và schema `CriteriaConfig` của OpenAPI, báo lỗi theo từng trường | Must |
| PRT-33 | **Xem trước màn P6** theo tổ hợp môn × loại đo × bài cụ thể | Must |
| PRT-34 | So sánh bản nháp với phiên bản đang chạy; cảnh báo các thay đổi ảnh hưởng dữ liệu cũ | Must |
| PRT-35 | Thống kê sử dụng: số set đã ghi theo từng tiêu chí/giá trị (tổng hợp, không theo người dùng) để biết tắt có an toàn không | Could |

Quy tắc:
- **BR-CR-1:** id tiêu chí đã từng xuất bản thì không xoá khỏi tài liệu; chỉ `enabled = false`. Không đổi `type`. Không xoá `options[].v` đã từng xuất bản (chỉ đổi `label`/`hint` hoặc thêm giá trị mới), vì set cũ còn lưu token đó.
- **BR-CR-2:** id dành riêng (`holdSec`, `reps`, `loadKg`) không được dùng làm tiêu chí; `rpe` và `pain` chỉ điều khiển hiển thị (C6).
- **BR-CR-3:** nhãn và gợi ý đi qua bộ lọc từ khoá y tế (chẩn đoán, chấn thương cụ thể, "nên dừng tập vì…"). Trúng bộ lọc ⇒ chặn xuất bản cho tới khi PO ghi chú chấp thuận. Đây là hỗ trợ, không thay cho người duyệt.
- **BR-CR-4:** `appliesTo.exerciseIds` chỉ chọn được bài đang có trong catalog; bài bị ngừng vẫn giữ trong danh sách cũ nhưng hiện cảnh báo.
- **AC:** xoá option `poor` khỏi `technique` ⇒ validation báo lỗi "giá trị đã từng xuất bản"; đổi nhãn `poor` thành "Cần sửa" ⇒ hợp lệ.

### 5.5 Định nghĩa chỉ số (indicator definitions)

| ID | Chức năng | Ưu tiên |
|---|---|---|
| PRT-40 | Danh sách và chi tiết chỉ số; tạo chỉ số mới | Must |
| PRT-41 | Sửa `label`, `step`, `measurement_types`, `enabled`; khoá `id`, `kind`, `unit`, `aggregation` (C8) | Must |
| PRT-42 | Xem trước thẻ mục tiêu trong app với chỉ số này | Should |
| PRT-43 | Hỗ trợ `kind = body` và aggregation mới (`avg_7d`) khi ADR-065 được triển khai | Could, cần migration mới |

- **BR-IN-1:** `kind ∈ {adherence, body}` ⇔ `measurement_types` rỗng (ràng buộc DB). Form ẩn ô loại đo cho hai kind này.
- **BR-IN-2:** tắt một chỉ số đang được mục tiêu của người dùng dùng ⇒ cảnh báo kèm số mục tiêu đang tham chiếu (tổng hợp). Mục tiêu cũ vẫn hiển thị; chỉ ẩn khỏi bộ chọn khi tạo mục tiêu mới.

### 5.6 Bản phát hành (release), xuất bản và rollback

Đây là chức năng xương sống. Thay vì xuất bản từng bản ghi lẻ, portal gom thay đổi thành **một bản phát hành**.

```text
Nháp ──(gửi duyệt)──▶ Chờ duyệt ──(publisher duyệt)──▶ Đã xuất bản
  ▲                       │                                 │
  └──────(trả lại)────────┘                     (rollback = bản phát hành mới
                                                  có nội dung của bản cũ)
```

| ID | Chức năng | Ưu tiên |
|---|---|---|
| PRT-50 | Tạo bản phát hành từ các thay đổi nháp (bài tập, media đã duyệt, tiêu chí, chỉ số); xem tổng hợp thay đổi | Must |
| PRT-51 | Kiểm tra trước khi xuất bản (pre-flight): validation, media đủ duyệt, object tồn tại trong storage, sha256 khớp, không vi phạm C1–C12 | Must |
| PRT-52 | Xuất bản **nguyên tử**: tất cả hoặc không gì cả, trong một transaction DB | Must |
| PRT-53 | Rollback về một bản phát hành trước: tạo bản phát hành mới mang nội dung cũ | Must |
| PRT-54 | Ghi chú phát hành (release notes) nội bộ | Should |
| PRT-55 | Hẹn giờ xuất bản | Won't (pilot) |

- **BR-RL-1:** không có thao tác "sửa trực tiếp bản đang phát hành". Mọi thay đổi đi qua nháp → bản phát hành.
- **BR-RL-2:** một bản phát hành chạm tới tiêu chí hoặc chỉ số sẽ đổi ETag (C9); màn xác nhận ghi rõ "mọi thiết bị sẽ tải lại cấu hình".
- **BR-RL-3:** rollback **không** gỡ được việc ngừng/xoá id (vì không có xoá); rollback media nghĩa là phiên bản cũ thành phiên bản mới hơn (C3).
- **BR-RL-4:** chỉ một bản phát hành ở trạng thái "Chờ duyệt" tại một thời điểm, tránh hai bản ghi đè nhau. Nháp mới có thể soạn song song.
- **AC:** pre-flight phát hiện một poster thiếu object trong storage ⇒ không xuất bản gì; sau khi xuất bản, `GET /v1/exercises` và `GET /v1/criteria-config` phản ánh đúng bản mới trong cùng một lần đọc.

### 5.7 Nhật ký thay đổi (audit log)

| ID | Chức năng | Ưu tiên |
|---|---|---|
| PRT-60 | Ghi mọi thao tác ghi và mọi lần bị từ chối quyền: ai, lúc nào (UTC), đối tượng, trước/sau (diff), IP, request id | Must |
| PRT-61 | Tra cứu nhật ký theo người, đối tượng, khoảng thời gian, loại thao tác; xem lịch sử của một bài/media | Must |
| PRT-62 | Xuất nhật ký ra CSV | Should |

- **BR-AU-1:** nhật ký chỉ thêm, không sửa, không xoá (trigger append-only như `plan_audit_events` ở db/005). Không ai, kể cả `admin`, xoá được.
- **BR-AU-2:** nhật ký không chứa secret, token, URL ký sẵn (docs/11).

### 5.8 Bảng điều khiển sức khoẻ nội dung

| ID | Chức năng | Ưu tiên |
|---|---|---|
| PRT-70 | Tổng quan: số bài theo môn/trạng thái; % bài có đủ poster + thumbnail (G4); media chờ duyệt; media `unverified-test-only`; bài thiếu cue | Must |
| PRT-71 | Danh sách việc cần làm có thể bấm vào (ví dụ "40 bài chưa có ảnh") | Must |
| PRT-72 | Các mục tự duyệt ở chế độ một người (BR-RBAC-2) | Should |
| PRT-73 | Lần xuất bản gần nhất, ai xuất bản, phiên bản tiêu chí/chỉ số đang chạy | Must |

## 6. Yêu cầu phi chức năng

| Nhóm | Yêu cầu |
|---|---|
| Bảo mật | OIDC (OpenIddict) + MFA; token portal có issuer/audience riêng, thời hạn ngắn, refresh token xoay vòng; SPA không lưu token trong `localStorage`; RBAC kiểm tra ở API (không chỉ ẩn nút ở UI); CSRF/CORS chặt; API quản trị có rate limit; chỉ truy cập qua mạng được phép (VPN/Tailscale hoặc IP allowlist) trong pilot |
| Tách biệt | Portal **chỉ ghi** vào bảng nội dung do nhà phát hành sở hữu và bảng nhật ký. Role DB của portal không có quyền đọc bảng dữ liệu người dùng |
| Toàn vẹn | Xuất bản trong một transaction; tải file lên storage trước, ghi DB sau (cùng thứ tự đã dùng trong seed) |
| Hiệu năng | Danh sách 1.000 bài lọc/tìm < 1 s; tải lên ảnh 20 MB có thanh tiến độ; pre-flight cho 500 thay đổi < 30 s |
| Khả dụng | Portal ngừng không ảnh hưởng app: API cho thiết bị chỉ đọc bảng đã xuất bản |
| Truy cập | Dùng được bằng bàn phím; tương phản đạt WCAG AA; giao diện tiếng Việt (nội dung có thể đa ngôn ngữ sau) |
| Quan sát | Log có request id, không ghi secret; cảnh báo khi xuất bản thất bại |
| Sao lưu | Backup DB và bucket media theo lịch; khôi phục thử ít nhất một lần trước khi phát hành công khai |

## 7. Tác động lên contract và hệ thống (phải làm trước khi code)

| Hạng mục | Thay đổi |
|---|---|
| OpenAPI | Nhóm endpoint `/admin/v1/...` (bài tập, media, upload, duyệt, tiêu chí, chỉ số, bản phát hành, nhật ký, tài khoản) với security scheme riêng. `Exercise` thêm `deprecated: boolean` (BR-EX-4) |
| SQL (migration mới, không sửa db/001..010) | `admin_users`, `admin_role_grants`; bảng nháp hoặc cột trạng thái nháp cho nội dung; `content_releases` + bảng liên kết thay đổi; `media_reviews` (người duyệt, bước, kết quả, ghi chú); `media_provenance` (nguồn, tác giả, là AI hay không); `admin_audit_events` append-only; `exercise_catalog.deprecated_at` |
| Backend | Module Admin trong modular monolith .NET; OpenIddict làm authorization server cho portal (user store ASP.NET Core Identity có TOTP), scheme xác thực riêng tách khỏi JWT của app; role DB riêng cho portal; CORS chỉ cho origin của portal |
| Frontend portal | Ứng dụng React (SPA) mới, gọi `/admin/v1`; client API sinh từ OpenAPI (AGENTS rule 4); vị trí thư mục và build/CI chốt trong ADR |
| iOS | Đọc `deprecated`: ẩn khỏi bộ chọn, giữ trong giáo án và lịch sử. Hiện `attribution` cạnh ảnh (C12). Hai việc này cần làm trước khi phát hành công khai, bất kể portal |
| Tài liệu | ADR cho công nghệ portal (React + OpenIddict), cơ chế nháp/bản phát hành, vai trò và chế độ một người; cập nhật docs/10 §4 (công cụ ingestion = portal), docs/11, docs/13 (backlog) |

## 8. Lộ trình đề xuất

Thứ tự theo rủi ro: media và danh mục đang là chỗ đau nhất (43 ảnh chưa rõ nguồn, 40 bài chưa có ảnh); bộ tiêu chí đã có v1 chạy được.

| Đợt | Nội dung | Kết quả |
|---|---|---|
| **P1 – Nền tảng + Danh mục + Media** | PRT-01..03, 10..14, 20..21, 23..24, 26, 50..53 (chỉ phần bài tập/media), 60..61, 70..71, 73 | Thay toàn bộ ảnh `unverified-test-only`; ngừng dùng script SQL để đổi nội dung |
| **P2 – Tiêu chí + Chỉ số** | PRT-30..34, 40..42, mở rộng 50..53 cho tiêu chí/chỉ số | Đổi nhãn/thêm tiêu chí không cần migration |
| **P3 – Hiệu suất vận hành** | PRT-15..16, 18, 22, 25, 27, 35, 54, 62, 72; PRT-17, 43 khi có contract | Nhập hàng loạt, xem trước như app, thống kê |
| **Sau** | §9 | Lập kế hoạch riêng |

## 9. Nhu cầu ngoài phạm vi ADR-051 (ghi nhận để PO quyết)

| Nhu cầu | Vì sao sẽ cần | Lưu ý bắt buộc |
|---|---|---|
| Thư viện giáo án mẫu | docs/19: "Thư viện mẫu do portal quản lý"; mẫu hiện đóng cứng trong app | Mẫu tham chiếu id bài tập ⇒ phụ thuộc BR-EX-4 |
| Hỗ trợ người dùng (tra cứu tài khoản, thiết bị, trạng thái đồng bộ, lỗi đồng bộ) | Khi có người dùng thật sẽ có ticket | Chỉ xem siêu dữ liệu; xem nội dung log cần sự đồng ý của người dùng và để lại nhật ký (AGENTS rule 6) |
| Xuất dữ liệu / xoá tài khoản theo yêu cầu | docs/11: phải chốt trước phát hành công khai | Quy trình có xác minh danh tính, có thời hạn xử lý |
| Vận hành AI (hàng đợi `ai_jobs`, lỗi, chi phí) | FR-11 | Không sửa nội dung đề xuất; không xem dữ liệu cá nhân vượt quá cần thiết |
| Bản địa hoá nội dung (tên, cue nhiều ngôn ngữ) | Catalog hiện chỉ có tiếng Việt, không có cột `locale` | Cần thay đổi schema và contract |

## 10. Quyết định của PO (2026-11-10) và câu hỏi còn mở

| # | Câu hỏi | Quyết định |
|---|---|---|
| 1 | Ngừng bài tập (BR-EX-4) | **Dùng trạng thái `deprecated`**: vẫn phục vụ, ẩn khỏi bộ chọn. Không ẩn hẳn bằng `is_published = false` |
| 2 | Nhân sự pilot | **Một người vận hành (PO).** Bật chế độ một người (BR-RBAC-2) |
| 3 | Người duyệt kỹ thuật hình | PO, trong chế độ một người. Cần người có chuyên môn rà lại trước khi phát hành công khai |
| 5 | Công nghệ portal | **React (SPA)** gọi `/admin/v1`. Cần ADR |
| 6 | Đăng nhập | **OIDC qua OpenIddict** tự host trong backend .NET, MFA bằng TOTP. Cần ADR |
| 7 | Thư viện giáo án mẫu | Để sau (§9), không vào P2 |
| 8 | Ảnh do AI tạo (BR-MD-4) | Giữ cấm |

Còn mở:
- **Nguồn media dài hạn:** tự chụp/quay (bộ ảnh đồng nhất góc máy, docs/10 §1) hay tiếp tục dùng ảnh cộng đồng CC-BY-SA? Ảnh hưởng ngân sách và việc hiển thị ghi công.

## 11. Rủi ro

| Rủi ro | Mức | Giảm thiểu |
|---|---|---|
| Portal xuất bản nội dung làm hỏng giáo án người dùng (xoá/đổi loại bài) | Cao | C1, BR-EX-4, BR-EX-5; pre-flight; không có xoá |
| Media vi phạm giấy phép lọt ra production | Cao | BR-MD-2/3/5; production từ chối `unverified-test-only`; four-eyes |
| Tài khoản quản trị bị chiếm | Cao | OIDC + MFA, mạng giới hạn, nhật ký append-only, khoá tài khoản tức thì |
| Phạm vi phình (biến portal thành CRM/hỗ trợ khách hàng) | Trung bình | §2.3 và §9 tách riêng; mỗi nhu cầu mới cần ADR |
| Một người vận hành tự duyệt mọi thứ (đang xảy ra trong pilot) | Trung bình | BR-RBAC-2: chế độ một người có nhật ký; rà lại các mục tự duyệt trước phát hành công khai |
| Tự host OpenIddict thêm bề mặt bảo mật phải tự vận hành (khoá ký, xoay vòng, lưu trữ token) | Trung bình | Khoá ký trong secret store và có quy trình xoay vòng; test tích hợp luồng đăng nhập; giới hạn mạng trong pilot |
| Validation ở portal lệch với validation ở sync | Trung bình | Dùng chung một thư viện validation và một bộ test vector |

# Handoff — Bắt đầu triển khai bằng AI Coding Agents

## Cách sử dụng bộ tài liệu
1. Copy **toàn bộ** thư mục này vào root repository (giữ nguyên cấu trúc); không chỉ tải riêng OpenAPI.
2. Chỉ định một **Integrator/Orchestrator Agent** đọc `AGENTS.md` và `agents/00-orchestrator.md`; giao các task M0.
3. Chạy `python3 tools/validate_handoff.py`; với môi trường thiếu PyYAML/jsonschema, cài dependencies dev trước khi coi kết quả là kiểm chứng đủ.
4. Chuyển `contracts/backlog.csv` vào GitHub Projects/Jira/Linear; giao từng task, tránh giao cả epic cho một prompt dài.
5. iOS Agent chạy POC trên **iPhone thật** trước khi triển khai full app; kết luận rõ GO/NO-GO Lock Screen.
6. Khi M0 chốt, tách PR theo vertical slices M1 → M2 → M3. Mỗi PR phải có test evidence.

## Prompt khởi tạo mẫu (đưa cho coding agent)
```text
Bạn là Integrator Agent của dự án CALI.
Hãy đọc README.md, AGENTS.md, agents/00-orchestrator.md,
docs/01-product-prd.md, docs/03-workout-domain.md,
docs/05-lock-screen-poc.md, docs/13-delivery-backlog.md
và docs/15-decisions-risks.md.

Nhiệm vụ đầu tiên: thực hiện milestone M0, KHÔNG code toàn bộ sản phẩm.
1) Xác minh/hệ thống hóa assumptions và ADR;
2) Lập repository structure và test plan;
3) Tạo spike iOS ActivityKit trên iPhone thật (POC-001/002);
4) Chốt command/state contract + OpenAPI/schema;
5) Báo cáo files changed, test results, evidence, blockers.
Không được giả định nút Live Activity chạy khi thiết bị chưa mở khóa.
```

## Người review cần chốt trước triển khai production
- Bundle identifier, Apple Team ID, entitlement App Group/Live Activity.
- Domain/brand name, thiết bị iOS target, iPhone test devices.
- Hosting region, Apple login setup, privacy/deletion policy.
- License và tính chính xác kỹ thuật của media.
- Coach policy cho skill nặng (Planche/Iron Cross).

## Tuyên bố trạng thái
Đây là bộ **tài liệu thiết kế/contract và kế hoạch thực thi**, chưa phải source code chạy được. DDL chưa được migrate trên PostgreSQL thật, Live Activity chưa được kiểm chứng trên thiết bị thật trong gói này. Các kết luận khả thi cần được ghi bằng evidence ở POC M0.

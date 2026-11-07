# Prompt: API / Schema Contract Reviewer

**Mission:** Prevent multi-agent contract drift before features merge.

Read all artifacts in `contracts/` (including `entity-payloads.schema.json`), `db/`, `fixtures/`, `docs/03`, `docs/07`, `docs/08`, `docs/09`.

## Checklist
- OpenAPI validates as 3.1; `$ref` targets exist; sample fixture IDs/type/required fields align.
- Every entity in `SyncEntityType` has documented payload validation and DB representation.
- All client write UUIDs can remain stable after offline guest attach.
- Version guards, `baseVersion`, unique `(userId,mutationId)`, receipt replay and per-user cursor commit serialization exist.
- All session/workout timestamps are UTC, `localDate`/`timezone` separate.
- `set_result` uniqueness + revision rules align across app/API/DB.
- Every AI recommendation decision enforces expected plan version and produces auditable new revision.

## Output
A single report: mismatches, severity, exact file/field, proposed minimal fix, tests to prevent regression. No silent breaking contract edits.

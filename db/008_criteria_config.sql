-- CON-008 Criteria config (docs/18 §5, docs/07, docs/11; ADR-045, ADR-049, ADR-050, ADR-051, ADR-058;
-- ADR-066, ADR-067).
-- New numbered migration (ADR-049): db/001..007 are never edited. Depends on db/001 (set_results)
-- and db/005 (indicator_definitions, served together with the criteria config, ADR-058).
-- Backward compatible: adds one publisher-owned table and two nullable set_results columns;
-- existing rows keep NULL (written before any criteria config existed).
--   * criteria_config_versions holds published criteria configs. A published version is immutable
--     and never deleted (ADR-051): changing or rolling back means publishing a new version. Only the
--     future portal writes here; no device or API write path exists (docs/11 §2).
--   * set_results.criteria_version + criteria store the extra per-set values keyed by criterion id
--     (ADR-067). Column-backed ids (rpe -> rpe, pain -> pain_reported, holdSec/reps/loadKg -> actual_*)
--     never appear in the map (ADR-045). Values are closed tokens, numbers, booleans or token lists:
--     no free text.
-- Cross-field rules (key exists and is enabled in that version, value matches the criterion type,
-- option and range) are enforced by backend sync + CaliDomain (ADR-020), not here.

-- 1. Published criteria configs. document = {supportedTypes, criteria}; version and publishedAt
--    are the columns. The served ETag also covers the indicator set (ADR-066).
CREATE TABLE criteria_config_versions (
    version integer PRIMARY KEY,
    published_at timestamptz NOT NULL,
    document jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_criteria_config_versions_version CHECK (version >= 1),
    -- coalesce: a missing key gives NULL, and a NULL CHECK would pass.
    CONSTRAINT ck_criteria_config_versions_document CHECK (
        jsonb_typeof(document) = 'object'
        AND coalesce(jsonb_typeof(document -> 'supportedTypes'), '') = 'array'
        AND coalesce(jsonb_typeof(document -> 'criteria'), '') = 'array')
);

CREATE FUNCTION criteria_config_versions_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'criteria config version % is published and immutable; publish a new version', OLD.version
        USING ERRCODE = 'restrict_violation', CONSTRAINT = 'ck_criteria_config_versions_immutable';
END $$;

CREATE TRIGGER trg_criteria_config_versions_guard
    BEFORE UPDATE OR DELETE ON criteria_config_versions
    FOR EACH ROW EXECUTE FUNCTION criteria_config_versions_guard();

-- Default version 1 = the config bundled in the iOS app for offline first launch (docs/18 §5.3).
-- fixtures/criteria_config.json carries the same criteria (tools/validate_handoff.py checks it).
INSERT INTO criteria_config_versions (version, published_at, document) VALUES (1, '2026-11-09T00:00:00Z', $criteria_v1$
{
  "supportedTypes": ["number", "choice", "scale", "chips", "toggle"],
  "criteria": [
    {"id": "technique", "type": "choice", "label": "Kỹ thuật (tự đánh giá)", "icon": "star",
     "appliesTo": {"disciplines": ["*"]}, "required": false, "enabled": true,
     "options": [{"v": "poor", "label": "Chưa ổn", "hint": "Form vỡ"},
                 {"v": "ok", "label": "Ổn", "hint": "Vài lỗi nhỏ"},
                 {"v": "good", "label": "Chuẩn", "hint": "Giữ form tốt"}]},
    {"id": "rpe", "type": "scale", "label": "Mức gắng sức (RPE)", "icon": "chart", "hint": "10 = không thể thêm lần nào.",
     "appliesTo": {"disciplines": ["gym"]}, "min": 6, "max": 10, "step": 1, "required": false, "enabled": true},
    {"id": "condition", "type": "chips", "label": "Điều kiện tập", "icon": "swap",
     "appliesTo": {"disciplines": ["calisthenics"]}, "prefill": "previousSet", "splitsTrend": true, "required": false, "enabled": true,
     "options": [{"v": "same", "label": "Như set trước"}, {"v": "assist", "label": "Có trợ lực"},
                 {"v": "variant", "label": "Đổi biến thể"}, {"v": "equip", "label": "Đổi dụng cụ"}]},
    {"id": "equipment", "type": "chips", "label": "Dụng cụ", "icon": "barbell",
     "appliesTo": {"disciplines": ["gym"]}, "prefill": "previousSet", "splitsTrend": true, "required": false, "enabled": true,
     "options": [{"v": "barbell", "label": "Tạ đòn"}, {"v": "dumbbell", "label": "Tạ đơn"},
                 {"v": "machine", "label": "Máy"}, {"v": "smith", "label": "Smith"}]},
    {"id": "pain", "type": "toggle", "label": "Đau bất thường trong set", "icon": "alert",
     "hint": "Chỉ ghi lại để bạn xem lại. Ứng dụng không chẩn đoán.",
     "appliesTo": {"disciplines": ["*"]}, "required": false, "enabled": true}
  ]
}
$criteria_v1$::jsonb);

-- 2. Per-set criteria values (docs/18 §5.3, ADR-067). Both columns are set together; NULL = the set
--    was written without a criteria config (legacy rows, or a client that has none).
--    8192 bytes of jsonb text covers the schema worst case (20 keys x 10 chips of 32 characters).
ALTER TABLE set_results
    ADD COLUMN criteria_version integer,
    ADD COLUMN criteria jsonb,
    ADD CONSTRAINT fk_set_results_criteria_version
        FOREIGN KEY (criteria_version) REFERENCES criteria_config_versions (version),
    ADD CONSTRAINT ck_set_results_criteria_pair CHECK ((criteria_version IS NULL) = (criteria IS NULL)),
    ADD CONSTRAINT ck_set_results_criteria CHECK (
        criteria IS NULL
        OR (jsonb_typeof(criteria) = 'object'
            AND octet_length(criteria::text) <= 8192
            AND NOT (criteria ?| ARRAY['rpe', 'pain', 'holdSec', 'reps', 'loadKg'])));

-- Development-only exercise definitions aligned with fixtures/exercise_catalog.json.
-- is_published=false: this handoff contains NO licensed poster/video assets.
-- Never publish or expose dev placeholders as approved instructional media.
INSERT INTO exercise_catalog (id, slug, name, exercise_type, equipment, cues, catalog_version, is_published) VALUES
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1', 'tuck-planche', 'Tuck Planche', 'static_hold', '[]', '["Duỗi thẳng khuỷu tay","Đẩy vai ra trước","Giữ thân ổn định"]', 1, false),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2', 'pull-up', 'Pull-up', 'reps', '["pull-up bar"]', '["Kiểm soát thân","Kéo không giật mạnh"]', 1, false),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3', 'dips', 'Dips', 'reps', '["parallel bars"]', '["Kiểm soát vai","Không đẩy qua đau khớp"]', 1, false),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa4', 'l-sit', 'L-sit Hold', 'static_hold', '["floor or parallettes"]', '["Đẩy vai xuống","Giữ gối duỗi theo khả năng"]', 1, false),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa5', 'squat', 'Bodyweight Squat', 'reps', '[]', '["Giữ gót chân ổn định","Kiểm soát xuống và lên"]', 1, false),
 ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa6', 'ring-support', 'Ring Support Hold', 'static_hold', '["gymnastic rings"]', '["Ổn định vai","Dừng nếu đau khớp"]', 1, false)
ON CONFLICT (id) DO NOTHING;

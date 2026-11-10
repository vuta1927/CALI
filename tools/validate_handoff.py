#!/usr/bin/env python3
"""Validate handoff docs, JSON examples and OpenAPI schema references.
Run: python3 tools/validate_handoff.py
Optional deps (required in CI): pyyaml, jsonschema[format-nongpl]."""
from pathlib import Path
import json
import re
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
errors = []

# Skip VCS/tool dirs, local venvs, build outputs and nested git worktrees
# (e.g. .claude/worktrees/*) so only this checkout's handoff files are checked.
SKIP_DIRS = {'node_modules', 'venv', 'bin', 'obj', 'DerivedData'}


def repo_files(pattern):
    for path in ROOT.rglob(pattern):
        parts = path.relative_to(ROOT).parts[:-1]
        if any(part.startswith('.') or part in SKIP_DIRS for part in parts):
            continue
        yield path


for p in repo_files('*.json'):
    try:
        json.loads(p.read_text(encoding='utf-8'))
    except Exception as exc:
        errors.append(f'Invalid JSON {p.relative_to(ROOT)}: {exc}')

# Check local markdown links (ignore URL anchors and external resources).
pat = re.compile(r'(?<!!)\[[^]]*\]\(([^)]+)\)')
for p in repo_files('*.md'):
    data = p.read_text(encoding='utf-8')
    for target in pat.findall(data):
        target = target.strip().split('#')[0]
        if not target or re.match(r'^https?://', target):
            continue
        if not (p.parent / target).exists():
            errors.append(f'Broken link {p.relative_to(ROOT)} -> {target}')

catalog = json.loads((ROOT / 'fixtures/exercise_catalog.json').read_text(encoding='utf-8'))
ids = {item['id'] for item in catalog['items']}
for item in catalog['items']:
    try:
        uuid.UUID(item['id'])
    except ValueError:
        errors.append(f'Invalid exercise uuid: {item["id"]}')
plan = json.loads((ROOT / 'fixtures/workout_plan.json').read_text(encoding='utf-8'))
for w in plan['workouts']:
    for e in w['exercises']:
        if e['exerciseId'] not in ids:
            errors.append(f'Fixture exercise missing: {e["exerciseId"]}')

spec = None
try:
    import yaml
    spec = yaml.safe_load((ROOT / 'contracts/openapi.yaml').read_text(encoding='utf-8'))
    if spec.get('openapi') != '3.1.0':
        errors.append('Unexpected OpenAPI version')
    def visit(node):
        if isinstance(node, dict):
            if '$ref' in node:
                ref = node['$ref']
                if ref.startswith('#/'):
                    cur = spec
                    for part in ref[2:].split('/'):
                        if part not in cur:
                            errors.append(f'Missing OpenAPI ref {ref}')
                            break
                        cur = cur[part]
            for val in node.values():
                visit(val)
        elif isinstance(node, list):
            for val in node:
                visit(val)
    visit(spec)
except ImportError:
    print('INFO: PyYAML unavailable; skipping OpenAPI structural check')
except Exception as exc:
    errors.append(f'Failed OpenAPI parse: {exc}')

try:
    import jsonschema
    schema = json.loads((ROOT / 'contracts/entity-payloads.schema.json').read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator.check_schema(schema)
    example = json.loads((ROOT / 'fixtures/sync_push.json').read_text(encoding='utf-8'))
    validator = jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker())
    for mutation in example['mutations']:
        for error in validator.iter_errors(mutation):
            errors.append(f'Invalid sample sync mutation: {error.message}')
    # ADR-020: business-rule vectors must be schema-valid (they fail only on cross-field rules).
    rules = json.loads((ROOT / 'fixtures/validation/business_rules.json').read_text(encoding='utf-8'))
    for case in rules['cases']:
        for error in validator.iter_errors(case['mutation']):
            errors.append(f"fixtures/validation case {case['name']} is not schema-valid: {error.message}")
        payload = case['mutation']['payload']
        for exercise_id in (payload.get('exerciseId'), (payload.get('prescribedSnapshot') or {}).get('exerciseId')):
            if exercise_id and exercise_id not in ids:
                errors.append(f"fixtures/validation case {case['name']} references unknown exercise {exercise_id}")
    # CON-004: schema-level rejections must stay schema-INVALID.
    rejections = json.loads((ROOT / 'fixtures/validation/schema_rejections.json').read_text(encoding='utf-8'))
    for case in rejections['cases']:
        if validator.is_valid(case['mutation']):
            errors.append(f"fixtures/validation/schema_rejections case {case['name']} is unexpectedly schema-valid")
    # Sample sync pushes (fixtures/samples/*.sample.json) must be valid mutations on known exercises.
    sample_pushes = sorted((ROOT / 'fixtures/samples').glob('*sync_push.sample.json'))
    for sample_path in sample_pushes:
        sample_rel = sample_path.relative_to(ROOT).as_posix()
        for mutation in json.loads(sample_path.read_text(encoding='utf-8'))['mutations']:
            for error in validator.iter_errors(mutation):
                errors.append(f'{sample_rel} mutation {mutation["mutationId"]} invalid: {error.message}')
            payload = mutation.get('payload', {})
            for exercise_id in (payload.get('exerciseId'), (payload.get('prescribedSnapshot') or {}).get('exerciseId')):
                if exercise_id and exercise_id not in ids:
                    errors.append(f'{sample_rel} references unknown exercise {exercise_id}')
    # ADR-028: offline catalog bundle manifest.
    bundle_schema = json.loads((ROOT / 'contracts/catalog-bundle.schema.json').read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator.check_schema(bundle_schema)
    bundle = jsonschema.Draft202012Validator(bundle_schema, format_checker=jsonschema.FormatChecker())
    for error in bundle.iter_errors(catalog):
        errors.append(f'fixtures/exercise_catalog.json does not match catalog-bundle schema: {error.message}')
    # CON-006: catalog-level rejections (measurementType mismatch, 'mixed' discipline, ...) must stay INVALID.
    catalog_rejections = json.loads((ROOT / 'fixtures/validation/catalog_rejections.json').read_text(encoding='utf-8'))
    for case in catalog_rejections['cases']:
        wrapped = {'catalogVersion': 1, 'status': 'development_fixture_only', 'items': [case['item']]}
        if bundle.is_valid(wrapped):
            errors.append(f"fixtures/validation/catalog_rejections case {case['name']} is unexpectedly schema-valid")
    # Fixtures must also conform to the OpenAPI wire schemas (OpenAPI 3.1
    # schemas are JSON Schema 2020-12, resolved in-document via referencing).
    if spec is not None:
        from referencing import Registry, Resource
        from referencing.jsonschema import DRAFT202012
        oas_uri = 'urn:cali:openapi'
        registry = Registry().with_resource(oas_uri, Resource(contents=spec, specification=DRAFT202012))
        wire_fixtures = [
            ('fixtures/workout_plan.json', 'TrainingPlan'),
            ('fixtures/sync_push.json', 'SyncPushRequest'),
        ] + [(path.relative_to(ROOT).as_posix(), 'SyncPushRequest') for path in sample_pushes]
        for rel, name in wire_fixtures:
            if name not in spec.get('components', {}).get('schemas', {}):
                errors.append(f'Missing OpenAPI schema {name}')
                continue
            wire = jsonschema.Draft202012Validator(
                {'$ref': f'{oas_uri}#/components/schemas/{name}'},
                registry=registry, format_checker=jsonschema.FormatChecker())
            instance = json.loads((ROOT / rel).read_text(encoding='utf-8'))
            # `_comment` labels fixture files and is never sent; closed schemas (ADR-069) would reject it.
            if isinstance(instance, dict):
                instance.pop('_comment', None)
            for error in wire.iter_errors(instance):
                errors.append(f'{rel} does not match OpenAPI {name}: {error.message}')
        # CON-004: prescription kinds stay in lockstep across contracts (catalog type == target kind).
        schemas = spec['components']['schemas']
        kind_sets = {
            'entity-payloads $defs.target': {o['properties']['kind']['const'] for o in schema['$defs']['target']['oneOf']},
            'OpenAPI PlannedTarget': {o['properties']['kind']['const'] for o in schemas['PlannedTarget']['oneOf']},
            'OpenAPI ExerciseType': set(schemas['ExerciseType']['enum']),
            'catalog-bundle item.type': set(bundle_schema['$defs']['item']['properties']['type']['enum']),
        }
        reference = kind_sets['entity-payloads $defs.target']
        for label, kinds in kind_sets.items():
            if kinds != reference:
                errors.append(f'Exercise type/target kind drift: {label} = {sorted(kinds)} vs {sorted(reference)}')
        # CON-003: sync entity types, payload mapping, plan revision status and limit error codes stay in lockstep.
        entity_consts = set()
        for ref in schema['oneOf']:
            mutation_def = schema['$defs'][ref['$ref'].rsplit('/', 1)[-1]]
            entity_consts |= {part['properties']['entityType']['const'] for part in mutation_def['allOf']
                              if 'entityType' in part.get('properties', {})}
        sync_types = set(schemas['SyncEntityType']['enum'])
        if sync_types != entity_consts:
            errors.append(f'SyncEntityType {sorted(sync_types)} != entity-payloads mutation entityTypes {sorted(entity_consts)}')
        change_types = set(schemas['ChangeEntityType']['enum'])
        if not sync_types <= change_types:
            errors.append(f'ChangeEntityType is missing sync entity types {sorted(sync_types - change_types)}')
        payload_map = schemas['SyncChange']['properties']['payload'].get('x-payload-schemas', {})
        if not sync_types <= set(payload_map):
            errors.append(f'SyncChange x-payload-schemas is missing {sorted(sync_types - set(payload_map))}')
        for entity_type, target in payload_map.items():
            if not target.startswith('entity-payloads.schema.json#/$defs/'):
                continue
            if target.rsplit('/', 1)[-1] not in schema['$defs']:
                errors.append(f'x-payload-schemas {entity_type} points to unknown {target}')
        plan_status_oas = set(schemas['TrainingPlan']['allOf'][1]['properties']['status']['enum'])
        plan_status_entity = set(schema['$defs']['training_plan_payload']['properties']['status']['enum'])
        if plan_status_oas != plan_status_entity:
            errors.append(f'TrainingPlan.status drift: OpenAPI {sorted(plan_status_oas)} vs entity schema {sorted(plan_status_entity)}')
        error_codes = set(schemas['MutationError']['properties']['code']['enum'])
        for code in ('active_plan_limit', 'plan_count_limit'):
            if code not in error_codes:
                errors.append(f'MutationError.code is missing {code} (CON-003)')
        for case in rules['cases']:
            if case['expect']['code'] not in error_codes:
                errors.append(f"fixtures/validation case {case['name']} expects unknown MutationError code {case['expect']['code']}")
        # CON-005: plan goals, phases and indicator definitions stay in lockstep across OpenAPI,
        # entity-payloads, the latest SQL migration, the vectors and the sample pushes.
        for code in ('pinned_goal_limit', 'goal_unlock_cycle'):
            if code not in error_codes:
                errors.append(f'MutationError.code is missing {code} (CON-005)')
        for oas_name, def_name in (('PlanGoal', 'plan_goal_payload'), ('PlanPhase', 'plan_phase_payload'),
                                   ('BodyMeasurement', 'body_measurement_payload')):
            oas_props = set(schemas[oas_name]['properties']) - {'version'}
            def_props = set(schema['$defs'][def_name]['properties'])
            if oas_props != def_props:
                errors.append(f'{oas_name} fields {sorted(oas_props)} != entity-payloads {def_name} {sorted(def_props)}')
        goal_status_oas = set(schemas['GoalStatus']['enum'])
        goal_status_entity = set(schema['$defs']['plan_goal_payload']['properties']['status']['enum'])
        if goal_status_oas != goal_status_entity:
            errors.append(f'GoalStatus drift: OpenAPI {sorted(goal_status_oas)} vs entity schema {sorted(goal_status_entity)}')
        target_shapes_oas = sorted(sorted(o['required']) for o in schemas['GoalTarget']['oneOf'])
        target_shapes_entity = sorted(sorted(o['required']) for o in schema['$defs']['goal_target']['oneOf'])
        if target_shapes_oas != target_shapes_entity:
            errors.append(f'GoalTarget drift: OpenAPI {target_shapes_oas} vs entity schema {target_shapes_entity}')
        goal_sql = (ROOT / 'db/005_plan_goals_phases.sql').read_text(encoding='utf-8')
        sql_kinds_match = re.search(r"ck_indicator_definitions_kind\s+CHECK \(kind IN \(([^)]*)\)\)", goal_sql)
        sql_kinds = set(re.findall(r"'([a-z_]+)'", sql_kinds_match.group(1))) if sql_kinds_match else set()
        if sql_kinds != set(schemas['IndicatorKind']['enum']):
            errors.append(f"IndicatorKind drift: OpenAPI {sorted(schemas['IndicatorKind']['enum'])} vs db/005 {sorted(sql_kinds)}")
        sql_goal_status_match = re.search(r"ck_plan_goals_status\s+CHECK \(status IN \(([^)]*)\)\)", goal_sql)
        sql_goal_status = set(re.findall(r"'([a-z_]+)'", sql_goal_status_match.group(1))) if sql_goal_status_match else set()
        if sql_goal_status != goal_status_oas:
            errors.append(f'GoalStatus drift: OpenAPI {sorted(goal_status_oas)} vs db/005 {sorted(sql_goal_status)}')
        seeded_indicators = set(re.findall(r"^\s*\('([a-z][a-z0-9_]*)',\s*'(?:performance|adherence|volume|milestone|body)'",
                                           goal_sql, re.MULTILINE))
        if not seeded_indicators:
            errors.append('db/005 seeds no indicator_definitions')
        # The latest migration that redefines the sync entity CHECK must accept every SyncEntityType.
        sync_check = None
        for migration in sorted((ROOT / 'db').glob('[0-9][0-9][0-9]_*.sql')):
            found = re.findall(r"ck_sync_mutations_entity_type CHECK \(entity_type IN \(([^)]*)\)\)",
                               migration.read_text(encoding='utf-8'))
            if found:
                sync_check = (migration.name, set(re.findall(r"'([a-z_]+)'", found[-1])))
        if sync_check is None or sync_check[1] != sync_types:
            errors.append(f'SQL ck_sync_mutations_entity_type {sync_check} != SyncEntityType {sorted(sync_types)}')
        # CON-007: one body measurement kind vocabulary and one value range (OpenAPI, entity-payloads, db/007).
        body_kinds_oas = set(schemas['BodyMeasurementKind']['enum'])
        body_payload = schema['$defs']['body_measurement_payload']
        body_kinds_entity = set(body_payload['properties']['kind']['enum'])
        body_sql = (ROOT / 'db/007_body_measurement.sql').read_text(encoding='utf-8')
        body_kinds_match = re.search(r"ck_body_measurements_kind CHECK \(kind IN \(([^)]*)\)\)", body_sql)
        body_kinds_sql = set(re.findall(r"'([a-z_]+)'", body_kinds_match.group(1))) if body_kinds_match else set()
        if not body_kinds_oas == body_kinds_entity == body_kinds_sql:
            errors.append(f'BodyMeasurementKind drift: OpenAPI {sorted(body_kinds_oas)} vs entity schema '
                          f'{sorted(body_kinds_entity)} vs db/007 {sorted(body_kinds_sql)}')
        oas_value = schemas['BodyMeasurement']['properties']['value']
        entity_value = body_payload['properties']['value']
        sql_range = re.search(r"ck_body_measurements_value CHECK \(value >= (\d+) AND value <= (\d+) AND value = round\(value, 2\)\)",
                              body_sql)
        ranges = {
            'OpenAPI': (oas_value.get('minimum'), oas_value.get('maximum')),
            'entity schema': (entity_value.get('minimum'), entity_value.get('maximum')),
            'db/007': (int(sql_range.group(1)), int(sql_range.group(2))) if sql_range else None,
        }
        if len(set(ranges.values())) != 1:
            errors.append(f'BodyMeasurement value range drift: {ranges}')
        goal_payloads = [(f"fixtures/validation case {case['name']}", case['mutation']) for case in rules['cases']]
        goal_payloads += [(f'{path.relative_to(ROOT).as_posix()} mutation', mutation) for path in sample_pushes
                          for mutation in json.loads(path.read_text(encoding='utf-8'))['mutations']]
        for label, mutation in goal_payloads:
            indicator_id = mutation['payload'].get('indicatorId') if mutation['entityType'] == 'plan_goal' else None
            if indicator_id and indicator_id not in seeded_indicators and not label.endswith('goal_unknown_indicator'):
                errors.append(f'{label} references indicator {indicator_id} not seeded in db/005')

        # CON-006: one discipline vocabulary (OpenAPI, bundle, db/006) and a derived measurementType (ADR-060, ADR-061).
        disciplines = set(schemas['Discipline']['enum'])
        bundle_item = bundle_schema['$defs']['item']
        if set(bundle_item['properties']['discipline']['enum']) != disciplines:
            errors.append(f"catalog-bundle item.discipline drifts from OpenAPI Discipline {sorted(disciplines)}")
        if not disciplines <= set(schemas['PrimaryDiscipline']['enum']):
            errors.append('OpenAPI Discipline must be a subset of PrimaryDiscipline')
        migration = (ROOT / 'db/006_exercise_discipline_load.sql').read_text(encoding='utf-8')
        match = re.search(r"ck_exercise_catalog_discipline CHECK \(discipline IN \(([^)]*)\)\)", migration)
        db_disciplines = set(re.findall(r"'([a-z_]+)'", match.group(1))) if match else set()
        if db_disciplines != disciplines:
            errors.append(f'db/006 ck_exercise_catalog_discipline {sorted(db_disciplines)} != OpenAPI Discipline {sorted(disciplines)}')
        measurement_map = {rule['if']['properties']['type']['const']: rule['then']['properties']['measurementType']['const']
                           for rule in bundle_item.get('allOf', [])}
        if set(measurement_map) != set(schemas['ExerciseType']['enum']):
            errors.append(f'catalog-bundle measurementType map does not cover ExerciseType: {sorted(measurement_map)}')
        if set(measurement_map.values()) != set(schemas['MeasurementType']['enum']):
            errors.append(f"measurementType map values {sorted(set(measurement_map.values()))} != OpenAPI MeasurementType")
        for item in catalog['items']:
            if measurement_map.get(item.get('type')) != item.get('measurementType'):
                errors.append(f"fixtures/exercise_catalog.json {item.get('slug')} measurementType differs from its type")
        for field in ('discipline', 'measurementType', 'focusTags'):
            if field not in schemas['Exercise']['properties']:
                errors.append(f'OpenAPI Exercise is missing {field} (CON-006)')
        if 'actualLoadKg' not in schema['$defs']['set_result_payload']['properties']:
            errors.append('entity-payloads set_result_payload is missing actualLoadKg (CON-006)')

        # CON-008: criteria config (ADR-066) and per-set criteria values (ADR-067) stay in lockstep across
        # OpenAPI, entity-payloads, db/008, fixtures/criteria_config.json and the db/005 indicator seed.
        config_doc = json.loads((ROOT / 'fixtures/criteria_config.json').read_text(encoding='utf-8'))
        config_doc.pop('_comment', None)
        config_wire = jsonschema.Draft202012Validator(
            {'$ref': f'{oas_uri}#/components/schemas/CriteriaConfig'},
            registry=registry, format_checker=jsonschema.FormatChecker())
        for error in config_wire.iter_errors(config_doc):
            errors.append(f'fixtures/criteria_config.json does not match OpenAPI CriteriaConfig: {error.message}')
        criteria_sql = (ROOT / 'db/008_criteria_config.sql').read_text(encoding='utf-8')
        seed_match = re.search(r'\$criteria_v1\$(.*?)\$criteria_v1\$', criteria_sql, re.DOTALL)
        seed_doc = json.loads(seed_match.group(1)) if seed_match else None
        if seed_doc is None:
            errors.append('db/008 seeds no criteria config version 1')
        elif config_doc.get('version') == 1 and seed_doc != {k: config_doc.get(k) for k in ('supportedTypes', 'criteria')}:
            errors.append('fixtures/criteria_config.json supportedTypes/criteria differ from the db/008 version 1 seed')
        indicator_set = config_doc.get('indicators', {})
        fixture_indicators = {i['id'] for i in indicator_set.get('indicators', [])}
        if fixture_indicators != seeded_indicators:
            errors.append(f'fixtures/criteria_config.json indicators {sorted(fixture_indicators)} != db/005 seed {sorted(seeded_indicators)}')
        if indicator_set.get('version') != sum(i['version'] for i in indicator_set.get('indicators', [])):
            errors.append('fixtures/criteria_config.json indicator set version must equal the sum of row versions (ADR-066)')
        reserved_measures = {'holdSec', 'reps', 'loadKg'}
        column_backed = {'rpe', 'pain'}
        criteria_def = schema['$defs']['criteria_values']
        reserved_entity = set(criteria_def['propertyNames']['not']['enum'])
        reserved_sql_match = re.search(r"criteria \?\| ARRAY\[([^\]]*)\]", criteria_sql)
        reserved_sql = set(re.findall(r"'([A-Za-z_]+)'", reserved_sql_match.group(1))) if reserved_sql_match else set()
        reserved_oas = set(schemas['Criterion']['properties']['id']['not']['enum'])
        if not reserved_entity == reserved_sql == reserved_measures | column_backed:
            errors.append(f'Reserved criteria keys drift: entity schema {sorted(reserved_entity)} vs db/008 {sorted(reserved_sql)}')
        if reserved_oas != reserved_measures:
            errors.append(f'OpenAPI Criterion.id must exclude exactly {sorted(reserved_measures)}, got {sorted(reserved_oas)}')
        token_pattern = schema['$defs']['criteria_token']['pattern']
        if schemas['CriterionOption']['properties']['v']['pattern'] != token_pattern:
            errors.append('OpenAPI CriterionOption.v pattern drifts from entity-payloads criteria_token')
        if schemas['Criterion']['properties']['id']['pattern'] != criteria_def['propertyNames']['pattern']:
            errors.append('OpenAPI Criterion.id pattern drifts from entity-payloads criteria key pattern')
        chips_max = next(b['maxItems'] for b in criteria_def['additionalProperties']['anyOf'] if b.get('type') == 'array')
        if schemas['Criterion']['properties']['options']['maxItems'] != chips_max:
            errors.append('OpenAPI Criterion.options maxItems drifts from the entity-payloads chips maxItems')
        applies_props = schemas['CriteriaAppliesTo']['properties']
        if applies_props.get('measurementTypes', {}).get('items', {}).get('$ref') != '#/components/schemas/MeasurementType':
            errors.append('OpenAPI CriteriaAppliesTo.measurementTypes must reference MeasurementType (ADR-066)')
        measurement_types = set(schemas['MeasurementType']['enum'])
        for criterion in config_doc.get('criteria', []):
            if criterion['type'] not in config_doc.get('supportedTypes', []):
                errors.append(f"fixtures/criteria_config.json criterion {criterion['id']} uses a type outside supportedTypes")
            unknown_types = set(criterion.get('appliesTo', {}).get('measurementTypes', [])) - measurement_types
            if unknown_types:
                errors.append(f"fixtures/criteria_config.json criterion {criterion['id']} uses unknown measurementTypes {sorted(unknown_types)}")
        # Worst-case criteria map: schema-valid and within the db/008 8192-byte text bound.
        size_match = re.search(r'octet_length\(criteria::text\) <= (\d+)', criteria_sql)
        token = 'a' * 32
        worst = {f'k{i:02d}' + 'x' * 29: [token[:-2] + f'{j:02d}' for j in range(chips_max)]
                 for i in range(criteria_def['maxProperties'])}
        worst_mutation = json.loads(json.dumps(json.loads((ROOT / 'fixtures/samples/criteria_sync_push.sample.json')
                                                          .read_text(encoding='utf-8'))['mutations'][0]))
        worst_mutation['payload']['criteria'] = worst
        for error in validator.iter_errors(worst_mutation):
            errors.append(f'Worst-case criteria map is not schema-valid: {error.message}')
        worst_bytes = len(json.dumps(worst, separators=(', ', ': ')).encode('utf-8'))
        if not size_match or worst_bytes > int(size_match.group(1)):
            errors.append(f'Worst-case criteria map ({worst_bytes} bytes) exceeds db/008 ck_set_results_criteria bound')
        criteria_versions = {config_doc.get('version')}
        valid_keys = {c['id'] for c in config_doc.get('criteria', []) if c['enabled']} - column_backed
        for path in sample_pushes:
            for mutation in json.loads(path.read_text(encoding='utf-8'))['mutations']:
                payload = mutation.get('payload', {})
                if mutation['entityType'] != 'set_result' or 'criteria' not in payload:
                    continue
                if payload.get('criteriaVersion') not in criteria_versions or not set(payload['criteria']) <= valid_keys:
                    errors.append(f"{path.relative_to(ROOT).as_posix()} mutation {mutation['mutationId']} uses criteria outside fixtures/criteria_config.json")

        # CON-010: the voice cue script (input of the BE-007 TTS job) stays in lockstep with OpenAPI
        # VoiceLocale/VoiceCueKey/VoiceCue.text and the db/011 checks (ADR-077, ADR-078).
        script = json.loads((ROOT / 'fixtures/voice_cues.vi-VN.json').read_text(encoding='utf-8'))
        voice_sql = (ROOT / 'db/011_voice_packs.sql').read_text(encoding='utf-8')
        key_pattern = schemas['VoiceCueKey']['pattern']
        locale_pattern = schemas['VoiceLocale']['pattern']
        text_max = schemas['VoiceCue']['properties']['text']['maxLength']
        if f"cue_key ~ '{key_pattern}'" not in voice_sql:
            errors.append('db/011 ck_voice_cues_key drifts from OpenAPI VoiceCueKey pattern')
        if f"locale ~ '{locale_pattern}'" not in voice_sql:
            errors.append('db/011 ck_voice_pack_versions_locale drifts from OpenAPI VoiceLocale pattern')
        if f'char_length(text) BETWEEN 1 AND {text_max}' not in voice_sql:
            errors.append('db/011 ck_voice_cues_text drifts from OpenAPI VoiceCue.text maxLength')
        if not re.fullmatch(locale_pattern, script.get('locale', '')):
            errors.append('fixtures/voice_cues.vi-VN.json locale does not match VoiceLocale')
        script_keys = [c['key'] for c in script.get('cues', [])]
        if len(script_keys) != len(set(script_keys)):
            errors.append('fixtures/voice_cues.vi-VN.json has duplicate cue keys')
        if len(script_keys) > schemas['VoicePack']['properties']['cues']['maxItems']:
            errors.append('fixtures/voice_cues.vi-VN.json has more cues than VoicePack.cues maxItems')
        documented_keys = set(re.findall(r'[a-z][a-z0-9_]*\.[a-z0-9_.]+', schemas['VoiceCueKey']['description'].split('v1 keys:')[1].split('. A key')[0]))
        if set(script_keys) != documented_keys:
            errors.append(f'fixtures/voice_cues.vi-VN.json keys {sorted(script_keys)} != OpenAPI VoiceCueKey v1 keys {sorted(documented_keys)}')
        for cue in script.get('cues', []):
            if not re.fullmatch(key_pattern, cue['key']):
                errors.append(f"fixtures/voice_cues.vi-VN.json key {cue['key']} does not match VoiceCueKey")
            if not 1 <= len(cue['text']) <= text_max:
                errors.append(f"fixtures/voice_cues.vi-VN.json {cue['key']} text length outside 1..{text_max}")
except ImportError:
    print('INFO: jsonschema unavailable; skipping JSON Schema semantic checks')
except Exception as exc:
    errors.append(f'Failed JSON Schema check: {exc}')

if errors:
    for err in errors:
        print('ERROR:', err)
    print(f'FAILED: {len(errors)} problem(s)')
    sys.exit(1)
print('PASS: JSON, local links, fixture IDs, OpenAPI references, sync payload schema and fixture wire schemas')

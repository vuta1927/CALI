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
        exercise_id = case['mutation']['payload'].get('exerciseId')
        if exercise_id and exercise_id not in ids:
            errors.append(f"fixtures/validation case {case['name']} references unknown exercise {exercise_id}")
    # ADR-028: offline catalog bundle manifest.
    bundle_schema = json.loads((ROOT / 'contracts/catalog-bundle.schema.json').read_text(encoding='utf-8'))
    jsonschema.Draft202012Validator.check_schema(bundle_schema)
    bundle = jsonschema.Draft202012Validator(bundle_schema, format_checker=jsonschema.FormatChecker())
    for error in bundle.iter_errors(catalog):
        errors.append(f'fixtures/exercise_catalog.json does not match catalog-bundle schema: {error.message}')
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
        ]
        for rel, name in wire_fixtures:
            if name not in spec.get('components', {}).get('schemas', {}):
                errors.append(f'Missing OpenAPI schema {name}')
                continue
            wire = jsonschema.Draft202012Validator(
                {'$ref': f'{oas_uri}#/components/schemas/{name}'},
                registry=registry, format_checker=jsonschema.FormatChecker())
            instance = json.loads((ROOT / rel).read_text(encoding='utf-8'))
            for error in wire.iter_errors(instance):
                errors.append(f'{rel} does not match OpenAPI {name}: {error.message}')
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

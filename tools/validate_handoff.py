#!/usr/bin/env python3
"""Validate handoff docs, JSON examples and OpenAPI schema references.
Run: python3 tools/validate_handoff.py (PyYAML/jsonschema optional)."""
from pathlib import Path
import json
import re
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
errors = []

for p in ROOT.rglob('*.json'):
    try:
        json.loads(p.read_text(encoding='utf-8'))
    except Exception as exc:
        errors.append(f'Invalid JSON {p.relative_to(ROOT)}: {exc}')

# Check local markdown links (ignore URL anchors and external resources).
pat = re.compile(r'(?<!!)\[[^]]*\]\(([^)]+)\)')
for p in ROOT.rglob('*.md'):
    data = p.read_text(encoding='utf-8')
    for target in pat.findall(data):
        target = target.strip().split('#')[0]
        if not target or re.match(r'^https?://', target):
            continue
        if not (p.parent / target).exists():
            errors.append(f'Broken link {p.relative_to(ROOT)} -> {target}')

catalog = json.loads((ROOT / 'fixtures/exercise_catalog.json').read_text())
ids = {item['id'] for item in catalog['items']}
for item in catalog['items']:
    try:
        uuid.UUID(item['id'])
    except ValueError:
        errors.append(f'Invalid exercise uuid: {item["id"]}')
plan = json.loads((ROOT / 'fixtures/workout_plan.json').read_text())
for w in plan['workouts']:
    for e in w['exercises']:
        if e['exerciseId'] not in ids:
            errors.append(f'Fixture exercise missing: {e["exerciseId"]}')

try:
    import yaml
    spec = yaml.safe_load((ROOT / 'contracts/openapi.yaml').read_text())
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
    schema = json.loads((ROOT / 'contracts/entity-payloads.schema.json').read_text())
    jsonschema.Draft202012Validator.check_schema(schema)
    example = json.loads((ROOT / 'fixtures/sync_push.json').read_text())
    validator = jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker())
    for mutation in example['mutations']:
        for error in validator.iter_errors(mutation):
            errors.append(f'Invalid sample sync mutation: {error.message}')
except ImportError:
    print('INFO: jsonschema unavailable; skipping JSON Schema semantic checks')
except Exception as exc:
    errors.append(f'Failed JSON Schema check: {exc}')

if errors:
    for err in errors:
        print('ERROR:', err)
    print(f'FAILED: {len(errors)} problem(s)')
    sys.exit(1)
print('PASS: JSON, local links, fixture IDs, OpenAPI references and sync payload schema')

#!/usr/bin/env python3
"""Export stable agent tasks from docs/13-delivery-backlog.md as CSV.
Run from any directory: python3 tools/export_backlog.py"""
from pathlib import Path
import csv
import re

root=Path(__file__).resolve().parents[1]
source=root/'docs/13-delivery-backlog.md'
target=root/'contracts/backlog.csv'
rows=[]
milestone=''
for line in source.read_text(encoding='utf-8').splitlines():
    m=re.search(r'^## Milestone (M\d) ',line)
    if m: milestone=m.group(1)
    if not line.startswith('|'): continue
    cols=[x.strip() for x in line.strip().strip('|').split('|')]
    if len(cols)!=4: continue
    task,owner,dependencies,dod=cols
    if not re.fullmatch(r'[A-Z]{2,4}-\d{3}',task):continue
    rows.append({'task_id':task,'milestone':milestone,'owner':owner,'depends_on':dependencies if dependencies not in ('none','-') else '', 'definition_of_done':dod})
with target.open('w',encoding='utf-8',newline='') as f:
    w=csv.DictWriter(f,fieldnames=['task_id','milestone','owner','depends_on','definition_of_done'])
    w.writeheader();w.writerows(rows)
print(f'Exported {len(rows)} tasks -> {target.relative_to(root)}')

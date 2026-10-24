#!/usr/bin/env python3
"""All configured source revisions; no rate rebuild or database connection."""
import argparse,csv,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from section122_sources import extract,sha
from section122_rules import compile_rules,load_history,interaction_rows
p=argparse.ArgumentParser();p.add_argument('output',type=Path);a=p.parse_args()
if a.output.exists():raise SystemExit('Refusing to overwrite audit evidence')
rows=[]
for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()):
 rev=r['revision']
 if not rev.startswith(('2025_','2026_')):continue
 x=extract(ROOT/f'data/us_notes/chapter99_{rev}.pdf',ROOT/f'data/hts_archives/hts_{rev}.json',rev)
 row=dict(revision=rev,source_hashes=[s['sha256'] for s in x['sources']],has_section122=bool(x['clauses']))
 if x['clauses']:
  fragment=compile_rules(x,['7318158085','8505110070'])
  text=next(c['text'] for c in x['clauses'] if c['id']=='v')
  # Post-expiry pharmaceutical subdivisions deliberately are not compiled.
  row.update(rule_count=len(fragment['rules']),historical_windows=[{k:v for k,v in h.items() if k!='rows'} for h in fragment['interaction_history']],
    native_note_sha256=sha(' '.join(text.split()).encode()),post_expiry_warning='modified after expiration' in text,
    malformed_references=sorted(set(__import__('re').findall(r'(?<![\d.])\d{3}\.\d{2}\.\d{2}',text))))
 rows.append(row);print(rev,'source checked',flush=True)
a.output.parent.mkdir(parents=True,exist_ok=True)
history=load_history()
a.output.write_text(json.dumps(dict(revisions=rows,history=history['periods'],
 independent_interactions=history['independent_interactions'],
 compiler_sha256=sha((ROOT/'src/section122_rules.py').read_bytes()),
 scope='Source extraction and bounded rule compilation, not a timeseries rebuild or full stack validation.'),indent=2)+'\n')

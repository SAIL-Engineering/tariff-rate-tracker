#!/usr/bin/env python3
"""Source-only historical metal audit. Never builds rates or writes MotherDuck."""
import argparse,csv,gzip,hashlib,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from section232_legacy_sources import extract,matches
from section232_legacy_rules import compile_legacy
p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);p.add_argument('--motherduck',type=Path)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
origins=dict(all=[r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())],uk=['4120'],russia=['4621'])
report=[];inventory={}
for row in csv.DictReader((ROOT/'config/revision_dates.csv').open()):
 rev=row['revision']
 if not rev.startswith(('2025','2026')):continue
 pdf=ROOT/f'data/us_notes/chapter99_{rev}.pdf';hts=ROOT/f'data/hts_archives/hts_{rev}.json'
 x=extract(pdf,hts,rev)
 products=sorted({r.get('htsno','').replace('.','') for r in json.loads(hts.read_bytes())
  if len(r.get('htsno','').replace('.',''))==10 and not r.get('htsno','').startswith(('98','99'))})
 rs=matches(x,products);inventory[rev]={r['hts10'] for r in rs}
 fragment=compile_legacy(x,products,origins) if x['regime']=='march_2025_metals' else None
 encoded=json.dumps(x,separators=(',',':')).encode()
 (a.output/(rev+'.json.gz')).write_bytes(gzip.compress(encoded,mtime=0))
 report.append(dict(revision=rev,regime=x['regime'],source_sha256=hashlib.sha256(encoded).hexdigest(),
  products=len(products),scope_matches=len(rs),candidate_products=len(inventory[rev]),
  description_limited_matches=sum(r['conditional'] for r in rs),
  compiled_rules=len(fragment['rules']) if fragment else 0,
  fragment_sha256=hashlib.sha256(json.dumps(fragment,sort_keys=True).encode()).hexdigest() if fragment else None,
  source_files=x['sources']))
 print(rev,x['regime'],len(rs),report[-1]['compiled_rules'],flush=True)
(a.output/'summary.json').write_text(json.dumps(report,indent=2)+'\n')
if a.motherduck:
 raw=a.motherduck.read_bytes();export=json.loads(gzip.decompress(raw) if a.motherduck.suffix=='.gz' else raw)
 findings=[]
 for row in export['results']['primary_chapter_scope']:
  if row['revision'] not in inventory:raise ValueError('Unknown audit revision')
  if row['hts10'] not in inventory[row['revision']] and row['positive_metal_rows']>0:
   findings.append(row)
 (a.output/'motherduck-comparison.json').write_text(json.dumps(dict(
  source_export_sha256=hashlib.sha256(raw).hexdigest(),
  interpretation='Positive modeled steel/aluminum rows outside both enumerated metal scopes. Other actions and complete shipment totals require independent adjudication.',
  groups=len(findings),positive_metal_rows=sum(r['positive_metal_rows'] for r in findings),findings=findings),indent=2)+'\n')

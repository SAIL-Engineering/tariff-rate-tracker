#!/usr/bin/env python3
"""Source and rule inventory only. Does not calculate a timeseries or publish."""
import argparse,csv,gzip,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from section232_legacy_sources import extract,matches,sha
from section232_legacy_rules import compile_legacy
from section232_pre_march import precedes_march_transition
p=argparse.ArgumentParser(description=__doc__);p.add_argument('output',type=Path);p.add_argument('--motherduck',type=Path);a=p.parse_args()
a.output.mkdir(parents=True,exist_ok=False)
origins=dict(all=[r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())],uk=['4120'],russia=['4621'])
summary=[];inventory={}
for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()):
 rev=r['revision']
 if not precedes_march_transition(rev):continue
 hts=ROOT/f'data/hts_archives/hts_{rev}.json';pdf=ROOT/f'data/us_notes/chapter99_{rev}.pdf'
 x=extract(pdf,hts,rev);old=x['pre_march'];schedule=json.loads(hts.read_bytes())
 products=sorted({r.get('htsno','').replace('.','') for r in schedule if len(r.get('htsno','').replace('.',''))==10 and not r.get('htsno','').startswith(('98','99'))})
 matched=matches(old,products);inventory[rev]={r['hts10'] for r in matched}
 f=compile_legacy(x,products,origins)
 unknown_refs=[dict(heading=q['code'],prefix=prefix) for q in old['quotas'] for prefix in q['includes'] if not any(h.startswith(prefix) for h in products)]
 missing_categories=[]
 for group in sorted({q['group'] for q in old['quotas']}):
  metal=group.split('_')[0];qs=[q for q in old['quotas'] if q['group']==group]
  primary={m['hts10'] for m in matched if m['metal']==metal and m['list_id'].startswith('n16_b' if metal=='steel' else 'n19_b')}
  for h in sorted(primary):
   candidates=[q['code'] for q in qs if any(h.startswith(p) for p in q['includes']) and not any(h.startswith(p) for p in q['excludes'])]
   if not candidates:missing_categories.append(dict(hts10=h,group=group))
 encoded=json.dumps(x,separators=(',',':')).encode();(a.output/(rev+'.json.gz')).write_bytes(gzip.compress(encoded,mtime=0))
 result=dict(revision=rev,source_sha256=sha(encoded),products=len(products),origins=len(origins['all']),scope_memberships=len(matched),candidate_products=len(inventory[rev]),quota_categories=len(old['quotas']),general_exclusions={m:len(h) for m,h in old['gae'].items()},compiled_rules=len(f['rules']),fragment_sha256=sha(json.dumps(f,sort_keys=True).encode()),quota_references_without_current_products=unknown_refs,primary_products_without_quota_category=missing_categories)
 summary.append(result);print(rev,result['candidate_products'],result['compiled_rules'],len(missing_categories),flush=True)
(a.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
if a.motherduck:
 raw=a.motherduck.read_bytes();md=json.loads(gzip.decompress(raw) if a.motherduck.suffix=='.gz' else raw)
 (a.output/'motherduck.json.gz').write_bytes(gzip.compress(gzip.decompress(raw) if a.motherduck.suffix=='.gz' else raw,mtime=0))
 outside=[];unknown=set()
 for r in md['results']['primary_chapter_scope']:
  if r['revision'] not in inventory:unknown.add(r['revision']);continue
  if r['hts10'] not in inventory[r['revision']] and r['positive_metal_rows']>0:outside.append(r)
 findings=dict(source_export_sha256=sha(raw),unreviewed_revisions=sorted(unknown),positive_metal_rows_outside_scope=sum(r['positive_metal_rows'] for r in outside),groups=len(outside),findings=outside,interpretation='Model components outside both source scopes; not a complete shipment total or monetary exposure. Quota/grant/material facts are absent from these production rows.')
 (a.output/'motherduck-comparison.json').write_text(json.dumps(findings,indent=2)+'\n')

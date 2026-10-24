#!/usr/bin/env python3
"""Source/compiler sweep and optional reconciliation of a read-only MD export.

No timeseries, normalized partition rebuild, database write or publication.
Stored parameter findings do not establish complete shipment totals.
"""
import argparse, collections, csv, gzip, json, sys
from datetime import datetime, timedelta
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from section338_sources import extract,periods,sha
from section338_rules import compile_rules

p=argparse.ArgumentParser();p.add_argument('output');p.add_argument('--motherduck');a=p.parse_args()
out=Path(a.output);out.mkdir(exist_ok=False,parents=True)
x=extract();history=periods(x)
version=sha((ROOT/'src/section338_rules.py').read_bytes())
revisions=(ROOT/'docs/audits/2026-10-23-motherduck/rebuild-revisions.txt').read_text().strip().split(',')
reports=[]
for rev in revisions:
 hts=json.loads((ROOT/f'data/hts_archives/hts_{rev}.json').read_bytes())
 products=sorted({r['htsno'].replace('.','') for r in hts if len(r.get('htsno','').replace('.',''))==10 and r['htsno'][:2]<'98'})
 fragment=compile_rules(rev,products)
 report=dict(revision=rev,hts10_count=len(products),rule_count=len(fragment['rules']),
   matched_products=len({p for r in fragment['rules'] for p in r['scope']['hts_exact']}),
   fragment_sha256=sha(json.dumps(fragment,sort_keys=True,separators=(',',':')).encode()),
   snapshot=fragment['snapshot_reconciliation'])
 assert all(r['scope']['countries']==['1220'] for r in fragment['rules'])
 reports.append(report)
 print(rev,report['matched_products'],flush=True)
if version!=sha((ROOT/'src/section338_rules.py').read_bytes()):raise ValueError('Compiler changed during source sweep')
summary=dict(revisions=reports,compiler_sha256=version,actions=history,
 sources=x['sources'],timeseries_rebuilt=False,complete_legal_coverage=False)
if a.motherduck:
 data=Path(a.motherduck).read_bytes();md=json.loads(data)
 if md['access_mode']!='READ_ONLY':raise ValueError('Expected read-only export')
 counts=collections.Counter();findings=[];checked=0
 for r in md['rows']:
  start=r['valid_from'][:10];end=min(r['valid_until'][:10],'2026-10-22')
  # Audit both ends of every stored window and every legal transition inside.
  days={start,end}|{w['from_'][:10] for w in history if start<=w['from_'][:10]<=end}
  for day in sorted(days):
   at=day+'T12:00:00-04:00';checked+=1
   matched=[w for w in history if w['from_']<=at<w['until'] and any(r['hts10']==c or len(c)==8 and r['hts10'].startswith(c) for c in w['products'])]
   full=sum(w['rate'] for w in matched);stored=r['statutory_rate_s338']
   if any(w['s232_exempt'] for w in matched):kind='requires_section232_shipment_decision'
   elif stored is None:kind='missing_statutory_parameter'
   elif abs(stored-full)>1e-9:kind='ordinary_scope_or_rate_mismatch'
   else:kind='ordinary_scope_parameter_agrees'
   counts[kind]+=r['row_count']
   if kind in ('missing_statutory_parameter','ordinary_scope_or_rate_mismatch'):
    findings.append(dict(entry_day=day,expected_ordinary_scope_rate=full,expected_action_codes=[w['heading'] for w in matched],**r))
 with gzip.open(out/'motherduck-findings.json.gz','wt') as f:json.dump(findings,f,separators=(',',':'))
 with gzip.open(out/'motherduck-read-only.json.gz','wb') as f:f.write(data)
 summary['motherduck']=dict(database=md['database'],started_at=md['started_at'],finished_at=md['finished_at'],
  export_sha256=sha(data),stored_groups=len(md['rows']),checked_entry_day_groups=checked,counts=dict(counts),
  distinct_mismatched_stored_groups=len({(r['revision'],r['hts10'],r['valid_from'],r['valid_until']) for r in findings}),
  limitations='Ordinary unclaimed scope/rate parameters only. Does not price aircraft, Chapter98, FTZ, Section232 facts or complete duties. Counts by entry-day test are not unique stored rows.')
(out/'report.json').write_text(json.dumps(summary,indent=2)+'\n')

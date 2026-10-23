#!/usr/bin/env python3
"""Source-only audit: no timeseries calculation or database writes."""
import argparse,csv,gzip,json,sys
from pathlib import Path
from collections import Counter
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from section122_sources import extract,sha
p=argparse.ArgumentParser();p.add_argument('output',type=Path);args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
calendar=list(csv.DictReader((ROOT/'config/revision_dates.csv').open()))
old=list(csv.DictReader((ROOT/'resources/s122_exempt_products.csv').open()))
old_scope={r['hts8'] for r in old}
rows=[]
for entry in calendar:
    revision=entry['revision']
    if not revision.startswith(('2025_','2026_')):continue
    data=extract(ROOT/f'data/us_notes/chapter99_{revision}.pdf',ROOT/f'data/hts_archives/hts_{revision}.json',revision)
    scope={r['scope_code'] for r in data['products']}
    payload=(json.dumps(data,sort_keys=True,indent=2)+'\n').encode()
    (args.output/f'{revision}.json.gz').write_bytes(gzip.compress(payload,mtime=0))
    rows.append(dict(revision=revision,headings=len(data['headings']),products=len(scope),
        conditions=dict(Counter(r['condition'] for r in data['products'])),
        exact_hts10=[r['scope_code'] for r in data['products'] if r['scope_grain']=='exact_hts10'],
        snapshot_only_scope=sorted(scope-old_scope) if scope else [],
        legacy_only_scope=sorted(old_scope-scope) if scope else [],
        extraction_sha256=sha(payload),source_hashes=[s['sha256'] for s in data['sources']]))
    print(revision,len(scope),'product scopes',flush=True)
(args.output/'report.json').write_text(json.dumps(dict(revisions=rows,
    scope='Source-table extraction only. No full shipment applicability or total certification.',
    source_parser_sha256=sha((ROOT/'src/section122_sources.py').read_bytes())),indent=2)+'\n')

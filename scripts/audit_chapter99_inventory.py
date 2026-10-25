#!/usr/bin/env python3
"""Census all configured Chapter 99 sources without calculating rates."""
import argparse
import csv
import gzip
import json
import sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from chapter99_inventory import build_inventory, encoded
from section301_sources import sha

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('output',type=Path);p.add_argument('--normalized-dir',type=Path)
    a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
    summary=[]
    for row in csv.DictReader((ROOT/'config/revision_dates.csv').open()):
        rev=row['revision']
        if not rev.startswith(('2025_','2026_')):continue
        fragments=sorted((a.normalized_dir/rev).glob('*_rules.json')) if a.normalized_dir else []
        x=build_inventory(ROOT/f'data/us_notes/chapter99_{rev}.pdf',ROOT/f'data/hts_archives/hts_{rev}.json',rev,fragments)
        raw=encoded(x).encode();file=a.output/(rev+'.json.gz')
        file.write_bytes(gzip.compress(raw,mtime=0))
        states={s:sum(r['status']==s for r in x['provisions']) for s in ('linked_rules_partial','unresolved_source')}
        summary.append(dict(revision=rev,counts=x['counts'],states=states,
            snapshot_expired=sum(r['snapshot_status']=='source_declares_expired' for r in x['provisions']),
            compiler_sha256=x['compiler_sha256'],sources=x['sources'],inventory_sha256=sha(raw),file=file.name,
            compressed_sha256=sha(file.read_bytes()),coverage_granted=False))
        print(rev,x['counts'],flush=True)
    (a.output/'summary.json').write_text(json.dumps(dict(contract_version='sail.chapter99-inventory-audit/v1',
        kind='source-only census; no rates build or legal completeness attestation',revisions=summary),indent=2)+'\n')

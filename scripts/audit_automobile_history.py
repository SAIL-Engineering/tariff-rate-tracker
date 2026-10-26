#!/usr/bin/env python3
"""Reconcile all native automobile sources and exact candidate memberships.

This is source extraction only, not a rate/revision/timeseries build, an
exhaustive shipment evaluation or a complete Section232 coverage attestation.
"""
import csv
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from section232_autos import extract, load_history, reconcile_native, excluded_codes, sha

if __name__=='__main__':
    target=Path(sys.argv[1])
    if target.exists():raise SystemExit('Use a new output file')
    history=load_history();rows=[]
    for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()):
        revision=r['revision']
        if not revision.startswith(('2025_','2026_')):continue
        pdf=ROOT/f'data/us_notes/chapter99_{revision}.pdf';hts=ROOT/f'data/hts_archives/hts_{revision}.json'
        x=extract(pdf,hts,revision);reconcile_native(x,history)
        products=sorted({p['htsno'].replace('.','') for p in json.loads(hts.read_bytes())
            if len(p.get('htsno','').replace('.',''))==10})
        memberships={k:[p for p in products if any(p.startswith(prefix) for prefix in history[k]['prefixes'])]
            for k in ('vehicles','parts')}
        rows.append(dict(revision=revision,sources=x['sources'],native_subdivisions=list(x['clauses']),
            native_headings=len(x['headings']),products=len(products),candidate_membership=memberships,
            native_nonstacking_codes={k:excluded_codes(x['clauses'][k]) for k in ('a','f')
                if 'shall not be subject to' in x['clauses'].get(k,'')},
            russian_reporting_codes=x['russian_reporting_codes'],coverage_granted=False))
        print(revision,len(products),{k:len(v) for k,v in memberships.items()},flush=True)
    target.write_text(json.dumps(dict(kind=__doc__,compiler_sha256=sha((ROOT/'src/section232_autos.py').read_bytes()),
        extraction_sources=history['sources'],revisions=rows),indent=2)+'\n')

#!/usr/bin/env python3
"""Read all configured native sources; no rate build or database mutation."""
import argparse
import copy
import csv
import gzip
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from section232_autos import extract,reconcile_native,load_history
from section232_vehicle_certified import add_certified_history
from section232_mhd_parts import load_history as mhd_history,memberships,signature


def census():
    h=load_history();m=mhd_history()
    revisions=[r['revision'] for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision'].startswith(('2025_','2026_'))]
    if len(revisions)!=len(set(revisions)):raise ValueError('Duplicate revision identity')
    result=[]
    for i,rev in enumerate(revisions):
        x=extract(ROOT/f'data/us_notes/chapter99_{rev}.pdf',ROOT/f'data/hts_archives/hts_{rev}.json',rev)
        reconcile_native(x,h)
        certified=add_certified_history(copy.deepcopy(h),x)
        products=sorted(x['base_sources'])
        groups=memberships(m,products,h['parts']['prefixes'])
        result.append(dict(revision=rev,products=len(products),mhd_native=bool(x['mhd_clauses']),
            native_mhd_part_clauses_sha256={k:signature(x['mhd_clauses'][k]) for k in 'hijkl' if k in x['mhd_clauses']},
            native_certified_auto_clauses_sha256={k:signature(x['clauses'][k]) for k in 'pqr' if k in x['clauses']},
            candidates=groups,certified_auto_candidates=certified['members'](products),native_artifacts=x['sources']))
        print(f'[{i+1}/{len(revisions)}] {rev}: reconciled; listed MHD={len(groups["listed"])}; optional certified={len(groups["certified"])}',flush=True)
    origins=list(csv.DictReader((ROOT/'resources/census_codes.csv').open()))
    return dict(contract_version='sail.vehicle-parts-source-census/v1',cutoff_exclusive=m['until'],origin_count=len({r['Code'] for r in origins}),
        source_revision_count=len(result),native_mhd_revision_count=sum(r['mhd_native'] for r in result),
        interpretation='Potential legal memberships, not confirmed shipment liability or erroneous-cell counts. Optional certified parts require a valid IOR election and actual use. No complete Section232 inventory attestation.',
        mhd_legal_periods=m['periods'],evidence=m['sources'],revisions=result)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args()
    target=Path(a.output)
    if target.exists():raise SystemExit('Output already exists; choose a new audit artifact')
    payload=json.dumps(census(),sort_keys=True,separators=(',',':')).encode()+b'\n'
    target.parent.mkdir(parents=True,exist_ok=True)
    with target.open('xb') as out:out.write(gzip.compress(payload,mtime=0) if target.suffix=='.gz' else payload)
    print('Source census ready: '+str(target),flush=True)

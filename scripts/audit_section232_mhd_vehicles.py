#!/usr/bin/env python3
"""Reconcile every configured source frame; no rates build/database mutation."""
import argparse,csv,gzip,json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from section232_mhd_vehicles import extract,load_history
from section232_mhd_parts import signature


def census():
    h=load_history();result=[]
    revisions=[r['revision'] for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision'].startswith(('2025_','2026_'))]
    if len(revisions)!=len(set(revisions)):raise ValueError('Duplicate source revision identity')
    for i,rev in enumerate(revisions):
        x=extract(rev)
        groups={k:sorted(p for p in x['products'] if any(p.startswith(a) for a in prefixes)) for k,prefixes in h['scopes'].items()}
        result.append(dict(revision=rev,native_mhd=bool(x['clauses']),reconciliation=x['reconciliation'],candidate_memberships=groups,
            native_clauses_sha256={k:signature(x['clauses'][k]) for k in 'abcdefg' if k in x['clauses']},native_sources=x['sources']))
        print(f'[{i+1}/{len(revisions)}] {rev}: reconciled; MHD={len(groups["vehicles"])}; buses={len(groups["buses"])}',flush=True)
    return dict(contract_version='sail.mhd-vehicle-source-census/v1',cutoff_exclusive=h['until'],source_revision_count=len(result),
        native_mhd_revision_count=sum(r['native_mhd'] for r in result),
        origin_count=len({r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())}),
        interpretation='Source candidate memberships, not confirmed liability or erroneous-cell counts. No complete Section232 attestation.',
        periods=h['periods'],sources=h['sources'],revisions=result)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args();target=Path(a.output)
    if target.exists():raise SystemExit('Choose a new output artifact')
    payload=json.dumps(census(),sort_keys=True,separators=(',',':')).encode()+b'\n'
    target.parent.mkdir(parents=True,exist_ok=True)
    with target.open('xb') as out:out.write(gzip.compress(payload,mtime=0) if target.suffix=='.gz' else payload)
    print('MHD source census ready: '+str(target),flush=True)

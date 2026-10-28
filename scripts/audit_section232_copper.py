#!/usr/bin/env python3
"""Source-only copper census; never rebuild rates or write a database."""
import argparse
import csv
import gzip
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from section232_copper import extract,load_history,matches
from section232_autos import load_history as automobile_history


def main():
    p=argparse.ArgumentParser();p.add_argument('--output',required=True);a=p.parse_args()
    target=Path(a.output)
    if target.exists():raise ValueError('Use a new census output path')
    calendar=list(csv.DictReader((ROOT/'config/revision_dates.csv').open()))
    revisions=[r for r in calendar if r['revision'].startswith(('2025_','2026_'))]
    h=load_history();auto=automobile_history();reports=[];union=set()
    scopes=[auto[s]['prefixes'] for s in ('vehicles','parts')]+[d.get('parts_prefixes',[]) for d in auto['deals']]
    for i,row in enumerate(revisions,1):
        revision=row['revision'];print(f'[{i}/{len(revisions)}] Reconciling copper source {revision}',flush=True)
        x=extract(revision);selected=matches(h,x['native_products']);union.update(selected)
        overlap=[p for p in selected if any(p.startswith(pre) for group in scopes for pre in group)]
        if overlap:raise ValueError('Source-defined auto/copper intersection requires reconciliation')
        reports.append(dict(revision=revision,snapshot_status=x['reconciliation']['status'],matched_products=selected,
            auto_intersection=overlap,source_versions=[dict(id=s['id'],sha256=s['sha256']) for s in x['sources']]))
    result=dict(contract_version='sail.copper-source-census/v1',qualification='source inventory only; not all-authority or shipment qualification',
        revisions=len(reports),original_hts8_count=len(h['hts8']),unique_native_hts10_count=len(union),
        native_heading_revisions=sum(r['snapshot_status']=='original_note36_reconciled' for r in reports),
        universal_origin_inventory_size=sum(1 for _ in csv.DictReader((ROOT/'resources/census_codes.csv').open())),
        legal_window=dict(from_=h['from_'],until=h['until']),
        original_sources=[dict(id=s['id'],sha256=s['sha256'],url=s['url']) for s in h['sources']],reports=reports)
    data=(json.dumps(result,sort_keys=True,separators=(',',':'))+'\n').encode()
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_bytes(gzip.compress(data,mtime=0) if target.suffix=='.gz' else data)
    print(json.dumps({k:result[k] for k in ('revisions','original_hts8_count','unique_native_hts10_count','native_heading_revisions','universal_origin_inventory_size')}))


if __name__=='__main__':main()

#!/usr/bin/env python3
"""Source/chronology census; never a rates build or legal-coverage certificate."""
import argparse
import csv
import gzip
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
import section301_labor as labor


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='labor-origin-census-') as tmp:
        target=Path(tmp)/'origins.json'
        code="""source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/ieepa_reciprocal_revision.R');source('src/section301_labor.R')
h<-load_s301_labor_history();j<-setNames(lapply(h$actions,function(a)resolve_original_action_origins(a$country_text)),vapply(h$actions,`[[`,character(1),'country_text'))
jsonlite::write_json(j,commandArgs(TRUE)[1],auto_unbox=TRUE,null='null')"""
        subprocess.run(['Rscript','-e',code,str(target)],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
        jurisdictions=json.loads(target.read_bytes())
    revisions=[r['revision'] for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision'].startswith(('2025_','2026_'))]
    rows=[];conflicts=[];history=labor.load_history()
    for i,revision in enumerate(revisions,1):
        print(f'[{i}/{len(revisions)}] Reconcile original/natively published note52: {revision}',flush=True)
        try:
            # Empty price cohort: inspect every source heading/annex but do not
            # manufacture shipment facts or claim a grid calculation.
            fragment=labor.compile_rules(revision,[],jurisdictions)
            rows.append(dict(revision=revision,status='source_inventory_reconciled',supported_from=fragment['supported_from'],supported_until=fragment['supported_until'],
                native_hts_sha256=hashlib.sha256((ROOT/f'data/hts_archives/hts_{revision}.json').read_bytes()).hexdigest(),
                heading_inventory=fragment['revision_heading_inventory'],annex_reconciliation=fragment['revision_annex_reconciliation'],
                emitted_rule_count=len(fragment['rules']),original_source_count=len(fragment['sources'])))
        except Exception as exc:
            row=dict(revision=revision,status='unresolved_source',error=str(exc));rows.append(row);conflicts.append(row)
    resolver_inputs=['src/helpers.R','src/05_parse_policy_params.R','src/ieepa_reciprocal_revision.R','resources/census_codes.csv','resources/country_name_aliases.csv','resources/country_qualified_names.csv','config/policy_params.yaml']
    report=dict(contract_version='sail.section301-forced-labor-source-census/v2',revisions=rows,conflicts=conflicts,
        original_headings=len(history['original_headings']),investigations=len(history['actions']),charge_headings=sum(len(a['headings']) for a in history['actions']),
        product_exemption_provisions=len({r['reporting_code'] for r in history['product_exemptions']}),product_condition_rows=len(history['product_exemptions']),
        procedural_provisions=history['procedural_provisions'],floor_policy=history['floor_policy'],unresolved_decisions=history['unresolved_decisions'],
        origin_resolution=jurisdictions,resolver_inputs={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in resolver_inputs},
        rates_calculated=False,shipment_grid_evaluated=False,legal_coverage_complete=False,production_qualified=False,
        limitation='Complete original inventory versus available native snapshots, including known publication-copy discrepancies and original amendment windows. This does not establish exhaustive external legal-feed coverage, FTZ pricing, all preferences or all-authority completeness.')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    opener=gzip.open if args.output.suffix=='.gz' else open
    with opener(args.output,'wt') as out:json.dump(report,out,indent=2);out.write('\n')
    print(f'{len(rows)} revisions checked; {len(conflicts)} unresolved source conflicts',flush=True)
    return int(bool(conflicts))


if __name__=='__main__':raise SystemExit(main())

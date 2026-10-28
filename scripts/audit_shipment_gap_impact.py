#!/usr/bin/env python3
"""Measure candidate scope without inventing shipment facts or rebuilding rates.

Scope counts are not numbers of erroneous rates or unresolved actual shipments.
The same HTS/origin/date can have several legally different fact patterns.
"""
import argparse,csv,json,sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(ROOT/'src'),str(ROOT/'scripts')]
from shipment_base_sources import extract_rows
from section301_labor import load_history
from section301_sources import sha
from audit_s232_note16 import audit_revision
from audit_section301_labor_policy import resolve_origin_context


def audit(output):
    output.mkdir(parents=True,exist_ok=False)
    calendar=[r for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision'].startswith(('2025_','2026_'))]
    countries={r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())}
    h=load_history();scope=h['common_products']['includes'];scope8={p for p in scope if len(p)==8};scope10={p for p in scope if len(p)==10}
    all_products=set();all_common=set();reports=[];active=[]
    # Reuse current ingestion identity resolution, not a fixed older audit's
    # derived map. Its complete dependency/source pins accompany the census.
    context=resolve_origin_context(calendar[0]['revision'])
    origins=context['origin_resolution']
    covered_origins={c for a in origins for c in a['countries']}
    for row in calendar:
        rev=row['revision'];path=ROOT/f'data/hts_archives/hts_{rev}.json';raw=path.read_bytes()
        ps={p['hts10'] for p in extract_rows(json.loads(raw))['products']};all_products|=ps
        # Source-selection intervals in this repo use the identified policy
        # instants; a later publication cannot erase an original retroactive day.
        day=row['policy_effective_date'] if row['policy_effective_date']!='NA' else row['effective_date']
        days=[r['policy_effective_date'] if r['policy_effective_date']!='NA' else r['effective_date'] for r in calendar]
        end=min((d for d in days if d>day),default=h['audit_until'][:10])
        applies=day<h['audit_until'][:10] and end>h['from_'][:10]
        matched={p for p in ps if p[:8] in scope8 or p in scope10}
        if applies:active.append(rev);all_common|=matched
        report=dict(revision=rev,source_from=day,source_until=end,ordinary_products=len(ps),native_hts_sha256=sha(raw),
            all_origin_candidate_cells=len(ps)*len(countries),forced_labor_operative=applies,
            forced_labor_origin_count=len(covered_origins) if applies else 0,
            forced_labor_candidate_cells=len(ps)*len(covered_origins) if applies else 0,
            common_product_candidates=len(matched) if applies else 0,
            common_product_candidate_cells=len(matched)*len(covered_origins) if applies else 0)
        reports.append(report);print(rev,len(ps),'ordinary products;',report['common_product_candidates'],'common-exemption candidates',flush=True)
    # Note16 predicates and scopes are parsed from each source snapshot, with
    # no model rates and no presumed end use/material origin/content facts.
    metals=list(ThreadPoolExecutor(max_workers=4).map(audit_revision,[r['revision'] for r in calendar]))
    metal_union=set();xi_union=set();metal_reports=[]
    for (report,scopes),row in zip(metals,calendar):
        members=set(scopes);xi={p for p,s in scopes.items() if 'xi' in s['list_ids']};metal_union|=members;xi_union|=xi
        bases={p['hts10']:p['general'] for p in extract_rows(json.loads((ROOT/f"data/hts_archives/hts_{row['revision']}.json").read_bytes()))['products']} if xi else {}
        free={p for p in xi if bases[p]['expression']=='Free'}
        metal_reports.append(dict(**report,candidate_origin_count=len(countries) if members else 0,
            candidate_cells=len(members)*len(countries),xi_candidates=len(xi),xi_conditional_conflict_candidate_cells=len(xi)*len(countries),
            xi_published_column1_free_candidates=len(free),xi_column1_sources={p:bases[p] for p in sorted(xi)}))
    result=dict(contract_version='sail.shipment-gap-impact/v1',method='Source-scope census; no rates calculated, no actual shipment fact prevalence assumed.',
        unique_ordinary_hts10=len(all_products),origins=len(countries),revisions=len(reports),
        product_revision_cells=sum(r['ordinary_products'] for r in reports),
        all_origin_hts_revision_candidate_cells=sum(r['all_origin_candidate_cells'] for r in reports),
        forced_labor=dict(origins=len(covered_origins),operative_revisions=active,candidate_cells=sum(r['forced_labor_candidate_cells'] for r in reports),
            common_product_scope_entries=len(scope),exact_hts10_scope_entries=sum(len(p)==10 for p in scope),
            common_unique_hts10=len(all_common),common_product_candidate_cells=sum(r['common_product_candidate_cells'] for r in reports)),
        section232_note16=dict(unique_candidate_hts10=len(metal_union),candidate_revisions=sum(bool(r['matched_products']) for r in metal_reports),
            candidate_cells=sum(r['candidate_cells'] for r in metal_reports),xi_unique_candidate_hts10=len(xi_union),
            xi_candidate_revisions=sum(bool(r['xi_candidates']) for r in metal_reports),xi_conditional_conflict_candidate_cells=sum(r['xi_conditional_conflict_candidate_cells'] for r in metal_reports)),
        classification_revisions=reports,section232_note16_revisions=metal_reports,
        origin_resolution=origins,origin_source_artifacts=context['source_artifacts'],
        origin_compiler_dependencies=context['compiler_dependencies'],
        source_pins={str(p.relative_to(ROOT)):sha(p.read_bytes()) for p in [ROOT/'config/revision_dates.csv',ROOT/'resources/census_codes.csv',ROOT/'src/section301_labor.py',ROOT/'src/section232_sources.py',ROOT/'src/shipment_base_sources.py',ROOT/'scripts/audit_section301_labor_policy.py',Path(__file__).resolve()]},
        caveats=['Counts are potential scope, not proven errors or counts of actually unresolved shipments.',
            'Common-product counts resolve that forced-labor component for supported ordinary-entry facts; they do not certify the whole stack.',
            'Note16 counts cover that post-April metal regime, not all Section232 sectors or pre-April regimes.',
            'The xi discrepancy requires the US-metal qualification; the HTS/origin/revision triple cannot reveal its actual prevalence.',
            'Missing complete authority inventories block complete totals more broadly than the individually unresolved branches.'],
        legal_coverage_complete=False,rates_calculated=False,motherduck_modified=False)
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',required=True,type=Path);audit(p.parse_args().out)

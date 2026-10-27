#!/usr/bin/env python3
"""Source-only civil-aircraft census across configured 2025/2026 revisions.

No revision or timeseries rates are built. Original agreements determine scope;
native snapshots corroborate reporting definitions and valid product identity.
"""
import argparse,csv,json,re,subprocess,sys,tempfile
from collections import defaultdict
from datetime import datetime
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from section232_civil_aircraft import load_history,compile_rules
from shipment_base_sources import extract_rows
from section301_sources import sha


def audit(output):
    output.mkdir(parents=True,exist_ok=False)
    calendar=[r for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision'].startswith(('2025_','2026_'))]
    day=lambda r:r['policy_effective_date'] if r['policy_effective_date']!='NA' else r['effective_date']
    calendar.sort(key=day)
    # The same R resolver used in the ordinary build supplies Census/EU maps.
    # An empty product request emits source context, not calculated duty rates.
    with tempfile.TemporaryDirectory() as temp:
        code=Path(temp)/'origins.R';context=Path(temp)/'origins.json'
        code.write_text("source('src/helpers.R');source('src/section232_civil_aircraft.R')\n"
            "args<-commandArgs(TRUE);f<-compile_s232_civil_aircraft_fragment(args[1],character())\n"
            "jsonlite::write_json(f,args[2],auto_unbox=TRUE,null='null',digits=NA)\n")
        subprocess.run(['Rscript',str(code),calendar[0]['revision'],str(context)],cwd=ROOT,check=True)
        origins=json.loads(context.read_bytes())
    (output/'origin-resolution.json').write_text(json.dumps(origins,indent=2)+'\n')
    jurisdictions={r['reporting_code']:r['countries'] for r in origins['origin_resolution']}
    source_by_id={s['id']:s for s in origins['sources']}
    paths={a['source_id']:a['path'] for a in origins['source_artifacts']}
    jurisdiction_sources=[dict(source_by_id[id],path=paths[id]) for id in origins['origin_resolution_source_ids']]
    pins={str(Path(a['path']).resolve()):a['sha256'] for a in origins['source_artifacts']}
    history=load_history();actions={a['reporting_code']:a for a in history['actions']}
    reports=[];conflicts=[]
    for row in calendar:
        rev=row['revision'];path=ROOT/f'data/hts_archives/hts_{rev}.json';raw=path.read_bytes();native=json.loads(raw)
        products=[r['hts10'] for r in extract_rows(native)['products']]
        product_set=set(products);by8=defaultdict(set)
        for p in products:by8[p[:8]].add(p)
        fragment=compile_rules(rev,products,jurisdictions,jurisdiction_sources)
        expected={}
        for code,a in actions.items():
            found=set()
            for p in a['products']:
                if len(p)==8:found.update(by8[p])
                elif len(p)==10 and p in product_set:found.add(p)
                elif len(p)!=10:raise ValueError('Unreviewed source scope precision')
            expected[code]=found
        start,end=map(datetime.fromisoformat,(fragment['supported_from'],fragment['supported_until']))
        active=[]
        for r in fragment['rules']:
            code=r['reporting_codes'][0]
            if set(r['scope']['hts_exact'])!=expected[code] or r['scope']['countries']!=jurisdictions[code]:
                raise ValueError('Source scope/origin projection mismatch: '+rev+' '+code)
            if datetime.fromisoformat(r['scope']['from'])<end and datetime.fromisoformat(r['scope']['until'])>start:active.append(r['id'])
        bycode={r.get('htsno'):r for r in native};headings=[]
        for code in actions:
            heading=bycode.get(code)
            if not heading:headings.append(dict(code=code,status='absent_in_snapshot_original_source_controls'));continue
            expression=' '.join((heading.get('general') or '').split())
            if not re.fullmatch(r'The duty provided in the applicable subheading\.?',expression):
                conflicts.append(dict(revision=rev,code=code,expression=expression,question='Reconcile original no-additional-duty definition with this native expression'))
            headings.append(dict(code=code,status='native_definition_corroborated',expression=expression))
        reports.append(dict(revision=rev,source_from=fragment['supported_from'],source_until=fragment['supported_until'],
            native_hts_sha256=sha(raw),valid_ordinary_products=len(products),scope_memberships={code:len(ps) for code,ps in expected.items()},
            active_rule_ids=active,reporting_headings=headings))
        print(rev,len(products),'ordinary products;',sum(map(len,expected.values())),'source memberships',flush=True)
    for p,pin in pins.items():
        if sha(Path(p).read_bytes())!=pin:raise ValueError('Source changed during aircraft census: '+p)
    result=dict(contract_version='sail.civil-aircraft-source-census/v1',revisions=reports,conflicts=conflicts,
        sources=[dict(path=p,sha256=s) for p,s in sorted(pins.items())],origin_resolution=origins['origin_resolution'],
        original_action_count=len(actions),other_authority_relief=history['other_authority_relief'],modern_from=history['modern_from'],
        rates_calculated=False,shipment_grid_evaluated=False,legal_coverage_complete=False,production_qualified=False,
        limitation='Complete scope/origin projection and carrier-definition census for these agreements only. Not full Section232, treaty-territory, FTZ or cross-program legal coverage.')
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    if conflicts:raise ValueError('Aircraft native definition conflicts require review; see summary.json')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',required=True,type=Path);audit(p.parse_args().out)

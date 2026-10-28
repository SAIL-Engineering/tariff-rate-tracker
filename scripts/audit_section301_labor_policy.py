#!/usr/bin/env python3
"""Reconcile original action definitions with every configured native snapshot.

This is a source census, not a revision/timeseries build or a full duty oracle.
"""
import argparse,csv,json,re,subprocess,sys,tempfile
from datetime import datetime
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from section301_labor import load_history,compile_rules,canonical
from section301_sources import sha


def resolve_origin_context(revision):
    """Use current ingestion resolution and preserve its input/source pins."""
    with tempfile.TemporaryDirectory() as temp:
        script=Path(temp)/'origins.R';context=Path(temp)/'origins.json'
        script.write_text("source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/section301_labor.R')\n"
            "a<-commandArgs(TRUE);f<-compile_s301_labor_fragment(a[1],character())\n"
            "jsonlite::write_json(f,a[2],auto_unbox=TRUE,null='null',digits=NA)\n")
        subprocess.run(['Rscript',str(script),revision,str(context)],cwd=ROOT,check=True)
        return json.loads(context.read_bytes())


def audit(output):
    output.mkdir(parents=True,exist_ok=False)
    calendar=[r for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision'].startswith(('2025_','2026_'))]
    origins=resolve_origin_context(calendar[0]['revision'])
    (output/'origin-resolution.json').write_text(json.dumps(origins,indent=2)+'\n')
    jurisdictions={r['country_text']:r['countries'] for r in origins['origin_resolution']}
    pins={a['path']:a['sha256'] for a in origins['source_artifacts']}
    for relative,pin in origins['compiler_dependencies'].items():
        pins[str(ROOT/relative)]=pin
    pins[str(ROOT/'src/section301_labor.py')]=origins['compiler_sha256']
    pins[str(Path(__file__).resolve())]=sha(Path(__file__).read_bytes())
    history=load_history();headings={r['reporting_code']:r for r in history['original_headings']}
    reports=[];conflicts=[]
    for row in calendar:
        rev=row['revision'];path=ROOT/f'data/hts_archives/hts_{rev}.json';data=path.read_bytes()
        native={r.get('htsno'):r for r in json.loads(data)}
        fragment=compile_rules(rev,[],jurisdictions)
        start,end=map(datetime.fromisoformat,(fragment['supported_from'],fragment['supported_until']))
        changes=0;present=0
        for code,source in headings.items():
            record=native.get(code)
            if record is None:
                if row['effective_date']>=history['from_'][:10]:
                    conflicts.append(dict(revision=rev,reporting_code=code,question='An operative original heading is missing from this native snapshot.'))
                continue
            present+=1;expected=source['description']
            for change in history['heading_amendments']:
                if code==change['reporting_code'] and row['effective_date']>=change['from_'][:10]:
                    if expected.count(change['after'])!=1:raise ValueError('Ambiguous original amendment operand')
                    expected=expected.replace(change['after'],change['after']+' '+change['insert']);changes+=1
            if canonical(record.get('description',''))!=canonical(expected):
                conflicts.append(dict(revision=rev,reporting_code=code,question='Unreconciled original/amended description',expected=expected,actual=record.get('description')))
            for column in ('general','special'):
                rates=sorted(set(re.findall(r'(\d+(?:\.\d+)?)%',record.get(column,''))))
                if rates!=source['percentages']:conflicts.append(dict(revision=rev,reporting_code=code,column=column,question='Unreconciled original rate expression',expected=source['percentages'],actual=rates))
        reports.append(dict(revision=rev,source_from=fragment['supported_from'],source_until=fragment['supported_until'],native_hts_sha256=sha(data),
            corroborated_headings=present,original_amendments_applied=changes,
            common_product_scope_corroborated=present>0,
            active_rule_ids=[r['id'] for r in fragment['rules'] if datetime.fromisoformat(r['scope']['from'])<end and datetime.fromisoformat(r['scope']['until'])>start]))
        print(rev,present,'original/amended definitions checked',flush=True)
    for path,pin in pins.items():
        if sha(Path(path).read_bytes())!=pin:raise ValueError('Source changed during forced-labor census')
    result=dict(contract_version='sail.section301-forced-labor-source-census/v1',revisions=reports,conflicts=conflicts,
        original_headings=len(headings),investigations=len(history['actions']),charge_headings=sum(len(a['headings']) for a in history['actions']),
        common_product_scope=dict(entries=len(history['common_products']['includes']),scope_grains=history['common_products']['scope_grains'],
            exact_hts10_entries=sum(len(p)==10 for p in history['common_products']['includes']),reporting_code=history['common_products']['reporting_code']),
        unresolved_decisions=history['unresolved_decisions'],origin_resolution=origins['origin_resolution'],sources=[dict(path=p,sha256=s) for p,s in sorted(pins.items())],
        legal_instants=[history[k] for k in ('from_','transit_until','amendment_from')],rates_calculated=False,shipment_grid_evaluated=False,
        legal_coverage_complete=False,production_qualified=False,limitation='Original action/definition, common product scope and dated reporting amendment census. Product and Section232 exemptions are executable for verified ordinary-entry facts; remaining annex/claims/valuation/FTZ paths are explicitly unpriced.')
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    if conflicts:raise ValueError('Native/original conflicts require review; see summary.json')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',required=True,type=Path);audit(p.parse_args().out)

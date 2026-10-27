#!/usr/bin/env python3
"""All-revision source/interval census; never calculate or publish a timeseries.

Corroborate original partner insertion rows against every available snapshot.
Missing later insertions in an older snapshot never establish legal absence.
"""
import argparse,csv,json,sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from ieepa_reciprocal_initial import initial_history
from ieepa_reciprocal_later import legal_instants
from ieepa_reciprocal_history import history as product_history
from ieepa_reciprocal_sources import extract
from section301_sources import sha


def audit(output):
    output.mkdir(parents=True,exist_ok=False)
    policy=initial_history();scope=product_history()
    versions={str(Path(s['path']).resolve()):s['sha256'] for s in policy['sources']+scope['sources']}
    calendar=list(csv.DictReader(open(Path(__file__).resolve().parents[1]/'config/revision_dates.csv')))
    root=Path(__file__).resolve().parents[1]
    calendar=[r for r in calendar if r['revision'].startswith(('2025_','2026_'))]
    day=lambda r:r['policy_effective_date'] if r['policy_effective_date']!='NA' else r['effective_date']
    calendar.sort(key=day)
    changes=[]
    for e in policy['later_policy']['inventories']:changes.append(dict(at=e['from_'],source_id=e['source_id'],kind='partner_annex',headings=e['headings']))
    for e in policy['china_suspension_continuations']:changes.append(dict(at=e['from_'],source_id=e['source_id'],kind='suspension_continuation'))
    for e in policy['later_sector_interactions']['links']:changes.append(dict(at=e['from_'],source_id=e['source_ids'][0],kind='sector_interaction',headings=e['codes']))
    changes.append(dict(at=policy['collection_ended_at'],source_id='CBP-CSMS-67834313',kind='collection_ended'))
    expected={}
    for r in policy['later_policy']['country_amendments']:
        for i,code in enumerate(r['reporting_codes']):expected[code]=dict(country=r['country_text'],rate=None if i==0 else r['rate'],source_ids=r['source_ids'])
    for r in policy['later_policy']['exemptions']:
        expected[r['reporting_code']]=dict(country=r['country_text'],rate=None,source_ids=r['source_ids'],condition=r['condition'])
    # Event labels are explanatory. The actual boundary inventory is collected
    # from all typed legal windows, so a nested deadline cannot disappear merely
    # because a new event was not added to the descriptive list above.
    instants=sorted(legal_instants(policy,scope),key=datetime.fromisoformat)
    reports=[];conflicts=[];mid_revision=[];boundaries=[]
    for i,entry in enumerate(calendar):
        rev=entry['revision'];path=root/f'data/hts_archives/hts_{rev}.json';pdf=root/f'data/us_notes/chapter99_{rev}.pdf'
        start=datetime.fromisoformat(day(entry)).replace(tzinfo=ZoneInfo('America/New_York')).isoformat()
        end=datetime.fromisoformat(day(calendar[i+1])).replace(tzinfo=ZoneInfo('America/New_York')).isoformat() if i+1<len(calendar) else '2026-10-23T00:00:00-04:00'
        rows=json.loads(path.read_bytes());native={r.get('htsno'):r for r in rows};corroborated=[];absent=[]
        # The full note/PDF extraction independently reconciles original AnnexII
        # changes, including exact conditional product scopes and terminations.
        x=extract(pdf,path,rev)
        for code,rule in expected.items():
            if code not in native:absent.append(code);continue
            r=native[code];description=' '.join(r.get('description','').split())
            country_match=rule['country'] in description
            rates=[float(v)/100 for v in __import__('re').findall(r'(\d+(?:\.\d+)?)%',r.get('general',''))]
            wanted=[] if rule['rate'] is None else [rule['rate']]
            if not country_match or rates!=wanted:
                conflicts.append(dict(revision=rev,heading=code,country_match=country_match,observed_expression=r.get('general'),expected_parameters=wanted,source_ids=rule['source_ids']))
            else:corroborated.append(code)
        split=[c for c in changes if datetime.fromisoformat(start)<datetime.fromisoformat(c['at'])<datetime.fromisoformat(end)]
        mid_revision.extend(dict(revision=rev,source_selection_from=start,source_selection_until=end,**c) for c in split)
        legal_splits=[at for at in instants if datetime.fromisoformat(start)<datetime.fromisoformat(at)<datetime.fromisoformat(end)]
        boundaries.extend(dict(revision=rev,at=at) for at in legal_splits)
        reports.append(dict(revision=rev,raw_hts_date=entry['effective_date'],source_selection_from=start,source_selection_until=end,
            original_partner_headings_corroborated=corroborated,later_headings_absent_from_snapshot=absent,
            native_product_scope_reconciliation=x['reconciliation'],mid_revision_changes=split,
            all_mid_revision_legal_boundaries=legal_splits,hts_sha256=sha(path.read_bytes()),pdf_sha256=sha(pdf.read_bytes())))
        print(rev,len(corroborated),'corroborated,',len(split),'intra-revision events',flush=True)
    for path,pin in versions.items():
        if sha(Path(path).read_bytes())!=pin:raise ValueError('Source changed during census: '+path)
    result=dict(contract_version='sail.reciprocal-policy-source-census/v1',revisions=reports,conflicts=conflicts,
        sources=[dict(path=p,sha256=s) for p,s in sorted(versions.items())],mid_revision_changes=mid_revision,
        all_legal_instants=instants,all_mid_revision_legal_boundaries=boundaries,
        legal_coverage_complete=False,shipment_grid_evaluated=False,production_qualified=False,
        limitation='Original-source/native corroboration and interval census only. Not an exhaustive duty-stack legal oracle.')
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    if conflicts:raise ValueError(f'{len(conflicts)} original/native policy discrepancies; see summary.json')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',required=True,type=Path)
    audit(p.parse_args().out)

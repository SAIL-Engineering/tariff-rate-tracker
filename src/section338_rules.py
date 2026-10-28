"""Executable Section 338 actions from original annexes and amendments."""
from __future__ import annotations
import argparse, csv, json, re
from pathlib import Path
from section338_sources import extract, periods, reconcile_snapshot, ROOT, sha
from section232_note16_rules import val, fact, op, both, either, negate
from chapter98_rules import compile_valuation, overlap_value


def interaction_codes(text):
    text=text.split('shall not apply to:',1)[1]
    result=[]
    for m in re.finditer(r'(9903\.\d{2}\.\d{2})(?:[—–-](9903\.\d{2}\.\d{2}))?',text):
        a,b=m.groups()
        if b and (a[:8]!=b[:8] or a>b):raise ValueError('Unreviewed Section 338 heading range')
        result += [a] if not b else [a[:8]+f'{i:02}' for i in range(int(a[-2:]),int(b[-2:])+1)]
    vehicle=re.search(r'(9903\.\d{2}\.\d{2}) \(as\s+applied to the U\.S\. content',text)
    parts=re.search(r'(9903\.\d{2}\.\d{2}) \(as applied to parts.*?knock-down kits or parts compilations\)',text,re.S)
    if not vehicle or not parts:raise ValueError('Unreviewed Section 338 qualified interaction')
    return dict(all=sorted(set(result)),vehicle=vehicle[1],parts=parts[1])


def compile_rules(revision, products):
    x=extract();ids=[s['id'] for s in x['sources']]
    hts_path=ROOT/f'data/hts_archives/hts_{revision}.json'
    hts=json.loads(hts_path.read_bytes());hid='USITC-'+revision+'-s338-classification'
    digest=sha(hts_path.read_bytes());ids.append(hid)
    x['sources'].append(dict(id=hid,status='verified',sha256=digest,
        url='https://hts.usitc.gov/reststop/exportList?release='+revision.replace('_rev_','HTSRev')+'&exportFormat=JSON',
        citation='Revision-valid ordinary and Chapter 98 classifications; not a substitute for original action chronology'))
    x['source_artifacts'].append(dict(source_id=hid,path=str(hts_path),sha256=digest))
    snapshot=reconcile_snapshot(x,revision,hts)
    if snapshot:
        id='USITC-'+revision+'-s338-note51';ids.append(id)
        x['sources'].append(dict(id=id,status='verified',sha256=snapshot['sha256'],
            url='https://hts.usitc.gov/reststop/file?release='+revision.replace('_rev_','HTSRev')+'&filename=Chapter%2099',
            citation='Note 51 codified scope and conditions reconciled with original annexes. Original sources control effective instants.'))
        x['source_artifacts'].append(dict(source_id=id,path=snapshot['path'],sha256=snapshot['sha256']))
    country=next(r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open()) if r['Name']=='Canada')
    rules=[];facts={}
    def f(name,label,kind='boolean',description=None,choices=None):
        d=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':d.update(minimum=0,unit='USD')
        if description:d['description']=description
        if choices is not None:d['enum']=choices
        facts[name]=d;return fact(name)
    f('s338_ftz_entry','Entry from a foreign trade zone')
    cv=f('customs_value','Customs value (USD)','number')
    claimed=f('s338_chapter98_claimed','Entry claimed under Chapter 98')
    valuation=compile_valuation(x['general_note'],hts,f,claimed,cv)
    refs=interaction_codes(x['interaction']['text'])
    def reported(codes,exclude=False):
        return {'reporting_predicate':dict(authority='section_232',codes=codes,positive_duty=False,exclude=exclude)}
    def emit(action,scope,path,code,formula=val(0),constraints=None):
        r=dict(id='s338_'+revision+'_'+str(len(rules)),action_id='section338_'+action['program'],authority='section_338',
            kind='duty',verification='verified',scope=scope,when=path,formula=formula,
            reporting_codes=[code] if code else [],source_ids=ids)
        if constraints:r['input_constraints']=constraints
        rules.append(r)
    def matches(product,entries):return any(product==c or (len(c)==8 and product.startswith(c)) for c in entries)
    products=sorted(set(products))
    if any(not re.fullmatch(r'\d{10}',p) for p in products):raise ValueError('Exact HTS10 required')
    valid={r['htsno'].replace('.','') for r in hts if 'htsno' in r}
    if not set(products)<=valid:raise ValueError('Product not valid in requested source revision')
    for action in periods(x):
      for aircraft_member in (True,False):
        ps=[p for p in products if matches(p,action['products']) and matches(p,x['aircraft']['products'])==aircraft_member]
        if not ps:continue
        scope=dict(hts_exact=ps,countries=[country],**{'from':action['from_'],'until':action['until']})
        path=val(True)
        def branch(test,code,formula=val(0),constraints=None):
            nonlocal path
            emit(action,scope,op('if',path,test,val(False)),code,formula,constraints)
            path=op('if',path,negate(test),val(False))
        branch(f('s338_personal_baggage','For personal use in accompanied baggage of a person arriving in the United States'),None)
        if aircraft_member:
            branch(f('s338_civil_aircraft_gn6','Civil aircraft article meeting General Note 6, excluding military and unmanned aircraft',description=x['aircraft']['text'].split(':')[0]),x['aircraft']['reporting_code'])
        branch(valuation['exempt'],None,constraints=valuation['constraints'])
        # The four adjusted-value Chapter 98 provisions are also in note 51(d).
        # A qualifying aircraft claim must not lose that separate exemption.
        if not aircraft_member:
            is_aircraft_98=both(valuation['adjusted'],f('s338_civil_aircraft_gn6','Civil aircraft article meeting General Note 6, excluding military and unmanned aircraft'))
            branch(is_aircraft_98,x['aircraft']['reporting_code'],constraints=valuation['constraints'])
        branch(f('s338_ftz_entry','Entry from a foreign trade zone'),None,
               {'unresolved_source':'section338_ftz_admission_status_and_classification_not_compiled'})
        constraints=list(valuation['constraints']);basis=valuation['basis']
        if action['s232_exempt']:
            whole=reported([c for c in refs['all'] if c not in (refs['vehicle'],refs['parts'])])
            qualified_parts=both(reported([refs['parts']]),f('s338_usmca_auto_parts_not_kits',
                'USMCA-eligible passenger-vehicle/light-truck parts, excluding knock-down kits and parts compilations'))
            branch(either(whole,qualified_parts),x['interaction']['reporting_code'])
            vehicle=both(reported([refs['vehicle']]),f('s338_commerce_approved_us_vehicle_content','Commerce-approved U.S. content under note 33(d)'))
            us=f('s338_vehicle_us_content_value','Commerce-approved U.S. vehicle content value (USD)','number')
            excluded=op('if',vehicle,us,val(0))
            constraints.append(dict(test=op('lte',excluded,cv),inputs=['s338_vehicle_us_content_value','customs_value'],label='Approved U.S. content cannot exceed vehicle value'))
            overlap,constraint=overlap_value(valuation,excluded,cv,f,'s338');constraints.append(constraint)
            basis=op('subtract',basis,overlap)
            branch(reported(refs['all'],exclude=True),None,
                   {'unresolved_source':'section338_unlisted_section232_decision_requires_original_annex_reconciliation'})
            branch(both({'authority_covered':'section_232'},op('eq',basis,val(0))),x['interaction']['reporting_code'],constraints=constraints)
            emit(action,scope,both(path,{'authority_covered':'section_232'},op('gt',overlap,val(0))),x['interaction']['reporting_code'],constraints=constraints)
            amount=op('if',{'authority_covered':'section_232'},op('multiply',val(action['rate']),basis),val(0))
        else:
            # September removed this exception for this action. No 232 fact or
            # inventory is needed to compute its independently additive amount.
            amount=op('multiply',val(action['rate']),basis)
        emit(action,scope,path,action['heading'],amount,constraints)
    rule_ids=[r['id'] for r in rules]
    unchanged=[]
    if rule_ids:
        unchanged=[dict(id='s338_'+revision+'_301_independent',claim_authority='section_301',candidate_required_fields=['exclusion_claim_id'],target_rule_ids=rule_ids,source_ids=ids),
          dict(id='s338_'+revision+'_232_reevaluate',effect='reevaluate',claim_authority='section_232',candidate_required_fields=['grant_id','grant_snapshot_id'],target_rule_ids=rule_ids,source_ids=ids)]
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='section338_'+revision,
        compiler_sha256=sha(Path(__file__).read_bytes()),
        compiler_dependencies={p:sha((ROOT/p).read_bytes()) for p in ('src/section338_sources.py','src/chapter98_rules.py','src/section232_note16_rules.py','src/section301_sources.py','resources/legal_evidence/section338/manifest.json','resources/census_codes.csv')},
        sources=x['sources'],source_artifacts=x['source_artifacts'],rules=rules,coverage=[],fact_definitions=facts,
        entry_context=dict(mode='ordinary_only',fact='s338_ftz_entry',source_ids=ids,
            unresolved_source='section338_ftz_admission_status_and_classification_not_compiled'),
        claim_definitions=[dict(id=c,label=label,rule_ids=rule_ids,source_ids=ids) for c,label in [('USMCA','USMCA'),('CHAPTER_98','Chapter 98')]] if rule_ids else [],
        relations=[],unchanged_claims=unchanged,supported_from='2025-01-01T00:00:00-05:00',supported_until='2026-10-23T00:00:00-04:00',
        action_history=periods(x),snapshot_reconciliation=snapshot,limitations=['No complete all-action authority coverage attestation.',
            'FTZ admission status/classification and unlisted Section 232 offset decisions require separate rules. Chapter 98 entitlement is an explicit shipment evidence predicate.'])


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('input');p.add_argument('output');a=p.parse_args()
    Path(a.output).write_text(json.dumps(compile_rules(**json.loads(Path(a.input).read_bytes())),separators=(',',':'))+'\n')

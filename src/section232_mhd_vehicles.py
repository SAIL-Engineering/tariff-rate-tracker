"""Original MHD vehicle/bus duties, approved content and historical precedence.

Vehicle duties are not parts duties or utilization-weighted estimates. Original
annex tables select reporting roles; dates and amendments are source-bound.
"""
from __future__ import annotations
import argparse
import copy
import csv
from datetime import datetime
from functools import lru_cache
import json
from pathlib import Path
import re

from section232_mhd_parts import ROOT,EVIDENCE,add_source,semantic,product_table,exclusion_clause,signature,extract as parts_extract,load_history as parts_history
from section232_stacking import reporting_codes
from section232_note16_rules import val,fact,op,both,either,negate
from section301_sources import unique_span,sha
from shipment_vehicle_calendar import boundaries,vintage
from ieepa_fentanyl_sources import windows


@lru_cache(maxsize=1)
def load_history():
    common=parts_history();sources=copy.deepcopy(common['sources']);artifacts=copy.deepcopy(common['source_artifacts'])
    original=common['vehicle_review']
    guidance={key:add_source(json.loads((EVIDENCE/name).read_bytes()),sources,artifacts) for key,name in [
        ('initial','CBP-CSMS-66665333.source.json'),('content','CBP-CSMS-68559236.source.json'),('procedure','FR-2026-02049.source.json')]}
    procedure=' '.join(guidance['procedure'].split());content_text=' '.join(guidance['content'].split())
    eligible_exports=re.search(r'Only MHDVs imported from ([A-Za-z ]+) and ([A-Za-z ]+) that qualify',procedure)
    if not eligible_exports or not all(s in procedure for s in ('If retroactive treatment is requested',
        'the entry numbers of the previously imported MHDVs subject to any retroactive treatment',
        'country of origin, and model of each authorized MHDV')):raise ValueError('Unreviewed MHD approval scope or retroactive authorization')
    if guidance['initial'].count('UNTIL FURTHER GUIDANCE IS PROVIDED')!=2 or 'Related Message Number(s): 66665333' not in content_text or \
        'Report Special Program Indicator (SPI) code “S”' not in content_text or windows(content_text)['valid_from']!=common['from_']:
        raise ValueError('MHD filing guidance and retroactive legal commencement do not reconcile')
    if 'Report the value of the non-U.S. content approved by the Commerce Department for entered value' not in content_text:
        raise ValueError('Unreviewed MHD authorized value/reporting basis')
    roster=list(csv.DictReader((ROOT/'resources/census_codes.csv').open()))
    def country(name):
        matches=[r['Code'] for r in roster if r['Name']==name]
        if len(matches)!=1:raise ValueError('Unresolved MHD import-from country '+name)
        return matches[0]
    clauses=original['clauses'];scopes={sector:product_table(clauses[k]) for sector,k in [('vehicles','b'),('buses','c')]}
    def role(k):
        match=re.search(r'(?:Heading|heading) (9903\.\d{2}\.\d{2}) (?:applies|apply)',clauses[k])
        if not match:raise ValueError('Missing original MHD vehicle reporting role')
        return match[1]
    roles={k:role(v) for k,v in [('vehicles','b'),('buses','c'),('non_us','d'),('non_vehicle','e'),('us','f'),('vintage','g')]}
    table={r['htsno']:r for r in original['headings']};rates={}
    for sector in ('vehicles','buses'):
        row=table[roles[sector]]
        values=[re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*([\d.]+)%\.?',row[k]) for k in ('general','special','other')]
        if any(not v for v in values) or len({v[1] for v in values})!=1:raise ValueError('Unreconciled original MHD vehicle duty columns')
        rates[sector]=float(values[0][1])/100
    for key in ('non_vehicle','us','vintage'):
        if any(semantic(table[roles[key]][k])!=semantic('The duty provided in the applicable subheading') for k in ('general','special','other')):
            raise ValueError('Unreviewed MHD vehicle reporting-only role')
    content=table[roles['non_us']]
    if any(semantic(content[k])!=semantic('The duty provided in the applicable subheading + a duty of '+f'{rates["vehicles"]*100:g}'+'% upon the value of the non-U.S. content') for k in ('general','special')) or semantic(content['other'])!=semantic('No change'):
        raise ValueError('Unreconciled original MHD non-US content columns')
    age=re.search(r'manufactured in a year at least (\d+) years prior to the year of the date of entry',clauses['g'])
    if not age:raise ValueError('Unparsed MHD manufacture-year exemption')
    body=Path(next(a['path'] for a in artifacts if a['source_id']=='FR-2025-19639')).read_text();flat=' '.join(body.split())
    if f'{rates["vehicles"]*100:g} percent ad valorem duty rate' not in flat or f'{rates["buses"]*100:g} percent ad valorem duty rate' not in flat:
        raise ValueError('Original MHD proclamation and annex rate disagreement')
    sanction=' '.join(unique_span(body,r'^\(6\)',r'^\(7\)').split())
    if not all(s in sanction for s in ('shall apply to the full value of the MHDV','regardless of the actual United States content',
        'same model imported by the same importer or responsible party','from the date of the inaccurate declaration until compliance is verified by CBP')):
        raise ValueError('Unreviewed MHD CBP overstatement treatment')
    retirement=' '.join(unique_span(body,r'^\(10\)',r'^\(11\)').split())
    if 'buses and other vehicles classified in HTSUS heading 8702' not in retirement or f'at least {age[1]} years' not in retirement:
        raise ValueError('Original MHD bus/vehicle age exemption does not reconcile')
    # Original note38(a) has the same seven metal/emergency exceptions as the
    # parts clause, without its additional timber row. April8(a), April23(8)
    # and June AnnexIV replay the same metal replacement operations for a/h.
    first=exclusion_clause(clauses['a'])
    common_rows=common['periods'][0]['clause']['rows']
    # A final list member has no conjunction, while the penultimate member
    # ends in "; and". Ignore only that list separator, not words in a rule.
    row_semantic=lambda r:semantic(re.sub(r';?\s+and$', '',r))
    if [row_semantic(r) for r in first['rows']]!=[row_semantic(r) for r in common_rows[:-1]]:
        raise ValueError('Original MHD vehicle/part exception relationship changed')
    proof=EVIDENCE/'april-mhd-vehicles-source.json'
    april_meta=json.loads(proof.read_bytes());april=add_source(april_meta,sources,artifacts)
    if not all(s in april for s in ('deleting subdivisions (1) through (5)','renumbering subdivisions (6) through (7) as (2) through (3)',
        '9903.82.02 and 9903.82.04–9903.82.17')):raise ValueError('Unreviewed original April vehicle replacement')
    periods=[]
    for p in common['periods']:
        rows=[r for r in p['clause']['rows'] if 'wood products' not in r]
        periods.append(dict(from_=p['from_'],until=p['until'],clause=dict(prefix=first['prefix'],rows=rows),
            targets=sorted({c for r in rows for c in reporting_codes(r)})))
    return dict(from_=common['from_'],until=common['until'],clauses=clauses,scopes=scopes,roles=roles,rates=rates,
        age_years=int(age[1]),headings=original['headings'],periods=periods,sources=sources,source_artifacts=artifacts,
        content_origin_countries=sorted(country(n) for n in eligible_exports.groups()),
        content_guidance=dict(retroactive_from=windows(content_text)['valid_from'],source_id='CBP-CSMS-68559236',
            approval_scope='Commerce-authorized importer/model and entry, including expressly approved retrospective entries'))


def extract(revision):
    x=parts_extract(revision);x.pop('integrity')
    # parts_extract already validates native note38 presence, part exclusions,
    # code hierarchy and primary provenance. Extend that same evidence object.
    h=load_history();c=x['clauses']
    if c:
        for k in 'bcdefg':
            if semantic(c.get(k,''))!=semantic(h['clauses'][k]):raise ValueError('Unreviewed MHD vehicle '+k+' scope/claim semantics')
        now=exclusion_clause(c['a'])
        row_semantic=lambda r:semantic(re.sub(r';?\s+and$', '',r))
        if not any(semantic(now['prefix'])==semantic(p['clause']['prefix']) and
            [row_semantic(r) for r in now['rows']]==[row_semantic(r) for r in p['clause']['rows']] for p in h['periods']):
            raise ValueError('Unreconciled MHD vehicle stacking amendment')
        rows={r['htsno']:r for r in x['headings']}
        for r in h['headings']:
            if r['htsno'] not in rows or any(semantic(rows[r['htsno']][k])!=semantic(r[k]) for k in ('description','general','special','other')):
                raise ValueError('MHD vehicle native reporting expression changed')
    x['reconciliation']='original_vehicle_annex_and_amendments_reconciled' if c else 'pre_action_native_snapshot'
    x['integrity']=signature(x);return x


def compile_rules(x,products,jurisdictions=None,jurisdiction_source=None):
    copied=copy.deepcopy(x);integrity=copied.pop('integrity',None)
    if integrity!=signature(copied):raise ValueError('MHD vehicle evidence changed after reconciliation')
    if set(products)-set(x['products']):raise ValueError('MHD vehicle product outside native source')
    h=load_history();sources=copy.deepcopy(h['sources']);artifacts=copy.deepcopy(h['source_artifacts'])
    for s in x['sources']:add_source(s,sources,artifacts)
    if jurisdictions is not None:
        if not jurisdiction_source or not jurisdictions.get('all') or not set(jurisdictions.get('non_ntr',[]))<=set(jurisdictions['all']):
            raise ValueError('MHD country inventory needs primary GN3 evidence')
        add_source(dict(id='USITC-'+x['revision']+'-mhd-gn3',**jurisdiction_source),sources,artifacts)
    ids=[s['id'] for s in sources];facts={};rules=[];relations=[]
    def f(name,label,kind='boolean',choices=None):
        d=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':d['minimum']=0
        if choices:d['enum']=choices
        facts[name]=d;return fact(name)
    cv=f('customs_value','Full article customs value (USD)','number');facts['customs_value']['unit']='USD'
    use=f('s232_mhd_vehicle','Article is a medium- or heavy-duty vehicle under the matched original action')
    auto=f('s232_auto_passenger_vehicle','Article is a passenger vehicle or light truck as defined by U.S. note33(a)')
    manufactured=f('s232_mhd_manufacture_year','Actual vehicle manufacture calendar year','number',list(range(1,datetime.fromisoformat(h['until']).year+1)))
    year=f('s232_mhd_entry_calendar_year','Calendar year on the actual CBP entry record','number',list(range(datetime.fromisoformat(h['from_']).year,datetime.fromisoformat(h['until']).year+1)))
    eligible=f('usmca_origin_eligible','Qualifies under General Note 11')
    properly=f('usmca_properly_claimed','USMCA treatment properly claimed for this entry')
    approved=f('s232_mhd_commerce_us_content_approved','Commerce importer/model authorization covers this entry, including any expressly approved retroactive entry number')
    non_us=f('s232_mhd_non_us_content_value','Commerce-authorized non-U.S. content entered value for this model/entry (USD)','number');facts['s232_mhd_non_us_content_value']['unit']='USD'
    finding=f('s232_mhd_cbp_overstatement_applies','The clause6 CBP overstatement determination applies to this model/importer and entry, before compliance was verified')
    f('ieepa_ftz_entry','Entry from a foreign trade zone')
    proper=f('chapter98_properly_claimed','Entry properly claimed under the selected Chapter98 provision')
    ch98=f('chapter98_provision','Chapter98 provision (eight digits)','string',x['chapter98_provisions'])
    full=re.search(r'except that duties under subheading (9802\.\d{2}\.\d{2}) shall be assessed based upon the full value',h['clauses']['a'])
    if not full:raise ValueError('Missing MHD Chapter98 full-value exception')
    ch98_ok=op('if',{'claim':'CHAPTER_98'},op('if',proper,op('if',op('eq',ch98,val(full[1].replace('.',''))),val(True),
        {'unresolved_source':'mhd_vehicle_chapter98_selected_provision_terms_and_valuation'}),{'unresolved_source':'mhd_vehicle_chapter98_entitlement'}),val(True))
    selected={'claim':'SECTION_232_MHD_US_CONTENT'}
    content_ok=op('if',selected,op('if',eligible,op('if',properly,approved,val(False)),val(False)),val(False))
    checks=[dict(test=op('lte',non_us,cv),inputs=['s232_mhd_non_us_content_value','customs_value'],label='Authorized non-U.S. entered value cannot exceed full vehicle value')]
    memberships={}
    def emit(sector,ps,scope,role,when,formula,subject,checks_=None):
        rid=f'mhd_vehicle_{x["revision"]}_{len(rules)}'
        r=dict(id=rid,action_id='s232_mhd_'+sector,authority='section_232',kind='duty',verification='verified',scope=scope,
            when=when,formula=formula,reporting_codes=[h['roles'][role]],source_ids=ids,
            legal_locator='Proclamation10984 clauses1,2,6,8-10; original note38(a)-(g); Commerce2026-02049 sectionsII-IV; CBP68559236; operative metal amendments')
        all_checks=classification_checks+list(checks_ or [])
        if all_checks:r['input_constraints']=all_checks
        if not subject and formula==val(0):r['reporting_only']=True
        rules.append(r)
        if subject:
            period=next(p for p in h['periods'] if p['from_']<=scope['from']<p['until'])
            relations.append(dict(id=rid+'_source_nonstacking',effect='suppress',when_rule_applies=rid,
                trigger_test='applicability',target_reporting_codes=period['targets'],source_ids=ids))
            if x['russian_reporting_codes']:relations.append(dict(id=rid+'_russian_aluminum_nonstacking',effect='suppress',when_rule_applies=rid,
                trigger_test='applicability',target_reporting_codes=x['russian_reporting_codes'],source_ids=ids))
    for sector in ('vehicles','buses'):
        members=sorted({p for p in products if any(p.startswith(a) for a in h['scopes'][sector])});memberships[sector]=members
        if not members:continue
        country_groups=[(None,None,None)] if jurisdictions is None else [
            (column2,origin_eligible,sorted(group & (set(h['content_origin_countries']) if origin_eligible else set(jurisdictions['all'])-set(h['content_origin_countries']))))
            for column2,group in [(False,set(jurisdictions['all'])-set(jurisdictions.get('non_ntr',[]))),
                (True,set(jurisdictions.get('non_ntr',[])))] for origin_eligible in (False,True)]
        bounds=sorted({h['from_'],h['until']}|{p['from_'] for p in h['periods']}|set(boundaries(h['from_'],h['until'])))
        for start,end,column2,origin_eligible,origins,possible_auto in ((a,b,c,e,o,k) for a,b in zip(bounds,bounds[1:]) for c,e,o in country_groups if o is None or o for k in (False,True)):
            ps=[p for p in members if (sector=='vehicles' and any(p.startswith(a) for a in x['auto_vehicle_scope']))==possible_auto]
            if not ps:continue
            classification_checks=[dict(test=negate(both(auto,use)),inputs=['s232_auto_passenger_vehicle','s232_mhd_vehicle'],
                label='Actual passenger/light and medium/heavy vehicle identities cannot both apply')] if possible_auto else []
            scope=dict(hts_exact=ps,**{'from':start,'until':end})
            if origins is not None:scope['countries']=origins
            actual=use if sector=='vehicles' else val(True)
            old=vintage(manufactured,year,start,h['age_years'],'invalid_fact_s232_mhd_manufacture_year_after_entry_year')
            active=op('if',actual,negate(old),val(False))
            if sector=='vehicles':emit(sector,ps,scope,'non_vehicle',negate(actual),val(0),False)
            emit(sector,ps,scope,'vintage',op('if',actual,old,val(False)),val(0),False)
            basis=op('multiply',cv,val(h['rates'][sector]))
            if sector=='buses':emit(sector,ps,scope,'buses',both(active,ch98_ok),basis,True);continue
            # The printed Column2 "No change" does not replace the ordinary
            # full-value charge with the Column1 approved-content expression.
            # Direct callers without the GN3 inventory may price ordinary
            # entries, but cannot establish content relief from missing data.
            relief=(val(False) if column2 is True or origin_eligible is False else content_ok if column2 is False else
                op('if',selected,{'unresolved_source':'mhd_vehicle_column2_country_inventory'},val(False)))
            ordinary=op('if',relief,finding,val(True))
            emit(sector,ps,scope,'vehicles',both(active,ordinary,ch98_ok),basis,True)
            content=op('if',both(active,relief),both(negate(finding),ch98_ok),val(False))
            emit(sector,ps,scope,'non_us',content,op('multiply',non_us,val(h['rates'][sector])),True,checks)
            emit(sector,ps,scope,'us',content,val(0),False,checks)
    rids=[r['id'] for r in rules]
    cids=[r['id'] for r in rules if r['action_id']=='s232_mhd_vehicles']
    eligible_ids=[r['id'] for r in rules if r['action_id']=='s232_mhd_vehicles' and not r.get('reporting_only') and
        set(r['scope'].get('countries',[])) & set(h['content_origin_countries'])]
    claim_defs=[dict(id=c,label=l,rule_ids=rids,source_ids=ids) for c,l in [('USMCA','USMCA'),('COLUMN1_SPECIAL','Selected Column 1 Special preference'),('CHAPTER_98','Chapter 98')]] if rules else []
    if cids:claim_defs.append(dict(id='SECTION_232_MHD_US_CONTENT',label='Commerce-approved MHD vehicle U.S. content',rule_ids=rids,candidate_rule_ids=eligible_ids,source_ids=ids))
    unchanged=[dict(id='mhd_vehicles_section301_independence',claim_authority='section_301',candidate_required_fields=['exclusion_claim_id'],target_rule_ids=rids,source_ids=ids)] if rules else []
    if cids:unchanged.append(dict(id='mhd_vehicle_content_reevaluation',effect='reevaluate',claim_authority='section_232',claim_ids=['SECTION_232_MHD_US_CONTENT'],
        target_authorities=['base','section_201','section_232','section_301','ieepa_fentanyl','ieepa_reciprocal','ieepa_other','section_122','section_338','adcvd','other_chapter99'],source_ids=ids))
    return dict(contract_version='sail.shipment-rule-fragment/v2',required_compiler_features=['claim_implications'],id='s232_mhd_vehicles_'+x['revision'],supported_from='2025-01-01T00:00:00-05:00',supported_until=h['until'],
        compiler_sha256=sha(Path(__file__).read_bytes()),sources=sources,source_artifacts=artifacts,rules=rules,relations=relations,coverage=[],fact_definitions=facts,claim_definitions=claim_defs,unchanged_claims=unchanged,
        claim_implications=([dict(id='mhd_approved_content_requires_spi_s',claim_id='SECTION_232_MHD_US_CONTENT',implies='USMCA',
            activation_rule_ids=eligible_ids,source_ids=['CBP-CSMS-68559236'])] if cids else []),
        content_guidance=h['content_guidance'],
        entry_context=dict(mode='ordinary_only',fact='ieepa_ftz_entry',source_ids=ids,unresolved_source='mhd_vehicle_ftz_admission_status_classification_and_rate_history'),
        candidate_memberships=memberships,
        candidate_scope_matches={kind:[dict(hts10=p,scope_code=prefix,scope_grain='exact_hts10' if len(prefix)==10 else 'prefix')
            for p in ps for prefix in h['scopes'][kind] if p.startswith(prefix)] for kind,ps in memberships.items()},
        snapshot_reconciliation=x['reconciliation'],
        limitations=['No full Section232 inventory attestation. Non-full-value Chapter98 and privileged FTZ histories remain separately uncompiled.'])


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    a=p.parse_args();x=json.loads(Path(a.input).read_bytes());Path(a.output).write_text(json.dumps(compile_rules(extract(x['revision']),x['products'],x.get('jurisdictions'),x.get('jurisdiction_source')),separators=(',',':'))+'\n')

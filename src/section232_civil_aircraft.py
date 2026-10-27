"""Civil-aircraft agreements are independent Section232 actions.

Original scopes and deletion/insertion operands supply the reporting history.
The end of reciprocal collection cannot expire a separate metal concession.
"""
from __future__ import annotations
import argparse,json,re
from datetime import datetime
from pathlib import Path
from ieepa_fentanyl_sources import ROOT
from ieepa_reciprocal_initial import uk_aircraft_history
from ieepa_reciprocal_august import load_august_country_policy
from ieepa_reciprocal_later import partner_history,entry_instant,flat
from ieepa_emergency_rules import revision_window
from section232_stacking import reporting_codes
from section232_note16_rules import val,fact,op
from section301_sources import sha,unique_span


def load_evidence(metadata=None):
    directory=ROOT/'resources/legal_evidence/section232/civil-aircraft'
    meta=metadata if metadata is not None else json.loads((directory/'sources.json').read_bytes())
    if meta['contract_version']!='sail.civil-aircraft-evidence/v1':raise ValueError('Unsupported aircraft evidence')
    sources={};texts={}
    for s in meta['sources']:
        p=ROOT/s['path']
        if sha(p.read_bytes())!=s['sha256']:raise ValueError('Aircraft evidence hash mismatch')
        role=s.get('role')
        if role not in ('proclamation_body','annex_transcription'):raise ValueError('Unreviewed aircraft evidence role')
        if role in texts and texts[role]!=p.read_text():raise ValueError('Conflicting aircraft evidence roles')
        record=dict(s,path=str(p.resolve()))
        if s['id'] in sources and sources[s['id']]!=record:raise ValueError('Conflicting aircraft evidence identities')
        sources[s['id']]=record;texts[role]=p.read_text()
    if set(texts)!= {'proclamation_body','annex_transcription'}:raise ValueError('Incomplete aircraft evidence roles')
    pdf=ROOT/meta['pdf_path']
    if sha(pdf.read_bytes())!=meta['pdf_sha256']:raise ValueError('Aircraft original PDF changed')
    sources['FR-2026-06960-aircraft-original-pdf']=dict(id='FR-2026-06960-aircraft-original-pdf',path=str(pdf),sha256=meta['pdf_sha256'],
        url='https://www.govinfo.gov/content/pkg/FR-2026-04-09/pdf/2026-06960.pdf',
        citation='Original Proclamation11021 PDF, clause10 and AnnexIV A(3), A(6); reviewed against pages60,61,64')
    return dict(body=texts['proclamation_body'],annex=texts['annex_transcription'],sources=[sources[id] for id in sorted(sources)])


def amendment_operations(text):
    """Account for every printed deletion/insertion, without rate selection."""
    text=flat(text)
    pattern=r'([ab])\. deleting from subdivision (\([a-z]+\)(?:\([a-z]+\))?) “([^”]+)” and inserting “([^”]+)” in lieu thereof'
    matches=list(re.finditer(pattern,text))
    if not matches or len(matches)!=len(re.findall('deleting from subdivision',text)):
        raise ValueError('Unaccounted aircraft amendment operands')
    out=[]
    def codes(t):
        result=reporting_codes(t)
        rest=re.sub(r'9903\.\d{2}\.\d{2}(?:\s*[-–—]\s*9903\.\d{2}\.\d{2})?','',t)
        if not result or re.sub(r'headings?|\band\b|[\s,]','',rest):raise ValueError('Unreviewed aircraft replacement grammar')
        return result
    for m in matches:
        header=list(re.finditer(r'U\.S\. note (\d+)(\([a-z]+\))? is modified by:',text[:m.start()]))
        if not header:raise ValueError('Missing aircraft amendment target note')
        h=header[-1];locator='note'+h[1]+(h[2] or '')+m[2]
        out.append(dict(locator=locator,old_codes=codes(m[3]),new_codes=codes(m[4]),clause_sha256=sha(m[0].encode())))
    # Duplicate operands from different notes must agree. Do not pick one of
    # two inconsistent replacements just because it appears later in a file.
    seen={}
    for r in out:
        key=tuple(r['old_codes']);value=tuple(r['new_codes'])
        if key in seen and seen[key]!=value:raise ValueError('Conflicting aircraft source replacements')
        seen[key]=value
    return out


def load_history():
    evidence=load_evidence();body=flat(evidence['body'])
    preserved=unique_span(body,r'\(10\) This proclamation',r'\(11\)')
    if not all(s in preserved for s in ('does not alter or supersede','section 232','Agreement on Trade in Civil Aircraft')):
        raise ValueError('Unreviewed preservation of prior aircraft agreements')
    at=entry_instant(unique_span(body,r'\(1\) Effective',r'\(2\)'))
    operations=amendment_operations(evidence['annex'])
    uk,uk_source=uk_aircraft_history()
    country=re.search(r'of the ([^,]+), that otherwise',uk['condition_text'])
    if not country:raise ValueError('Unresolved original UK aircraft origin')
    actions=[dict(reporting_code=uk['reporting_code'],country_text=country[1],from_=uk['from_'],products=uk['products'],
        fact='uk_civil_aircraft_gn6',condition_text=uk['condition_text'],original_targets=uk['removed_codes'],source_ids=[uk['source_id']])]
    august=load_august_country_policy();partners=partner_history(august)
    reciprocal_codes={c for a in august['actions']+partners['country_amendments'] for c in a['reporting_codes']}
    reciprocal_codes.add(august['baseline']['reporting_code'])
    other_relief=[]
    for a in partners['exemptions']:
        if a['condition']!='civil_aircraft_gn6_excluding_unmanned':continue
        if set(a['removed_reporting_codes'])<=reciprocal_codes:
            # Some partner aircraft concessions remove only reciprocal duty.
            # A shared GN6 condition does not establish Section232 relief.
            other_relief.append(dict(reporting_code=a['reporting_code'],country_text=a['country_text'],
                target_reporting_codes=a['removed_reporting_codes'],source_ids=a['source_ids'],
                determination='reciprocal_relief_only_no_section232_concession_in_this_clause'))
            continue
        actions.append(dict(reporting_code=a['reporting_code'],country_text=a['country_text'],from_=a['from_'],products=a['products'],
            fact='reciprocal_partner_civil_aircraft_gn6_excluding_unmanned',condition_text=a['condition_text'],
            original_targets=a['removed_reporting_codes'],source_ids=a['source_ids']))
    audit=json.loads((ROOT/'resources/shipment_rules/build_contract.json').read_bytes())
    modern_ids=[s['id'] for s in evidence['sources']]
    for a in actions:
        original=set(a['original_targets'])
        compatible=[r for r in operations if set(r['old_codes'])<=original]
        if not compatible:raise ValueError('Unreconciled preserved aircraft agreement: '+a['reporting_code'])
        outcomes={tuple(sorted((original-set(r['old_codes']))|set(r['new_codes']))) for r in compatible}
        if len(outcomes)!=1:raise ValueError('Conflicting applicable aircraft amendment operands')
        if datetime.fromisoformat(a['from_'])>=datetime.fromisoformat(at):raise ValueError('Aircraft agreement requires a later amendment chronology')
        a['periods']=[dict(from_=a['from_'],until=at,target_reporting_codes=sorted(original),source_ids=a['source_ids']),
            dict(from_=at,until=audit['audit_until'],target_reporting_codes=list(outcomes.pop()),
                 source_ids=sorted(set(a['source_ids']+modern_ids)),amendment_locators=sorted({r['locator'] for r in compatible}))]
    wanted={i for a in actions+other_relief for i in a['source_ids']}
    sources=[s for s in [uk_source,*partners['sources']] if s['id'] in wanted]+evidence['sources']
    return dict(contract_version='sail.section232-civil-aircraft-history/v1',actions=actions,modern_from=at,
        audit_from=audit['audit_from'],audit_until=audit['audit_until'],sources=sources,amendment_operations=operations,
        other_authority_relief=other_relief)


def compile_rules(revision_id,products,jurisdictions,jurisdiction_sources=None):
    h=load_history();start,end=revision_window(revision_id);end=min([end,h['audit_until']],key=datetime.fromisoformat)
    if any(not re.fullmatch(r'\d{10}',p) for p in products):raise ValueError('Exact aircraft HTS10 identities required')
    countries={}
    for a in h['actions']:
        found=jurisdictions.get(a['reporting_code'])
        if not found or any(not isinstance(c,str) or not re.fullmatch(r'\d{4}',c) for c in found):
            raise ValueError('Unresolved aircraft agreement origin: '+a['country_text'])
        countries[a['reporting_code']]=sorted(set(found))
    sources=list(h['sources'])+list(jurisdiction_sources or [])
    for s in sources:
        if sha(Path(s['path']).read_bytes())!=s['sha256']:raise ValueError('Aircraft compiler source changed')
    ids=sorted({s['id'] for s in sources});facts={};rules=[];relations=[]
    for a in h['actions']:
        if any(not re.fullmatch(r'\d{8}(?:\d{2})?',prefix) for prefix in a['products']):
            raise ValueError('Unreviewed aircraft product scope grain')
        scope8={p for p in a['products'] if len(p)==8};scope10={p for p in a['products'] if len(p)==10}
        selected=sorted({p for p in products if p[:8] in scope8 or p in scope10})
        if not selected:continue
        facts[a['fact']]=dict(type='boolean',label=('UK civil aircraft under General Note6' if a['fact']=='uk_civil_aircraft_gn6' else
            'Civil aircraft under General Note6, excluding military and unmanned aircraft'),source_ids=ids)
        for i,period in enumerate(a['periods']):
            id='s232_civil_aircraft_'+a['reporting_code'].replace('.','')+'_'+str(i)
            # Ordinary-entry relief is verified. Privileged FTZ admission/rate
            # history is a separate path, never an assumed current-date waiver.
            when=op('if',fact(a['fact']),op('if',fact('ieepa_ftz_entry'),
                {'unresolved_source':'civil_aircraft_ftz_admission_and_agreement_history'},val(True)),val(False))
            rules.append(dict(id=id,action_id='s232_civil_aircraft_'+a['reporting_code'].replace('.',''),authority='section_232',
                kind='duty',verification='verified',reporting_only=True,formula=val(0),when=when,
                scope=dict(hts_exact=selected,countries=countries[a['reporting_code']],**{'from':period['from_'],'until':period['until']}),
                reporting_codes=[a['reporting_code']],source_ids=sorted(set(period['source_ids']+[s['id'] for s in jurisdiction_sources or []])),
                legal_locator='Original civil-aircraft agreement '+a['reporting_code']+'; '+', '.join(period.get('amendment_locators',[])),
                source_condition=dict(text=a['condition_text'],sha256=sha(a['condition_text'].encode()),source_ids=a['source_ids'])))
            relations.append(dict(id=id+'_metal_relief',effect='suppress',when_rule_applies=id,target_authority='section_232',
                target_reporting_codes=period['target_reporting_codes'],source_ids=period['source_ids']))
    if rules:facts['ieepa_ftz_entry']=dict(type='boolean',label='Entry withdrawn from a U.S. foreign-trade zone',source_ids=ids)
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='s232_civil_aircraft_'+revision_id,
        supported_from=start,supported_until=end,compiler_sha256=sha(Path(__file__).read_bytes()),
        compiler_dependencies={p:sha((ROOT/p).read_bytes()) for p in ('src/ieepa_reciprocal_initial.py','src/ieepa_reciprocal_later.py',
            'src/ieepa_reciprocal_august.py','src/ieepa_emergency_rules.py','src/ieepa_fentanyl_sources.py',
            'src/section232_stacking.py','src/section232_note16_rules.py','src/section301_sources.py',
            'resources/legal_evidence/reciprocal-later/source-catalog.json','resources/legal_evidence/reciprocal-later/reviewed-conditions.json',
            'resources/legal_evidence/section232/civil-aircraft/sources.json','config/revision_dates.csv','resources/shipment_rules/build_contract.json')},
        sources=[dict(id=s['id'],status='verified',sha256=s['sha256'],url=s['url'],citation=s['citation']) for s in sources],
        source_artifacts=[dict(source_id=s['id'],path=s['path'],sha256=s['sha256']) for s in sources],
        rules=rules,relations=relations,coverage=[],fact_definitions=facts,claim_definitions=[],
        origin_resolution=[dict(reporting_code=a['reporting_code'],country_text=a['country_text'],countries=countries[a['reporting_code']]) for a in h['actions']],
        origin_resolution_source_ids=[s['id'] for s in jurisdiction_sources or []],
        civil_aircraft_history=h,
        limitations=['Civil-aircraft concessions only; no full Section232 coverage attestation.',
            'Independent of reciprocal IEEPA collection. Source-defined product/origin conditions and reporting amendments remain operative in their own authority.',
            'FTZ admission/status and unpriced Chapter98 classifications remain separate source/fact questions.'])


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--history',action='store_true');p.add_argument('output');p.add_argument('--input')
    a=p.parse_args();value=load_history() if a.history else compile_rules(**json.loads(Path(a.input).read_bytes()))
    Path(a.output).write_text(json.dumps(value,separators=(',',':'))+'\n')

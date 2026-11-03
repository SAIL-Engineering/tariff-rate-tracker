"""Compile drug-emergency decisions; never infer liability from aggregate rates.

The extractor supplies named actions, original amendments and entry instants.
This adapter supplies reviewed predicates. Incomplete FTZ/de minimis histories
and unverified Section 232 inventories remain explicit source gaps.
"""
from __future__ import annotations
import argparse, copy, csv, json, re, subprocess
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo
from ieepa_fentanyl_sources import ROOT, HEADING, verified_source, inception_sources, windows
from section301_sources import sha, unique_span
from build_contract import audit_until
from section232_note16_rules import val, fact, op, both, either, negate
from chapter98_rules import compile_valuation
from section232_stacking import amendment, timber_amendment, vehicle_predicate, reported


def chapter98_clause(note):
    flat=' '.join(note.split())
    m=re.search(r'The additional duties imposed by headings? .*?shall not apply to goods for which entry is properly claimed under a provision of chapter 98.*?For heading 9802\.00\.80,.*?as described\.',flat)
    if not m:raise ValueError('Missing complete emergency Chapter 98 clause')
    # The regex must start at the valuation paragraph, not an earlier origin paragraph.
    return m[0][m[0].rfind('The additional duties imposed by',0,m[0].index('shall not apply')):]


def relief_actions():
    """Original March 7 insertions apply inside the March 4 HTS interval.

    Read the original text table and inserted note, not a future revision's
    product exceptions. Preserve the Canada publication's I/l typography.
    """
    dates,_=inception_sources();result=[];sources=[]
    for doc in ('2025-03900','2025-03901'):
        text,source=verified_source(doc);sources.append(source)
        note=unique_span(text,r'^``\([cl]\) For the purposes of heading',r'^\d\. Effective with respect')
        flat=' '.join(note.split())
        m=re.search(r'heading ('+HEADING+r'), products of (Mexico|Canada).*?additional ([\d.]+)% ad valorem',flat)
        if not m:raise ValueError('Unparsed March relief original note')
        origin=m[2]
        table=text[text.index('Heading/subheading          Article description'):]
        starts=list(re.finditer(r'^`*('+HEADING+r')\.{2,}  (.*)$',table,re.M))
        if len(starts)!=2:raise ValueError('Unexpected March relief heading table')
        for i,s in enumerate(starts):
            block=table[s.start():starts[i+1].start() if i+1<len(starts) else table.index('\n---',s.start())]
            lines=block.splitlines();lines[0]=re.sub(r'^`*'+HEADING+r'\.{2,}  ','',lines[0])
            description=' '.join(re.split(r' {2,}',line)[0].strip() for line in lines)
            code=s[1];is_potash=description.startswith('Potash that is a product of ')
            if not is_potash and not description.startswith('Articles that are entered free of duty under the terms of general note 11'):
                raise ValueError('Unreviewed March relief table description')
            if is_potash and code!=m[1]:raise ValueError('Potash note/heading mismatch')
            result.append(dict(ch99_code=code,country_names=[origin],rate=float(m[3])/100 if is_potash else 0,
                entry_type='carveout' if is_potash else 'exemption',source_description=description,
                duty_expression='The duty provided in the applicable subheading'+(' + '+m[3]+'%' if is_potash else ''),
                source_note=note,source_note_sha256=sha(note.encode()),source_heading_sha256=sha(block.encode()),
                valid_from=dates[code]['valid_from'],valid_until=None,note_locator='Original March 7 inserted note and heading table',
                inception_source_id=source['id']))
    return result,sources


def revision_window(revision):
    rows=list(csv.DictReader((ROOT/'config/revision_dates.csv').open()))
    dates={r['revision']:r['policy_effective_date'] if r['policy_effective_date']!='NA' else r['effective_date'] for r in rows}
    begin=dates[revision];ends=[d for d in dates.values() if d>begin]
    instant=lambda d:datetime.fromisoformat(d).replace(tzinfo=ZoneInfo('America/New_York')).isoformat()
    return instant(begin),instant(min(ends)) if ends else audit_until()


def role(a):
    d=a['source_description']
    if a['entry_type']=='general':return 'general'
    if a['entry_type']=='conditional_replacement':
        if not ('determined by CBP' in d and 'transshipped to evade' in d):raise ValueError('Unreviewed emergency replacement')
        return 'evasion'
    if d.startswith('Potash that is a product of '):return 'potash'
    if d.startswith('Crude oil, natural gas, lease condensates, natural gas liquids,') and '30 U.S.C. 1606(a)(3)' in d:return 'energy'
    if 'that are donations, by persons subject to the jurisdiction of the United States' in d:return 'donation'
    if 'that are informational materials, including but not limited to' in d:return 'information'
    if d.startswith('Articles that are entered free of duty under the terms of general note 11'):return 'usmca'
    if 'were loaded onto a vessel' in d and 'final mode of transport' in d:return 'transit'
    raise ValueError('Unreviewed emergency heading condition: '+a['ch99_code'])


def compile_emergency(x,products):
    if x['contract_version']!='sail.ieepa-emergency-extraction/v1':raise ValueError('Unsupported emergency extraction')
    for source in x['sources']:
        if sha(Path(source['path']).read_bytes())!=source['sha256']:raise ValueError('Emergency source changed')
    rev=x['revision'];start,end=revision_window(rev)
    hts_path=Path(x['sources'][1]['path']);hts=json.loads(hts_path.read_bytes())
    if sha(hts_path.read_bytes())!=x['sources'][1]['sha256']:raise ValueError('Emergency classification source changed')
    products=sorted(set(products));valid={r.get('htsno','').replace('.','') for r in hts}
    # A revision can have an HTS8 leaf, whose statistical extension is 00.
    statistical_parents={p[:8] for p in valid if len(p)==10}
    valid|={p+'00' for p in valid if len(p)==8 and p not in statistical_parents}
    if any(not re.fullmatch(r'\d{10}',p) or p not in valid for p in products):raise ValueError('Revision-valid exact HTS10 required')
    ids=[f'USITC-{rev}-ieepa-emergency-'+s for s in ('note2','headings')]
    release=rev.replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    sources=[dict(id=id,status='verified',sha256=s['sha256'],citation=f'USITC {rev} U.S. note 2(a)-(u) and emergency headings; conditional candidates, not full coverage',
        url=f'https://hts.usitc.gov/reststop/file?release={release}&filename=Chapter%2099' if i==0 else f'https://hts.usitc.gov/reststop/exportList?release={release}&exportFormat=JSON') for i,(id,s) in enumerate(zip(ids,x['sources']))]
    artifacts=[dict(source_id=id,**s) for id,s in zip(ids,x['sources'])]
    vehicle=amendment();timber=timber_amendment()
    extra=list(x.get('additional_sources',[]))+[vehicle['source'],timber['source']];actions=copy.deepcopy(x['actions'])
    raw=subprocess.check_output(['pdftotext','-layout',x['sources'][0]['path'],'-'],text=True)
    if actions:
        relief,evidence=relief_actions();extra+=evidence
        for a in relief:
            if a['ch99_code'] not in {r['ch99_code'] for r in actions}:
                a['valid_until']=x['collection_ended_at'];actions.append(a)
    review_path=ROOT/'resources/legal_evidence/ieepa-emergency/reviewed-semantics.json'
    review=json.loads(review_path.read_bytes())
    accepted={(e['heading'],e['description_sha256'],e['note_sha256'],e['role']) for e in review['entries']}
    for a in actions:
        key=(a['ch99_code'],sha(' '.join(a['source_description'].split()).encode()),sha(' '.join(a['source_note'].split()).encode()),role(a))
        if key not in accepted:raise ValueError('Unreviewed emergency legal conditions: '+a['ch99_code'])
    for s in extra:
        if sha(Path(s['path']).read_bytes())!=s['sha256']:raise ValueError('Emergency amendment source changed')
        if s['id'] in ids:continue
        ids.append(s['id']);sources.append({k:s[k] for k in ('id','sha256','url','citation')}|dict(status='verified'))
        artifacts.append(dict(source_id=s['id'],path=s['path'],sha256=s['sha256']))
    ids=sorted(ids);sources.sort(key=lambda s:s['id']);artifacts.sort(key=lambda s:s['source_id'])
    actions=list({json.dumps(a,sort_keys=True):a for a in actions}.values())
    facts={};rules=[]
    def f(name,label,kind='boolean',description=None,choices=None):
        d=dict(type=kind,label=label,source_ids=list(ids))
        if kind=='number':d.update(minimum=0,unit='USD')
        if description:d['description']=description
        if choices is not None:d['enum']=choices
        facts[name]=d;return fact(name)
    cv=f('customs_value','Customs value (USD)','number')
    vehicle_tests={}
    wood=sorted(r['htsno'] for r in hts if re.search(r'\bU\.S\. note 37\b',r.get('description','')) and re.search(r'[\d.]+%',r.get('general','')))
    def vehicles(after):
        if after not in vehicle_tests:vehicle_tests[after]=vehicle_predicate(hts,raw,f,after)
        return vehicle_tests[after]
    census={r['Name']:r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())}
    def emit(action,scope,path,code=None,formula=None,constraints=None):
        r=dict(id=f'ieepa_emergency_{rev}_{len(rules)}',action_id='ieepa_drug_emergency_'+'_'.join(action['country_names']),
            authority='ieepa_fentanyl',kind='duty',verification='verified',scope=scope,when=path,
            formula=formula if formula is not None else val(0),reporting_codes=[code] if code else [],source_ids=list(ids),
            source_note_sha256=action['source_note_sha256'],source_heading_sha256=action['source_heading_sha256'],
            legal_locator=action['note_locator'],decision_heading=action['ch99_code'])
        if constraints:r['input_constraints']=constraints
        if formula is not None and code and action['rate']>0 and set(action['country_names']) & {'Canada','Mexico'}:
            # A reporting decision for a non-automobile article is not a
            # vehicle exemption. The helper retains mixed-heading predicates.
            if role(action)!='evasion':
                r['suppressed_when']=vehicles(scope['from']>=vehicle['effective_from'])
            if wood and scope['from']>=timber['effective_from']:
                r['suppressed_when']=either(r.get('suppressed_when',val(False)),reported(wood))
        rules.append(r)
    for countries in sorted({tuple(a['country_names']) for a in actions}):
        aa=[a for a in actions if tuple(a['country_names'])==countries]
        boundaries=sorted({start,end}|{t for a in aa for t in (a['valid_from'],a['valid_until']) if t and start<t<end}|
            {a['effective_from'] for a in (vehicle,timber) if start<a['effective_from']<end})
        for begin,until in zip(boundaries,boundaries[1:]):
            active=[a for a in aa if a['valid_from']<=begin<a['valid_until']]
            byrole={}
            for a in active:
                key=role(a)
                if key in byrole:raise ValueError('Overlapping emergency decisions: '+key)
                byrole[key]=a
            if not active:continue
            general=byrole.get('general')
            if not general:
                # A later relief heading alone cannot establish an ordinary action.
                continue
            scope=dict(hts_exact=products,countries=[census[c] for c in countries],**{'from':begin,'until':until})
            path=val(True)
            def branch(test,action,code=None,formula=None,constraints=None):
                nonlocal path
                emit(action,scope,op('if',path,test,val(False)),code,formula,constraints)
                path=op('if',path,negate(test),val(False))
            if set(countries) & {'Canada','Mexico'}:
                branch(negate(f('ieepa_origin_rule_confirmed','Selected origin satisfies the emergency Part 102 or last-substantial-transformation rule, with no conflicting covered origin',
                    description='The emergency note covers either legal origin test. A conflicting origin determination requires reconciliation, not selection of the lower duty.')),general,
                    formula={'unresolved_source':'ieepa_conflicting_or_unestablished_origin'})
            # Admission status/classification can select a different historical
            # decision. Do not apply ANY ordinary-entry relief first and then
            # silently bypass the uncompiled admission-date decision.
            branch(f('ieepa_ftz_entry','Entry from a foreign trade zone'),general,
                   formula={'unresolved_source':'ieepa_ftz_admission_status_classification_and_rate_history_required'})
            branch(f('ieepa_personal_accompanied_baggage','For personal use in accompanied baggage of a person arriving in the United States'),general)
            for key,name,label in [('donation','ieepa_qualifying_humanitarian_donation','Donation by a person subject to U.S. jurisdiction to relieve human suffering, without a disqualifying presidential determination'),
                                   ('information','ieepa_informational_material','Information or informational materials covered by 50 U.S.C. 1702(b)(3)')]:
                if key not in byrole:raise ValueError('Missing emergency statutory exemption: '+key)
                a=byrole[key];branch(f(name,label,description=a['source_description']),a,a['ch99_code'])
            # Do not use an HTS zero base rate or modeled utilization as proof of an actual claim.
            if 'usmca' in byrole:
                a=byrole['usmca'];branch(op('if',{'claim':'USMCA'},f('ieepa_usmca_entered_free','Entered free of duty under General Note 11, including the specified Chapter 98/99 USMCA treatment'),val(False)),a,a['ch99_code'])
            if 'transit' in byrole:
                a=byrole['transit'];condition=a.get('transit_condition')
                if not condition:raise ValueError('Missing separate transit loading deadline')
                branch(f('ieepa_china_transit_loading_satisfied','Loading or final-mode transit satisfies the original emergency cutoff',description=condition),a,a['ch99_code'])
            # Low-value requests require their own transport/entry chronology.
            branch(f('ieepa_de_minimis_claimed','Administrative de minimis treatment requested'),general,
                   formula={'unresolved_source':'ieepa_de_minimis_transport_and_effective_history_required'})
            v=compile_valuation(chapter98_clause(general['source_note']),hts,f,{'claim':'CHAPTER_98'},cv,'ieepa_emergency')
            if v['policy']['geography']!=' and '.join(countries):raise ValueError('Emergency Chapter 98 origin disagreement')
            branch(v['exempt'],general,constraints=v['constraints'])
            # All charge branches share the source's valuation policy. A changed
            # carveout policy must be compiled explicitly, not inherited silently.
            for a in active:
                if a['rate'] and compile_valuation(chapter98_clause(a['source_note']),hts,f,{'claim':'CHAPTER_98'},cv,'ieepa_emergency')['policy']!=v['policy']:
                    raise ValueError('Different emergency valuation policies')
            def amount(a):
                # Missing suppressing programs cannot leave an overstated known subtotal.
                return op('if',{'authority_covered':'section_232'},op('multiply',val(a['rate']),v['basis']),val(0))
            if 'evasion' in byrole:
                a=byrole['evasion'];note=' '.join(a['source_note'].split())
                if 'do not qualify as originating' not in note or 'in lieu of' not in note:raise ValueError('Unreviewed evasion replacement predicate')
                determined=f('ieepa_canada_cbp_evasion_determination','CBP determined the goods were transshipped to evade the specified emergency duties')
                nonorigin=negate(f('ieepa_canada_usmca_originating','Goods qualify as originating under USMCA (whether or not preference is claimed)'))
                branch(op('if',determined,nonorigin,val(False)),a,a['ch99_code'],amount(a),v['constraints'])
            for key,name,label in [('potash','ieepa_potash','Article is potash under the applicable emergency action'),('energy','ieepa_canada_energy_or_critical_mineral','Covered Canadian energy product or critical mineral under 30 U.S.C. 1606(a)(3)')]:
                if key in byrole:
                    a=byrole[key];branch(f(name,label,description=a['source_description']),a,a['ch99_code'],amount(a),v['constraints'])
            emit(general,scope,path,general['ch99_code'],amount(general),v['constraints'])
    rids=[r['id'] for r in rules]
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='ieepa_emergency_'+rev,
        supported_from=start,supported_until=end,compiler_sha256=sha(Path(__file__).read_bytes()),
        semantic_review_sha256=sha(review_path.read_bytes()),
        compiler_dependencies={p:sha((ROOT/p).read_bytes()) for p in ('src/chapter98_rules.py','src/ieepa_fentanyl_sources.py','src/section232_stacking.py','src/section232_note16_rules.py','config/revision_dates.csv','resources/census_codes.csv','resources/shipment_rules/build_contract.json')},
        sources=sources,source_artifacts=artifacts,rules=rules,coverage=[],fact_definitions=facts,relations=[],
        claim_definitions=[dict(id=c,label=l,rule_ids=rids,source_ids=ids) for c,l in [('USMCA','USMCA'),('CHAPTER_98','Chapter 98')]] if rids else [],
        unchanged_claims=[dict(id='ieepa_'+rev+'_301_independent',claim_authority='section_301',candidate_required_fields=['exclusion_claim_id'],target_rule_ids=rids,source_ids=ids),
            dict(id='ieepa_'+rev+'_232_reevaluate',effect='reevaluate',claim_authority='section_232',candidate_required_fields=['grant_id','grant_snapshot_id'],target_rule_ids=rids,source_ids=ids)] if rids else [],
        limitations=['No complete emergency or all-authority coverage attestation.',
            'FTZ and de minimis histories remain explicit unresolved paths.',
            'Country input must reflect the emergency origin rules; conflicting Part 102 and substantial-transformation origins require separate reconciliation.',
            'Section 232 precedence must be composed from the matching dated source fragments.'])


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('input');p.add_argument('output');a=p.parse_args()
    Path(a.output).write_text(json.dumps(compile_emergency(**json.loads(Path(a.input).read_bytes())),separators=(',',':'))+'\n')

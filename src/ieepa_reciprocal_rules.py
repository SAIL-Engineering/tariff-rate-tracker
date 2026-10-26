"""Compile original reciprocal decisions to the shared shipment interpreter.

No aggregate column, utilization share, predicted heading or payable-232 test
is used. Original decisions, June portions and UK aircraft relief are bounded
by the next copper/country-policy amendment. No full coverage is attested.
"""
from __future__ import annotations
import argparse, json, re
from collections import defaultdict
from pathlib import Path
from ieepa_reciprocal_initial import initial_history, HEADING
from ieepa_reciprocal_history import history as scope_history
from ieepa_emergency_rules import revision_window
from ieepa_fentanyl_sources import ROOT
from section301_sources import sha
from section232_note16_rules import val, fact, op, both, either, negate
from section232_stacking import reported
from chapter98_rules import compile_valuation, overlap_value


def june_metal_headings(x):
    """Use operative note/heading identities, never repair the CBP typo.

    CSMS 65236374 prints 9903.91.98 for UK outside-Chapter-73 derivatives.
    The actual note 16(u) and heading independently identify 9903.81.98;
    the subsequent Commerce annex also cites that exact existing heading.
    """
    from section232_legacy_sources import extract
    metal=extract(Path(x['sources'][0]['path']),Path(x['sources'][1]['path']),x['revision'])
    if metal['regime']!='march_2025_metals':raise ValueError('Missing June metal rule inventory')
    review=json.loads((ROOT/'resources/legal_evidence/section232/legacy-reviewed-semantics.json').read_bytes())
    accepted={(c['locator'],c['sha256']) for c in review['entries']}
    groups={'steel':[],'aluminum':[]}
    for h in metal['headings']:
        if (h['code'],sha(' '.join(h['description'].split()).encode())) not in accepted:
            raise ValueError('Unreviewed reciprocal metal reporting decision')
        kinds=[m for m in groups if re.search(r'\b'+m+r'\b',h['description'],re.I)]
        if len(kinds)!=1:raise ValueError('Ambiguous metal reporting identity')
        groups[kinds[0]].append(h['code'])
    if not all(groups.values()):raise ValueError('Incomplete metal reporting families')
    return groups


def compile_reciprocal(x, products, jurisdictions):
    if x['contract_version']!='sail.ieepa-reciprocal-scope/v1':raise ValueError('Unsupported reciprocal extraction')
    history=initial_history(); rev=x['revision']; start,end=revision_window(rev)
    expected_scope=scope_history()
    def canonical_rows(rows):return sorted({json.dumps(r,sort_keys=True) for r in rows})
    if canonical_rows(x['history']['products'])!=canonical_rows(expected_scope['products']):
        raise ValueError('Reciprocal product history differs from original legal sources')
    products=sorted(set(products))
    for s in x['sources']+x['history']['sources']+history['sources']:
        if sha(Path(s['path']).read_bytes())!=s['sha256']:raise ValueError('Reciprocal source hash mismatch')
    hts=json.loads(Path(x['sources'][1]['path']).read_bytes())
    valid={r.get('htsno','').replace('.','') for r in hts}
    # A revision can have an HTS8 leaf, whose statistical extension is 00.
    statistical_parents={p[:8] for p in valid if len(p)==10}
    valid|={p+'00' for p in valid if len(p)==8 and p not in statistical_parents}
    if any(not re.fullmatch(r'\d{10}',p) or p not in valid for p in products):raise ValueError('Revision-valid exact products required')
    country_codes=set(jurisdictions['all'])
    if not country_codes or not set(jurisdictions['non_ntr'])<=country_codes:raise ValueError('Missing country inventory')
    by_country={}
    for a in history['actions']:
        codes=jurisdictions['actions'].get(a['code'])
        if not codes or not set(codes)<=country_codes:raise ValueError('Unresolved reciprocal country mapping')
        for c in codes:
            if c in by_country:raise ValueError('Overlapping reciprocal country headings')
            by_country[c]=a
    for name in ('Canada','Mexico','UnitedKingdom'):
        if len(jurisdictions[name])!=1 or not set(jurisdictions[name])<=country_codes:raise ValueError('Missing country exclusion')
    sources={}; artifacts={}
    def evidence(s):
        if s['id'] in sources and sources[s['id']]['sha256']!=s['sha256']:raise ValueError('Conflicting source identity')
        sources[s['id']]={k:s[k] for k in ('id','sha256','url','citation')}|dict(status='verified')
        artifacts[s['id']]=dict(source_id=s['id'],path=s['path'],sha256=s['sha256'])
    for s in history['sources']+x['history']['sources']:evidence(s)
    release=rev.replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    for i,s in enumerate(x['sources']):
        evidence(dict(s,id=f'USITC-{rev}-reciprocal-runtime-{i}',
            url=f'https://hts.usitc.gov/reststop/'+('file?release='+release+'&filename=Chapter%2099' if i==0 else 'exportList?release='+release+'&exportFormat=JSON'),
            citation='Revision-valid classification and reconciliation of original reciprocal chronology'))
    for s in jurisdictions['sources']:
        if sha(Path(s['path']).read_bytes())!=s['sha256']:raise ValueError('Jurisdiction evidence hash mismatch')
        evidence(s)
    ids=sorted(sources);facts={};rules=[];relations=[]
    def f(name,label,kind='boolean',description=None,choices=None):
        d=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':d.update(minimum=0,unit='USD')
        if description:d['description']=description
        if choices is not None:d['enum']=choices
        facts[name]=d;return fact(name)
    cv=f('customs_value','Customs value (USD)','number')
    valuation=compile_valuation(history['clauses']['i'],hts,f,{'claim':'CHAPTER_98'},cv)
    content=history['clauses']['xii']
    threshold=re.search(r'provided at least (\d+)% of the customs value',content)
    content_heading=re.search(r'Heading ('+HEADING+r') covers only the U.S. content portion',content)
    if not threshold or not content_heading or 'substantially transformed in the United States' not in content:
        raise ValueError('Unreviewed reciprocal U.S. content predicate')
    us=f('reciprocal_us_content_value','Qualifying U.S.-originating component value (USD)','number',description=content)
    claim={'claim':'RECIPROCAL_US_CONTENT'}
    eligible=op('if',claim,op('gte',us,op('multiply',cv,val(float(threshold[1])/100))),val(False))
    # Chapter 98 and reciprocal U.S. content can overlap. Only their
    # intersection may be deducted from an already adjusted valuation basis.
    overlap=f('reciprocal_us_content_in_chapter98_value','Qualifying U.S. content included in the Chapter 98 dutiable value (USD)','number',
        description='Reconcile the same value basis. U.S. components already deducted under 9802.00.80 cannot be deducted again.')
    assembly=op('if',valuation['adjusted'],op('eq',fact('chapter98_provision'),val(valuation['policy']['assembly'])),val(False))
    # The U.S. products already deducted under 9802.00.80 are part of the
    # qualifying U.S. content. Deduct only the remainder, once. Repairs have
    # a different value basis and require its independently evidenced overlap.
    assembly_deduction=op('subtract',us,fact('chapter98_us_products_value'))
    deduction=op('if',valuation['adjusted'],op('if',assembly,assembly_deduction,overlap),us)
    basis=op('if',eligible,op('subtract',valuation['basis'],deduction),valuation['basis'])
    constraints=valuation['constraints']+[
        dict(test=op('if',claim,op('lte',us,cv),val(True)),inputs=[us['fact'],'customs_value'],label='U.S. content cannot exceed customs value'),
        dict(test=op('if',both(eligible,assembly),op('gte',us,fact('chapter98_us_products_value')),val(True)),
            inputs=[us['fact'],'chapter98_us_products_value'],label='Qualifying U.S. content includes the U.S. products already deducted under 9802.00.80'),
        dict(test=op('if',both(eligible,valuation['adjusted'],negate(assembly)),both(op('lte',overlap,us),op('lte',overlap,valuation['basis']),
            op('gte',overlap,op('max',val(0),op('subtract',op('add',us,valuation['basis']),cv)))),val(True)),
            inputs=[overlap['fact'],us['fact'],'customs_value'],label='U.S. content intersection must fit both valuation bases')]
    transit_claim={'claim':'RECIPROCAL_TRANSIT'}
    vessel=f('reciprocal_transit_final_vessel',
        'Goods were loaded at the port of loading and in transit on the final vessel to the United States',
        description='Vessel-only relief. A qualifying final vessel can make intermediate stops with the cargo aboard; an earlier feeder loading or transloading to air, rail or truck does not establish this predicate.')
    loading=f('reciprocal_transit_loading_window','Time window of loading and commencement of the qualifying final vessel transit','string',
        description='before_initial_cutoff: before '+history['inception']+'; before_country_cutoff: from that instant to before '+history['country_from']+
            '; before_china_increase: from that instant to before '+history['suspension_from']+'; after_cutoffs: at or after that instant. All endpoints come from the original entry instructions.',
        choices=['before_initial_cutoff','before_country_cutoff','before_china_increase','after_cutoffs'])
    transit=op('if',transit_claim,vessel,val(False))
    june=None
    if start<history['policy_until'] and end>history['inception']:
        june=june_metal_headings(x)
    def emit(scope,path,code=None,formula=None,checks=None):
        r=dict(id=f'reciprocal_{rev}_{len(rules)}',action_id='ieepa_reciprocal_14257',authority='ieepa_reciprocal',kind='duty',
            verification='verified',scope=scope,when=path,formula=val(0) if formula is None else formula,
            reporting_codes=[] if code is None else [code],source_ids=ids)
        if checks:r['input_constraints']=checks
        rules.append(r)
        return r['id']
    boundary=sorted({start,end}|{t for t in (history['inception'],history['country_from'],history['suspension_from'],history['china_suspension_from'],history['metal_portion_from'],history['transit_until'],history['uk_aircraft']['from_'],history['suspension_extension']['from_'],history['policy_until']) if start<t<end})
    for begin,until in zip(boundary,boundary[1:]):
        if begin<history['inception'] or begin>=history['policy_until']:continue
        portion=begin>=history['metal_portion_from']
        period_basis=basis;period_constraints=list(constraints)
        if portion:
            triggers={m:reported(june[m]) for m in june}
            values={m:f(m+'_content_value',m.title()+' content value (USD)','number') for m in june}
            excluded=op('add',*(op('if',triggers[m],values[m],val(0)) for m in june))
            metal_value,metal_constraint=overlap_value(valuation,excluded,cv,f,'reciprocal')
            overlap_us=f('reciprocal_us_content_in_metal_excluded_value',
                'Qualifying U.S. content included in the metal value excluded from the Chapter 98-adjusted reciprocal basis (USD)','number',
                description='Intersection of the same dutiable-value portions. U.S.-origin metal must not be deducted twice.')
            needs_overlap=both(eligible,op('gt',metal_value,val(0)),op('gt',deduction,val(0)))
            shared=op('if',needs_overlap,overlap_us,val(0))
            period_basis=op('add',op('subtract',basis,metal_value),shared)
            period_constraints += [dict(test=op('lte',excluded,cv),inputs=['steel_content_value','aluminum_content_value','customs_value'],
                label='Disjoint steel and aluminum content values cannot exceed the article value'),metal_constraint,
                dict(test=op('if',needs_overlap,both(op('lte',overlap_us,metal_value),op('lte',overlap_us,deduction),
                    op('gte',overlap_us,op('max',val(0),op('subtract',op('add',metal_value,deduction),valuation['basis'])))),val(True)),
                    inputs=[overlap_us['fact'],'reciprocal_us_content_value','customs_value'],label='U.S./metal intersection must fit both excluded portions on the same valuation basis')]
        # A country's ordinary action is replaced, never added to the baseline.
        groups=defaultdict(list)
        for c in sorted(country_codes):
            a=by_country.get(c);code=history['baseline_code'];rate=history['baseline_rate']
            if a and begin>=history['country_from']:
                code=a['code'];rate=a['rate']
                for amendment in history['amendments']:
                    if amendment['code']==code and begin>=amendment['from_']:
                        if rate!=amendment['old_rate']:raise ValueError('Reciprocal replacement predecessor does not reconcile')
                        rate=amendment['rate']
                china=code==history['amendments'][0]['code']
                if (not china and begin>=history['suspension_from']) or (china and begin>=history['china_suspension_from']):
                    code=history['baseline_code'];rate=history['baseline_rate']
            exemption=None
            for name,key in [('Canada','iv'),('Mexico','v')]:
                if c in jurisdictions[name]:exemption=re.search(HEADING,history['clauses'][key])[0]
            if c in jurisdictions['non_ntr']:exemption=history['headings']['column2']['code']
            uk=begin>=history['uk_aircraft']['from_'] and c in jurisdictions['UnitedKingdom']
            groups[(code,rate,exemption,uk)].append(c)
        # The product history may contain amendments between HTS releases.
        # Initial policy has only unconditional exemptions, already reconciled
        # against the original annex and retroactive electronics memorandum.
        exempt=set()
        for p in x['history']['products']:
            if p['valid_from']<=begin<p['valid_until'] and p['condition']=='none':
                exempt.update(h for h in products if h.startswith(p['scope_code']))
        for (code,rate,country_exempt,uk),countries in groups.items():
            partition=[]
            for product_exempt,subset in [(True,sorted(exempt)),(False,sorted(set(products)-exempt))]:
                listed={p for p in subset if p[:8] in history['uk_aircraft']['products']} if uk else set()
                if listed:partition.append((product_exempt,True,sorted(listed)))
                other=sorted(set(subset)-listed)
                if other:partition.append((product_exempt,False,other))
            for product_exempt,aircraft_listed,subset in partition:
                if not subset:continue
                scope=dict(hts_exact=subset,countries=countries,**{'from':begin,'until':until})
                path=val(True)
                def branch(test,heading=None,formula=None,checks=None):
                    nonlocal path
                    rule_id=emit(scope,op('if',path,test,val(False)),heading,formula,checks)
                    path=op('if',path,negate(test),val(False))
                    return rule_id
                # Admission status can select a different classification/date.
                branch(f('ieepa_ftz_entry','Entry from a foreign trade zone'),formula={'unresolved_source':'reciprocal_ftz_admission_history_required'})
                if country_exempt:
                    emit(scope,path,country_exempt);continue
                if product_exempt:
                    emit(scope,path,history['headings']['products']['code']);continue
                if uk:
                    aircraft=history['uk_aircraft']
                    ch98=either(*(op('eq',fact('chapter98_provision'),val(p)) for p in aircraft['products'] if p.startswith('98')))
                    ch98=op('if',{'claim':'CHAPTER_98'},both(fact('chapter98_properly_claimed_and_cbp_agreed'),ch98),val(False))
                    match=op('if',either(val(aircraft_listed),ch98),f('uk_civil_aircraft_gn6',
                        'UK article meets the civil-aircraft criteria of General Note 6',description=aircraft['condition_text']),val(False))
                    rid=branch(match,aircraft['reporting_code'])
                    relations.append(dict(id=rid+'_named_metal_relief',effect='suppress',when_rule_applies=rid,
                        target_reporting_codes=[c for c in aircraft['removed_codes'] if c!=history['baseline_code']],
                        source_ids=[aircraft['source_id']]))
                branch(f('ieepa_personal_accompanied_baggage','For personal use in accompanied baggage of a person arriving in the United States'))
                branch(f('ieepa_qualifying_humanitarian_donation','Donation by a person subject to U.S. jurisdiction to relieve human suffering, without a disqualifying presidential determination'), history['headings']['donation']['code'])
                branch(f('ieepa_informational_material','Information or informational materials covered by 50 U.S.C. 1702(b)(3)'), history['headings']['information']['code'])
                branch(f('ieepa_de_minimis_claimed','Administrative de minimis treatment requested'),formula={'unresolved_source':'reciprocal_de_minimis_transport_and_effective_history_required'})
                # GN3(c)(i) preferential treatment remains subject to reciprocal
                # duties even when reported through Chapter 98 (e.g. HOPE).
                # A proper classification claim alone does not establish the
                # separate reciprocal special-classification exemption.
                special=op('if',valuation['exempt'],f('reciprocal_chapter98_nonpreference',
                    'The Chapter 98 treatment is a special classification, not preferential treatment under General Note 3(c)(i)',
                    description='Verify the actual Chapter 98 provision and program. A GN3 preference reported in Chapter 98/99 does not waive reciprocal duties.'),val(False))
                branch(special,checks=valuation['constraints'])
                if begin<history['transit_until']:
                    branch(op('if',transit,op('eq',loading,val('before_initial_cutoff')),val(False)),history['headings']['transit']['code'])
                # Literal source inventory, including named zero-payable metal
                # headings. Other zero decisions are not blanket exemptions.
                covered=reported([c for key,codes in history['section232'].items() if not portion or key in ('x','xi') for c in codes])
                if not portion:
                    # EO 14257 section 3(b)(ii) independently covers the
                    # Russian-aluminum decisions under the amended metal
                    # proclamations, although the original note enumeration
                    # omits their separate reporting identifiers.
                    covered=either(covered,reported([c for codes in june.values() for c in codes],positive=True))
                branch(covered,history['headings']['section232']['code'])
                # Missing 232 coverage prevents an overstated known subtotal.
                branch(negate({'authority_covered':'section_232'}),formula={'unresolved_source':'reciprocal_section232_inventory_required'})
                if portion:
                    emit(scope,op('if',path,either(*triggers.values()),val(False)),history['headings']['section232']['code'],checks=period_constraints)
                # Emit the no-additional-duty content reporting line separately.
                # It shares all applicable constraints and does not double count.
                emit(scope,op('if',path,eligible,val(False)),content_heading[1],checks=period_constraints)
                if code!=history['baseline_code'] and begin<history['transit_until']:
                    windows=[op('eq',loading,val('before_country_cutoff'))]
                    if code==history['amendments'][0]['code'] and begin>=history['suspension_from']:
                        windows.append(op('eq',loading,val('before_china_increase')))
                    reduced=op('if',transit,either(*windows),val(False))
                    branch(reduced,history['baseline_code'],op('multiply',val(history['baseline_rate']),period_basis),period_constraints)
                emit(scope,path,code,op('multiply',val(rate),period_basis),period_constraints)
    rids=[r['id'] for r in rules]
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='ieepa_reciprocal_initial_'+rev,
        supported_from=start,supported_until=end,compiler_sha256=sha(Path(__file__).read_bytes()),
        compiler_dependencies={p:sha((ROOT/p).read_bytes()) for p in ('src/ieepa_reciprocal_initial.py','src/ieepa_reciprocal_history.py','src/ieepa_emergency_rules.py','src/chapter98_rules.py','src/section232_stacking.py','src/section232_note16_rules.py','src/section232_legacy_sources.py','resources/legal_evidence/section232/legacy-reviewed-semantics.json','src/ieepa_fentanyl_sources.py','config/revision_dates.csv')},
        sources=[sources[k] for k in ids],source_artifacts=[artifacts[k] for k in ids],
        rules=rules,coverage=[],relations=relations,fact_definitions=facts,
        claim_definitions=[dict(id=c,label=l,rule_ids=rids,source_ids=ids,**({} if c in ('CHAPTER_98','USMCA') else dict(candidate_rule_ids=rids))) for c,l in [('CHAPTER_98','Chapter 98'),('USMCA','USMCA'),('RECIPROCAL_US_CONTENT','Reciprocal U.S. content'),('RECIPROCAL_TRANSIT','Reciprocal in-transit treatment')]] if rids else [],
        unchanged_claims=[dict(id='reciprocal_'+rev+'_301_independent',claim_authority='section_301',candidate_required_fields=['exclusion_claim_id'],target_rule_ids=rids,source_ids=ids),
            dict(id='reciprocal_'+rev+'_232_reevaluate',effect='reevaluate',claim_authority='section_232',candidate_required_fields=['grant_id','grant_snapshot_id'],target_rule_ids=rids,source_ids=ids),
            dict(id='reciprocal_'+rev+'_other_duties_remain',claim_authority='ieepa_reciprocal',claim_ids=['RECIPROCAL_US_CONTENT','RECIPROCAL_TRANSIT'],
                target_authorities=['base','section_201','section_232','section_301','ieepa_fentanyl'],source_ids=ids)] if rids else [],
        legal_horizon=dict(from_=history['inception'],until=history['policy_until']),
        limitations=['No full reciprocal or all-authority coverage attestation.',
            'Original policy, June 4 metal portions, June 30 UK aircraft relief and July suspension extension only, ending at the August 1 copper/country-policy horizon.',
            'FTZ and de minimis instruction histories remain explicit unresolved paths. Transit continuation beyond the compiler horizon is not attested.'])


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('input');p.add_argument('output');a=p.parse_args()
    Path(a.output).write_text(json.dumps(compile_reciprocal(**json.loads(Path(a.input).read_bytes())),separators=(',',':'))+'\n')

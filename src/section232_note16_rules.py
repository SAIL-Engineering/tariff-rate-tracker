"""Compile note 16's reporting decisions to the existing shipment interpreter.

Rates, product scopes, thresholds and heading descriptions are extraction data.
This compiler supplies the reviewed meaning of the note's predicates. No HTS
example, modeled share, rate matching or maximum-rate attribution is used.
This fragment does not attest coverage of the other Section 232 actions.
"""
from __future__ import annotations
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re
from section232_sources import matches, sha
from section301_sources import unique_span
from shipment_base_sources import extract_rows


def val(x): return {'value': x}
def fact(x): return {'fact': x}
def op(name, *args): return {'op': name, 'args': list(args)}
def choose(test, yes, no):
    if test == val(True): return yes
    if test == val(False): return no
    return ('if', test, yes, no)
def both(*args):
    if val(False) in args: return val(False)
    args = [a for a in args if a != val(True)]
    return val(True) if not args else args[0] if len(args)==1 else op('and',*args)
def either(*args):
    if val(True) in args:return val(True)
    args=[a for a in args if a!=val(False)]
    return val(False) if not args else args[0] if len(args)==1 else op('or',*args)
def negate(x):return val(not x['value']) if 'value' in x else op('not',x)


def xi_us_metal_sources(root):
    """Keep conflicting original formulations; do not choose one by hierarchy.

    A shipment can still be priced when all sourced formulations yield the
    same additional amount. The CBP bulletin is implementation evidence, not
    an amendment of a different proclamation or native heading expression.
    """
    review=json.loads((root/'resources/legal_evidence/section232/note16-us-metal-reconciliation.json').read_bytes())
    if review['contract_version']!='sail.note16-us-metal-reconciliation/v1':raise ValueError('Unknown US-metal source review')
    directory=root/'resources/legal_evidence/2026-11314';meta=json.loads((directory/'source.json').read_bytes())
    body=directory/'notice.txt'
    if sha(body.read_bytes())!=meta['sha256']:raise ValueError('US-metal original proclamation changed')
    text=body.read_text();clauses={
        '2(b)':unique_span(text,r'^\(b\) For products of',r'^\(c\)'),
        '2(c)':unique_span(text,r'^\(c\) [\d.]+ percent, determined based',r'^\(d\)')}
    for key,value in clauses.items():
        if sha(' '.join(value.split()).encode())!=review['reviewed_clauses'][key]:raise ValueError('Unreviewed US-metal source semantics')
    flat=' '.join(clauses['2(c)'].split());rate=re.match(r'\(c\) (\d+(?:\.\d+)?) percent, determined based',flat)
    if not rate or 'in the same manner outlined in clause (2)(b)' not in flat:raise ValueError('Missing original US-metal floor')
    cbp=review['cbp_source'];path=root/cbp['path']
    if sha(path.read_bytes())!=cbp['sha256']:raise ValueError('US-metal CBP instructions changed')
    raw=path.read_text();starts=list(re.finditer(r'^(9903\.\d{2}\.\d{2}):',raw,re.M));rates={}
    for i,m in enumerate(starts):
        block=raw[m.end():starts[i+1].start() if i+1<len(starts) else len(raw)]
        match=re.search(r'^([\d.]+)% additional ad valorem rate of duty\s*$',block,re.M)
        if match:
            if m[1] in rates:raise ValueError('Duplicate CBP heading formula')
            rates[m[1]]=float(match[1])/100
    return dict(floor_rate=float(rate[1])/100,cbp_additional_rates=rates,sources=[
        dict(id='FR-2026-11314-US-metal-body',path=str(body),sha256=meta['sha256'],url=meta['url'],
             citation='Proclamation11032 clauses2(b),2(c),3(b): original combined-duty wording and lowest applicable treatment.'),
        dict(cbp,path=str(path))])


def compile_note16(x: dict, products: list[str], jurisdictions: dict) -> dict:
    root=Path(__file__).resolve().parents[1]
    grammar=root/'resources/legal_evidence/section232/note16-reviewed-semantics.json'
    reviewed=json.loads(grammar.read_bytes())
    accepted={(e['locator'],e['sha256']) for e in reviewed['entries']}
    texts=[(f"note16({c['id']})",c['text']) for c in x['clauses'] if c['id']!='c']
    texts += [(h['code'],h['description']) for h in x['headings']+x['external_headings']]
    for locator,text in texts:
        if (locator,sha(' '.join(text.split()).encode())) not in accepted:
            raise ValueError('Unreviewed legal predicate grammar: '+locator)
    rev=x['revision']
    ids=[f'USITC-{rev}-note16',f'USITC-{rev}-note16-headings']
    release=rev.replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    sources=[dict(id=id,status='verified',sha256=s['sha256'],
        url=f'https://hts.usitc.gov/reststop/file?release={release}&filename=Chapter%2099' if i==0 else
            f'https://hts.usitc.gov/reststop/exportList?release={release}&exportFormat=JSON',
        citation=f'USITC {rev}, Chapter 99 U.S. note 16 and specified reporting heading.')
        for i,(id,s) in enumerate(zip(ids,x['sources']))]
    artifacts=[dict(source_id=id,path=s['path'],sha256=s['sha256']) for id,s in zip(ids,x['sources'])]
    for s in x.get('additional_sources',[]):
        if sha(Path(s['path']).read_bytes())!=s['sha256']:raise ValueError('Additional note16 primary source changed')
        sources.append({k:s[k] for k in ('id','sha256','url','citation')}|{'status':'verified'})
        artifacts.append(dict(source_id=s['id'],path=s['path'],sha256=s['sha256']))
        ids.append(s['id'])
    params=x['parameters']; headings={h['code']:h for h in x['headings']+x['external_headings']}
    p=root/'resources/legal_evidence/section232/2026-06960.pdf'
    sources.append(dict(id='FR-2026-06960-note16',status='verified',sha256=sha(p.read_bytes()),
        url='https://www.govinfo.gov/content/pkg/FR-2026-04-09/pdf/2026-06960.pdf',
        citation='Proclamation 11021 clauses 1-12; Annex IV; 91 FR 18201. Clause 8 retains Russian-aluminum treatment; clause12 requires separate FTZ admission/status/classification reconciliation.'))
    artifacts.append(dict(source_id='FR-2026-06960-note16',path=str(p),sha256=sha(p.read_bytes())))
    ids.append('FR-2026-06960-note16')
    # Independent amendment evidence is necessary for the xi formula conflict
    # and for the explicit lowest-applicable-rate instruction. OCR is not used
    # as executable extraction; the retained primary PDF is the source.
    if 'xi' in {s['id'] for s in x['lists']}:
        p=root/'resources/legal_evidence/2026-11314/proclamation.pdf'
        if sha(p.read_bytes()) != json.loads(p.with_name('source.json').read_bytes())['pdf_sha256']:
            raise ValueError('June proclamation source hash mismatch')
        sources.append(dict(id='FR-2026-11314',status='verified',sha256=sha(p.read_bytes()),
            url='https://www.govinfo.gov/content/pkg/FR-2026-06-04/pdf/2026-11314.pdf',
            citation='Proclamation 11032 clauses 2(c), 3(b), 4; Annex IV A(2), A(12), 91 FR 34087-34088, 34135-34139.'))
        artifacts.append(dict(source_id='FR-2026-11314',path=str(p),sha256=sha(p.read_bytes())))
        ids.append('FR-2026-11314')
        xi_sources=xi_us_metal_sources(root)
        for s in xi_sources['sources']:
            sources.append({k:s[k] for k in ('id','sha256','url','citation')}|dict(status='verified'))
            artifacts.append(dict(source_id=s['id'],path=s['path'],sha256=s['sha256']));ids.append(s['id'])
    facts={}
    def f(name,label,kind='number',unit='fraction',description=None):
        definition=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':definition.update(minimum=0,unit=unit)
        if unit=='fraction' and kind=='number':definition['maximum']=1
        if description:definition['description']=description
        facts[name]=definition
        return fact(name)
    cv=f('customs_value','Customs value (USD)',unit='USD')
    f('ieepa_ftz_entry','Entry withdrawn from a U.S. foreign-trade zone',kind='boolean')
    weights={m:f(m+'_weight_fraction',m.title()+' fraction of total article weight') for m in ('aluminum','steel','copper')}
    contains_metal=either(*(op('gt',w,val(0)) for w in weights.values()))
    groups=defaultdict(list)
    memberships=defaultdict(set)
    for row in matches(x,products):memberships[row['hts10']].add(row['list_id'])
    metals={s['id']:s['metal'] for s in x['lists']}
    native_bases={};base_decisions=[];basis_data={}
    if memberships:
        native=[s for s in x['sources'] if Path(s['path']).suffix=='.json']
        if len(native)!=1:raise ValueError('Missing unique native Column1 benchmark source')
        raw=Path(native[0]['path']).read_bytes()
        if sha(raw)!=native[0]['sha256']:raise ValueError('Native Column1 benchmark source changed')
        native_products={p['hts10']:p for p in extract_rows(json.loads(raw))['products']}
        native_bases={p:r['general'] for p,r in native_products.items()}
    for hts,lists in memberships.items():
        base=native_bases.get(hts)
        free=bool(base) and base['expression']=='Free'
        supplied=x.get('column1_amounts',{}).get(hts)
        if supplied and base and (supplied.get('raw')!=base['expression'] or any(
            supplied.get(k)!=base[k] for k in ('source_code','source_row_index'))):
            raise ValueError('Native Column1 expression/owner mismatch: '+hts)
        if supplied:
            data={k:supplied[k] for k in ('formula','fact_definitions','input_constraints','status')}
            special=supplied.get('usmca')
            if special:
                owner=native_products.get(hts,{}).get('special',dict(expression=None,source_code=None,source_row_index=None))
                if special.get('raw')!=owner['expression'] or any(special.get(k)!=owner[k] for k in ('source_code','source_row_index')):
                    raise ValueError('Native Column1 Special expression/owner mismatch: '+hts)
                data['usmca']=special
        elif free:
            data=dict(formula=val(0),fact_definitions={},input_constraints=[],status='parsed')
        else:
            data=dict(formula={'unresolved_source':'note16_native_column1_expression_not_compiled:'+hts},
                fact_definitions={},input_constraints=[],status='unresolved_source')
        signature=json.dumps(data,sort_keys=True,separators=(',',':'));basis_data[signature]=data
        groups[(tuple(sorted(lists)),hts[:2],signature)].append(hts)
        base_decisions.append(dict(hts10=hts,source=base,status='source_zero' if free else data['status'],
            source_id=ids[1],benchmark='published_column1_general',formula=data['formula']))
    by_country=defaultdict(list)
    required=('all','uk','russia','non_ntr','usmca','xi_partner')
    if any(k not in jurisdictions for k in required):raise ValueError('Missing explicit country inventories')
    for country in sorted(set(jurisdictions['all'])):
        key=tuple(country in jurisdictions[k] for k in required[1:])
        by_country[key].append(country)
    rules=[];decisions=[]
    def heading(n):
        code=f'9903.82.{n:02d}'
        if code not in headings:raise ValueError('Heading absent from verified extraction: '+code)
        return code
    def leaf(n,formula=None):
        code=n if isinstance(n,str) else heading(n);h=headings[code]
        if formula is None:
            if h['formula_kind']=='no_change':formula=val(0)
            elif h['formula_kind']=='additional_ad_valorem':formula=op('multiply',cv,val(h['rate']))
            elif h['formula_kind']=='column1_floor':formula=op('max',val(0),op('subtract',op('multiply',cv,val(h['rate'])),column1))
            else:raise ValueError('Unknown heading formula')
        return dict(code=code,formula=formula)
    def gap(reason,locator,code=None,inputs=None):
        return dict(error=reason,locator=locator,code=code,invalid_inputs=inputs)
    def floor(low,high):
        h=headings[heading(low)]
        if h['formula_kind']!='column1_floor' or headings[heading(high)]['formula_kind']!='no_change':
            raise ValueError('Unreviewed floor pair')
        return choose(op('lt',column1,op('multiply',cv,val(h['rate']))),leaf(low),leaf(high))
    def agreed_us_metal(code,question,locator,competitor=None,reported_code=None):
        candidate=leaf(code);identity=candidate['code']
        if identity not in xi_sources['cbp_additional_rates']:raise ValueError('Missing named US-metal CBP formula')
        original=op('max',val(0),op('subtract',op('multiply',cv,val(xi_sources['floor_rate'])),column1))
        collected=op('multiply',cv,val(xi_sources['cbp_additional_rates'][identity]))
        agreement=both(op('eq',candidate['formula'],original),op('eq',candidate['formula'],collected))
        if competitor is not None:
            # Clause3(b), not an arbitrary rate selection, requires the
            # lowest legally applicable treatment. A divergent original
            # formulation remains unresolved even if its heading is known.
            agreement=both(agreement,op('lte',candidate['formula'],competitor['formula']))
        if reported_code is not None:
            # The reporting identity/applicability is established even when
            # the amount is not. Other programs must not need this valuation
            # fact merely to recognize an explicitly named covered article.
            return dict(candidate,formula=op('if',agreement,candidate['formula'],{'unresolved_source':question}),locator=locator)
        return choose(agreement,candidate,gap(question,locator,reported_code))
    def walk(tree,path,group_id,scope):
        if isinstance(tree,dict) and tree.get('skip'):return
        if isinstance(tree,list):
            for component in tree:walk(component,path,group_id,scope)
            return
        if isinstance(tree,tuple):
            _,test,yes,no=tree
            walk(yes,op('if',path,test,val(False)),group_id,scope)
            walk(no,op('if',path,negate(test),val(False)),group_id,scope)
            return
        id=f's232_note16_{group_id}_{len(rules)}'
        error=tree.get('error')
        invalid_inputs=tree.get('invalid_inputs')
        r=dict(id=id,action_id='s232_note16_metals',authority='section_232',kind='duty',
            verification='verified',scope=scope,when=path,
            formula=val(0) if invalid_inputs else {'unresolved_source':error} if error else tree['formula'],
            reporting_codes=[tree['code']] if tree.get('code') else [],source_ids=ids,
            legal_locator=tree.get('locator','U.S. note 16 and '+(tree.get('code') or '')))
        # Constraints belong to a benchmark only when this branch consumes it;
        # a flat Section232 amount must not demand an unrelated base quantity.
        if benchmark_used(r['formula']) or benchmark_used(r['when']):
            r['input_constraints']=basis_constraints
        if not error:r['published_expression']=headings[tree['code']]['duty_expression']
        if invalid_inputs:
            # The selected branch proves a contradiction in shipment facts.
            # Request corrected inputs; do not mislabel it as ambiguous law.
            r['input_constraints']=[dict(test=val(False),inputs=invalid_inputs,reason=error)]
        rules.append(r)
        decisions.append(dict(rule_id=id,status='requires_input_correction' if invalid_inputs else
            'requires_source_reconciliation' if error else 'compiled',
            reason=error,reporting_codes=r['reporting_codes'],legal_locator=r['legal_locator']))
    def benchmark_used(node):
        if node==column1 and column1!=val(0):return True
        if isinstance(node,dict):return any(benchmark_used(v) for v in node.values())
        if isinstance(node,list):return any(benchmark_used(v) for v in node)
        return False
    for gi,((lists,chapter,signature),htss) in enumerate(sorted(groups.items())):
        basis=basis_data[signature];general=basis['formula'];basis_constraints=basis['input_constraints']
        special=basis.get('usmca',dict(formula={'unresolved_source':'note16_native_column1_special_expression_not_compiled'},fact_definitions={},input_constraints=[]))
        column1=general
        definitions=dict(basis['fact_definitions'] or {})
        definitions.update(special['fact_definitions'] or {})
        if special['formula']!=general and not (general==val(0) and special.get('raw') is None):
            column1=op('if',{'claim':'USMCA'},special['formula'],general)
            f('usmca_origin_eligible','Qualifies under General Note 11',kind='boolean')
            f('usmca_properly_claimed','USMCA treatment properly claimed for this entry',kind='boolean')
            basis_constraints=[dict(c,test=op('if',{'claim':'USMCA'},val(True),c['test'])) for c in basis_constraints]
            basis_constraints += [dict(c,test=op('if',{'claim':'USMCA'},c['test'],val(True))) for c in special['input_constraints']]
            basis_constraints += [dict(test=op('if',{'claim':'USMCA'},both(fact('usmca_origin_eligible'),fact('usmca_properly_claimed')),val(True)),
                inputs=['usmca_origin_eligible','usmca_properly_claimed'],reason='USMCA entitlement and proper claim must be established')]
        for name,definition in definitions.items():
            definition=dict(definition,source_ids=ids)
            old=facts.get(name);semantic=lambda d:{k:d[k] for k in ('type','unit','minimum','maximum','enum') if k in d}
            if old and semantic(old)!=semantic(definition):raise ValueError('Conflicting native Column1 valuation fact: '+name)
            facts[name]=definition
        lists=set(lists); applicable_metals=sorted({metals[i] for i in lists})
        domestic=[]
        for d in params['domestic']:
            if not lists.intersection(d['list_ids']):continue
            m=d['metal'];share=f('us_'+m+'_origin_fraction','U.S. origin fraction of '+m,
                description=f"Note 16(e): {m} smelted and cast (steel: melted and poured) in the United States, divided by total {m} weight. Requirements are cumulative for overlapping lists.")
            domestic.append(op('if',op('eq',weights[m],val(0)),val(True),op('gte',share,val(d['minimum_fraction']))))
        us=both(*domestic) if domestic else val(False)
        for ci,(country_flags,countries) in enumerate(sorted(by_country.items())):
            uk,russia,non_ntr,usmca,partner=country_flags
            # GN3 Special entitlement is distinct from nonpreferential origin.
            # Only the separate note16(h)-(j) concessions require CA/MX origin.
            # Only the legally matching heading family is considered. The
            # choice is by predicates, never whichever numeric rate is largest.
            tiers=[t for t in x['ordinary_tiers'] if lists.intersection(t['list_ids'])]
            if len(tiers)!=1:raise ValueError('Conflicting note 16 family inventory')
            ordinary=int(tiers[0]['reporting_code'][-2:])
            if ordinary==10:
                tree=leaf(17) if russia and 'x' in lists else leaf(12) if non_ntr else choose(us,floor(7,8),floor(10,11))
            else:
                n=14 if russia and ordinary==2 else 16 if russia else ordinary
                tree=leaf(n)
                domestic_code=15 if russia else 6
                if lists.intersection(headings[heading(domestic_code)]['list_ids']):
                    resolved=leaf(domestic_code)
                    if 'xi' in lists:
                        # The proclamation's clause 2(c) is a column-1 floor;
                        # Annex IV adds xi to the existing +10% heading without
                        # changing its expression. Both sources are retained.
                        resolved=agreed_us_metal(domestic_code,'note16_xi_us_metal_formula_conflict:proclamation_11032_2c_vs_99038206',
                            'Proclamation 11032 clause 2(c); Annex IV A(12), A(14); heading '+heading(domestic_code),reported_code=heading(domestic_code))
                    tree=choose(us,resolved,tree)
                if uk:
                    n=4 if ordinary==2 else 5
                    if lists.intersection(headings[heading(n)]['list_ids']):
                        checks=[]
                        for m in applicable_metals:
                            if m not in params['uk_minimum_fractions']:continue
                            q=f('uk_'+m+'_origin_fraction','Qualifying UK fraction of '+m,
                                description='Note 16(d). For steel, include Tata Steel UK steel reported melted/poured in the Netherlands as permitted by 91 FR 23056-23057 through January 1, 2028. Aluminum must be smelted OR most recently cast in the UK.')
                            checks.append(both(op('gt',weights[m],val(0)),op('gte',q,val(params['uk_minimum_fractions'][m]))))
                        tree=choose(either(*checks),leaf(n),tree)
                if 'k' in {c['id'] for c in x['clauses']} and not non_ntr and chapter in params['equipment_parts_chapters'] and lists.intersection(params['equipment_parts_lists']):
                    use=f('parts_exclusively_for_us_note16_equipment','Parts used exclusively to manufacture qualifying equipment in the U.S.',kind='boolean',
                        description='Note 16(k): agricultural/fixed industrial equipment in (c)(ix)-(x), or mobile industrial equipment in (c)(xi). The final equipment classification and exclusive manufacturing use must be established.')
                    tree=choose(use,choose(us,floor(23,24),floor(25,26)),tree)
                if 'xi' in lists:
                    # Partner floor and USMCA content choices require the
                    # explicit minimum rule (clause 3(b)); do not choose a
                    # heading from its rate alone. The U.S.-metal discrepancy
                    # is kept narrow to shipments satisfying that predicate.
                    if partner:tree=choose(us,agreed_us_metal(domestic_code,'note16_xi_us_metal_formula_conflict:proclamation_11032_2c_vs_99038206',
                        'Proclamation 11032 clauses 2(c), 3(b); Annex IV A(12); the floor/flat discrepancy can also change the lowest applicable reporting alternative',competitor=leaf(22)),leaf(22))
                    if usmca:
                        us_value=f('us_produced_parts_value','Value attributable to parts produced in the U.S.',unit='USD',
                            description='Note 16(j): documented U.S.-produced parts value, not the origin of raw steel and not a trade share.')
                        exempt_value=op('min',us_value,op('multiply',cv,val(params['us_content_cap_fraction'])))
                        charge=leaf(20,op('multiply',val(headings[heading(20)]['rate']),op('subtract',cv,exempt_value)))
                        exempt=leaf(21)
                        content=[charge,choose(op('gt',exempt_value,val(0)),exempt,dict(skip=True))]
                        content=choose(op('lte',us_value,cv),content,
                            gap('inconsistent_us_content_value','U.S.-produced parts value exceeds customs value',
                                inputs=['us_produced_parts_value','customs_value']))
                        # Clause 3(b) makes the U.S.-metal concession lower than
                        # the content treatment, but the former's amount has a
                        # source conflict. Do not silently select the higher one.
                        content=choose(us,agreed_us_metal(domestic_code,'note16_xi_us_metal_formula_conflict:proclamation_11032_2c_vs_99038206',
                            'Proclamation 11032 clauses 2(c), 3(b); Annex IV A(12)',reported_code=heading(domestic_code)),content)
                        eligible=both({'claim':'USMCA'},f('usmca_origin_eligible','Qualifies under General Note 11',kind='boolean'))
                        tree=choose(eligible,content,tree)
                if chapter in params['motorcycle_chapters'] and lists.intersection(params['motorcycle_lists']):
                    tree=choose(f('motorcycle_part_for_us_manufacture','Motorcycle part for U.S. motorcycle manufacturing',kind='boolean',
                        description='U.S. note 16(g): actual motorcycle part and U.S. manufacturing use, not just a Chapter 84/85/87 classification.'),leaf(13),tree)
                # Authorized quantities are not inferable from origin or from
                # a statistical association. A claimed concession must expose
                # the actual Commerce authorization, not a modeled share.
                for list_id,n,metal in [('iii',18,'steel'),('i',19,'aluminum')]:
                    if list_id in lists and heading_exists(headings,n) and usmca:
                        eligible=both({'claim':'USMCA'},f('usmca_origin_eligible','Qualifies under General Note 11',kind='boolean'),
                            f(metal+'_origin_canada_mexico',metal.title()+' produced in Canada or Mexico',kind='boolean',
                                description='Note 16(h)/(i): steel melted and poured; aluminum smelted and cast.'),
                            f('commerce_authorized_'+metal+'_quantity','Shipment within Commerce-authorized '+metal+' quantity',kind='boolean',
                                description='Documented authorization pursuant to Proclamation 10984 clause 13 and note 16(h)/(i), including required CBP information.'))
                        tree=choose(eligible,leaf(n),tree)
            if chapter not in params['weight_exempt_chapters']:
                weight=op('add',*(weights[m] for m in applicable_metals))
                tree=choose(op('lt',weight,val(params['weight_minimum_fraction'])),leaf(3),tree)
            if 'aluminum' in applicable_metals:
                russian=val(True) if russia else f('aluminum_primary_smelted_or_cast_russia','Any primary aluminum smelted in Russia or article cast in Russia',kind='boolean')
                russian_heading='9903.85.67' if 'i' in lists else '9903.85.68'
                tree=choose(both(op('gt',weights['aluminum'],val(0)),russian),leaf(russian_heading),tree)
            tree=choose(op('lte',op('add',*(weights[m] for m in applicable_metals)),val(1)),tree,
                gap('inconsistent_metal_weight_fractions','Sum of metal weight fractions exceeds article weight',
                    inputs=[m+'_weight_fraction' for m in applicable_metals]))
            tree=choose(contains_metal,tree,leaf(1))
            scope=dict(hts_exact=sorted(htss),countries=countries,from_='2026-04-06T00:01:00-04:00')
            scope['from']=scope.pop('from_')
            # A later threshold/list must never operate before its amendment.
            if 'xi' in {s['id'] for s in x['lists']}:scope['from']='2026-06-08T00:01:00-04:00'
            walk(tree,val(True),f'{gi}_{ci}',scope)
    claim_ids=[r['id'] for r in rules]
    # Note 16(b) preserves the .82 duties alongside lower Chapter 99 treatment.
    # Do not extend that review to the separately retained Russian headings.
    unchanged_301=[r['id'] for r in rules if
        all(c.startswith('9903.82.') for c in r['reporting_codes'])]
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='s232_note16_'+rev,
        semantic_review_sha256=sha(grammar.read_bytes()),
        compiler_dependencies={'src/shipment_base_sources.py':sha((root/'src/shipment_base_sources.py').read_bytes())}|({p:sha((root/p).read_bytes()) for p in (
            'src/section301_sources.py',
            'resources/legal_evidence/section232/note16-us-metal-reconciliation.json',
            'resources/legal_evidence/2026-11314/source.json')} if 'xi' in {s['id'] for s in x['lists']} else {}),
        sources=sources,source_artifacts=artifacts,rules=rules,fact_definitions=facts,column1_reference_decisions=base_decisions,
        entry_context=dict(mode='ordinary_only',fact='ieepa_ftz_entry',
            unresolved_source='note16_ftz_admission_status_classification_and_rate_history',source_ids=ids),
        claim_definitions=[dict(id='USMCA',label='USMCA',rule_ids=claim_ids,source_ids=ids)] if claim_ids else [],
        unchanged_claims=[dict(id='note16_'+rev+'_section301_claims',claim_authority='section_301',candidate_required_fields=['exclusion_claim_id'],
            target_rule_ids=unchanged_301,source_ids=ids)] if unchanged_301 else [],
        coverage=[],relations=[],reporting_decisions=decisions,
        limitations=['Note 16 fragment only; no complete Section 232 coverage attestation.',
            'Other action precedence and civil-aircraft/Chapter 98 claims require separately verified composition.',
            'A revision snapshot is not an all-date chronology; compose only into its identified legal interval.'])


def heading_exists(headings,n):return f'9903.82.{n:02d}' in headings


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('input',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();request=json.loads(a.input.read_bytes())
    a.output.write_text(json.dumps(compile_note16(**request),separators=(',',':'))+'\n')

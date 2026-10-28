"""Source Column1 benchmarks for note52(k), independent of payable/model rates."""
import copy
import json
import re
from collections import defaultdict
from section232_note16_rules import val,fact,op,both,either,negate


def per_dollar(node):
    if node==fact('customs_value'):return val(1)
    if isinstance(node,dict):return {k:per_dollar(v) for k,v in node.items()}
    if isinstance(node,list):return [per_dollar(v) for v in node]
    return node


def compile_floor_rules(template,spec,policy,products,native_products,references,valuation,define,facts,ids,program_symbols):
    groups=defaultdict(list);data={}
    for hts in sorted(set(products)):
        native=native_products.get(hts)
        provided=(references or {}).get(hts)
        if provided:
            if not native or provided.get('raw')!=native['general']['expression'] or any(provided.get(k)!=native['general'][k] for k in ('source_code','source_row_index')):
                raise ValueError('Forced-labor native Column1 expression/owner mismatch: '+hts)
            special=provided.get('usmca',{})
            if special and (special.get('raw')!=native['special']['expression'] or any(special.get(k)!=native['special'][k] for k in ('source_code','source_row_index'))):
                raise ValueError('Forced-labor native Special expression/owner mismatch: '+hts)
            basis=copy.deepcopy(provided)
        elif native and native['general']['expression']=='Free':
            basis=dict(raw='Free',normalized_text='Free',status='parsed',formula=val(0),fact_definitions={},input_constraints=[],usmca={})
        else:
            basis=dict(raw=native['general']['expression'] if native else None,status='unresolved_source',
                formula={'unresolved_source':'section301_forced_labor_native_column1_expression_not_compiled:'+hts},fact_definitions={},input_constraints=[],usmca={})
        # Source owners remain in the source map, not the arithmetic grouping.
        signature={k:basis.get(k) for k in ('raw','normalized_text','status','formula','fact_definitions','input_constraints')}
        signature['usmca']={k:v for k,v in (basis.get('usmca') or {}).items() if k not in ('source_code','source_row_index')}
        key=json.dumps(signature,sort_keys=True,separators=(',',':'))
        data[key]=basis;groups[key].append(hts)
    result=[]
    cv=fact('customs_value')
    for gi,(key,htss) in enumerate(sorted(groups.items())):
        basis=data[key]
        def register(reference):
            for name,definition in (reference.get('fact_definitions') or {}).items():
                definition=dict(definition,source_ids=ids)
                semantic=lambda d:{k:d[k] for k in ('type','unit','minimum','maximum','enum') if k in d}
                if name in facts and semantic(facts[name])!=semantic(definition):raise ValueError('Conflicting note52 benchmark valuation fact')
                facts[name]=definition
        def rate(reference,special=False):
            register(reference)
            expression=reference.get('normalized_text',reference.get('raw'))
            fixed=isinstance(expression,str) and bool(re.fullmatch(r'Free|[\d.]+%',expression,re.I))
            formula=reference['formula']
            if reference.get('status')!='parsed':return formula,val(True),[]
            if special and not fixed and spec['country_text']!=policy['special_compound_ave_country']:
                return {'unresolved_source':'note52_non_korean_special_specific_compound_ave_instruction'},val(True),[]
            return (per_dollar(formula),val(True),reference.get('input_constraints') or []) if fixed else (
                op('divide',formula,cv),op('gt',cv,val(0)),reference.get('input_constraints') or [])
        general,valid,constraints=rate(basis)
        # Native General Free cannot be reduced further by a valid preference.
        # Do not ask entitlement/quantity questions that cannot change this floor.
        if general!=val(0):
            usmca=basis.get('usmca') or dict(status='unresolved_source',formula={'unresolved_source':'note52_native_S_expression_not_compiled'})
            sr,sv,sc=rate(usmca,True)
            native_groups=usmca.get('groups') or []
            korus=[g for g in native_groups if 'KR' in g['symbols']]
            mapped=any(r.get('symbol')=='KR' and 'Korea' in r.get('program_name','') for r in program_symbols or [])
            if (usmca.get('programme_status') or {}).get('KR')=='unambiguous' and len(korus)==1 and mapped:
                kr=copy.deepcopy(korus[0]['parsed']);kr['formula']=kr.get('formula') or {'unresolved_source':'note52_native_KR_expression_is_conditional'}
                rr,rv,rc=rate(kr,True)
            else:rr,rv,rc={'unresolved_source':'note52_native_KR_expression_or_programme_mapping_not_compiled'},val(True),[]
            selected=define('column1_special_program','Selected Column1 Special programme symbol','string')
            eligible=define('column1_special_properly_claimed_and_eligible','Selected Special programme was properly claimed and its entitlement established')
            s_eligible=both(define('usmca_origin_eligible','Qualifies under General Note 11'),define('usmca_properly_claimed','USMCA treatment properly claimed for this entry'))
            us={'claim':'USMCA'};other={'claim':'COLUMN1_SPECIAL'};is_kr=op('eq',selected,val('KR'))
            def select(g,s,r,fallback=None):
                return op('if',us,s,op('if',other,op('if',is_kr,r,
                    fallback if fallback is not None else {'unresolved_source':'note52_selected_special_programme_requires_reconciliation'}),g))
            general=select(general,sr,rr)
            valid=select(valid,sv,rv,val(True))
            constraints=[dict(c,test=op('if',either(us,other),val(True),c['test'])) for c in constraints]
            constraints += [dict(c,test=op('if',us,c['test'],val(True))) for c in sc]
            constraints += [dict(c,test=op('if',us,val(True),op('if',both(other,is_kr),c['test'],val(True)))) for c in rc]
            constraints += [dict(test=op('if',us,s_eligible,val(True)),inputs=['usmca_origin_eligible','usmca_properly_claimed'],label='USMCA benchmark requires entitlement and proper claim'),
                dict(test=op('if',us,val(True),op('if',both(other,is_kr),eligible,val(True))),inputs=['column1_special_properly_claimed_and_eligible'],label='Special benchmark requires entitlement and proper claim')]
        scope=dict(template['scope'],hts_exact=htss)
        source_map=[dict(hts10=p,general_owner=native_products[p]['general']['source_code'],general_row=native_products[p]['general']['source_row_index'],
            special_owner=native_products[p]['special']['source_code'],special_row=native_products[p]['special']['source_row_index']) for p in htss if p in native_products]
        for high in (True,False):
            r=copy.deepcopy(template);r['id']+=f'_benchmark_{gi}_'+('high' if high else 'low');r['scope']=scope
            comparison=op('gte' if high else 'lt',general,val(spec['threshold']))
            r['when']=both(template['when'],valid,comparison)
            r['reporting_codes']=[spec['high_reporting_code'] if high else spec['low_reporting_code']]
            r['formula']=val(0) if high else op('multiply',valuation['basis'],op('max',val(0),op('subtract',val(spec['threshold']),general)))
            r['input_constraints']=list(valuation['constraints'])+constraints
            r['legal_locator']=spec['legal_locator']
            r['column1_reference']=dict(general_expression=basis.get('raw'),special_expression=(basis.get('usmca') or {}).get('raw'),source_rows=source_map,
                interpretation='Full-article source benchmark before Chapter98 valuation adjustment or another action suppresses payable base. Additional rate applies only to the legally dutiable value.')
            result.append(r)
        if valid!=val(True):
            r=copy.deepcopy(template);r['id']+=f'_benchmark_{gi}_invalid_value';r['scope']=scope
            r.update(when=both(template['when'],negate(valid)),formula=val(0),reporting_codes=[],
                input_constraints=[dict(test=val(False),inputs=['customs_value'],label='A specific/compound AVE requires positive full-article customs value')],legal_locator=spec['legal_locator'])
            result.append(r)
    return result

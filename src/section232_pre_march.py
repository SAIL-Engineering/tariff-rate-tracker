"""Source-defined January--March 2025 Section 232 metal decisions.

Country quota allocation and importer grants are shipment evidence, not an
average utilization share. Printed heading presence alone is not activation.
"""
from collections import defaultdict
import csv
from datetime import datetime
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo
from section232_legacy_sources import ROOT, codes, scoped_lists, sha, matches
from section232_note16_rules import val, fact, op, both, either, negate, choose

def transition_end():
    p=ROOT/'resources/legal_evidence/2025-02833/notice.txt'
    meta=json.loads(p.with_name('source.json').read_bytes())
    if sha(p.read_bytes())!=meta['sha256']:raise ValueError('Metal termination amendment hash mismatch')
    dates=set(re.findall(r'shall be ineffective as of 12:01 a\.m\. eastern time on ([A-Z][a-z]+ \d+, \d{4})',' '.join(p.read_text().split())))
    if len(dates)!=1:raise ValueError('Unresolved country-arrangement termination instant')
    return datetime.strptime(dates.pop(),'%B %d, %Y').replace(hour=0,minute=1,tzinfo=ZoneInfo('America/New_York')).isoformat()

EVIDENCE=ROOT/'resources/legal_evidence/section232/pre-march'


def precedes_march_transition(revision):
    rows=csv.DictReader((ROOT/'config/revision_dates.csv').open())
    row=next(r for r in rows if r['revision']==revision)
    day=row['policy_effective_date'] if row['policy_effective_date']!='NA' else row['effective_date']
    return '2025-01-01' <= day <= transition_end()[:10]


def top(note, letter, following=None):
    # Top-level subdivisions start in the margin; nested roman/subletters do not
    # have the recognized legal lead. Restrict to the unique complete paragraph.
    starts=list(re.finditer(r'^\s*\('+letter+r'\)\s+(?=(?:The|Any|Subheadings?|Headings?|\(i\)))',note,re.M))
    if len(starts)!=1:raise ValueError('Ambiguous pre-March subdivision '+letter)
    end=re.search(r'^\s*\('+following+r'\)\s+(?=(?:The|Any|Subheadings?|Headings?|\(i\)))',note[starts[0].end():],re.M) if following else None
    if following and not end:raise ValueError('Missing pre-March subdivision '+following)
    return note[starts[0].start():starts[0].end()+end.start() if end else len(note)].strip()


def scope_table(description):
    """Only classification references establish scope; retain statistical exclusions."""
    excludes=re.findall(r'\(except[^)]*\)',description)
    clean=re.sub(r'\(except[^)]*\)','',description)
    # Do not treat measurements, note numbers or other descriptions as codes.
    refs=re.findall(r'(?:provided for in|described in) (?:subheadings?|headings?|statistical reporting numbers?)\s*([^)]*)',clean)
    if not refs:raise ValueError('Unparsed quota category: '+description)
    return codes(' '.join(refs)),codes(' '.join(excludes))


def extract_pre_march(x):
    notes={n['number']:n['text'] for n in x['notes']}
    # Later revisions retain the old subdivisions beside the new ones. End the
    # legal state at the proclamation, not at the revision publication date.
    old=dict(notes)
    for n,letter in ((16,'i'),(19,'f')):
        boundary=re.search(r'^\s*\('+letter+r'\)\s+(?:The rates|Headings?|Any importer)',notes[n],re.M)
        if boundary:old[n]=notes[n][:boundary.start()]
    lists=[]
    for n,metal,ordinary,derivative,roman in [(16,'steel','9903.80.01','9903.80.03','ii'),(19,'aluminum','9903.85.01','9903.85.03','iii')]:
        b=top(old[n],'b','c')
        # Reuse the exact primary enumeration parser with a bounded paragraph.
        ls,_=scoped_lists(b+'\n(c) The rates',n,'b','c','primary',ordinary,metal)
        a=old[n][:old[n].index(b)]
        # Derivative A--F list alone, excluding subsequent roman subdivisions.
        start=re.search(r'Heading '+re.escape(derivative)+r' shall\s+apply only to',a)
        if not start:raise ValueError('Missing original derivative definition')
        tail=a[start.start():]
        stop=re.search(r'^\s*\((?:iii|iv)\)\s+',tail,re.M)
        if stop:tail=tail[:stop.start()]
        ds,_=scoped_lists('(a) The rates\n'+tail+'\n(b) The rates',n,'a','b','described',derivative,metal)
        for s in ls+ds:s['country_group']='ordinary'
        lists+=ls+ds
    schedule=json.loads(Path(x['sources'][1]['path']).read_bytes())
    headings=[];quotas=[];parents=[]
    def category(c):
        if '9903.80.05'<=c<='9903.80.58':return 'steel_absolute'
        if '9903.80.65'<=c<='9903.81.19':return 'steel_eu'
        if '9903.81.25'<=c<='9903.81.78':return 'steel_japan_uk'
        if '9903.85.05'<=c<='9903.85.06':return 'aluminum_absolute'
        if '9903.85.27'<=c<='9903.85.44':return 'aluminum_eu'
        if '9903.85.51'<=c<='9903.85.66':return 'aluminum_uk'
    for row in schedule:
        depth=int(row.get('indent',0));parents=parents[:depth]
        code=row.get('htsno','');desc=row.get('description','')
        if re.fullmatch(r'9903\.(?:80|81|85)\.\d{2}',code) and (code<'9903.81.87' or code.startswith('9903.85.') and code not in ('9903.85.02','9903.85.04','9903.85.07','9903.85.08','9903.85.09')):
            expression=row.get('general','').strip()
            m=re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*([\d.]+)%\.?',expression)
            if m:rate=float(m[1])/100
            elif expression=='Free' or re.fullmatch(r'The duty provided (?:for )?in the applicable subheading\.?',expression):rate=0
            else:raise ValueError('Unparsed pre-March formula '+expression)
            h=dict(code=code,description=desc,duty_expression=expression,rate=rate,valuation_basis='customs_value',superior_text=list(parents))
            headings.append(h)
            group=category(code)
            if group:
                inc,exc=scope_table(desc)
                if not inc:raise ValueError('Empty quota scope '+code)
                quotas.append(dict(code=code,group=group,includes=inc,excludes=exc,description=desc,superior_text=list(parents)))
        parents.append(desc)
    bulletins=[];gae={}
    for meta in json.loads((EVIDENCE/'sources.json').read_bytes()):
        p=EVIDENCE/meta['path']
        if sha(p.read_bytes())!=meta['sha256']:raise ValueError('Quota instruction hash mismatch')
        text=p.read_text();bulletins.append(dict(**meta,artifact_path=str(p)))
        m=re.search(r'Current GAE HTS list as of July 1, 2024:\s*([^\n]+)',text)
        if not m:raise ValueError('Missing current GAE table')
        table=codes(m[1]);metal='steel' if '-6' in meta['id'] else 'aluminum'
        if any(len(c)!=10 for c in table):raise ValueError('Nonstatistical GAE reference')
        if metal in gae and gae[metal]!=table:raise ValueError('Conflicting GAE tables')
        gae[metal]=table
    eu=re.search(r'shall include the following:\s*(.*?)Sweden\.',old[16],re.S)
    if not eu:raise ValueError('Missing EU membership')
    names=[s.strip() for s in (' '.join(eu[1].split())+'Sweden').split(',')]
    countries={r['Name']:r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())}
    aliases={'Czechia (Czech Republic)':'Czech Republic','Denmark':'Denmark, except Greenland','Germany':'Germany (Federal Republic of Germany)'}
    def resolve(name):
        name=aliases.get(name,name)
        if name not in countries:raise ValueError('Unresolved country '+name)
        return countries[name]
    eu_codes=[resolve(n) for n in names]
    # A zero in the aggregate configuration must at least have a legally
    # available country exemption/quota path for that metal. It is still a
    # modeling assumption about admission, never proof for a shipment.
    model_zero={}
    for metal,code in [('steel','9903.80.01'),('aluminum','9903.85.01')]:
        description=next(h['description'] for h in headings if h['code']==code)
        exemption=description.split(', except products of ',1)
        if len(exemption)!=2:raise ValueError('Missing primary country exceptions')
        text=exemption[1].split('under any')[0]
        text+=' '+' '.join(' '.join(q['superior_text']) for q in quotas if q['group'].startswith(metal+'_'))
        eligible=set(eu_codes if 'European Union' in text else [])
        for name,cc in countries.items():
            plain=name.split(' (')[0]
            if re.search(r'(?<![A-Za-z])'+re.escape(plain)+r'(?![A-Za-z])',text):eligible.add(cc)
        model_zero[metal]=sorted(eligible)
    return dict(model_zero_country_candidates=model_zero,lists=lists,notes=[dict(number=n,text=t) for n,t in old.items()],headings=headings,quotas=quotas,
        gae=gae,eu_countries=eu_codes,bulletins=bulletins,valid_until=transition_end(),
        extractor_sha256=sha(Path(__file__).read_bytes()))


def check_review(x):
    review=json.loads((EVIDENCE/'reviewed-semantics.json').read_bytes())
    accepted={(r['locator'],r['sha256']) for r in review['entries']}
    for locator,text in [(f'n{n["number"]}',n['text']) for n in x['notes']]+[(h['code'],h['description']+' '+' '.join(h['superior_text'])) for h in x['headings']]:
        if (locator,sha(' '.join(text.split()).encode())) not in accepted:raise ValueError('Unreviewed pre-March condition '+locator)


def compile_pre_march(outer, products, jurisdictions):
    x=outer['pre_march'];check_review(x)
    for source in x['bulletins']:
        if sha(Path(source['artifact_path']).read_bytes())!=source['sha256']:raise ValueError('Changed quota instruction source')
    calendar={r['revision']:(r['policy_effective_date'] if r['policy_effective_date']!='NA' else r['effective_date']) for r in csv.DictReader((ROOT/'config/revision_dates.csv').open())}
    day=calendar[outer['revision']];later=sorted(d for d in calendar.values() if d>day)
    instant=lambda d:datetime.fromisoformat(d).replace(tzinfo=ZoneInfo('America/New_York')).isoformat()
    start=instant(day);until=min(instant(later[0]),x['valid_until'])
    if start>=x['valid_until']:raise ValueError('Pre-March compiler outside legal interval')
    release=outer['revision'].replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    sources=[];artifacts=[]
    for i,s in enumerate(outer['sources']):
        id=f'USITC-{outer["revision"]}-pre-march-{i}'
        sources.append(dict(id=id,status='verified',sha256=s['sha256'],url=f'https://hts.usitc.gov/reststop/file?release={release}&filename=Chapter%2099' if i==0 else f'https://hts.usitc.gov/reststop/exportList?release={release}&exportFormat=JSON',citation=f'USITC {outer["revision"]}, U.S. notes 16(a)-(h), 19(a)-(e); quota superior text and individual headings.'))
        artifacts.append(dict(source_id=id,path=s['path'],sha256=s['sha256']))
    for s in x['bulletins']:
        sources.append(dict(id=s['id'],status='verified',**{k:s[k] for k in ('sha256','url','citation')}))
        artifacts.append(dict(source_id=s['id'],path=s['artifact_path'],sha256=s['sha256']))
    for doc in ('2025-02832','2025-02833','2025-09066'):
        p=ROOT/f'resources/legal_evidence/{doc}/notice.txt';s=json.loads(p.with_name('source.json').read_bytes())
        if sha(p.read_bytes())!=s['sha256']:raise ValueError('Amendment hash mismatch')
        id='FR-'+doc;sources.append(dict(id=id,status='verified',**{k:s[k] for k in ('sha256','url','citation')}));artifacts.append(dict(source_id=id,path=str(p),sha256=s['sha256']))
    ids=[s['id'] for s in sources];facts={};rules=[];decisions=[]
    def f(key,label,kind='boolean',description=None):
        facts[key]=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':facts[key].update(minimum=0,unit='USD')
        if description:facts[key]['description']=description
        return fact(key)
    cv=f('customs_value','Customs value (USD)','number')
    hs={h['code']:h for h in x['headings']}
    def leaf(code=None,reason=None):
        return dict(code=code,formula=op('multiply',cv,val(hs[code]['rate'])) if code and hs[code]['rate'] else val(0),reason=reason)
    def gap(reason):return dict(formula={'unresolved_source':reason},reason=reason)
    def emit(tree,path,scope,locator):
        if isinstance(tree,tuple):
            _,test,yes,no=tree
            emit(yes,op('if',path,test,val(False)),scope,locator);emit(no,op('if',path,negate(test),val(False)),scope,locator);return
        id='s232_pre_march_'+str(len(rules));code=tree.get('code')
        r=dict(id=id,action_id='s232_pre_march_'+locator['metal'],authority='section_232',kind='duty',verification='verified',scope=scope,when=path,formula=tree['formula'],reporting_codes=[code] if code else [],source_ids=ids,legal_locator=locator['locator'])
        if code:r['published_expression']=hs[code]['duty_expression']
        if tree.get('constraints'):r['input_constraints']=tree['constraints']
        r['section232_metal']=locator['metal']
        r['section232_country_group']=country
        r['section232_treatment']=tree.get('section232_treatment','russian_aluminum' if code in ('9903.85.67','9903.85.68','9903.85.69','9903.85.70') else 'ordinary_metal')
        if (tree.get('reason') or '').startswith('Country exempt under the archived note'):
            r['section232_treatment']='independent_country_relief'
        r['grant_reporting_codes']=[grant_code] if grant_code else []
        if locator['metal']=='aluminum':
            russian_test=val(True) if country=='Russia' else fact('aluminum_primary_smelted_or_cast_russia')
            r['grant_material_condition']=russian_test if r['section232_treatment']=='russian_aluminum' else negate(russian_test)
        rules.append(r);decisions.append(dict(rule_id=id,reporting_codes=r['reporting_codes'],legal_locator=locator['locator'],status='requires_source_reconciliation' if 'unresolved_source' in tree['formula'] else 'compiled',reason=tree.get('reason')))
    def quota_tree(metal, group, candidates, standard):
        qs=[q for q in candidates if q['group']==group]
        allocation=f('s232_'+metal+'_quota_allocated','CBP allocated quota to this entire entry line',description='Use the actual country/category and presentation date allocation. Split partially allocated lines; a modeled utilization share is not an allocation.')
        choices=[]
        for q in qs:
            conditional=len(qs)>1 or bool(re.search(r'Products meeting|clad products',q['description']))
            cond=f('s232_quota_description_'+q['code'].replace('.',''),'Matches quota category '+q['code'],description=q['description']) if conditional else val(True)
            choices.append((q,cond))
        tree=gap('quota_category_not_established_by_archived_schedule' if not qs else 'quota_category_description_not_established')
        for q,cond in reversed(choices):
            branch=leaf(q['code']);others=[c for other,c in choices if other!=q]
            if others:branch=choose(either(*others),gap('overlapping_quota_descriptions'),branch)
            tree=choose(cond,branch,tree)
        if group.endswith('_absolute'):
            denied=leaf(reason='Absolute quota has not been allocated; consumption entry is not authorized without relief.')
            denied['constraints']=[dict(test=allocation,inputs=['s232_'+metal+'_quota_allocated'],reason='Absolute quota has not been allocated: no over-quota duty alternative.')]
            return choose(allocation,tree,denied)
        # Above-quota liability is known even if the source cannot establish the
        # claimed in-quota category. Do not demand an irrelevant quota heading.
        return choose(allocation,tree,standard)
    byproduct=defaultdict(list);scopes={s['id']:s for s in x['lists']}
    for r in matches(x,products):
        if r['list_id'] not in byproduct[r['hts10']]:byproduct[r['hts10']].append(r['list_id'])
    countries={r['Name']:r['Code'] for r in csv.DictReader((ROOT/'resources/census_codes.csv').open())}
    named=lambda name:countries[{'South Korea':'South Korea (Republic of Korea)'}.get(name,name)]
    eu=set(x['eu_countries']);all_c=set(jurisdictions['all']);grouped=defaultdict(list)
    for hts,ls in byproduct.items():
        qs=tuple(sorted(q['code'] for q in x['quotas'] if any(hts.startswith(p) for p in q['includes']) and not any(hts.startswith(p) for p in q['excludes'])))
        gae=tuple(m for m in ('steel','aluminum') if hts in x['gae'][m])
        grouped[(tuple(sorted(ls)),qs,gae)].append(hts)
    claim_candidates=defaultdict(list)
    for (ls,qcodes,gae),htss in sorted(grouped.items()):
      for lid in ls:
        s=scopes[lid];metal=s['metal'];derivative=s['derivative'];ordinary=s['reporting_code']
        cond=f('s232_scope_'+lid,'Matches '+s['locator'],description=s['condition_text']) if s['condition_text'] else val(True)
        if derivative:cond=both(f('contains_'+metal,'Article contains '+metal),cond)
        candidates=sorted([q for q in x['quotas'] if q['code'] in qcodes],key=lambda q:q['code'])
        # Sharing equal legal branches keeps the bundle tractable across all origins.
        groups={name:([named(name)] if named(name) in all_c else []) for name in ('Canada','Mexico','Australia','Argentina','Brazil','South Korea','Japan','United Kingdom','Ukraine','Russia','United States of America')}
        groups['eu']=sorted(eu&all_c);used={c for cs in groups.values() for c in cs};groups['ordinary']=sorted(all_c-used)
        for country,cc in groups.items():
          if not cc:continue
          # CBP's country-specific quota bulletins distinguish the exclusion
          # reporting identity from the original quota category. Reuse this
          # decision for both GAEs and reviewed individual grants.
          grant_code=(('9903.80.60' if country in ('Argentina','Brazil','South Korea') else '9903.81.80' if country in ('Japan','United Kingdom') else None) if metal=='steel' else ('9903.85.11' if country=='Argentina' else '9903.85.25' if country=='eu' else '9903.85.50' if country=='United Kingdom' else None)) if not derivative else None
          standard=leaf(ordinary);tree=standard
          exemption=['Canada','Australia','United States of America']
          if derivative:exemption+=['Argentina','eu','United Kingdom']+(['Brazil','South Korea','Japan'] if metal=='steel' else [])
          if country in exemption:tree=leaf(reason='Country exempt under the archived note and heading; no Section 232 reporting heading')
          elif country=='Mexico':
            if metal=='steel':test=f('steel_melted_poured_us_mexico_canada','Steel melted and poured in the US, Mexico or Canada');tree=choose(test,leaf(),leaf('9903.81.86' if derivative else '9903.81.85'))
            else:test=f('aluminum_smelt_cast_china_russia_belarus_iran','Primary/secondary smelt or most recent cast is China, Russia, Belarus or Iran');tree=choose(test,leaf('9903.85.72' if derivative else '9903.85.71'),leaf())
          elif metal=='steel' and country=='Ukraine':
            tree=choose(f('ukraine_steel_certificate_of_origin','Required Ukrainian steel certificate of origin supplied'),leaf(),leaf('9903.81.84' if derivative else '9903.81.83'))
          elif not derivative:
            if country in (['Argentina','Brazil','South Korea'] if metal=='steel' else ['Argentina']):tree=quota_tree(metal,metal+'_absolute',candidates,standard)
            elif country in ('eu','United Kingdom') or metal=='steel' and country=='Japan':
                group=metal+('_eu' if country=='eu' else '_japan_uk' if metal=='steel' else '_uk')
                tree=quota_tree(metal,group,candidates,standard)
                if metal=='steel':
                    melt=f('steel_melted_poured_'+('eu' if country=='eu' else 'japan' if country=='Japan' else 'uk'),'Steel melted and poured in '+('an EU member country' if country=='eu' else country))
                    if country=='United Kingdom':tree=choose(f('uk_steel_producer_trq_access','UK producer has TRQ access under the attestation requirements'),tree,standard)
                    tree=choose(melt,tree,standard)
                    if country=='eu':
                        special=choose(f('s232_steel_quota_allocated','CBP allocated quota to this entire entry line'),leaf('9903.81.81'),standard)
                        tree=choose(f('steel_melted_poured_uk','Steel melted and poured in United Kingdom'),special,tree)
                        tree=choose(f('steel_melted_poured_ukraine','Steel melted and poured in Ukraine'),leaf('9903.81.82'),tree)
                else:
                    if country=='United Kingdom' and not all(h.startswith('7601') for h in htss):
                        tree=choose(f('aluminum_primary_china_russia_belarus','Wrought aluminum contains primary aluminum from China, Russia or Belarus'),standard,tree)
                    tree=choose(f('aluminum_certificate_of_analysis','Required aluminum Certificate of Analysis or CBP-accepted information supplied'),tree,standard)
          # General Approved Exclusions are exact statistical entries. They are
          # claims and do not suppress the distinct Russian action.
          gae_claim='section232:gae:'+metal
          if metal in gae and country!='Russia' and not (isinstance(tree,dict) and tree.get('formula')==val(0) and not tree.get('code')):
            tree=choose({'claim':gae_claim},leaf(grant_code,'General Approved Exclusion, exact HTS10 and pre-March interval'),tree)
          if metal=='aluminum':
            russian=val(True) if country=='Russia' else f('aluminum_primary_smelted_or_cast_russia','Any primary aluminum smelted in Russia or article cast in Russia')
            rtree=choose(f('privileged_ftz_before_20230410','Privileged foreign status before April 10, 2023 at 00:01 Eastern'),leaf('9903.85.70' if derivative else '9903.85.69'),leaf('9903.85.68' if derivative else '9903.85.67'))
            tree=choose(russian,rtree,tree)
          # An individual Commerce grant is not inferred from the HTS or an
          # unverified exclusion ID. It needs the reproducible grant inventory.
          grant='section232:individual:'+metal
          def grant_effect(branch):
              if isinstance(branch,tuple):return choose(branch[1],grant_effect(branch[2]),grant_effect(branch[3]))
              if branch.get('formula')==val(0) and not branch.get('code') and not branch.get('constraints'):return branch
              missing=gap('individual_commerce_grant_requires_verified_party_scope_entry_window_quantity_and_reporting')
              missing['section232_treatment']='russian_aluminum' if branch.get('code') in ('9903.85.67','9903.85.68','9903.85.69','9903.85.70') else 'ordinary_metal'
              return choose({'claim':grant},missing,branch)
          tree=grant_effect(tree)
          begin=len(rules)
          emit(tree,cond,dict(hts_exact=sorted(htss),countries=sorted(cc),**{'from':start,'until':until}),s)
          for claim in (grant,gae_claim):
              candidate_ids=[r['id'] for r in rules[begin:] if json.dumps({'claim':claim}) in json.dumps(r['when'])]
              if candidate_ids:claim_candidates[claim]+=candidate_ids
    all_ids=[r['id'] for r in rules];claims=[dict(id='USMCA',label='USMCA',rule_ids=all_ids,source_ids=ids)] if rules else []
    for claim,cs in sorted(claim_candidates.items()):claims.append(dict(id=claim,label=claim,rule_ids=all_ids,candidate_rule_ids=cs,source_ids=ids))
    relations=[]
    # EO 14289 was retroactive to March 4. Dependency on the actual emergency
    # action (not on a country flag) reevaluates USMCA and zero-duty outcomes.
    charged=sorted({r['reporting_codes'][0] for r in rules if r['reporting_codes'] and hs[r['reporting_codes'][0]]['rate']>0})
    if charged:relations.append(dict(id='pre_march_emergency_precedence_'+outer['revision'],effect='suppress_by_reporting_codes',trigger_reporting_codes=['9903.01.10','9903.01.01'],trigger_test='positive_duty',target_reporting_codes=charged,source_ids=ids))
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='s232_pre_march_'+outer['revision'],compiler_sha256=sha(Path(__file__).read_bytes()),extractor_sha256=outer['extractor_sha256'],semantic_review_sha256=sha((EVIDENCE/'reviewed-semantics.json').read_bytes()),compiler_dependencies={p:sha((ROOT/p).read_bytes()) for p in ('resources/census_codes.csv','src/section232_legacy_sources.py','config/revision_dates.csv')},supported_from=start,supported_until=until,sources=sources,source_artifacts=artifacts,rules=rules,fact_definitions=facts,relations=relations,reporting_decisions=decisions,coverage=[],claim_definitions=claims,unchanged_claims=[dict(id='pre_march_301_claims_'+outer['revision'],claim_authority='section_301',target_rule_ids=all_ids,source_ids=ids),dict(id='pre_march_exclusion_independence_'+outer['revision'],claim_authority='section_232',claim_ids=sorted(claim_candidates),target_authorities=['section_301','ieepa_fentanyl'],source_ids=ids),dict(id='pre_march_exclusion_ordinary_base_'+outer['revision'],claim_authority='section_232',claim_ids=sorted(claim_candidates),target_authorities=['base'],target_base_treatments=['column1_general','column2'],source_ids=ids)] if rules else [],limitations=['Individual Commerce grants require a verified grant inventory; claim remains unpriced without it.','Quota allocation is an entry-line input; partially apportioned lines must be split. Absolute quota rejection is not a tariff alternative.','No all-authority coverage attestation. Chapter 98 and other authority claim effects require separate compilation.'])

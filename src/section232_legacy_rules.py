"""Compile source-defined March 2025--April 2026 metal reporting decisions.

No aggregate shares enter this interpreter. This fragment intentionally supplies
no all-authority coverage attestation. Uncompiled exceptions remain explicit.
"""
from __future__ import annotations
import argparse
from collections import defaultdict
import csv
from datetime import datetime
import json
from pathlib import Path
import re
from zoneinfo import ZoneInfo
from section232_legacy_sources import ROOT, extract, matches, sha
from section232_note16_rules import val, fact, op, both, either, negate, choose


def compile_legacy(x, products, jurisdictions, _entry_window=None):
    from section232_pre_march import compile_pre_march
    if x['regime']=='pre_march_2025':return compile_pre_march(x,products,jurisdictions)
    if x['regime']!='march_2025_metals':raise ValueError('Unsupported legacy metal regime')
    grammar=ROOT/'resources/legal_evidence/section232/legacy-reviewed-semantics.json'
    reviewed=json.loads(grammar.read_bytes())
    accepted={(c['locator'],c['sha256']) for c in reviewed['entries']}
    for locator,text in [(c['locator'],c['text']) for c in x['clauses']]+[(h['code'],h['description']) for h in x['headings']]:
        if (locator,sha(' '.join(text.split()).encode())) not in accepted:
            raise ValueError('Unreviewed historical metal condition: '+locator)
    rows=list(csv.DictReader((ROOT/'config/revision_dates.csv').open()))
    calendar={r['revision']:(r['policy_effective_date'] if r['policy_effective_date']!='NA' else r['effective_date']) for r in rows}
    day=calendar[x['revision']]
    later=sorted(d for d in calendar.values() if d>day)
    def instant(d):return datetime.fromisoformat(d).replace(tzinfo=ZoneInfo('America/New_York')).isoformat()
    start=instant(day);until=min(instant(later[0]),'2026-04-06T00:01:00-04:00')
    active_from=max(start,'2025-03-12T00:01:00-04:00')
    if _entry_window:
        active_from,until=_entry_window
    ids=[f'USITC-{x["revision"]}-legacy-notes',f'USITC-{x["revision"]}-legacy-headings']
    release=x['revision'].replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    sources=[dict(id=id,status='verified',sha256=s['sha256'],
        url=f'https://hts.usitc.gov/reststop/file?release={release}&filename=Chapter%2099' if i==0 else
            f'https://hts.usitc.gov/reststop/exportList?release={release}&exportFormat=JSON',
        citation=f'USITC {x["revision"]}, U.S. notes 16 and 19; individual subdivision and heading retained on each decision.')
        for i,(id,s) in enumerate(zip(ids,x['sources']))]
    artifacts=[dict(source_id=id,path=s['path'],sha256=s['sha256']) for id,s in zip(ids,x['sources'])]
    for doc in ('2025-02832','2025-02833','2025-09066','2025-10524','2025-14999'):
        p=ROOT/f'resources/legal_evidence/{doc}/notice.txt';m=json.loads(p.with_name('source.json').read_bytes())
        if m['sha256']!=sha(p.read_bytes()):raise ValueError('Amendment hash mismatch '+doc)
        id='FR-'+doc;ids.append(id)
        sources.append(dict(id=id,status='verified',**{k:m[k] for k in ('sha256','url','citation')}))
        artifacts.append(dict(source_id=id,path=str(p),sha256=m['sha256']))
    audit=ROOT/'docs/audits/2026-10-23-stacking-followup'
    meta=next(s for s in json.loads((audit/'sources.json').read_bytes()) if s['path']=='CSMS-65054270.txt')
    p=audit/meta['path']
    if sha(p.read_bytes())!=meta['sha256']:raise ValueError('CBP precedence source hash mismatch')
    ids.append('CBP-CSMS-65054270')
    sources.append(dict(id=ids[-1],status='verified',sha256=meta['sha256'],url=meta['url'],
        citation='CBP CSMS 65054270, May 15, 2025; EO 14289 action precedence, positive duty owed, and cumulative Section 301. Amended June 4 by Proclamation 10947.'))
    artifacts.append(dict(source_id=ids[-1],path=str(p),sha256=meta['sha256']))
    facts={}
    def f(key,label,kind='boolean',description=None):
        d=dict(type=kind,label=label,source_ids=list(ids))
        if kind=='number':d.update(minimum=0,unit='USD')
        if description:d['description']=description
        facts[key]=d;return fact(key)
    cv=f('customs_value','Customs value (USD)','number')
    headings={h['code']:h for h in x['headings']}
    scopes={s['id']:s for s in x['lists']}
    grouped=defaultdict(list);membership=defaultdict(set)
    for r in matches(x,products):membership[(r['hts10'],r['metal'],r['country_group'])].add(r['list_id'])
    for (hts,metal,country),ls in membership.items():grouped[(metal,country,hts[:2],tuple(sorted(ls)))].append(hts)
    uk=jurisdictions['uk'];russia=jurisdictions['russia']
    if not uk or not russia or not jurisdictions['all']:raise ValueError('Missing country inventory')
    has_uk=any(s['country_group']=='uk' for s in x['lists'])
    after_june=day>='2025-06-04'
    if has_uk!=after_june:raise ValueError('Heading/source chronology mismatch')
    rules=[];relations=[];decisions=[]
    def emit(tree,path,scope,metal,loc):
        if isinstance(tree,tuple):
            _,test,yes,no=tree
            emit(yes,op('if',path,test,val(False)),scope,metal,loc)
            emit(no,op('if',path,negate(test),val(False)),scope,metal,loc)
            return
        if tree.get('skip'):return
        code=tree.get('code');error=tree.get('error')
        id=f's232_legacy_{metal}_{len(rules)}'
        r=dict(id=id,action_id=f's232_legacy_{metal}',authority='section_232',kind='duty',
            verification='verified',scope=scope,when=path,formula=tree.get('formula',{'unresolved_source':error}),
            reporting_codes=[code] if code else [],source_ids=list(ids),legal_locator=loc)
        if code:r['published_expression']=headings[code]['duty_expression']
        if tree.get('constraints'):r['input_constraints']=tree['constraints']
        r['section232_metal']=metal
        r['section232_treatment']='russian_aluminum' if code in ('9903.85.67','9903.85.68','9903.85.69','9903.85.70') else 'ordinary_metal'
        r['grant_reporting_codes']=[]
        if metal=='aluminum':
            russian_test=val(True) if russian_coo else fact('aluminum_primary_smelted_or_cast_russia')
            r['grant_material_condition']=russian_test if r['section232_treatment']=='russian_aluminum' else negate(russian_test)
        rules.append(r)
        decisions.append(dict(rule_id=id,legal_locator=loc,reporting_codes=r['reporting_codes'],
            status='requires_source_reconciliation' if error else 'compiled',reason=error))
    def gap(reason,code=None):return dict(error=reason,code=code)
    def leaf(code,chapter,metal):
        h=headings[code];basis=h['valuation_basis']
        # Proclamation 10947 clause 6 overrides the heading's abbreviated
        # expression. Russian 200-percent treatment stays on the full value.
        russian=code in ('9903.85.67','9903.85.68','9903.85.69','9903.85.70')
        if after_june and chapter==('73' if metal=='steel' else '76') and not russian and basis!='no_change':
            basis=metal+'_content_value'
        amount=cv if basis=='customs_value' else f(basis,metal.title()+' content value (USD)','number') if basis!='no_change' else val(0)
        r=dict(code=code,formula=op('multiply',amount,val(h['rate'])))
        if basis.endswith('_content_value'):
            r['constraints']=[dict(test=op('lte',amount,cv),inputs=[basis,'customs_value'],
                reason='Metal content value exceeds customs value')]
        return r
    for (metal,country,chapter,ls),htss in sorted(grouped.items()):
        countries=sorted(set(uk if country=='uk' else set(jurisdictions['all'])-set(uk) if has_uk else jurisdictions['all']))
        # Keep Russian COO independent from primary smelt/cast in another COO.
        for russian_coo in (False,True):
            cc=[c for c in countries if (c in russia)==russian_coo]
            if not cc:continue
            byheading=defaultdict(list)
            for id in ls:byheading[scopes[id]['reporting_code']].append(scopes[id])
            candidates=[]
            for code,entries in sorted(byheading.items()):
                conditions=[]
                for s in entries:
                    conditions.append(f('s232_scope_'+s['id'],'Matches '+s['locator'],description=s['condition_text']) if s['condition_text'] else val(True))
                candidates.append((code,either(*conditions),entries))
            original={code:condition for code,condition,_ in candidates}
            resolved=[]
            for code,condition,entries in candidates:
                # Primary steel expressly excludes the named derivative
                # headings. Resolve that legal precedence before declaring
                # overlapping lists ambiguous (e.g. an HTS6 primary range).
                desc=headings[code]['description']
                exception=re.match(r'Except for derivative .*? described in headings (.*?), products',desc)
                excluded=re.findall(r'9903\.\d{2}\.\d{2}',exception[1]) if exception else []
                blockers=[original[c] for c in excluded if c in original]
                if blockers:condition=both(condition,negate(either(*blockers)))
                resolved.append((code,condition,entries))
            candidates=resolved
            for code,condition,entries in candidates:
                s=entries[0];loc='; '.join(e['locator'] for e in entries)
                others=[c for other,c,_ in candidates if other!=code]
                tree=leaf(code,chapter,metal)
                # A source uses the US-material exception only for the newly
                # added derivative lists, not for primary or 2020 derivatives.
                if 'unless the derivative' in s['source_text']:
                    label='Steel melted and poured in the United States' if metal=='steel' else 'Aluminum smelted and cast in the United States'
                    relief='9903.81.92' if metal=='steel' else '9903.85.09'
                    tree=choose(f(metal+'_processed_from_us_metal',label),leaf(relief,chapter,metal),tree)
                # Certain legacy steel FTZ headings differ despite equal rates.
                for h in x['headings']:
                    if 'foreign trade zone' not in h['description'] or not h['code'].startswith('9903.81'):continue
                    refs=re.findall(r'subdivision(?:s)?\s+((?:\([a-z]\)(?:\s*(?:and|,)\s*)?)+)',h['description'])
                    letters=set(re.findall(r'\(([a-z])\)',' '.join(refs)))
                    if not any(e['id'].split('_')[1] in letters for e in entries):continue
                    if ('United Kingdom' in h['description']) != (country=='uk'):continue
                    date=re.search(r'prior to 12:01 a\.m\..*?on ([A-Z][a-z]+ \d+, \d{4})',h['description'])
                    if not date:raise ValueError('Unparsed FTZ heading condition')
                    cutoff=datetime.strptime(date[1],'%B %d, %Y').strftime('%Y%m%d')
                    ftz=f('privileged_ftz_before_'+cutoff,'Privileged foreign status before '+date[1]+' at 00:01 Eastern',
                        description=h['description'])
                    # The special .93/.99 heading expressly excludes the US
                    # melted/poured exception. Check that predicate first.
                    ftz_branch=leaf(h['code'],chapter,metal)
                    if 'unless the derivative' in s['source_text']:
                        ftz_branch=choose(fact(metal+'_processed_from_us_metal'),leaf('9903.81.92',chapter,metal),ftz_branch)
                    tree=choose(ftz,ftz_branch,tree)
                if 'unless the derivative' in s['source_text']:
                    # Domestic-material relief does not require an FTZ answer.
                    tree=choose(fact(metal+'_processed_from_us_metal'),leaf(relief,chapter,metal),tree)
                if metal=='aluminum':
                    russian=val(True) if russian_coo else f('aluminum_primary_smelted_or_cast_russia',
                        'Any primary aluminum smelted in Russia or article cast in Russia')
                    russian_code='9903.85.68' if s['derivative'] else '9903.85.67'
                    # Pre-April-10-2023 privileged status has distinct .69/.70.
                    rtree=choose(f('privileged_ftz_before_20230410','Privileged foreign status before April 10, 2023 at 00:01 Eastern'),
                        leaf('9903.85.70' if s['derivative'] else '9903.85.69',chapter,metal),leaf(russian_code,chapter,metal))
                    tree=choose(russian,rtree,tree)
                if others:tree=choose(either(*others),gap('overlapping_legacy_metal_categories'),tree)
                if s['derivative']:
                    condition=both(f('contains_'+metal,'Article contains '+metal),condition)
                scope=dict(hts_exact=sorted(htss),countries=cc,**{'from':active_from,'until':until})
                emit(tree,condition,scope,metal,loc)
    charged_codes=sorted({r['reporting_codes'][0] for r in rules if r['reporting_codes'] and headings[r['reporting_codes'][0]]['rate']>0})
    # Action dependencies are bound to the assembled bundle's actual rules,
    # including their claims and dates. An exclusion of Section 301 cannot be
    # reused as an exclusion of Section 232.
    schedule=json.loads(Path(x['sources'][1]['path']).read_bytes())
    auto_codes=sorted({r['htsno'] for r in schedule if re.fullmatch(r'9903\.94\.\d{2}',r.get('htsno',''))
        and re.search(r'[1-9][\d.]*%',r.get('general',''))})
    from ieepa_fentanyl_sources import extract as emergency_extract
    emergency=emergency_extract(Path(x['sources'][0]['path']),Path(x['sources'][1]['path']),x['revision'])
    # EO 14289 identifies presidential actions, not two abbreviated ordinary
    # headings. Energy and potash carveouts remain under EO 14193/14194 as
    # amended. EO 14325 sec. 2(d) preserves stacking for its sec. 2 ordinary
    # rate change; the separate sec. 3 anti-evasion charge expressly retains
    # other applicable duties and cannot inherit that ordinary exemption.
    triggers=sorted({a['ch99_code'] for a in emergency['actions'] if a['rate']>0 and
        a['entry_type'] in ('general','carveout') and
        set(a['country_names']) & {'Canada','Mexico'}})
    if after_june and triggers:
        for r in rules:
            if r['reporting_codes'] and r['reporting_codes'][0] in charged_codes:
                # Bind individual rules so the one-minute June predecessor
                # keeps its own ordering. Russian aluminum is explicitly
                # included by 90 FR 21487 footnote 1; zero relief is not.
                relations.append(dict(id=r['id']+'_emergency',effect='suppress',when_rule_applies=r['id'],
                    trigger_test='positive_duty',target_reporting_codes=triggers,source_ids=list(ids)))
    if auto_codes and charged_codes:
        relations.append(dict(id='legacy_auto_precedence_'+x['revision'],effect='suppress_by_reporting_codes',
            trigger_reporting_codes=auto_codes,trigger_test='positive_duty',target_reporting_codes=sorted(set(charged_codes+triggers)),source_ids=ids))
    if not after_june:
        if triggers and charged_codes:relations.append(dict(id='legacy_emergency_precedence_'+x['revision'],effect='suppress_by_reporting_codes',
            trigger_reporting_codes=triggers,trigger_test='positive_duty',target_reporting_codes=charged_codes,source_ids=ids))
    result=dict(contract_version='sail.shipment-rule-fragment/v1',id='s232_legacy_'+x['revision'],
        compiler_sha256=sha(Path(__file__).read_bytes()),extractor_sha256=x['extractor_sha256'],
        compiler_dependencies={name:sha(Path(__file__).with_name(name).read_bytes()) for name in
            ('section232_note16_rules.py','ieepa_fentanyl_sources.py','section301_sources.py','section232_pre_march.py')},
        semantic_review_sha256=sha(grammar.read_bytes()),
        supported_from=start,supported_until=until,sources=sources,source_artifacts=artifacts,
        rules=rules,fact_definitions=facts,relations=relations,reporting_decisions=decisions,coverage=[],
        claim_definitions=[dict(id='USMCA',label='USMCA',rule_ids=[r['id'] for r in rules],source_ids=ids)] if rules else [],
        unchanged_claims=[dict(id='s232_legacy_'+x['revision']+'_section301_claims',
            claim_authority='section_301',target_rule_ids=[r['id'] for r in rules],source_ids=list(ids))] if rules else [],
        limitations=['Only the identified revision and ordinary metal/US-material/Russian-material decisions are compiled.',
            'Pre-March quotas, exclusion grants, civil-aircraft/Chapter 98 and other Section 232 precedence require separate rules.',
            'No all-authority coverage or complete total is attested. Section 301 remains cumulative; its exclusion does not erase metal duties.'])
    # The daily release calendar changes at midnight, but Proclamation 10947
    # changes rates, valuation and stacking at 00:01. Resolve that leading
    # minute from the preceding archived notes/headings, not today's rate or
    # a fabricated heading. This narrowly verified transition is not a rule
    # that every revision or FTZ admission date starts at 00:01.
    transition=x['content_amendment_from']
    if not _entry_window and start < transition < until:
        for r in result['rules']:r['scope']['from']=max(r['scope']['from'],transition)
        previous=max((d,rev) for rev,d in calendar.items() if d<day)[1]
        prior=extract(ROOT/f'data/us_notes/chapter99_{previous}.pdf',
            ROOT/f'data/hts_archives/hts_{previous}.json',previous)
        old=compile_legacy(prior,products,jurisdictions,_entry_window=(start,transition))
        prefix='before_june_amendment_'
        mapping={r['id']:prefix+r['id'] for r in old['rules']}
        for r in old['rules']:r['id']=mapping[r['id']]
        for d in old['reporting_decisions']:d['rule_id']=mapping[d['rule_id']]
        for edge in old['relations']:
            if edge['id'].startswith('legacy_emergency_precedence_'):
                edge['target_rule_ids']=list(mapping.values())
            edge['id']=prefix+edge['id']
            if edge.get('when_rule_applies'):edge['when_rule_applies']=mapping[edge['when_rule_applies']]
        for edge in old['unchanged_claims']:
            edge['id']=prefix+edge['id'];edge['target_rule_ids']=[mapping[i] for i in edge['target_rule_ids']]
        for key in ('sources','source_artifacts'):
            idkey='id' if key=='sources' else 'source_id'
            byid={s[idkey]:s for s in result[key]}
            for s in old[key]:
                if s[idkey] in byid and byid[s[idkey]]!=s:raise ValueError('Conflicting transition evidence')
                byid[s[idkey]]=s
            result[key]=list(byid.values())
        for key,d in old['fact_definitions'].items():
            if key not in result['fact_definitions']:result['fact_definitions'][key]=d
            else:
                existing=result['fact_definitions'][key]
                if any(existing.get(k)!=d.get(k) for k in ('type','unit','minimum','maximum')):
                    raise ValueError('Conflicting transition input semantics')
                existing['source_ids']=sorted(set(existing['source_ids']+d['source_ids']))
        for claim in old['claim_definitions']:
            current=next((c for c in result['claim_definitions'] if c['id']==claim['id']),None)
            if current is None:
                current=dict(id=claim['id'],label=claim['label'],rule_ids=[],source_ids=[])
                result['claim_definitions'].append(current)
            current['rule_ids'] += [mapping[i] for i in claim['rule_ids']]
            current['source_ids']=sorted(set(current['source_ids']+claim['source_ids']))
        for key in ('rules','relations','reporting_decisions','unchanged_claims'):result[key]+=old[key]
        result['temporal_transitions']=[dict(effective_from=transition,source_id='FR-2025-10524',
            previous_revision=previous,reason='Prior metal treatment through the first minute of the daily release')]
    if x.get('pre_march') and not _entry_window:
        old=compile_pre_march(x,products,jurisdictions)
        for key in ('sources','source_artifacts'):
            idkey='id' if key=='sources' else 'source_id'
            merged={s[idkey]:s for s in result[key]}
            for item in old[key]:
                if item[idkey] in merged and merged[item[idkey]]!=item:raise ValueError('Conflicting March transition source')
                merged[item[idkey]]=item
            result[key]=list(merged.values())
        for key,d in old['fact_definitions'].items():
            if key in result['fact_definitions']:
                existing=result['fact_definitions'][key]
                if any(existing.get(k)!=d.get(k) for k in ('type','unit','minimum','maximum')):raise ValueError('Conflicting March transition fact')
                d['source_ids']=sorted(set(d['source_ids']+existing['source_ids']))
            result['fact_definitions'][key]=d
        for claim in old['claim_definitions']:
            existing=next((c for c in result['claim_definitions'] if c['id']==claim['id']),None)
            if existing:
                for key in ('rule_ids','candidate_rule_ids','source_ids'):existing[key]=sorted(set(existing.get(key,[])+claim.get(key,[])))
            else:result['claim_definitions'].append(claim)
        for key in ('rules','relations','reporting_decisions','unchanged_claims'):result[key]+=old[key]
        result['pre_march_semantic_review_sha256']=old['semantic_review_sha256']
        result.setdefault('temporal_transitions',[]).append(dict(effective_from=old['supported_until'],reason='Pre-March quotas and headings end at the proclamation instant within this revision'))
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('input',type=Path);p.add_argument('output',type=Path)
    a=p.parse_args();inputs=json.loads(a.input.read_bytes());snapshot=inputs.pop('grant_snapshot',None)
    result=compile_legacy(**inputs)
    if snapshot:
        from section232_grants import load_snapshot,apply_grants
        result=apply_grants(result,load_snapshot(snapshot))
    a.output.write_text(json.dumps(result,separators=(',',':'))+'\n')

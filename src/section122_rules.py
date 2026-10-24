"""Source-bound Section 122 rules and historical Section 232 interactions.

No model shares, rate matching or assumed absence of another authority. The
composer binds reporting predicates to sourced rules; coverage remains separate.
"""
from __future__ import annotations
import argparse, copy, csv, json, re, subprocess
from pathlib import Path
from datetime import datetime,timezone,timedelta
from zoneinfo import ZoneInfo
from section301_sources import sha
from section122_sources import extract
from section232_note16_rules import val, fact, op, both, either, negate
from chapter98_rules import compile_valuation, overlap_value, treatment
ROOT=Path(__file__).resolve().parents[1]
EVIDENCE=ROOT/'resources/legal_evidence/section122/interactions'


def date_at(text):
    return datetime.strptime(text,'%B %d, %Y').replace(hour=0,minute=1,tzinfo=ZoneInfo('America/New_York')).isoformat()


def usitc_url(revision,source):
    release=revision.replace('_rev_','HTSRev')
    return (f'https://hts.usitc.gov/reststop/exportList?release={release}&exportFormat=JSON'
            if Path(source['path']).suffix=='.json' else
            f'https://hts.usitc.gov/reststop/file?release={release}&filename=Chapter%2099')


def interaction_rows(text):
    """Retain bad references, ranges and qualifiers instead of dropping tokens."""
    starts=list(re.finditer(r'^\s*\(([a-k]|[1-8])\)\s+',text,re.M))
    if not starts:raise ValueError('Missing Section 122 interaction subdivisions')
    rows=[]
    for i,m in enumerate(starts):
        s=' '.join(text[m.end():starts[i+1].start() if i+1<len(starts) else len(text)].split())
        if 'non-steel content' in s:kind='steel'
        elif 'non-aluminum content' in s:kind='aluminum'
        elif 'non-copper content' in s:kind='copper'
        elif s.startswith(('articles of aluminum','passenger vehicles','parts of passenger vehicles','wood products','medium- and heavy-duty','semiconductor articles')):kind='whole'
        else:raise ValueError('Unreviewed Section 122 interaction grammar: '+s)
        codes=[];bad=[]
        for match in re.finditer(r'(?<![\d.])(\d{3,4}\.\d{2}\.\d{2})(?:[–—-](\d{3,4}\.\d{2}\.\d{2}))?(?!\d|\.\d)',s):
            a,b=match.groups()
            if not re.fullmatch(r'9903\.\d{2}\.\d{2}',a) or (b and (a[:8]!=b[:8] or a>b)):
                bad.append(match[0]);continue
            codes += [a] if not b else [a[:8]+f'{n:02}' for n in range(int(a[-2:]),int(b[-2:])+1)]
        if not codes:raise ValueError('Interaction has no legal heading reference')
        rows.append(dict(locator='note 2(aa)(v)('+m[1]+')',kind=kind,codes=sorted(set(codes)),
            malformed_references=bad,text=s,sha256=sha(s.encode())))
    return rows


def taiwan_interaction_basis(proclamation, notice):
    """Independent operative provisions, not a spelling repair to note 2.

    Proclamation 11012 paragraph 4 governs later Section 232 actions as well.
    The Taiwan notice's note 33(u) and inserted heading table independently
    identify the same full-article auto-parts decisions. Retain paragraph 6's
    malformed reference verbatim; it is not an executable heading identifier.
    """
    flat=' '.join(proclamation.split());t=' '.join(notice.split())
    clause=re.search(r'\(4\) (The surcharge imposed.*?)(?=\(5\))',flat)
    if not clause or not all(s in clause[1] for s in (
        'shall not apply in addition to tariffs imposed under section 232',
        'part of an import', 'shall not apply to the part of the import')):
        raise ValueError('Unreviewed operative Section 122 portion rule')
    scope=re.search(r'1\. U\.S\. note 33.*?headings (.*?) set forth the ordinary customs duty treatment for (.*?)Taiwan\.',t)
    table=re.search(r'3\. The following new headings.*?(?=4\. U\.S\.)',t)
    when=re.search(r'on or after 12:01 a\.m\. eastern time on (\w+ \d+, \d{4})',t)
    if not scope or not table or not when:raise ValueError('Missing Taiwan operative auto-parts provisions')
    codes=re.findall(r'9903\.\d{2}\.\d{2}',scope[1])
    rows=re.findall(r'(9903\.\d{2}\.\d{2})\.{2,}(.*?)(?=9903\.\d{2}\.\d{2}\.{2,}|$)',table[0])
    substantive={code:body for code,body in rows if code in codes}
    if len(codes)!=len(set(codes)) or set(substantive)!=set(codes) or not codes:
        raise ValueError('Taiwan note and inserted heading inventory disagree')
    if any(not all(s in body for s in ('Parts of passenger', 'products of Taiwan', 'U.S. note 33'))
           for body in substantive.values()):
        raise ValueError('Unreviewed Taiwan heading scope/valuation')
    return dict(kind='whole',codes=sorted(codes),country_names=['Taiwan'],from_=date_at(when[1]),
        locator='Proclamation 11012 paragraph 4; 2026-10571 Annex paragraphs 1 and 3, note 33(u)',
        source_ids=['FR-2026-03824-text','FR-2026-10571'],
        decision='Independent substantive provisions establish full-article Section 232 treatment. Note 2 malformed text remains unmodified.',
        operative_clause_sha256=sha(clause[1].encode()),heading_scope_sha256=sha(scope[0].encode()),
        heading_table_sha256=sha(table[0].encode()))


def load_history():
    review=json.loads((EVIDENCE/'review.json').read_bytes());sources=[];artifacts=[]
    for s in review['sources']:
        p=ROOT/s['path']
        if sha(p.read_bytes())!=s['sha256']:raise ValueError('Section 122 primary source hash mismatch: '+s['id'])
        sources.append({k:s[k] for k in ('id','sha256','url','citation')}|{'status':'verified'})
        artifacts.append(dict(source_id=s['id'],path=str(p),sha256=s['sha256']))
    clauses=[]
    for reviewed in review['clauses']:
        rev=reviewed['revision']
        x=extract(ROOT/f'data/us_notes/chapter99_{rev}.pdf',ROOT/f'data/hts_archives/hts_{rev}.json',rev)
        text=next(c['text'] for c in x['clauses'] if c['id']=='v')
        if sha(' '.join(text.split()).encode())!=reviewed['clause_sha256']:
            raise ValueError('Unreviewed Section 122 predecessor clause')
        clauses.append(text)
        for i,s in enumerate(x['sources']):
            id=f'USITC-{rev}-s122-history-{i}'
            sources.append(dict(id=id,status='verified',sha256=s['sha256'],url=usitc_url(rev,s),citation=f'USITC {rev} note 2(aa), reconciled against original annex'))
            artifacts.append(dict(source_id=id,path=s['path'],sha256=s['sha256']))
    text=' '.join((EVIDENCE/'2026-03824.txt').read_text().split())
    window=re.search(r'after 12:01 a.m. eastern standard time on (\w+ \d+, \d{4}), and shall continue in effect through 12:01 a.m. eastern daylight time on (\w+ \d+, \d{4})',text)
    if not window:raise ValueError('Unparsed Section 122 operative window')
    start,end=map(date_at,window.groups())
    taiwan=' '.join((EVIDENCE/'2026-10571.txt').read_text().split())
    when=re.search(r'on or after 12:01 a.m. eastern time on (\w+ \d+, \d{4})',taiwan)
    if not when:raise ValueError('Missing Taiwan operative date')
    april23=' '.join((EVIDENCE/'2026-07987.txt').read_text().split())
    replacement=re.search(r'3\. Subdivision \(aa\)\(v\)\(1\).*?deleting ``(.*?)\'\' and inserting ``(.*?)\'\' in lieu thereof',april23)
    clock=re.search(r'after 12:01 a.m. eastern standard time on (\w+ \d+, \d{4})',april23)
    if not replacement or not clock:raise ValueError('Missing April 23 insertion or entry instant')
    old,new=replacement.groups()
    if old!=review['malformed_deletion_review']['published_deleted_text']:
        raise ValueError('Unreviewed malformed deletion operand')
    first=interaction_rows(clauses[1])[0]['text']
    ranges=re.findall(r'9903\.\d{2}\.\d{2}[–—-]9903\.\d{2}\.\d{2}',first)
    if len(ranges)!=1 or not re.fullmatch(r'9903\.\d{2}\.\d{2}-9903\.\d{2}\.\d{2}',new):
        raise ValueError('Ambiguous target subdivision/insertion range')
    successor_revision=review['malformed_deletion_review']['corroborating_revision']
    successor=extract(ROOT/f'data/us_notes/chapter99_{successor_revision}.pdf',ROOT/f'data/hts_archives/hts_{successor_revision}.json',successor_revision)
    successor_clause=next(c['text'] for c in successor['clauses'] if c['id']=='v')
    corrected_april=clauses[1].replace(ranges[0],new)
    if interaction_rows(corrected_april)[0]['codes']!=interaction_rows(successor_clause)[0]['codes']:
        raise ValueError('April insertion is not corroborated by successor note')
    for i,s in enumerate(successor['sources']):
        id=f'USITC-{successor_revision}-s122-successor-{i}'
        sources.append(dict(id=id,status='verified',sha256=s['sha256'],url=usitc_url(successor_revision,s),citation='Successor note 2(aa)(v)(1) independently confirms explicit April 23 insertion.'))
        artifacts.append(dict(source_id=id,path=s['path'],sha256=s['sha256']))
    april23_at=datetime.strptime(clock[1],'%B %d, %Y').replace(hour=0,minute=1,tzinfo=timezone(timedelta(hours=-5))).isoformat()
    amended=corrected_april
    # Parse the replacement operations from the original notice, including its
    # malformed token. No edit-distance replacement of 903 with 9903 is allowed.
    for n in (6,7):
        match=re.search(str(n)+r'\. U.S. note 2\(aa\)\(v\)\(\d\) is modified by deleting ``(.*?)\'\' and inserting ``(.*?)\'\' in lieu thereof',taiwan)
        if not match:raise ValueError('Unparsed Taiwan Section 122 amendment')
        old,new=match.groups();amended=' '.join(amended.split())
        if amended.count(old)!=1:raise ValueError('Taiwan amendment predecessor mismatch')
        amended=amended.replace(old,new)
    # Restore subdivision starts after whitespace-normalized replacement.
    amended=re.sub(r' (?=\([1-7]\) )','\n',amended)
    def amendment_instant(id):
        p=next(ROOT/s['path'] for s in review['sources'] if s['id']==id)
        t=' '.join(subprocess.check_output(['pdftotext','-layout',str(p),'-'],text=True).split())
        days=set(re.findall(r'12:01 a\.m\. eastern daylight time on (\w+ \d+, \d{4})',t))
        if len(days)!=1:raise ValueError('Ambiguous amendment entry instant: '+id)
        return date_at(days.pop())
    april=amendment_instant('FR-2026-06960')
    june=amendment_instant('FR-2026-11314')
    # The intervening April 23 insertion supplies the June predecessor. Parse
    # the June replacement, preserving the unaffected standalone heading.
    june_ocr=(ROOT/'resources/legal_evidence/2026-11314/annex-iv-ocr.txt').read_text()
    replacement=re.search(r'7\. Subdivision \(aa\)\(v\)\(1\).*?(?=8\.)',june_ocr,re.S)
    if not replacement:raise ValueError('Missing original June interaction amendment')
    ranges=re.findall(r'9903\.82\.(\d{2})[—–-]+9903\.82\.(\d{2})',replacement[0])
    if len(ranges)!=2:raise ValueError('Unparsed June replacement ranges')
    predecessor=f'9903.82.{ranges[0][0]}-9903.82.{ranges[0][1]}'
    inserted=f'9903.82.{ranges[1][0]}-9903.82.{ranges[1][1]}'
    if amended.count(predecessor)!=1:raise ValueError('June amendment predecessor does not reconcile')
    june_clause=amended.replace(predecessor,inserted)
    periods=[dict(from_=start,until=april,rows=interaction_rows(clauses[0])),
             dict(from_=april,until=april23_at,rows=interaction_rows(clauses[1])),
             dict(from_=april23_at,until=date_at(when[1]),rows=interaction_rows(corrected_april)),
             dict(from_=date_at(when[1]),until=june,rows=interaction_rows(amended)),
             dict(from_=june,until=end,rows=interaction_rows(june_clause))]
    independent=taiwan_interaction_basis((EVIDENCE/'2026-03824.txt').read_text(),
                                         (EVIDENCE/'2026-10571.txt').read_text())
    return dict(start=start,end=end,periods=periods,sources=sources,source_artifacts=artifacts,
                independent_interactions=[independent])


def compile_rules(x,products):
    if not x.get('clauses'):raise ValueError('Section 122 source note absent')
    history=load_history();ids=[s['id'] for s in history['sources']]
    native=next(c['text'] for c in x['clauses'] if c['id']=='v')
    review=json.loads((EVIDENCE/'review.json').read_bytes())
    if sha(' '.join(native.split()).encode()) not in review['known_snapshot_clause_sha256']:
        raise ValueError('Unreviewed Section 122 snapshot interaction amendment')
    for i,s in enumerate(x['sources']):
        id=f'USITC-{x["revision"]}-s122-{i}';ids.append(id)
        history['sources'].append(dict(id=id,status='verified',sha256=s['sha256'],url=usitc_url(x['revision'],s),citation='Revision-specific Section 122 rate, product tables and conditional exemptions'))
        history['source_artifacts'].append(dict(source_id=id,path=s['path'],sha256=s['sha256']))
    # No later mutation to a nonproduct predicate is silently accepted.
    baseline=extract(ROOT/'data/us_notes/chapter99_2026_rev_4.pdf',ROOT/'data/hts_archives/hts_2026_rev_4.json','2026_rev_4')
    for c in x['clauses']:
        if c['id'] in ('i','vi','vii','viii') and ' '.join(c['text'].split())!=' '.join(next(b['text'] for b in baseline['clauses'] if b['id']==c['id']).split()):
            raise ValueError('Unreviewed Section 122 claim/valuation predicate')
    if x['rate']!=baseline['rate']:raise ValueError('Unreviewed Section 122 rate amendment')
    # All retained revisions agree on these product tables. A later change
    # needs its own original-annex chronology before it can price earlier entry.
    def product_predicates(source):
        return sorted(tuple(p.get(k) for k in ('scope_code','condition','condition_text','reporting_code')) for p in source['products'])
    if product_predicates(x)!=product_predicates(baseline):
        raise ValueError('Unreviewed Section 122 product-exemption amendment')
    for code in ('9903.03.02','9903.03.10','9903.03.11'):
        if next(h['description'] for h in x['headings'] if h['htsno']==code)!=next(h['description'] for h in baseline['headings'] if h['htsno']==code):
            raise ValueError('Unreviewed Section 122 procedural-exemption amendment')
    transit_heading=next(h for h in x['headings'] if h['htsno']=='9903.03.02')
    transit_dates=re.findall(r'before 12:01 a\.m\. eastern standard time on (\w+ \d+, \d{4})',transit_heading['description'])
    if len(transit_dates)!=2 or date_at(transit_dates[0])!=history['start']:
        raise ValueError('Unreviewed transit conditions/window')
    transit_until=date_at(transit_dates[1])
    facts={};rules=[]
    def f(name,label,kind='boolean',description=None,choices=None):
        d=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':d.update(minimum=0,unit='USD')
        if description:d['description']=description
        if choices is not None:d['enum']=choices
        facts[name]=d;return fact(name)
    cv=f('customs_value','Customs value (USD)','number')
    # Reconcile the valuation clause with the original annex, independently of
    # later HTS note snapshots. Each source revision supplies valid Chapter 98
    # provisions, but may not silently change the operative valuation policy.
    original=(EVIDENCE/'2026-03824-page9347-ocr.txt').read_text()
    clause=next(c['text'] for c in x['clauses'] if c['id']=='i')
    if treatment(clause)!=treatment(original):raise ValueError('Section 122 Chapter 98 policy changed without original-annex reconciliation')
    hts=json.loads((ROOT/f'data/hts_archives/hts_{x["revision"]}.json').read_bytes())
    valuation=compile_valuation(clause,hts,f,f('s122_chapter98_claimed','Entry claimed under Chapter 98'),cv)
    def reported(codes,positive=False,exclude=False):
        return {'reporting_predicate':dict(authority='section_232',codes=sorted(set(codes)),positive_duty=positive,exclude=exclude)}
    def emit(scope,path,code,formula,constraints=None):
        id=f's122_{x["revision"]}_{len(rules)}'
        r=dict(id=id,action_id='section122_surcharge',authority='section_122',kind='duty',verification='verified',scope=scope,when=path,formula=formula,reporting_codes=[code] if code else [],source_ids=ids)
        if constraints:r['input_constraints']=constraints
        rules.append(r)
    country_rows=list(csv.DictReader((ROOT/'resources/census_codes.csv').open()))
    country=lambda name:next(r['Code'] for r in country_rows if r['Name']==name)
    jurisdictions=[([country('Canada')],'9903.03.07'),([country('Mexico')],'9903.03.08')]
    cafta=[country(n) for n in ('Costa Rica','Dominican Republic','El Salvador','Guatemala','Honduras','Nicaragua')]
    jurisdictions += [(cafta,'9903.03.09'),([r['Code'] for r in country_rows if r['Code'] not in {c for cs,_ in jurisdictions for c in cs}|set(cafta)],None)]
    # Independent source reconciliation is country-specific. Split groups
    # rather than assuming a reporting identifier proves its country scope.
    for decision in history['independent_interactions']:
        cc={country(n) for n in decision['country_names']}
        jurisdictions=[(sorted(part),pref) for cs,pref in jurisdictions
                       for part in (set(cs)&cc,set(cs)-cc) if part]
    groups={}
    for p in sorted(set(products)):
        if not re.fullmatch(r'\d{10}',p):raise ValueError('Exact HTS10 required')
        matches=[r for r in x['products'] if p==r['scope_code'] or (len(r['scope_code'])==8 and p.startswith(r['scope_code']))]
        if len(matches)>1:raise ValueError('Overlapping Section 122 product conditions')
        row=matches[0] if matches else None
        key=(row['condition'],row['condition_text'],row['reporting_code']) if row else (None,None,None)
        groups.setdefault(key,[]).append(p)
    for (condition,description,ex_code),ps in groups.items():
      for period in history['periods']:
       for countries,prefcode in jurisdictions:
        scope=dict(hts_exact=ps,countries=countries,**{'from':period['from_'],'until':period['until']})
        path=val(True)
        def branch(test,code,formula=val(0),constraints=None):
            nonlocal path
            emit(scope,op('if',path,test,val(False)),code,formula,constraints)
            path=op('if',path,negate(test),val(False))
        # Already exempt goods do not need facts about hypothetical other relief.
        if condition=='none':emit(scope,path,ex_code,val(0));continue
        if condition:
            name='s122_gn6_civil_aircraft' if condition=='gn6_civil_aircraft' else 's122_description_'+sha(description.encode())[:12]
            branch(f(name,'Meets Section 122 '+condition.replace('_',' '),description=description),ex_code)
        if prefcode:
            claim='CAFTA_DR' if prefcode.endswith('09') else 'USMCA'
            eligible=f('s122_'+claim.lower()+'_entered_free','Entered free of duty under '+claim,
                description='Verified originating treatment and actual duty-free entry; eligibility or a modeled utilization share alone is insufficient.')
            if claim=='CAFTA_DR':eligible=both(eligible,f('s122_gn29_textile_apparel','Textile/apparel good under General Note 29(d)(v)'))
            branch(both({'claim':claim},eligible),prefcode)
        # These procedural facts cannot be inferred from HTS/COO alone.
        branch(f('s122_personal_baggage','For personal use in accompanied baggage of a person arriving in the United States'),None)
        branch(f('s122_humanitarian_donation','Qualifying donation to relieve human suffering',
            description=next(h['description'] for h in x['headings'] if h['htsno']=='9903.03.10')),'9903.03.10')
        branch(f('s122_informational_material','Informational material under 9903.03.11',
            description=next(h['description'] for h in x['headings'] if h['htsno']=='9903.03.11')),'9903.03.11')
        # Scope the transit question to the source's short entry window.
        if period['from_'] < transit_until:
            transit_scope=copy.deepcopy(scope);transit_scope['until']=transit_until
            transit=dict(id=f's122_transit_{len(rules)}',action_id='section122_surcharge',authority='section_122',kind='duty',verification='verified',scope=transit_scope,
              when=both(path,f('s122_loaded_and_final_transit_before_start','Loaded on vessel and in final transit before Section 122 began',description=transit_heading['description'])),formula=val(0),reporting_codes=['9903.03.02'],source_ids=ids)
            rules.append(transit);path=both(path,negate({'rule_applies':transit['id']}))
        branch(valuation['exempt'],None,constraints=valuation['constraints'])
        branch(f('s122_ftz_entry','Entry from a foreign trade zone'),None,{'unresolved_source':'section122_ftz_admission_classification_requires_separate_rule'})
        whole=[];parts={};known=[]
        independently_defined={c for d in history['independent_interactions'] for c in d['codes']}
        for d in history['independent_interactions']:
            if period['from_']>=d['from_'] and set(countries)<={country(n) for n in d['country_names']}:
                whole.append(reported(d['codes']));known+=d['codes']
        for row in period['rows']:
            codes=[c for c in row['codes'] if c not in independently_defined];known+=codes
            # The two parenthetical qualifications are not blanket zero-rate
            # exemptions for every use of the named headings.
            if 'as applied to the U.S. content' in row['text']:
                restricted=re.search(r'(9903\.\d{2}\.\d{2}) \(as applied to the U.S. content',row['text'])[1]
                codes=[c for c in codes if c!=restricted]
                parts['vehicle_us_content']=both(reported([restricted]),f('s122_commerce_approved_us_vehicle_content','Commerce-approved U.S. vehicle content under note 33(d)'))
            if 'knock-down kits' in row['text']:
                restricted=re.search(r'(9903\.\d{2}\.\d{2}) \(as applied to parts',row['text'])[1]
                codes=[c for c in codes if c!=restricted]
                whole.append(both(reported([restricted]),f('s122_usmca_auto_parts_not_kits','USMCA-eligible auto parts, excluding knock-down kits and parts compilations')))
            if row['kind']=='whole':whole.append(reported(codes))
            else:parts.setdefault(row['kind'],[]).append(reported(codes))
        branch(either(*whole),'9903.03.06')
        portions=[];constraints=list(valuation['constraints']);active_portions=[]
        for metal,pred in parts.items():
            hit=either(*pred) if isinstance(pred,list) else pred
            value=f(metal+'_content_value' if metal!='vehicle_us_content' else 's122_vehicle_us_content_value',metal.replace('_',' ').title()+' value (USD)','number')
            portions.append(op('if',hit,value,val(0)))
            active_portions.append(both(hit,op('gt',value,val(0))))
            constraints.append(dict(test=op('if',hit,op('lte',value,cv),val(True)),inputs=['customs_value',value['fact']],label='Exempt content cannot exceed article value'))
        excluded=op('add',*portions) if portions else val(0)
        overlap,overlap_constraint=overlap_value(valuation,excluded,cv,f,'s122')
        constraints.append(overlap_constraint)
        remaining=op('subtract',valuation['basis'],overlap)
        constraints.append(dict(test=op('lte',excluded,cv),inputs=['customs_value'],label='Distinct exempt portions cannot exceed article value; do not count the same content twice'))
        if len(active_portions)>1:
            multiple=either(*(both(a,b) for i,a in enumerate(active_portions) for b in active_portions[i+1:]))
            disjoint=f('s122_content_values_disjoint','Exempt content values are distinct, with no double counting')
            constraints.append(dict(test=op('if',multiple,disjoint,val(True)),inputs=['s122_content_values_disjoint'],label='Multiple exempt portions require reconciled nonoverlapping values'))
        # An unreviewed reporting decision cannot establish full-value Section
        # 122, including when the Section 232 amount is zero. Its applicability
        # and valuation treatment require an explicit cross-program decision.
        unresolved=reported(known,exclude=True)
        branch(unresolved,None,{'unresolved_source':'section122_unlisted_section232_action_or_amendment_requires_portion_reconciliation'})
        checked=both({'authority_covered':'section_232'},op('eq',remaining,val(0)))
        branch(checked,'9903.03.06',constraints=constraints)
        # A split valuation reports the exempt portion as well as .03.01 on
        # the remaining portion. It is a zero-dollar component, not a credit.
        emit(scope,both(path,{'authority_covered':'section_232'},op('gt',overlap,val(0))),
             '9903.03.06',val(0),constraints)
        formula=op('if',{'authority_covered':'section_232'},op('multiply',val(x['rate']),remaining),val(0))
        emit(scope,path,'9903.03.01',formula,constraints)
    all_ids=[r['id'] for r in rules]
    claims=[dict(id=c,label=c if c=='USMCA' else 'CAFTA-DR',rule_ids=all_ids,source_ids=ids) for c in ('USMCA','CAFTA_DR')]
    claims.append(dict(id='CHAPTER_98',label='Chapter 98',rule_ids=all_ids,source_ids=ids))
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='section122_'+x['revision'],compiler_sha256=sha(Path(__file__).read_bytes()),
        compiler_dependencies={p:sha((ROOT/p).read_bytes()) for p in ('src/section122_sources.py','src/section301_sources.py','src/section232_note16_rules.py','src/chapter98_rules.py','resources/legal_evidence/section122/interactions/review.json','resources/census_codes.csv')},
        supported_from='2025-01-01T00:00:00-05:00',supported_until='2026-10-23T00:00:00-04:00',sources=history['sources'],source_artifacts=history['source_artifacts'],
        rules=rules,coverage=[],fact_definitions=facts,claim_definitions=claims,relations=[],interaction_history=history['periods'],
        independent_interactions=history['independent_interactions'],
        unchanged_claims=[dict(id='s122_301_independence_'+x['revision'],claim_authority='section_301',candidate_required_fields=['exclusion_claim_id'],target_rule_ids=all_ids,source_ids=ids),
          dict(id='s122_232_reevaluation_'+x['revision'],effect='reevaluate',claim_authority='section_232',candidate_required_fields=['grant_id','grant_snapshot_id'],target_rule_ids=all_ids,source_ids=ids)],
        limitations=['No complete authority coverage attestation. FTZ and import-adjustment offsets remain unresolved. Chapter 98 entitlement requires proper claim and CBP agreement; intersecting adjusted and Section 232 values requires shipment evidence.',
          'Taiwan auto-parts interaction uses independent operative provisions; malformed annex text is retained, not repaired. Underlying Section 232 applicability must still be established.',
          'Post-expiry note mutations never establish earlier Section 122 liability.'])

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('input');p.add_argument('output');a=p.parse_args()
    args=json.loads(Path(a.input).read_bytes());Path(a.output).write_text(json.dumps(compile_rules(**args),separators=(',',':'))+'\n')

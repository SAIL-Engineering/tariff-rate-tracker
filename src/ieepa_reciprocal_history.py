"""Original-annex chronology for EO 14257 product exemptions.

Country agreements, informational materials, claims and Section 232 are separate
predicates. The aligned-partner annex never becomes a universal product list.
"""
from __future__ import annotations
import re
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo
import json
from section301_sources import sha, unique_span
from ieepa_reciprocal_sources import CODE
from ieepa_fentanyl_sources import verified_source, windows, collection_termination, ROOT


def annex(doc):
    p=ROOT/'resources/legal_evidence'/doc/'annex.txt'
    m=json.loads(p.with_name('annex-source.json').read_bytes())
    if sha(p.read_bytes())!=m['sha256']:raise ValueError('Reciprocal annex hash mismatch: '+doc)
    return p.read_text(),dict(path=str(p),**m)


def clean_fr(text):
    # Only page furniture. Anything else left in an enumeration is fatal.
    return '\n'.join(l for l in text.splitlines() if not re.search(
        r'Federal Register\s*/|^\s*VerDate |^\s*(?:lotter|khammond) on |ED\d+[A-Z]+\d+\.\d+</GPH>|^\s*\d{1,3}\s*$',l))


def enumeration(text):
    clean=clean_fr(text)
    codes=re.findall(CODE,clean)
    if not codes or re.sub(CODE,'',clean).strip():
        raise ValueError('Unparsed original reciprocal enumeration: '+re.sub(CODE,'',clean).strip()[:160])
    return sorted(set(c.replace('.','') for c in codes))


def after(text,marker):
    matches=list(re.finditer(marker,text,re.M))
    if len(matches)!=1:raise ValueError('Ambiguous original annex marker: '+marker)
    return text[matches[0].end():]


def history():
    sources=[]
    def notice(doc):
        t,s=verified_source(doc);sources.append(s);return t
    def original(doc):
        t,s=annex(doc);sources.append(s);return t
    def start(t):
        v=windows(t)['valid_from']
        if not v:raise ValueError('Missing original reciprocal effective instant')
        return v
    initial=notice('2025-06063')
    inception=start(unique_span(initial,r'^Sec\. 3\.',r'^\(b\)') .split('except that goods loaded')[0])
    base=original('2025-06063')
    base_table=after(base,r'following subheadings of the HTSUS:').split('(iv) As provided')[0]
    base_codes=enumeration(base_table)
    rows=[]
    def add(codes,date,source,locator,clause,condition='none',reporting='9903.01.32'):
        for c in codes:
            if len(c) not in (4,6,8,10) or not c.isdigit() or c[:2]>='98':raise ValueError('Invalid reciprocal scope')
            rows.append(dict(scope_code=c,scope_grain=len(c),valid_from=date,valid_until=None,
                condition=condition,condition_text=clause if condition!='none' else '',reporting_code=reporting,
                source_id=source,source_locator=locator,source_scope_sha256=sha(clause.encode())))
    add(base_codes,inception,'FR-2025-06063-ANNEX','Annex III, note 2(v)(iii)',base_table)
    memo=notice('2025-04-11-reciprocal-electronics')
    table=memo[memo.index('·'):memo.index('To the extent')]
    electronics=re.findall(r'^·\s*(\d{4,8})\s*$',table,re.M)
    if not electronics or re.sub(r'^·\s*\d{4,8}\s*$','',table,flags=re.M).strip():raise ValueError('Unparsed electronics memorandum')
    m=re.search(r'effective as of 12:01 a\.m\. eastern daylight time on ([A-Z][a-z]+ \d+, \d{4})',memo)
    if not m:raise ValueError('Missing retroactive electronics commencement')
    retro=datetime.strptime(m[1],'%B %d, %Y').replace(minute=1,tzinfo=ZoneInfo('America/New_York')).isoformat()
    if retro!=inception:raise ValueError('Electronics clarification no longer aligns with inception')
    add(sorted(set(electronics)-set(base_codes)),retro,'WH-2025-04-11-reciprocal-electronics','Listed headings and retroactive commencement',table)
    transitions=[]
    def remove(codes,date,source,locator,clause):
        for c in codes:
            active=[r for r in rows if r['scope_code']==c and r['valid_until'] is None and r['condition']=='none']
            if len(active)!=1:raise ValueError('Deletion does not identify one active reciprocal scope: '+c)
            active[0].update(valid_until=date,termination_source_id=source,termination_locator=locator,
                termination_clause_sha256=sha(clause.encode()))
    copper=notice('2025-14893');cu_at=start(unique_span(copper,r'^\(1\)',r'^\(2\)'))
    cu=original('2025-14893')
    cu_clause=unique_span(cu,r'^\s*3\. U\.S\. note 2\(v\)\(iii\)',r'^\s*4\. U\.S\. note 2\(v\)')
    cu_codes=enumeration(after(cu_clause,r'following subheadings from its list:'))
    remove(cu_codes,cu_at,'FR-2025-14893-ANNEX','Annex paragraph 3',cu_clause)
    transitions.append(dict(effective_at=cu_at,removed=cu_codes,added=[]))
    sept=notice('2025-17507')
    dated=re.search(r'Executive Order \d+ of ([A-Z][a-z]+ \d+, \d{4})',sept)
    clause=unique_span(sept,r'^Sec\. 2\.',r'^Sec\. 3\.')
    delay=re.search(r'12:01 a\.m\.\s+eastern daylight time (\d+) days after the date of this\s+order',clause)
    if not dated or not delay:raise ValueError('Unparsed relative September effective date')
    sept_at=(datetime.strptime(dated[1],'%B %d, %Y')+timedelta(days=int(delay[1]))).replace(minute=1,tzinfo=ZoneInfo('America/New_York')).isoformat()
    sa=original('2025-17507');si=unique_span(sa,r'^\s*ANNEX I\s*$',r'^\s*ANNEX II\s*$')
    insert=after(si,r'by inserting in numerical order the following provisions of the HTSUS:').split('Effective with respect')[0]
    deletes=after(si,r'by removing the following provisions of the HTSUS:')
    plus,minus=enumeration(insert),enumeration(deletes)
    add(plus,sept_at,'FR-2025-17507-ANNEX','Annex I additions',insert)
    remove(minus,sept_at,'FR-2025-17507-ANNEX','Annex I deletions',deletes)
    transitions.append(dict(effective_at=sept_at,added=plus,removed=minus))
    timber=notice('2025-19482');wood=unique_span(timber,r'^\(12\)',r'^\(13\)')
    wood_at=start(unique_span(timber,r'^\(5\)',r'^\(6\)'))
    if not all(s in ' '.join(wood.split()) for s in ('all tariff provisions under Chapter 44','except those tariff provisions that:',
        'Potential Tariff Adjustments for Aligned Partners Annex','do not include products of a type that are subject to an antidumping or countervailing duty order')):
        raise ValueError('Unreviewed timber reciprocal exception')
    wa=original('2025-19482')
    wood_table=after(wa,r'iii\. by deleting the following from the list of HTSUS provisions in subdivision \(iii\):').split('7. U.S. note')[0]
    wood_codes=enumeration(wood_table)
    if any(not c.startswith('44') for c in wood_codes):raise ValueError('Unexpected timber deletion scope')
    # The same proclamation's operative annex implements clause 12 by exact
    # enumeration. Do not convert its AD/CVD rationale into an extra user fact,
    # or remove every Chapter 44 code. Native snapshots are a second check.
    remove(wood_codes,wood_at,'FR-2025-19482-ANNEX','Annex I paragraph 6(iii); clause 12',wood_table)
    retained=sorted(r['scope_code'] for r in rows if r['scope_code'].startswith('44') and r['valid_until'] is None)
    transitions.append(dict(effective_at=wood_at,added=[],removed=wood_codes))
    nov=notice('2025-21203');nov_at=start(unique_span(nov,r'^Sec\. 2\.',r'^Sec\. 3\.'))
    na=original('2025-21203');ni=unique_span(na,r'^\s*ANNEXI\s*$',r'^\s*ANNEX II\s*$')
    plus_text=after(ni,r'\(v\)\(iii\)\(a\) the following provisions of the HTSUS in numerical order:').split('ii. by inserting')[0]
    plus=enumeration(plus_text)
    add(plus,nov_at,'FR-2025-21203-ANNEX','Annex I paragraph f(i)',plus_text)
    cond=clean_fr(after(ni,r'"\(b\) As provided in heading 9903\.02\.78,'))
    cond=re.sub(r'(?<=\d)\s+(?=\.)|(?<=\.)\s+(?=\d)','',cond)
    starts=list(re.finditer(r'^\s*\((\d+)\)\s',cond,re.M))
    if [int(m[1]) for m in starts]!=list(range(1,12)):raise ValueError('Unreviewed conditional agricultural inventory')
    for i,m in enumerate(starts):
        text=' '.join(cond[m.end():starts[i+1].start() if i+1<len(starts) else len(cond)].strip().rstrip('"').split())
        codes=re.findall(r'classifiable in\s+subheading ('+CODE+r')',text)
        if len(codes)!=1:raise ValueError('Unparsed conditional agricultural exemption')
        add([codes[0].replace('.','')],nov_at,'FR-2025-21203-ANNEX','Annex I paragraph f(ii), item '+m[1],text,'article_description','9903.02.78')
    transitions.append(dict(effective_at=nov_at,added=plus,removed=[]))
    end,termination=collection_termination()
    if not all('Executive Order 14257' in Path(s['path']).read_text().replace('\n',' ') for s in termination):
        raise ValueError('Reciprocal termination not established')
    sources+=termination
    for r in rows:
        if r['valid_until'] is None:r.update(valid_until=end,termination_source_id=termination[-1]['id'])
    return dict(contract_version='sail.ieepa-reciprocal-history/v1',products=rows,sources=sources,
        transitions=transitions,valid_from=inception,valid_until=end,
        native_initial_codes=base_codes,wood_retained_codes=retained)


def active_rows(h,at):
    at=datetime.fromisoformat(at)
    if at.tzinfo is None:raise ValueError('Entry instant requires timezone')
    return [r for r in h['products'] if datetime.fromisoformat(r['valid_from'])<=at<datetime.fromisoformat(r['valid_until'])]


def reconcile_native(extraction,h):
    """A snapshot may lag a retroactive amendment; it is never the legal clock."""
    native=extraction['products']
    if not native:return dict(status='pre_reciprocal_snapshot',matched_states=[])
    observed={(r['scope_code'],r['condition']) for r in native}
    states=[(h['valid_from']+'-original',set((c,'none') for c in h['native_initial_codes']))]
    for at in sorted({r['valid_from'] for r in h['products']}|{t['effective_at'] for t in h['transitions']}):
        states.append((at,{(r['scope_code'],r['condition']) for r in active_rows(h,at) }))
    matched=[at for at,codes in states if codes==observed]
    if not matched:raise ValueError('Native reciprocal scope differs from every verified original-annex state')
    return dict(status='reconciled_original_annex',matched_states=matched)

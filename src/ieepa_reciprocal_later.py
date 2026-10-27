"""Source-extracted continuations and partner amendments to EO 14257.

The insertion tables and their operative note clauses must account for one
another completely. Original effective instants, not HTS/publication dates,
select policy. No HTS examples, Census codes or modeled rates appear here.
"""
from __future__ import annotations
from datetime import datetime,timedelta,timezone
import json,re
from zoneinfo import ZoneInfo
from ieepa_fentanyl_sources import verified_source,ROOT
from section301_sources import sha,unique_span
from ieepa_reciprocal_august import country
from section232_stacking import reporting_codes

H=r'9903\.\d{2}\.\d{2}'
P=r'(?<![\d.])\d{4}\.\d{2}\.\d{2}(?:\.\d{2})?(?![\d.])'


def legal_instants(*nodes):
    """Collect typed legal windows, including later nested claim deadlines.

    Publication/retrieval timestamps are metadata, not legal boundaries. A new
    window using the shared temporal fields cannot be omitted from tiling.
    """
    result=set()
    def visit(node):
        if isinstance(node,list):
            for v in node:visit(v)
        elif isinstance(node,dict):
            for k,v in node.items():
                legal=k in ('inception','from','from_','until','effective_at','collection_ended_at') or k.endswith(('_from','_until'))
                if legal and v is not None:
                    if not isinstance(v,str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})',v):
                        raise ValueError('Invalid typed legal instant: '+k)
                    try:datetime.fromisoformat(v)
                    except ValueError as e:raise ValueError('Invalid typed legal instant: '+k) from e
                    result.add(v)
                elif isinstance(v,(dict,list)):visit(v)
    for node in nodes:visit(node)
    return result


def flat(t):return ' '.join(t.replace('\x00','').split())


def source_catalog():
    p=ROOT/'resources/legal_evidence/reciprocal-later/source-catalog.json'
    x=json.loads(p.read_bytes())
    if x.get('contract_version')!='sail.reciprocal-source-catalog/v1':raise ValueError('Unsupported reciprocal source catalog')
    docs=x['suspension_documents']+[r['document'] for r in x['partner_documents']]
    if len(set(docs))!=len(docs) or any(not re.fullmatch(r'\d{4}-\d{5}',d) for d in docs):raise ValueError('Invalid reciprocal source catalog inventory')
    return x


def entry_instant(t):
    matches=list(re.finditer(r'12:0([01]) a\.m\.\s+eastern(?:( daylight| standard))? time on (\w+ \d+, \d{4})',flat(t)))
    if not matches:raise ValueError('Missing original entry instant')
    if len({m.groups() for m in matches})!=1:raise ValueError('Ambiguous original entry instants; select the operative clause')
    m=matches[0]
    tz=timezone(timedelta(hours=-4 if m[2]==' daylight' else -5)) if m[2] else ZoneInfo('America/New_York')
    return datetime.strptime(m[3],'%B %d, %Y').replace(minute=int(m[1]),tzinfo=tz).isoformat()


def suspension_chain(initial):
    previous=initial.get('china_suspension_initial_until',initial['china_suspension_until']);code=initial['amendments'][0]['code'];events=[];sources=[]
    prior_order='14298'
    for doc in source_catalog()['suspension_documents']:
        text,s=verified_source(doc);t=flat(text);section=unique_span(t,r'Sec\. 2\.',r'Sec\. 3\.')
        target=re.fullmatch(r'[^.]*Heading ('+H+r') and subdivision (\(v\)\([ivx]+\)\(\d+\)) of U\.S\. note 2 to subchapter III of chapter 99 of the (?:HTSUS|Harmonized Tariff Schedule of the United States) shall continue to be suspended until (.*?)\.',section.replace('Sec. 2. ','').replace('Continued Suspension of Country-Specific Ad Valorem Rate of Duty. ','').replace('Implementation. ',''))
        if not target or target[1]!=code or 'Executive Order '+prior_order not in t:
            raise ValueError('Unreconciled reciprocal suspension continuation: '+doc)
        end=entry_instant(target[3]);signed=re.search(r'Executive Order (\d+) of (\w+ \d+, \d{4})',t)
        if not signed or datetime.strptime(signed[2],'%B %d, %Y').date()>datetime.fromisoformat(previous).date() or datetime.fromisoformat(end)<=datetime.fromisoformat(previous):
            raise ValueError('Unreconciled suspension predecessor or chronology')
        if not events:
            # a.m. contains periods; use its complete original timestamp.
            recap=re.search(r'This 90-day suspension expires at (12:01 a\.m\. eastern daylight time on \w+ \d+, \d{4})\.',t)
            if not recap or entry_instant(recap[1])!=previous:raise ValueError('Suspension predecessor date differs from original source')
        events.append(dict(from_=previous,until=end,reporting_code=code,note_locator=target[2],source_id=s['id'],clause_sha256=sha(section.encode())))
        sources.append(s);previous=end;prior_order=signed[1]
    return events,sources


def source(doc):
    if (ROOT/'resources/legal_evidence'/doc/'source.json').exists():return verified_source(doc)
    review=json.loads((ROOT/'resources/legal_evidence/section232/autos/review.json').read_bytes())
    entries=[s for s in review['sources'] if s.get('corpus',{}).get('document_number')==doc]
    if len(entries)!=1:raise ValueError('Missing original partner source: '+doc)
    s=dict(entries[0]);p=ROOT/s['path']
    if sha(p.read_bytes())!=s['sha256']:raise ValueError('Partner source hash mismatch')
    s['path']=str(p);return p.read_text(),s


def tables(t):
    starts=list(re.finditer(r'^\s*[`"“]*('+H+r')\.{2,}\s+',t,re.M));rows={}
    for i,m in enumerate(starts):
        block=t[m.start():starts[i+1].start() if i+1<len(starts) else len(t)]
        block=re.split(r'\n\s*-{5,}',block)[0]
        lines=[re.split(r' {2,}',l.strip()) for l in block.splitlines() if l.strip() and not re.match(r'^\[\[Page',l)]
        # First line includes the identifier, following lines start with prose.
        description=flat(' '.join(p[1] if n==0 else p[0] for n,p in enumerate(lines)))
        if m[1] in rows:raise ValueError('Duplicate original partner heading')
        rows[m[1]]=dict(description=description,rates=sorted(set(re.findall(r'(\d+(?:\.\d+)?)%',block))),sha256=sha(block.encode()))
    if not rows:raise ValueError('Missing partner insertion table')
    return rows


def clean_table(t):
    t=re.sub(r'\[\[Page \d+\]\]','',t)
    t=re.sub(r'["`“”\s;.,]+$','',t)
    t=re.sub(r'\s*\([a-zivx]+\)\s*$','',t)
    return flat(t)


def partner_history(august):
    sources=[];changes=[];exemptions=[];inventories=[]
    charged={c:r['country_text'] for r in august['actions'] for c in r['reporting_codes']}
    for specification in source_catalog()['partner_documents']:
        doc,begin,end=(specification[k] for k in ('document','begin','end'))
        raw,s=source(doc);sources.append(s)
        text=unique_span(raw,begin,end) if end else raw[list(re.finditer(begin,raw,re.M))[-1].start():]
        at=entry_instant(text);headings=tables(text)
        # Floors are replaced country actions. Exact reporting identity comes
        # from the original high/low insertion rows, never a rate->code guess.
        floors={}
        for code,row in headings.items():
            d=row['description']
            if re.search(r'column 1[-–]{1,2}General|column 1[–-]General',d,re.I) and re.search(r'(?:less than|equal to or greater than) (\d+(?:\.\d+)?) percent',d):
                c=country(d);kind='high' if 'equal to or greater than' in d else 'low'
                if kind in floors.setdefault(c,{}):raise ValueError('Duplicate partner floor branch')
                floors[c][kind]=(code,row)
        retired=set()
        for a in re.findall(r'Headings? ('+H+r'(?: and '+H+r')?) (?:is |are )(?:hereby )?terminated',flat(text)):
            retired.update(re.findall(H,a))
        for c,pair in floors.items():
            if set(pair)!={'high','low'}:raise ValueError('Incomplete partner floor')
            hi,lo=pair['high'],pair['low'];thresholds=re.findall(r'(?:less than|equal to or greater than) (\d+(?:\.\d+)?) percent',hi[1]['description']+' '+lo[1]['description'])
            if len(thresholds)!=2 or len(set(thresholds))!=1 or lo[1]['rates']!=[thresholds[0]] or hi[1]['rates']:
                raise ValueError('Partner floor thresholds and duties differ')
            previous=[code for code in retired if charged.get(code)==c]
            if len(previous)!=1:raise ValueError('Partner floor does not replace one original country action')
            change=dict(country_text=c,from_=at,kind='column1_general_floor',rate=float(thresholds[0])/100,
                reporting_codes=[hi[0],lo[0]],replaced_reporting_code=previous[0],source_ids=[s['id']])
            changes.append(change)
            for code in change['reporting_codes']:charged[code]=c
        # Keep only the original inserted note definitions. Outer amendment
        # instructions and heading tables are separate evidence, not scope.
        note=unique_span(text,specification['note_begin'],specification['note_end'])
        n=flat(note)
        lead=r'As provided in headings? ('+H+r'(?:[\s,;a-z–—-]|'+H+r')*?), the additional duties imposed by headings? ('+H+r'(?:[\s,;a-z–—-]|'+H+r')*?),? shall not apply to '
        markers=list(re.finditer(lead,n))
        if not markers:raise ValueError('Missing original partner exception clauses')
        accounted={x for r in changes if r['source_ids']==[s['id']] for x in r['reporting_codes']}
        for i,m in enumerate(markers):
            reporters=reporting_codes(m[1]);removed=reporting_codes(m[2]);body=clean_table(n[m.end():markers[i+1].start() if i+1<len(markers) else len(n)])
            countries=sorted({charged[c] for c in removed if c in charged})
            if not countries:raise ValueError('Partner exception has no original reciprocal target')
            prefix,sep,table=body.partition(':')
            if 'following particular articles' in body:
                items=re.findall(r'\(\d+\) (.*?)(?=\(\d+\)|$)',body)
                if not items:raise ValueError('Missing description-limited partner items')
                scope=[]
                for item in items:
                    codes=re.findall(P,item)
                    if len(codes)!=1:raise ValueError('Ambiguous partner description-limited scope')
                    scope.append(([codes[0].replace('.','')],item,'article_description'))
            else:
                if not sep:raise ValueError('Missing partner product table')
                codes=re.findall(P,table)
                residual=re.sub(P,'',clean_table(table))
                junk=re.sub(r"[\s;,\.\"'`“”]",'',residual)
                if not codes or junk:raise ValueError('Unparsed partner product table: '+doc+' '+str(reporters)+' '+junk[:200])
                if 'civil aircraft' in prefix:
                    if 'General Note 6' not in prefix or 'unmanned aircraft' not in prefix:raise ValueError('Unreviewed aircraft condition')
                    condition='civil_aircraft_gn6_excluding_unmanned'
                elif re.search(r'(?:non-patented articles|not patented in the United States) for use in pharmaceutical applications',prefix):condition='nonpatented_pharmaceutical_use'
                elif 'that are classifiable in the following provisions' in prefix:condition='none'
                else:raise ValueError('Unreviewed partner scope condition: '+prefix[:180])
                scope=[(sorted({c.replace('.','') for c in codes}),prefix,condition)]
            for code in reporters:
                if code not in headings or headings[code]['rates']:raise ValueError('Exception heading not reconciled with insertion table')
                names=[c for c in countries if re.search(r'\b'+re.escape(c)+r'\b',headings[code]['description'])]
                if len(names)!=1:raise ValueError('Exception reporting heading origin ambiguity')
                for products,condition_text,condition in scope:
                    exemptions.append(dict(reporting_code=code,country_text=names[0],from_=at,products=products,
                        condition=condition,condition_text=condition_text,removed_reporting_codes=removed,source_ids=[s['id']],prefix_sha256=sha(condition_text.encode())))
                accounted.add(code)
        collateral={code:row for code,row in headings.items() if code not in accounted and
            re.search(r'U\.S\. note 37\b',row['description'])}
        if accounted|set(collateral)!=set(headings):raise ValueError('Unaccounted partner heading inventory: '+str(set(headings)^(accounted|set(collateral))))
        inventories.append(dict(document=doc,from_=at,headings=sorted(headings),source_id=s['id'],
            other_program_headings=collateral,other_program_status='requires_independent_section232_reconciliation' if collateral else None))
    review_path=ROOT/'resources/legal_evidence/reciprocal-later/reviewed-conditions.json'
    review=json.loads(review_path.read_bytes())
    actual=sorted([dict(heading=r['reporting_code'],condition=r['condition'],prefix_sha256=r['prefix_sha256']) for r in exemptions],key=lambda r:r['heading'])
    if review['conditions']!=actual:raise ValueError('Unreviewed partner legal condition grammar')
    return dict(country_amendments=changes,exemptions=exemptions,sources=sources,inventories=inventories,
        condition_review_sha256=sha(review_path.read_bytes()))


def sector_links(partners):
    """Explicit source-named interactions, including zero-payable decisions.

    Recognize an actually matched legal reporting decision, never a positive
    Section232 aggregate rate or a guessed family of reporting identifiers.
    """
    from ieepa_reciprocal_history import annex
    from section232_stacking import timber_amendment,amendment
    wood=timber_amendment();raw,s=annex('2025-19482')
    clause=flat(raw)
    m=re.search(r'shall apply to wood products provided for in heading ('+H+r'), but shall not apply to wood products provided for in headings (.*?)\.”',clause)
    if not m:raise ValueError('Missing original timber reciprocal subject-to rule')
    wood_codes=reporting_codes(m[2])
    if not wood_codes or m[1] in wood_codes:raise ValueError('Timber covered and outside-scope reporting overlap')
    links=[dict(from_=wood['effective_from'],codes=wood_codes,priority=False,source_ids=[s['id'],wood['source']['id']],source_clause_sha256=sha(m[0].encode()))]
    sources=[s,wood['source']]
    # An implementing partner agreement can append a new timber heading to
    # the original note. Preserve it as its own dated interaction amendment.
    for inventory in partners['inventories']:
        extra=inventory['other_program_headings']
        if not extra:continue
        text,source_meta=source(inventory['document']);t=flat(text)
        inserted=re.search(r'U\.S\. note 2 is amended by deleting ``and ('+H+r")'' in subdivision \(v\)\(xiii\) and inserting ``(.*?)'' in lieu thereof",t)
        if not inserted or inserted[1] not in wood_codes or set(reporting_codes(inserted[2]))!={inserted[1],*extra}:
            raise ValueError('Unreconciled partner timber interaction amendment')
        links.append(dict(from_=inventory['from_'],codes=sorted(extra),priority=False,source_ids=[source_meta['id']],source_clause_sha256=sha(inserted[0].encode())))
    path=ROOT/'resources/legal_evidence/2025-19639/reciprocal-annex-source.json'
    meta=json.loads(path.read_bytes());p=ROOT/meta['path']
    if sha(p.read_bytes())!=meta['sha256'] or sha((ROOT/meta['pdf_path']).read_bytes())!=meta['pdf_sha256']:
        raise ValueError('MHDV reciprocal annex evidence mismatch')
    text=flat(p.read_text());note=text.split('4. US. note 2(x)',1)[0]
    rows=re.findall(r'shall not apply to medium- and heavy-duty (?:vehicle parts|vehicles) provided for in headings (.*?)\.”',note)
    if len(rows)!=2:raise ValueError('Incomplete MHDV reciprocal action relations')
    vehicle=amendment();sources += [dict(meta,path=str(p)),vehicle['source']]
    links.append(dict(from_=vehicle['effective_from'],codes=sorted({c for row in rows for c in reporting_codes(row)}),priority=False,
        source_ids=[meta['id'],vehicle['source']['id']],source_clause_sha256=sha(note.encode())))
    path=ROOT/'resources/legal_evidence/2026-01052/CSMS-67400472-source.json'
    meta=json.loads(path.read_bytes());p=ROOT/meta['path']
    if sha(p.read_bytes())!=meta['sha256']:raise ValueError('Semiconductor reporting instruction changed')
    m=re.search(r'For goods that are properly classified in subheading (\d{4}\.\d{2}) and properly subject to duties under heading ('+H+r'), filers should use heading ('+H+r').*?rather than heading ('+H+r')',flat(p.read_text()))
    if not m:raise ValueError('Missing original semiconductor reporting priority')
    proclamation,notice=verified_source('2026-01052')
    operative=unique_span(proclamation,r'^\(3\)',r'^\(4\)')
    links.append(dict(from_=entry_instant(operative),codes=[m[2]],priority=True,reporting_code=m[3],replaces_reporting_code=m[4],
        source_ids=[meta['id'],notice['id']],source_clause_sha256=sha(m[0].encode())))
    sources += [dict(meta,path=str(p)),notice]
    return dict(links=links,sources=sources)

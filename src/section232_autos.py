"""Original-annex automobile decisions, independent of economic sector models.

The native schedule corroborates scope/claims; original instruments supply entry
windows, including retroactive country amendments. Unpriced valuation, offsets
and FTZ paths remain executable questions, never ordinary-rate fallbacks. This
does not certify the complete Section 232 inventory.
"""
from __future__ import annotations
import argparse
import copy
from datetime import datetime
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess
from zoneinfo import ZoneInfo

from section301_sources import sha, verify_revision_header, unique_span
from section232_stacking import note, reporting_codes, amendment
from section232_note16_rules import val, fact, op, both, either, negate, choose
from shipment_base_sources import extract_rows

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT/'resources/legal_evidence/section232/autos'
PRODUCT = r'(?<![\d.])(?:\d{4}\.\d{2}\.\d{4}|\d{4}\.\d{2}\.\d{2}|\d{4}\.\d{2}|\d{4})(?![\d.])'
HEADING = r'9903\.\d{2}\.\d{2}'


def canonical(text):
    return ' '.join(text.replace('\0', '').split())


def products(text):
    """A bounded, codes-only annex table; malformed cells cannot be dropped."""
    text = re.sub(r'\[\[Page \d+\]\]', '', text)
    codes = re.findall(PRODUCT, text)
    if not codes or re.sub(PRODUCT, '', text).strip(' \n\t\r;,'):
        raise ValueError('Unreviewed automobile scope table')
    return sorted(set(c.replace('.', '') for c in codes))


def native_scope(clause):
    try:
        _, table = clause.split('this subdivision:', 1)
    except ValueError:
        raise ValueError('Unreviewed automobile scope introduction') from None
    return products(table)


def scope_span(text, begin, end):
    span = unique_span(text, begin, end)
    return span[re.match(begin, span).end():]


def instant(text):
    days = set(re.findall(r'12:01 a\.m\. eastern (?:daylight )?time on (\w+ \d+, \d{4})', canonical(text)))
    if len(days) != 1:
        raise ValueError('Ambiguous automobile operative entry instant')
    return datetime.strptime(days.pop(), '%B %d, %Y').replace(hour=0, minute=1,
        tzinfo=ZoneInfo('America/New_York')).isoformat()


def heading_pair(text, subdivision, count):
    # Parse the actual inserted subdivision, rather than predicting a suffix.
    m = re.search(r'\('+subdivision+r'\) (?:Except as provided for in headings? .*?, )?[Hh]eadings? (.*?) set[s]? forth the ordinary customs duty treatment', canonical(text))
    if not m:
        raise ValueError('Missing original automobile reporting decision')
    codes = re.findall(HEADING, m[1])
    if len(codes) != count or len(set(codes)) != count:
        raise ValueError('Ambiguous original automobile reporting decision')
    return codes


def excluded_codes(text, subdivision=None):
    flat=canonical(text)
    if subdivision:
        m=re.search(r'\('+subdivision+r'\) (?:Except as provided for in headings? .*?, )?[Hh]eadings? .*? set[s]? forth the ordinary customs duty treatment',flat)
        if not m:raise ValueError('Missing original automobile interaction subdivision')
        flat=flat[m.start():]
        stop=re.search(r'\b(?:\d+|[a-z])\.\s+(?:U\.S\. note|Subchapter|The article description)',flat)
        if stop:flat=flat[:stop.start()]
    m=re.search(r'shall not be subject to(?: the additional duties imposed on)?\s*:\s*(.*)',flat)
    if not m:raise ValueError('Unreviewed automobile nonstacking clause')
    codes=reporting_codes(m[1])
    if not codes or any(c.startswith('9903.94.') for c in codes):
        raise ValueError('Unbounded automobile nonstacking references')
    return codes


@lru_cache(maxsize=1)
def load_history():
    review = json.loads((EVIDENCE/'review.json').read_bytes())
    sources, artifacts, texts = [], [], {}
    for s in review['sources']:
        p = ROOT/s['path']
        if sha(p.read_bytes()) != s['sha256']:
            raise ValueError('Automobile original source hash mismatch: '+s['id'])
        sources.append({k:s[k] for k in ('id','sha256','url','citation')} | {'status':'verified'})
        artifacts.append(dict(source_id=s['id'], path=str(p), sha256=s['sha256']))
        if p.suffix == '.txt':
            texts[s['id']] = p.read_text().replace('\0', '')
    original = texts['FR-2025-05930-auto-annex-extraction']
    # The retained PDF's six annex pages were visually reviewed. Its image
    # extraction is corroborated independently against the first native note.
    vehicle_text = unique_span(original, r'A\. Effective', r'B\. Effective')
    parts_text = original[original.index('B. Effective'):]
    vehicle_codes = products(scope_span(vehicle_text,
        r'enumerated in this subdivision:\s*', r'\(c\) Heading'))
    parts_table = scope_span(parts_text, r'enumerated in this subdivision:\s*', r'\(h\) Heading')
    # Remove only independently identified printed page furniture, not numeric
    # residuals that could be malformed product codes.
    parts_table = re.sub(r'^.*Federal Register.*$', '', parts_table, flags=re.M)
    parts_table = re.sub(r'^\s*1471[234]\s*$', '', parts_table, flags=re.M)
    part_codes = products(parts_table)
    baseline_rev = review['baseline_revision']
    baseline = extract(ROOT/f'data/us_notes/chapter99_{baseline_rev}.pdf',
        ROOT/f'data/hts_archives/hts_{baseline_rev}.json', baseline_rev)
    if vehicle_codes != native_scope(baseline['clauses']['b']) or part_codes != native_scope(baseline['clauses']['g']):
        raise ValueError('Original and native automobile product scopes do not reconcile')
    for k, digest in review['stable_clause_sha256'].items():
        if sha(baseline['clauses'][k].encode()) != digest:
            raise ValueError('Unreviewed automobile baseline claim semantics')
    def code(k):
        m = re.search(r'Heading ('+HEADING+r') applies to', baseline['clauses'][k])
        if not m:raise ValueError('Missing automobile claim reporting role')
        return m[1]
    headings = {r['htsno']:r for r in review['baseline_headings']}
    def charge(clause):
        m = re.search(r'heading ('+HEADING+r') provides the ordinary', baseline['clauses'][clause])
        if not m:raise ValueError('Missing automobile ordinary reporting role')
        h = headings[m[1]]
        rates = [re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*([\d.]+)%\.?', canonical(h[k])) for k in ('general','special','other')]
        if any(not r for r in rates) or len({r[1] for r in rates}) != 1:
            raise ValueError('Unreviewed automobile ordinary duty expression')
        percent = float(rates[0][1])
        if str(int(percent))+'%' not in original or m[1] not in original:
            raise ValueError('Original automobile rate table does not corroborate native rate')
        return dict(code=m[1], percent=percent, expression=h['general'])
    age = re.search(r'manufactured in a year at least (\d+) years prior to the year of the date of entry', baseline['clauses']['e'])
    if not age or age[0] not in canonical(original):raise ValueError('Unreviewed automobile calendar-year exception')
    vehicles = dict(prefixes=vehicle_codes, **{'from':instant(vehicle_text)}, **charge('a'))
    parts = dict(prefixes=part_codes, **{'from':instant(parts_text)}, **charge('f'))
    roles = dict(non_vehicle=code('c'), non_us_content=code('d'), vintage=code('e'), exempt_parts=code('h'))
    uk = texts['FR-2025-12060-auto-original-text']
    uk_order=canonical(texts['FR-2025-11473-auto-order'])
    if not all(s in uk_order for s in ('Sec. 2. Automobiles and Automobile Parts.',
        'total tariff of 10 percent (including any most-favored-nation tariffs)',
        'are for use in automobiles that are products of the United Kingdom',
        'effective as of the date of the publication of the Federal Register notice')):
        raise ValueError('Unreviewed original UK parts use, combined basis or commencement')
    uk_a = unique_span(uk,r'    A\. Effective',r'    B\. Effective')
    uk_b = unique_span(uk,r'    B\. Effective',r'    C\. Effective')
    uk_vehicle = heading_pair(uk_a,'i',1)[0]
    uk_parts = heading_pair(uk_b,'j',1)[0]
    uk_vehicle_scope = products(scope_span(uk_a,r'following subheadings\s+of 8703:\s*',r'The aggregate annual'))
    uk_parts_scope = products(scope_span(uk_b,r'following\s+statistical reporting numbers of the HTSUS Annotated:\s*',r'Any automotive part'))
    uk_addition = re.search(r'subheading \+ ([\d.]+)%',uk_a)
    uk_total = re.search(r'total tariff of ([\d.]+) percent',canonical(uk))
    if not uk_addition or not uk_total or instant(uk_a)!=instant(uk_b):raise ValueError('Unreviewed UK automobile duty/window')
    passthrough='The duty provided in the applicable subheading'
    def expressions(general,special=None):
        return dict(general=general,special=general if special is None else special,other='No change')
    deals = [dict(country='United Kingdom', **{'from':instant(uk_a)}, vehicles=[uk_vehicle], parts=[uk_parts],
        vehicles_prefixes=uk_vehicle_scope, parts_prefixes=uk_parts_scope,
        percent=float(uk_addition[1]),parts_percent=float(uk_total[1]), source_id='FR-2025-12060-auto-original-text', kind='uk_quota',
        excluded={'vehicles':excluded_codes(uk_a,'i'),'parts':excluded_codes(uk_b,'j')},
        heading_expressions={uk_vehicle:expressions(passthrough+' + '+uk_addition[1]+'%','No change'),
            uk_parts:expressions(uk_total[1]+'%')})]
    japan_order=canonical(texts['FR-2025-17389-auto-order'])
    if not all(s in japan_order for s in ('Sec. 4. Automobiles and Automobile Parts.',
        "shall be determined by the product's Column 1 Duty Rate",'As of the date of publication of the Federal Register notice described in subsection (b)')):
        raise ValueError('Unreviewed original Japan automobile delegation and duty basis')
    for doc,country,subdivisions,begin,end in [
        ('2025-17908','Japan',('k','l'),r'    c\. Effective',None),
        ('2025-18660','European Union',('n','o'),r'Annex II\s+\n\s*A\. Effective',r'    B\. Effective'),
        ('2025-21940','South Korea',('s','t'),r'    A\. Effective',r'    B\. Effective'),
        ('2026-10571','Taiwan',(None,'u'),r'Annex[ \t]*\n',None)]:
        id = 'FR-'+doc+'-auto-original-text';text = texts[id]
        start = re.search(begin,text)
        if not start:raise ValueError('Missing original country automobile annex: '+doc)
        body = text[start.start():]
        if end:body=body[:re.search(end,body).start()]
        # Taiwan's annex also creates timber treatment; note33(u) independently
        # supplies valid automobile headings despite the malformed note2 text.
        codes = heading_pair(body,subdivisions[1],4 if country in ('South Korea','Taiwan') else 2)
        vehicle = heading_pair(body,subdivisions[0],2) if subdivisions[0] else []
        rates = set(re.findall(r'(?:less than|greater than) ([\d.]+) percent',canonical(body)))
        if len(rates)!=1:raise ValueError('Ambiguous original automobile floor parameter: '+doc)
        percent = float(rates.pop())
        if not all(c in body for c in codes+vehicle) or f'{percent:g}%' not in body:
            raise ValueError('Original automobile floor/table disagreement: '+doc)
        expected={}
        for high,low in [vehicle,codes[:2]] if vehicle else [codes[:2]]:
            # The original row, not the suffix, distinguishes "No change"
            # from a printed ordinary-duty passthrough. Both add zero here.
            row=re.search(r'^`*'+re.escape(high)+r'\.{2,}([^\n]*)',body,re.M)
            if not row:raise ValueError('Missing original automobile floor table row: '+high)
            zero=passthrough if 'The duty provided' in row[1] else 'No change'
            if zero=='No change' and 'No change' not in row[1]:raise ValueError('Unparsed automobile passthrough expression')
            low_row=re.search(r'^`*'+re.escape(low)+r'\.{2,}([^\n]*)',body,re.M)
            if not low_row or f'{percent:g}%' not in low_row[1]:raise ValueError('Unparsed automobile combined-rate expression')
            expected[high]=expressions(zero)
            expected[low]=expressions(f'{percent:g}%')
        deals.append(dict(country=country, **{'from':instant(body[:body.index('U.S. note 33')])},
            vehicles=vehicle,parts=codes[:2], percent=percent, source_id=id,kind='column1_floor',heading_expressions=expected,
            excluded={'vehicles':excluded_codes(body,subdivisions[0]) if vehicle else [],'parts':excluded_codes(body,subdivisions[1])}))
    priority=amendment();s=priority['source']
    sources.append({k:s[k] for k in ('id','sha256','url','citation')}|{'status':'verified'})
    artifacts.append(dict(source_id=s['id'],path=s['path'],sha256=s['sha256']))
    p=ROOT/'resources/legal_evidence/2025-09066/notice.txt'
    m=json.loads(p.with_name('source.json').read_bytes())
    if sha(p.read_bytes())!=m['sha256'] or 'encompasses Proclamation 10522' not in canonical(p.read_text()):
        raise ValueError('Unreviewed Russian-aluminum stacking inclusion')
    sources.append(dict(id='FR-2025-09066',status='verified',**{k:m[k] for k in ('sha256','url','citation')}))
    artifacts.append(dict(source_id='FR-2025-09066',path=str(p),sha256=m['sha256']))
    audit=ROOT/'docs/audits/2026-10-23-stacking-followup'
    m=next(s for s in json.loads((audit/'sources.json').read_bytes()) if s['path']=='CSMS-65054270.txt')
    p=audit/m['path']
    if sha(p.read_bytes())!=m['sha256']:raise ValueError('Automobile positive-payable source hash mismatch')
    sources.append(dict(id='CBP-CSMS-65054270',status='verified',sha256=m['sha256'],url=m['url'],
        citation='CBP CSMS65054270, May15,2025; duty owed/payable interpretation before the November subject-to amendment.'))
    artifacts.append(dict(source_id='CBP-CSMS-65054270',path=str(p),sha256=m['sha256']))
    return dict(vehicles=vehicles,parts=parts,roles=roles,age_years=int(age[1]),deals=deals,
        priority_from=priority['effective_from'],until=review['cutoff_until'],review=review,baseline=baseline,sources=sources,source_artifacts=artifacts)


def extract(pdf, hts, revision):
    raw = subprocess.check_output(['pdftotext','-layout',str(pdf),'-'],text=True)
    verify_revision_header(raw,revision)
    schedule = json.loads(hts.read_bytes())
    headings = [{k:r.get(k,'') for k in ('htsno','description','general','special','other')}
        for r in schedule if re.fullmatch(r'9903\.94\.\d{2}',r.get('htsno',''))]
    return dict(revision=revision,clauses=note(raw,33) if headings else {},headings=headings,
        russian_reporting_codes=sorted({r['htsno'] for r in schedule if
            re.fullmatch(HEADING,r.get('htsno','')) and 'primary aluminum' in r.get('description','') and
            'smelted in Russia' in r.get('description','') and 'cast in Russia' in r.get('description','')}),
        base_sources={p['hts10']:p['general'] for p in extract_rows(schedule)['products']},
        valid_products=sorted({r['htsno'].replace('.','') for r in schedule
            if re.fullmatch(r'\d{4}\.\d{2}\.\d{2}\.\d{2}',r.get('htsno',''))}),
        chapter98_provisions=sorted({r['htsno'].replace('.','')[:8] for r in schedule
            if re.fullmatch(r'98\d{2}\.\d{2}\.\d{2}(?:\.\d{2})?',r.get('htsno',''))}),
        sources=[dict(path=str(p.resolve()),sha256=sha(p.read_bytes())) for p in (pdf,hts)])


def reconcile_native(x, h=None):
    h = load_history() if h is None else h
    clauses=x['clauses'];review=h['review']
    if bool(clauses)!=bool(x['headings']):raise ValueError('Unreviewed automobile note/heading inventory mismatch')
    if clauses:
        for k,digest in review['stable_clause_sha256'].items():
            if sha(clauses.get(k,'').encode())!=digest:raise ValueError('Unreviewed automobile '+k+' claim semantics')
        for k,group in [('b','vehicles'),('g','parts')]:
            if k in clauses and native_scope(clauses[k])!=h[group]['prefixes']:
                raise ValueError('Unreviewed automobile '+k+' product scope')
        if 'h' in clauses:
            normalized = clauses['h'].replace('enumerated in subdivision','enumerated subdivision').replace(
                ' or meeting the requirements of subdivision (p) of this note','')
            if normalized != review['parts_exception_original']:
                raise ValueError('Unreviewed automobile parts exception semantics')
        current={r['htsno']:r for r in x['headings']}
        for old in review['baseline_headings']:
            now=current.get(old['htsno'])
            if now is None:continue
            for k in ('general','special','other'):
                norm=lambda s:re.sub(r'\s*\+\s*','+',canonical(s)).rstrip('.')
                if norm(now[k])!=norm(old[k]):raise ValueError('Unreviewed automobile reporting duty expression')
        for deal in h['deals']:
            for code,expected in deal['heading_expressions'].items():
                if code not in current:continue
                if any(norm(current[code][k])!=norm(v) for k,v in expected.items()):
                    raise ValueError('Unreviewed automobile country duty expression: '+code)


def compile_rules(x, product_list, jurisdictions):
    h = copy.deepcopy(load_history())
    reconcile_native(x,h)
    if not jurisdictions.get('all'):raise ValueError('Missing automobile country inventory')
    product_list=sorted(set(product_list))
    if any(not re.fullmatch(r'\d{10}',p) for p in product_list):raise ValueError('Invalid automobile HTS10 inventory')
    if not x.get('valid_products') or not set(product_list)<=set(x['valid_products']):
        raise ValueError('Automobile product is not valid in the identified revision')
    ids=[s['id'] for s in h['sources']]
    release=x['revision'].replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    for i,s in enumerate(x['sources']):
        id=f'USITC-{x["revision"]}-note33-{i}';ids.append(id)
        h['sources'].append(dict(id=id,status='verified',sha256=s['sha256'],
            url='https://hts.usitc.gov/reststop/'+(f'file?release={release}&filename=Chapter%2099' if i==0 else f'exportList?release={release}&exportFormat=JSON'),
            citation='Revision note33 scope and unchanged original claims; original instruments supply operative entry dates.'))
        h['source_artifacts'].append(dict(source_id=id,**s))
    if x.get('jurisdiction_source'):
        s=x['jurisdiction_source'];p=Path(s['path'])
        if sha(p.read_bytes())!=s['sha256']:raise ValueError('Automobile GN3 source hash mismatch')
        id='USITC-'+x['revision']+'-auto-gn3';ids.append(id)
        h['sources'].append(dict(id=id,status='verified',**{k:s[k] for k in ('sha256','url','citation')}))
        h['source_artifacts'].append(dict(source_id=id,path=str(p),sha256=s['sha256']))
    elif jurisdictions.get('non_ntr'):
        raise ValueError('Missing primary automobile GN3 country evidence')
    facts={}
    def f(name,label,kind='boolean',unit=None,description=None):
        d=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':d['minimum']=0
        if unit:d['unit']=unit
        if description:d['description']=description
        facts[name]=d
        return fact(name)
    cv=f('customs_value','Customs value (USD)','number','USD')
    use_vehicle=f('s232_auto_passenger_vehicle','Article is a passenger vehicle or light truck as defined by U.S. note33(a)')
    manufacture=f('s232_auto_manufacture_year','Actual vehicle manufacture calendar year','number',
        description='Use manufacture year, not model year. The rule compares this year with the entry calendar year, including January1 changes.')
    # Reuse the v1 numeric-enum contract for whole calendar years. This avoids
    # silently accepting fractional years or requiring a newer interpreter.
    facts['s232_auto_manufacture_year'].update(minimum=1,
        enum=list(range(1,datetime.fromisoformat(h['until']).year+1)))
    entry_calendar=f('s232_auto_entry_calendar_year','Calendar year on the actual CBP entry record','number',
        description='Needed around NewYear: a port entry date and the Eastern legal-clock instant can have different calendar years. Use the entry record, not an assumed port timezone.')
    facts['s232_auto_entry_calendar_year']['enum']=list(range(datetime.fromisoformat(h['vehicles']['from']).year,
        datetime.fromisoformat(h['until']).year+1))
    use_parts=f('s232_auto_parts_use','Article is a part of a passenger vehicle or light truck as defined by U.S. note33(f)')
    eligible=f('s232_auto_usmca_eligible','Goods actually qualify for preferential treatment under USMCA',
        description='Eligibility is a legal shipment fact; neither Canada/Mexico origin nor a requested claim establishes eligibility.')
    kit=f('s232_auto_knockdown_kit_or_compilation','Shipment is an automobile knock-down kit or parts compilation')
    approved=f('s232_auto_commerce_us_content_approved','Commerce approved U.S. content treatment for the vehicle/model')
    us=f('s232_auto_us_content_value','Commerce-approved U.S. vehicle content value (USD)','number','USD')
    punitive=f('s232_auto_cbp_overstatement_finding','CBP U.S.-content overstatement finding applies to this model/importer and entry')
    ftz=f('ieepa_ftz_entry','Entry withdrawn from a U.S. foreign-trade zone')
    column1=f('column1_duty_amount','Applicable column 1 duty (USD)','number','USD',
        description='Actual applicable column 1 duty after a valid preference, with specific/compound quantities priced. Never an aggregate or trade-weighted AVE.')
    proper_preference=f('s232_auto_column1_preference_properly_claimed','Selected Column1-Special preference was properly claimed for this entry')
    special_eligible=f('s232_auto_column1_preference_eligible','Goods actually satisfy the selected Column1-Special preference rules',
        description='Establish the selected program and its entitlement separately from USMCA eligibility. This fact does not establish base-duty relief or any other authority interaction.')
    special_requested=either({'claim':'COLUMN1_SPECIAL'},{'claim':'USMCA'})
    quota=f('s232_uk_auto_quota_allocated','CBP allocation for this UK passenger-vehicle entry is within the applicable annual and quarterly quota')
    uk_parts_use=f('s232_uk_auto_parts_uk_vehicle_use','UK-produced part is for use in an automobile that is a product of the United Kingdom',
        description='EO14309 sec2(b) requires both UK origin of the part and UK origin of the automobile in which it is used.')
    rules=[];relations=[]
    chapter98=f('chapter98_properly_claimed','Entry properly claimed under the selected Chapter 98 provision')
    facts['chapter98_provision']=dict(type='string',label='Chapter 98 provision (eight digits)',enum=x['chapter98_provisions'],source_ids=ids)
    full=re.search(r'except that duties under subheading (9802\.\d{2}\.\d{2}) shall be assessed based upon the full value',h['baseline']['clauses']['a'])
    if not full:raise ValueError('Missing original automobile Chapter98 full-value exception')
    ch98=op('if',{'claim':'CHAPTER_98'},op('if',chapter98,
        op('if',op('eq',fact('chapter98_provision'),val(full[1].replace('.',''))),val(True),
            {'unresolved_source':'auto_chapter98_selected_provision_terms_and_valuation'}),
        {'unresolved_source':'auto_chapter98_claim_entitlement'}),val(True))
    ordinary=op('if',ftz,{'unresolved_source':'auto_ftz_admission_status_and_privileged_rate_history'},ch98)
    content_claim={'claim':'SECTION_232_AUTO_US_CONTENT'}
    offset_claim={'claim':'SECTION_232_AUTO_IMPORT_OFFSET'}
    def leaf(code,formula=val(0),checks=None,subject=False,country=None,replaces_base=False):return dict(code=code,formula=formula,checks=checks or [],subject=subject,country=country,replaces_base=replaces_base)
    def unresolved(question,code=None,subject=False,country=None,replaces_base=False):return leaf(code,{'unresolved_source':question},subject=subject,country=country,replaces_base=replaces_base)
    def branch(test,yes,no):return choose(test,yes,no)
    def amount(percent,basis=cv):return op('multiply',basis,op('divide',val(percent),val(100)))
    def walk(tree,path,scope,action):
        if isinstance(tree,tuple):
            _,test,yes,no=tree
            walk(yes,op('if',path,test,val(False)),scope,action)
            walk(no,op('if',path,negate(test),val(False)),scope,action)
            return
        if isinstance(tree,list):
            for t in tree:walk(t,path,scope,action)
            return
        if tree.get('skip'):return
        id=f'auto_{x["revision"]}_{len(rules)}'
        r=dict(id=id,action_id=action,authority='section_232',kind='duty',verification='verified',
            scope=scope,when=op('if',path,ordinary,val(False)),formula=tree['formula'],
            reporting_codes=[tree['code']] if tree['code'] else [],source_ids=ids,
            legal_locator='Proclamation10908 clauses1-5,8; AnnexI note33; original country amendment annexes')
        checks=list(tree['checks'])
        if checks:r['input_constraints']=checks
        rules.append(r)
        if tree['replaces_base']:
            r['valuation_role']='combined_ordinary_duty_including_mfn'
            relations.append(dict(id=id+'_replaces_ordinary_base',effect='suppress',when_rule_applies=id,
                target_action_ids=['ordinary_customs_duty'],source_ids=['FR-2025-11473-auto-order','FR-2025-12060-auto-original-text']))
        if tree['subject'] and x['russian_reporting_codes']:
            # EO14289 identifies actions, not an exhaustive numeric heading
            # list. CBP's original footnote expressly includes Proclamation10522.
            # A later continuation of its200percent rate does not itself repeal
            # that separate stacking rule or November's subject-to amendment.
            relations.append(dict(id=id+'_russian_aluminum_nonstacking',effect='suppress',when_rule_applies=id,
                trigger_test='applicability' if scope['from']>=h['priority_from'] else 'positive_duty',
                target_reporting_codes=x['russian_reporting_codes'],source_ids=ids))
        # Individual country annexes expressly remove named competing duties,
        # including a zero-additional combined-rate heading. Those relationships
        # cannot wait for the reporting heading to appear in a later snapshot.
        for d in h['deals']:
            sector='vehicles' if action=='s232_automobiles' else 'parts'
            if tree['code'] in d[sector] or tree['country']==d['country']:
                relations.append(dict(id=id+'_country_nonstacking',effect='suppress',when_rule_applies=id,
                    target_reporting_codes=d['excluded'][sector],source_ids=[d['source_id']]))
        window=x.get('native_window')
        if window and tree['subject']:
            lo=max(window['from'],h['priority_from']);hi=window['until']
            if lo<hi:
                clause='a' if action=='s232_automobiles' else 'f'
                targets=excluded_codes(x['clauses'].get(clause,''))
                relations.append(dict(id=id+'_native_nonstacking',effect='suppress',when_rule_applies=id,
                    target_reporting_codes=targets,source_ids=ids,source_window={'from':lo,'until':hi}))
    def offset(tree):
        # A claimed offset does not erase legal coverage or its reporting role.
        # Preserve each country/valuation decision while withholding the amount.
        def unpriced(t):
            if isinstance(t,tuple):return branch(t[1],unpriced(t[2]),unpriced(t[3]))
            return unresolved('auto_import_adjustment_offset_allocation_and_entry_application',t['code'],t['subject'],t['country'],t['replaces_base'])
        return branch(offset_claim,unpriced(tree),tree)
    # Group exact products by source membership, not by an economic sector's
    # winning candidate. A source-listed HTS10 cannot widen to its HTS8 parent.
    for sector,action in [('vehicles','s232_automobiles'),('parts','s232_automobile_parts')]:
        group=h[sector];members=[p for p in product_list if any(p.startswith(prefix) for prefix in group['prefixes'])]
        if not members:continue
        boundaries=sorted({group['from'],h['until']}|{d['from'] for d in h['deals'] if d[sector] and d['from']>group['from']})
        if sector=='vehicles':
            boundaries=sorted(set(boundaries)|{datetime(y,1,1,tzinfo=ZoneInfo('America/New_York')).isoformat()
                for y in range(datetime.fromisoformat(group['from']).year+1,datetime.fromisoformat(h['until']).year+1)
                if datetime(y,1,1,tzinfo=ZoneInfo('America/New_York')).isoformat()<h['until']})
            # Date-of-entry year is not a proclamation's Eastern instant. A
            # conservative NewYear window requests the actual record year;
            # ordinary dates can use the unambiguous calendar year directly.
            for y in range(datetime.fromisoformat(group['from']).year+1,datetime.fromisoformat(h['until']).year+1):
                boundaries += [datetime(y-1,12,31,tzinfo=ZoneInfo('America/New_York')).isoformat(),
                    datetime(y,1,2,tzinfo=ZoneInfo('America/New_York')).isoformat()]
            boundaries=sorted({b for b in boundaries if group['from']<=b<=h['until']})
        for current_from,until in zip(boundaries,boundaries[1:]):
            active=[d for d in h['deals'] if d[sector] and d['from']<=current_from]
            # Identical decisions share a rule scope. UK list precision can
            # differ from the original universal automobile/parts lists.
            groups={}
            for origin in sorted(set(jurisdictions['all'])):
                by_decision={}
                for p in members:
                    key=tuple(d['country'] for d in active if origin in jurisdictions.get(d['country'],[]) and
                        (d['kind']!='uk_quota' or any(p.startswith(a) for a in d[sector+'_prefixes'])))
                    by_decision.setdefault(key,[]).append(p)
                for countries,ps in by_decision.items():
                    # Country floors use the complete native General expression
                    # in an unclaimed entry. Keep unlike valuation expressions
                    # separate; neither an input AVE nor an economic rate selects it.
                    bases={}
                    for p in ps:
                        data=x.get('base_amounts',{}).get(p)
                        signature=json.dumps(data,sort_keys=True) if countries else ''
                        bases.setdefault(signature,[]).append(p)
                    for basis,items in bases.items():
                        key=(countries,tuple(items),origin in jurisdictions.get('non_ntr',[]))
                        groups.setdefault(key,[]).append(origin)
            for (countries,ps,column2),origins in groups.items():
                ordinary_charge=leaf(group['code'],amount(group['percent']),subject=True)
                # Only operative country instruments can replace the ordinary
                # action; publication/snapshot dates do not select the rate.
                for d in active:
                    if d['country'] not in countries:continue
                    if d['kind']=='uk_quota':
                        ordinary_charge=branch(quota,leaf(d[sector][0],amount(d['percent']),subject=True),ordinary_charge) if sector=='vehicles' else branch(
                            uk_parts_use,leaf(d[sector][0],amount(d['parts_percent']),subject=True,replaces_base=True),ordinary_charge)
                    else:
                        threshold=amount(d['percent'])
                        base=x.get('base_amounts',{}).get(ps[0])
                        if base:
                            source=x['base_sources'].get(ps[0])
                            if not source or any(base.get(k)!=source.get(k) for k in ('source_code','source_row_index')) or base.get('raw')!=source.get('expression'):
                                raise ValueError('Automobile native base expression/owner mismatch')
                            for name,definition in base['fact_definitions'].items():
                                definition=copy.deepcopy(definition);definition['source_ids']=ids
                                old=facts.get(name)
                                semantics=lambda q:{k:q[k] for k in ('type','unit','minimum','maximum','enum') if k in q}
                                if old and semantics(old)!=semantics(definition):raise ValueError('Conflicting automobile base valuation fact')
                                facts[name]=definition
                            general=base['formula'];checks=base['input_constraints']
                        else:
                            general={'unresolved_source':'auto_column1_general_source_expression_required'};checks=[]
                        def floor(basis,rate_test=None):
                            test=rate_test if rate_test is not None else op('if',op('gt',cv,val(0)),op('gte',basis,threshold),
                                {'unresolved_source':'auto_ave_floor_requires_positive_customs_value'})
                            return branch(test,leaf(d[sector][0],checks=checks,subject=True,country=d['country']),
                                leaf(d[sector][1],op('subtract',threshold,basis),checks,subject=True,country=d['country']))
                        rate_test=None
                        fixed_expression=base.get('normalized_text',base.get('raw')) if base else None
                        if isinstance(fixed_expression,str) and re.fullmatch(r'(?:Free|[\d.]+%)',fixed_expression,re.I):
                            def per_dollar(node):
                                if node==fact('customs_value'):return val(1)
                                if isinstance(node,dict):return {k:per_dollar(v) for k,v in node.items()}
                                if isinstance(node,list):return [per_dollar(v) for v in node]
                                return node
                            rate_test=op('gte',per_dollar(general),op('divide',val(d['percent']),val(100)))
                        unclaimed=floor(general,rate_test)
                        # Korea expressly defines General OR Special and supplies
                        # a Special specific/compound AVE instruction. EU uses
                        # MFN; Japan's and Taiwan's specific/compound provisions
                        # name General. Do not silently equate these bases.
                        if d['country']=='South Korea':
                            entitlement=op('if',{'claim':'COLUMN1_SPECIAL'},special_eligible,eligible)
                            claimed=branch(both(entitlement,proper_preference),floor(column1),
                                unresolved('auto_korea_column1_special_entitlement_not_established',subject=True,country=d['country']))
                        else:
                            claimed=unresolved('auto_country_preference_and_column1_general_special_reconciliation',subject=True,country=d['country'])
                        ordinary_charge=branch(special_requested,claimed,unclaimed)
                        ordinary_charge=branch({'claim':'CHAPTER_98'},unresolved('auto_country_floor_and_chapter98_valuation',subject=True,country=d['country']),ordinary_charge)
                if sector=='vehicles':
                    calendar=datetime.fromisoformat(current_from)
                    if (calendar.month,calendar.day) in ((12,31),(1,1)):
                        lo=calendar.year if calendar.month==12 else calendar.year-1
                        hi=lo+1
                        needs_record=either(both(op('gt',manufacture,val(lo-h['age_years'])),
                            op('lte',manufacture,val(hi-h['age_years']))),op('gt',manufacture,val(lo)))
                        entry_year=op('if',needs_record,entry_calendar,val(lo))
                    else:entry_year=val(calendar.year)
                    vintage=op('if',op('lte',manufacture,entry_year),
                        op('lte',manufacture,op('subtract',entry_year,val(h['age_years']))),
                        {'unresolved_source':'invalid_fact_s232_auto_manufacture_year_after_entry_year'})
                    checks=[dict(test=op('lte',us,cv),inputs=['s232_auto_us_content_value','customs_value'],label='Approved U.S. content cannot exceed vehicle value')]
                    content=branch(punitive,unresolved('auto_cbp_overstatement_model_importer_entry_window_and_reporting',subject=True),[
                        leaf(h['roles']['non_vehicle'],checks=checks),leaf(h['roles']['non_us_content'],amount(group['percent'],op('subtract',cv,us)),checks,subject=True)])
                    content=branch(eligible,branch(approved,content,unresolved('auto_us_content_commerce_approval_not_established',subject=True)),
                        unresolved('auto_us_content_usmca_entitlement_not_established',subject=True))
                    # Country agreements may replace the original content path;
                    # do not choose whichever independently calculated rate is
                    # smaller without an express legal election/precedence.
                    if countries:content=unresolved('auto_country_agreement_and_approved_us_content_election',subject=True,
                        country=next((d['country'] for d in active if d['country'] in countries and d['kind']!='uk_quota'),None))
                    if column2:content=unresolved('auto_us_content_column2_no_change_and_claim_eligibility',subject=True)
                    charged=branch(content_claim,content,ordinary_charge)
                    tree=branch(use_vehicle,branch(vintage,leaf(h['roles']['vintage']),charged),leaf(h['roles']['non_vehicle']))
                else:
                    exception=op('if',eligible,negate(kit),val(False))
                    tree=branch(use_parts,branch(exception,leaf(h['roles']['exempt_parts'],subject=True),offset(ordinary_charge)),leaf(h['roles']['exempt_parts']))
                walk(tree,val(True),dict(hts_exact=list(ps),countries=origins,**{'from':current_from,'until':until}),action)
    rids=[r['id'] for r in rules]
    # Candidate provenance is the original mixed-precision annex, not the first
    # retained country amendment or a statistical code invented during expansion.
    memberships={action:[dict(hts10=p,scope_code=prefix,
        scope_grain='exact_hts10' if len(prefix)==10 else 'prefix')
        for p in product_list for prefix in h[sector]['prefixes'] if p.startswith(prefix)]
        for sector,action in [('vehicles','s232_automobiles'),('parts','s232_automobile_parts')]}
    scope_source=next(a for a in h['source_artifacts'] if a['source_id']=='FR-2025-05930-auto-pdf')
    # Existing cross-program compilers used independently entered aliases for
    # these same legal facts. In a composed normal build they must resolve from
    # one authoritative automobile decision/value, not contradictory answers.
    approved_content=both(use_vehicle,content_claim,eligible,approved)
    individual_parts=both(use_parts,eligible,negate(kit))
    derived={name:dict(expression=expression,source_ids=ids) for expression,names in [
        (approved_content,['s232_auto_approved_us_content','s122_commerce_approved_us_vehicle_content','s338_commerce_approved_us_vehicle_content']),
        (individual_parts,['s232_usmca_auto_parts_not_kits','s122_usmca_auto_parts_not_kits','s338_usmca_auto_parts_not_kits']),
        (us,['s122_vehicle_us_content_value','s338_vehicle_us_content_value'])] for name in names}
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='s232_autos_'+x['revision'],
        supported_from='2025-01-01T00:00:00-05:00',supported_until=h['until'],sources=h['sources'],source_artifacts=h['source_artifacts'],
        rules=rules,relations=relations,fact_definitions=facts,derived_facts=derived,coverage=[],
        candidate_memberships=memberships,candidate_scope_source=scope_source,
        claim_definitions=[dict(id=c,label=l,rule_ids=rids,source_ids=ids) for c,l in [('USMCA','USMCA'),('CHAPTER_98','Chapter 98'),
            ('COLUMN1_SPECIAL','Selected Column 1 Special preference'),
            ('SECTION_232_AUTO_US_CONTENT','Commerce-approved automobile U.S. content'),('SECTION_232_AUTO_IMPORT_OFFSET','Automobile import-adjustment offset')]] if rids else [],
        unchanged_claims=[dict(id='autos_'+x['revision']+'_301_independent',claim_authority='section_301',candidate_required_fields=['exclusion_claim_id'],target_rule_ids=rids,source_ids=ids)] if rids else [],
        unresolved_questions=[dict(id='auto_additional_certified_parts',question='Reconcile note33(p)/(q)/(r) certified U.S. production/repair parts outside original(g), including MHDV exclusions, original November commencement and later country amendments.',source_ids=ids),
            dict(id='auto_remaining_valuation',question='Price approved offsets, other Chapter98 and FTZ histories; country/content elections and CBP overstatement findings remain explicit shipment branches.',source_ids=ids)],
        limitations=['Original listed passenger/light-truck vehicles and parts only; no complete Section232 coverage attestation.',
            'Unclaimed country floors use native whole General duty expressions and legal quantities. Korea Special treatment requires established entitlement and actual duty; other country preference/AVE and Chapter98 floor interactions remain unpriced.',
            'Manufacture exception uses the entry calendar year. No modeled shares or assembly credit alters these decisions.'])


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--pdf',type=Path,required=True);parser.add_argument('--hts',type=Path,required=True)
    parser.add_argument('--revision',required=True);parser.add_argument('--input',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    a=parser.parse_args();x=json.loads(a.input.read_bytes())
    native=extract(a.pdf,a.hts,a.revision)
    if x.get('jurisdiction_source'):native['jurisdiction_source']=x['jurisdiction_source']
    if x.get('base_amounts'):native['base_amounts']=x['base_amounts']
    if x.get('native_window'):native['native_window']=x['native_window']
    result=compile_rules(native,x['products'],x['jurisdictions'])
    result['compiler_sha256']=sha(Path(__file__).read_bytes())
    a.output.write_text(json.dumps(result,indent=2)+'\n')


if __name__=='__main__':main()

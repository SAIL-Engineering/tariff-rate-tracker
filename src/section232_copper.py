"""Original note36 copper action, distinct from modeled metal allocations.

Native tables corroborate the original annex rather than selecting legal dates.
Peer automobile rules supply actual action decisions, not a maximum numeric rate.
This fragment does not certify the complete Section232 or FTZ inventory.
"""
from __future__ import annotations
import argparse
import copy
import csv
from functools import lru_cache
import json
from pathlib import Path
import re
import subprocess

from section301_sources import sha, unique_span, verify_revision_header
from section232_stacking import note,reporting_codes
from section232_note16_rules import val,fact,op
from ieepa_fentanyl_sources import verified_source, windows
from ieepa_reciprocal_history import annex,clean_fr
from shipment_base_sources import extract_rows
from section232_autos import load_history as automobile_history
from chapter99_inventory import note_index
from section232_civil_aircraft import load_history as aircraft_history

ROOT=Path(__file__).resolve().parents[1]
CODE=r'(?<![\d.])\d{4}\.\d{2}\.\d{2}(?![\d.])'


def semantic(text):
    # Compare the complete lexical content across PDF typography. Product
    # enumeration and each duty-column expression have independent validation.
    return re.sub(r'[^a-z0-9%]','',text.lower())


def signature(x):
    return sha(json.dumps(x,sort_keys=True,separators=(',',':')).encode())


def source_record(meta,path):
    path=Path(path)
    if not path.is_absolute():path=ROOT/path
    if sha(path.read_bytes())!=meta['sha256']:raise ValueError('Copper source hash mismatch: '+meta['id'])
    return dict(meta,path=str(path))


def codes_only(text):
    text=text.replace("[Compiler's note: numbers in sequence left to right; list may appear or continue on a subsequent page.]",'')
    codes=re.findall(CODE,text)
    if not codes or re.sub(CODE,'',text).strip():raise ValueError('Unparsed copper scope table')
    return sorted(set(c.replace('.','') for c in codes))


@lru_cache(maxsize=1)
def known_exceptions():
    auto=automobile_history();aircraft=aircraft_history();charged=load_history()['charged_code']
    codes=set()
    for d in auto['deals']:
        for sector in ('parts','vehicles'):
            if charged in d['excluded'][sector]:codes.update(d[sector])
    for a in aircraft['actions']:
        if charged in a['original_targets']:codes.add(a['reporting_code'])
    return codes,aircraft['sources']


def reconcile_note(clauses,headings,h):
    if set(clauses)!=set(h['clauses']):raise ValueError('Unreviewed copper note structure')
    if codes_only(clauses['b'].split('this subdivision:',1)[1])!=h['hts8']:raise ValueError('Copper annex/native product scope mismatch')
    prefix=re.match(r'^Except as provided in headings (.*?), heading (?=9903\.78\.01 provides)',clauses['a'])
    stripped=clauses['a'];exceptions=[]
    if prefix:
        exceptions=reporting_codes(prefix[1])
        residual=re.sub(r'9903\.\d{2}\.\d{2}(?:\s*[-–—]\s*9903\.\d{2}\.\d{2})?','',prefix[1])
        known,_=known_exceptions()
        if not exceptions or set(exceptions)-known or re.sub(r'\band\b|[,\s]','',residual):
            raise ValueError('Unreconciled copper exception reference or condition')
        stripped='Heading '+clauses['a'][prefix.end():]
    if any(semantic(clauses[k] if k!='a' else stripped)!=semantic(h['clauses'][k]) for k in ('a','c','d')):
        raise ValueError('Unreviewed copper native semantics')
    if {r['htsno'] for r in headings}!={h['charged_code'],h['remainder_code']}:raise ValueError('Copper heading inventory changed')
    for row in headings:
        expected=('The duty provided in the applicable subheading + a duty of '+f'{h["rate"]*100:g}'+'% upon the value of the copper content') if row['htsno']==h['charged_code'] else 'The duty provided in the applicable subheading'
        if any(semantic(row.get(k,''))!=semantic(expected) for k in ('general','special','other')):
            raise ValueError('Copper original/native duty-column mismatch')
    return exceptions


@lru_cache(maxsize=1)
def load_history():
    text,original=verified_source('2025-14893')
    raw,original_annex=annex('2025-14893')
    first=unique_span(text,r'^\(1\)',r'^\(2\)')
    begin=windows(first)['valid_from']
    rate=re.search(r'subject to a ([\d.]+) percent tariff', ' '.join(first.split()))
    portion=unique_span(text,r'^\(4\)',r'^\(5\)')
    priority=unique_span(text,r'^\(5\)',r'^\(6\)')
    if not begin or not rate or not all(s in ' '.join(portion.split()) for s in
        ('shall apply only to the copper content','non-copper content','Executive Order 14257')):
        raise ValueError('Unreviewed original copper rate or portion instruction')
    if not all(s in ' '.join(priority.split()) for s in ('Proclamation 10908','and not those imposed pursuant to this proclamation')):
        raise ValueError('Unreviewed original copper automobile priority')
    flat=clean_fr(raw)
    flat=re.sub(r'(?<=\d)\s+(?=\.)|(?<=\.)\s+(?=\d)','',flat)
    span=unique_span(flat,r'^\s*"\(a\) Heading',r'^\s*2\. Subchapter Ill')
    starts=list(re.finditer(r'^\s*"?\(([a-d])\)\s',span,re.M))
    if [m[1] for m in starts]!=list('abcd'):raise ValueError('Missing original copper note subdivision')
    clauses={m[1]:' '.join(span[m.end():starts[i+1].start() if i+1<len(starts) else len(span)].split()).rstrip('"')
             for i,m in enumerate(starts)}
    table=clauses['b'].split('this subdivision:',1)
    if len(table)!=2:raise ValueError('Unrecognized original copper scope introduction')
    htss=codes_only(table[1])
    charged=re.search(r'Heading (9903\.\d{2}\.\d{2}) provides',clauses['a'])
    remainder=re.search(r'Heading (9903\.\d{2}\.\d{2}) applies to the non-copper content',clauses['c'])
    full=re.search(r'except that duties under subheading (9802\.\d{2}\.\d{2}) shall be assessed based upon the full value',clauses['a'])
    if not charged or not remainder or not full:raise ValueError('Original copper reporting or Chapter98 role missing')
    primary_headings=unique_span(flat,r'^\s*2\. Subchapter Ill',r'^\s*3\. U\.S\. note')
    table_rates=re.findall(r'([\d.]+)%',primary_headings)
    if not all(s in primary_headings for s in (charged[1],remainder[1])) or table_rates!=[rate[1]]*3:
        raise ValueError('Original copper heading table does not reconcile')
    guidance_meta=json.loads((ROOT/'resources/legal_evidence/CSMS-65794272/source.json').read_bytes())
    guidance=source_record(guidance_meta,'resources/legal_evidence/CSMS-65794272/notice.txt')
    cbp=' '.join(Path(guidance['path']).read_text().split())
    required=('imported goods under the subject HTSUS classifications which contain no copper',
        'If the value of the copper content cannot be determined, then report the duty based on the total entered value',
        'When insufficient documentation is provided to substantiate the reported values, CBP will collect the duties on the copper content based on the entire value of the good',
        'For imported articles composed only of copper, the dutiable value of the copper content is the total entered value')
    if not all(s in cbp for s in required):raise ValueError('Unreviewed copper CBP valuation states')
    retirement=json.loads((ROOT/'resources/legal_evidence/section232/copper/retirement-source.json').read_bytes())
    reviewed=source_record(retirement,retirement['path'])
    pdf=ROOT/retirement['original_pdf_path']
    if sha(pdf.read_bytes())!=retirement['original_pdf_sha256']:raise ValueError('Copper retirement PDF changed')
    retirement_text=Path(reviewed['path']).read_text()
    if not all(s in retirement_text for s in ('U.S. note 36 is deleted',charged[1],remainder[1],'terminated and deleted')):
        raise ValueError('Copper retirement instruction does not identify its action')
    april_meta=json.loads((ROOT/'resources/legal_evidence/section232/civil-aircraft/sources.json').read_bytes())
    april=source_record(next(s for s in april_meta['sources'] if s['role']=='proclamation_body'),
        next(s['path'] for s in april_meta['sources'] if s['role']=='proclamation_body'))
    end=windows(unique_span(Path(april['path']).read_text(),r'\(1\) Effective',r'\(2\)'))['valid_from']
    if not end:raise ValueError('Missing copper replacement instant')
    sources=[original,original_annex,guidance,reviewed,april,dict(id='FR-2026-06960-copper-retirement-original',
        path=str(pdf),sha256=retirement['original_pdf_sha256'],url=retirement['url'],citation='Proclamation11021 AnnexIV A(7),A(11), printed18264-18265; original copper action deleted at the operative April6 instant.')]
    return dict(from_=begin,until=end,rate=float(rate[1])/100,hts8=htss,clauses=clauses,
        charged_code=charged[1],remainder_code=remainder[1],chapter98_full_value_code=full[1].replace('.',''),
        sources=sources,original_priority=priority,original_portion=portion)


def extract(revision):
    if not re.fullmatch(r'202[56]_(?:basic|rev_\d+)',revision):raise ValueError('Identified copper source revision required')
    h=load_history();pdf=ROOT/f'data/us_notes/chapter99_{revision}.pdf';hts=ROOT/f'data/hts_archives/hts_{revision}.json'
    raw=subprocess.check_output(['pdftotext','-layout',str(pdf),'-'],text=True);verify_revision_header(raw,revision)
    rows=json.loads(hts.read_bytes());headings=[r for r in rows if re.fullmatch(r'9903\.78\.\d{2}',r.get('htsno',''))]
    calendar=[r for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision']==revision]
    if len(calendar)!=1:raise ValueError('Missing copper source calendar identity')
    day=calendar[0]['policy_effective_date']
    if day=='NA':day=calendar[0]['effective_date']
    if headings and day>=h['until'][:10]:
        raise ValueError('Copper headings reappear after verified retirement; reconcile a new legal action')
    clauses=note(raw,36) if headings else {}
    state='no_native_copper_heading'
    exceptions=[]
    if headings:
        exceptions=reconcile_note(clauses,headings,h)
        state='original_note36_reconciled'
    elif any(r.get('htsno','').startswith('9903.82.') for r in rows):
        native_note=[n for n in note_index(raw)[0] if n['id']=='III:36']
        if len(native_note)!=1 or not re.fullmatch(r'36\.\s*\[Note deleted\.\]',native_note[0]['text']):
            raise ValueError('Missing original copper heading without its verified note36 deletion')
        state='retired_note36_snapshot'
    else:
        if h['from_'][:10]<=day<h['until'][:10]:
            raise ValueError('Operative copper snapshot lacks its original reporting headings')
    release=revision.replace('_rev_','HTSRev').replace('_basic','HTSBasic')
    sources=[dict(id=f'USITC-{revision}-copper-'+p.suffix[1:],path=str(p),sha256=sha(p.read_bytes()),
        url=f'https://hts.usitc.gov/reststop/'+(f'file?release={release}&filename=Chapter%2099' if p.suffix=='.pdf' else f'exportList?release={release}&exportFormat=JSON'),
        citation='USITC '+revision+' note36 and actual reporting headings; original instruments determine operative instants.') for p in (pdf,hts)]
    valid=extract_rows(rows)
    if exceptions:sources+=known_exceptions()[1]
    x=dict(revision=revision,clauses=clauses,headings=headings,reconciliation=dict(status=state,original_exception_references=exceptions),sources=sources,
        native_products=[r['hts10'] for r in valid['products']],
        chapter98_provisions=sorted({r['htsno'].replace('.','')[:8] for r in rows if re.fullmatch(r'98\d{2}\.\d{2}\.\d{2}(?:\.\d{2})?',r.get('htsno',''))}))
    x['integrity']=signature(x)
    return x


def matches(history,products):
    if any(not re.fullmatch(r'\d{10}',p) for p in products):raise ValueError('Exact copper HTS10 identities required')
    return sorted({p for p in products if p[:8] in history['hts8']})


def compile_rules(x,products):
    copied=copy.deepcopy(x);integrity=copied.pop('integrity',None)
    if integrity!=signature(copied):raise ValueError('Copper source changed after extraction')
    if set(products)-set(x['native_products']):raise ValueError('Copper product outside identified native revision')
    h=load_history();selected=matches(h,products)
    sources=h['sources']+x['sources'];ids=[s['id'] for s in sources]
    facts={};rules=[]
    def define(name,label,kind='boolean',choices=None):
        d=dict(type=kind,label=label,source_ids=ids)
        if kind=='number':d.update(minimum=0,unit='USD')
        if choices:d['enum']=choices
        facts[name]=d;return fact(name)
    cv=define('customs_value','Full article customs value (USD)','number')
    contains=define('contains_copper','Article contains copper')
    pure=define('s232_copper_only_material','Imported article is composed only of copper under the CBP copper filing instruction')
    status=define('copper_value_determination','Determination and documentary support for the copper-content value','string',
        ['substantiated','cannot_be_determined','insufficient_documentation'])
    declared=define('declared_copper_content_value','Substantiated copper-content value under19USC1401a (USD)','number')
    copper=op('if',contains,op('if',pure,cv,op('if',op('eq',status,val('substantiated')),declared,cv)),val(0))
    basis=op('if',{'claim':'CHAPTER_98'},{'unresolved_source':'copper_selected_chapter98_terms_and_copper_value_intersection'},copper)
    define('ieepa_ftz_entry','Entry from a foreign trade zone')
    scope=dict(hts_exact=selected,**{'from':h['from_'],'until':h['until']})
    constraints=[dict(test=op('if',contains,op('lte',copper,cv),val(True)),inputs=['declared_copper_content_value','customs_value'],label='Copper content cannot exceed article value')]
    if selected:
        rules=[dict(id='s232_copper_content',action_id='s232_copper_10962',authority='section_232',kind='duty',verification='verified',
            scope=scope,when=contains,formula=op('multiply',basis,val(h['rate'])),input_constraints=constraints,
            reporting_codes=[h['charged_code']],source_ids=ids,legal_locator='Proclamation10962 clauses1,4,5; AnnexA note36(a),(b); CBP-CSMS65794272',
            published_expression=next((r['general'] for r in x['headings'] if r['htsno']==h['charged_code']),None)),
            dict(id='s232_copper_remainder',action_id='s232_copper_10962_reporting',authority='section_232',kind='duty',verification='verified',
            scope=scope,when=op('if',contains,op('gt',op('subtract',cv,copper),val(0)),val(True)),formula=val(0),input_constraints=constraints,
            reporting_codes=[h['remainder_code']],reporting_only=True,source_ids=ids,legal_locator='Original note36(c); CBP-CSMS65794272 non-copper and copper-free reporting')]
        # A claim can change applicability, not merely the amount. Downstream
        # portion rules must not treat a pending Chapter98 decision as a proven
        # copper action just because its unclaimed reporting code is known.
        for r in rules:
            r['when']=op('if',op('and',contains,{'claim':'CHAPTER_98'}),
                {'unresolved_source':'copper_selected_chapter98_terms_and_copper_value_intersection'},r['when'])
        # Reconcile the original automobile and every country-specific parts
        # inventory before establishing that priority is irrelevant. The current
        # original copper table is disjoint; a newly overlapping scope must get
        # its executable decision, never an assumed maximum or positive rate.
        auto_history=automobile_history()
        auto_scopes=[auto_history[s]['prefixes'] for s in ('parts','vehicles')]+[d.get('parts_prefixes',[]) for d in auto_history['deals']]
        auto_products=sorted({p for p in selected if any(p.startswith(prefix) for group in auto_scopes for prefix in group)})
        if auto_products:raise ValueError('New copper/automobile scope intersection requires source-backed executable precedence')
        for s in auto_history['sources']:
            if s['id'] not in ids:
                artifact=next(a for a in auto_history['source_artifacts'] if a['source_id']==s['id'])
                sources.append(dict(s,path=artifact['path']));ids.append(s['id'])
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='s232_copper_'+x['revision'],
        supported_from='2025-01-01T00:00:00-05:00',supported_until=h['until'],
        sources=[{k:s[k] for k in ('id','sha256','url','citation')}|dict(status='verified') for s in sources],
        source_artifacts=[dict(source_id=s['id'],path=s['path'],sha256=s['sha256']) for s in sources],
        compiler_sha256=sha(Path(__file__).read_bytes()),
        compiler_dependencies={p:sha((ROOT/p).read_bytes()) for p in ('src/section232_autos.py','src/section232_stacking.py',
            'src/section301_sources.py','src/ieepa_fentanyl_sources.py','src/ieepa_reciprocal_history.py','src/shipment_base_sources.py',
            'resources/legal_evidence/section232/autos/review.json','resources/legal_evidence/section232/copper/retirement-source.json')},
        rules=rules,relations=[],coverage=[],fact_definitions=facts,
        claim_definitions=[dict(id=c,label=l,rule_ids=[r['id'] for r in rules],source_ids=ids) for c,l in
            [('USMCA','USMCA'),('COLUMN1_SPECIAL','Selected Column 1 Special preference'),('CHAPTER_98','Chapter 98')]] if rules else [],
        entry_context=dict(mode='ordinary_only',fact='ieepa_ftz_entry',source_ids=ids,
            unresolved_source='copper_ftz_admission_classification_and_rate_history'),
        derived_facts={'copper_content_value':dict(expression=copper,source_ids=ids)} if rules else {},
        unchanged_claims=[dict(id='copper_section301_independence',claim_authority='section_301',
            candidate_required_fields=['exclusion_claim_id'],target_rule_ids=[r['id'] for r in rules],source_ids=ids)] if rules else [],
        snapshot_reconciliation=x['reconciliation'],candidate_memberships=[dict(hts10=p,scope_code=p[:8],scope_grain='hts8') for p in selected],
        legal_window=dict(from_=h['from_'],until=h['until']),
        authority_interactions=dict(automobile=dict(status='source_scope_disjoint',overlapping_products=[])),
        limitations=['No full Section232 coverage attestation; distinct actions and AD/CVD remain cumulative unless specifically displaced.',
            'Privileged FTZ history, certified MHD part paths and selected Chapter98 treatment remain explicitly uncompiled.'])


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    a=p.parse_args();x=json.loads(Path(a.input).read_bytes())
    Path(a.output).write_text(json.dumps(compile_rules(extract(x['revision']),x['products']),separators=(',',':'))+'\n')

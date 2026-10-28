"""Original forced-labor action inventory and named Section232 interactions.

An exemption follows legal applicability, including zero-payable Section232
decisions. It is not inferred from a modeled rate. Remaining annex/valuation
decisions have an identified, unpriced action rather than an invented amount.
"""
from __future__ import annotations
import argparse
import gzip
import json
import re
import subprocess
from datetime import datetime
from pathlib import Path

from ieepa_fentanyl_sources import ROOT
from ieepa_emergency_rules import revision_window
from ieepa_reciprocal_later import entry_instant
from section301_sources import sha, unique_span
from section232_note16_rules import val, fact, op, either, both
from section232_stacking import reporting_codes, reported, note as native_note
from section122_rules import date_at

EVIDENCE = ROOT/'resources/legal_evidence/section301/forced-labor'
H = r'9903\.\d{2}\.\d{2}'


def canonical(text):
    text = ' '.join(text.translate(str.maketrans({'–':'-', '—':'-', '“':'"', '”':'"', '’':"'"})).split())
    return re.sub(r'(?<=\w)-\s+(?=\w)', '-', text).rstrip(' ."')


def evidence(metadata=None):
    meta = metadata if metadata is not None else json.loads((EVIDENCE/'sources.json').read_bytes())
    if meta['contract_version'] != 'sail.section301-forced-labor-evidence/v1':
        raise ValueError('Unsupported forced-labor source contract')
    roles = {}; sources = {}
    for source in meta['sources']:
        p = ROOT/source['path']
        if sha(p.read_bytes()) != source['sha256']:
            raise ValueError('Forced-labor original source changed')
        record = dict(source, path=str(p.resolve()))
        if source['id'] in sources and sources[source['id']] != record:
            raise ValueError('Conflicting forced-labor source identity')
        if source['role'] in roles and roles[source['role']] != record:
            raise ValueError('Conflicting forced-labor evidence role')
        roles[source['role']] = record; sources[source['id']] = record
    if set(roles) != {'original_pdf', 'original_layout', 'published_notice'}:
        raise ValueError('Incomplete forced-labor original evidence')
    pdf = Path(roles['original_pdf']['path'])
    layout = gzip.decompress(Path(roles['original_layout']['path']).read_bytes()).decode()
    extracted = subprocess.check_output(['pdftotext', '-layout', str(pdf), '-'], text=True)
    if extracted.split() != layout.split():
        raise ValueError('Forced-labor PDF/layout disagree')
    layout = re.sub(r'^\s*\d+\s*$', '', layout.replace('\f', '\n'), flags=re.M)
    published = re.sub(r'^\[\[Page \d+\]\]\s*$', '', Path(roles['published_notice']['path']).read_text(), flags=re.M)
    return layout, published, [sources[k] for k in sorted(sources)]


def original_headings(layout):
    table = unique_span(layout, r'^[“"]9903\.\d{2}\.\d{2}', r'^\s*2\. The following new U\.S\. note 52')
    starts = list(re.finditer(r'^[ \t]*[“"]?('+H+r')[ \t]+(?=Except|Articles)', table, re.M))
    rows = []
    for i, match in enumerate(starts):
        block = table[match.start():starts[i+1].start() if i+1 < len(starts) else len(table)]
        lines = [line for line in block.splitlines() if line.strip() and not re.fullmatch(r'\s*\d+\s*', line)]
        description = []
        for j, line in enumerate(lines):
            if j and len(line)-len(line.lstrip()) > 25:
                continue  # rate columns, not the article-description column
            fields = re.split(r' {2,}', line.strip())
            description.append(fields[1] if j == 0 else fields[0])
        text = re.sub(r'(?:\s*\.){2,}[ ”"]*$', '', ' '.join(description)).strip().rstrip('”')
        rows.append(dict(reporting_code=match[1], description=text,
            percentages=sorted(set(re.findall(r'(\d+(?:\.\d+)?)%', block))), heading_sha256=sha(block.encode()),
            source_table_text=block,rate_extraction_status='inventory_only_not_executable_rate'))
    if not rows or len({r['reporting_code'] for r in rows}) != len(rows):
        raise ValueError('Missing/duplicated original forced-labor heading')
    return rows


def clauses(layout, published):
    original = unique_span(layout, r'^[“"]52\. \(a\)', r'^B\.\s+Effective with respect')
    publication = unique_span(published, r'^``52\. \(a\)', r'^B\. Effective with respect')
    def split(text):
        starts = list(re.finditer(r'^\s*(?:[“"]52\. )?\(([a-z])\)', text, re.M))
        if [m[1] for m in starts] != list('abcdefghijk'):
            raise ValueError('Unreconciled original note52 subdivisions')
        return {m[1]:text[m.end():starts[i+1].start() if i+1 < len(starts) else len(text)] for i,m in enumerate(starts)}
    source = split(original); pub = split(publication.replace('``52.', '"52.'))
    # The published HTML's product tables are images. The operative interaction
    # paragraph is text and independently reconciles in full, not just its codes.
    if canonical(source['f']) != canonical(pub['f']):
        raise ValueError('USTR/published Section232 interaction disagreement')
    return source, pub


def interaction_inventory(text):
    starts = list(re.finditer(r'\((\d+)\)\s+', text))
    if not starts or [int(m[1]) for m in starts] != list(range(1,len(starts)+1)):
        raise ValueError('Unaccounted forced-labor interaction items')
    result = []
    for i,m in enumerate(starts):
        clause = ' '.join(text[m.end():starts[i+1].start() if i+1 < len(starts) else len(text)].split())
        codes = reporting_codes(clause)
        if not codes:
            raise ValueError('Interaction item lacks original reporting heads')
        result.append(dict(item=int(m[1]), text=clause, reporting_codes=codes, sha256=sha(canonical(clause).encode())))
    return result


def common_product_table(text):
    """A complete unconditional table, preserving both printed HTS10 styles.

    A description, footnote or unparsed operand cannot disappear from a table
    and become an unconditional exemption of an entire eight-digit parent.
    """
    prefix,sep,table=text.partition(':')
    match=re.fullmatch(r'As provided in heading ('+H+r'), the duties imposed by headings ('+H+r'-'+H+
        r') shall not apply to articles that are classifiable in the following provisions of the HTSUS',canonical(prefix))
    if not sep or not match:raise ValueError('Unreviewed common-product exemption condition')
    pattern=r'(?<![\d.])\d{4}\.\d{2}\.\d{2}(?:\.?\d{2})?(?![\d.])'
    printed=re.findall(pattern,table)
    if not printed or re.sub(pattern,'',table).strip():raise ValueError('Unparsed common-product table content')
    codes=sorted({c.replace('.','') for c in printed})
    return dict(reporting_code=match[1],target_reporting_codes=reporting_codes(match[2]),includes=codes,
        scope_grains=sorted({len(c) for c in codes}),condition_text=canonical(prefix),
        source_scope_sha256=sha(canonical(text).encode()),source_text=text)


def load_history():
    layout, publication, sources = evidence()
    rows = original_headings(layout); note, pub = clauses(layout, publication)
    common_products=common_product_table(note['b'])
    prefix = unique_span(publication, r'^Annex I\s*$', r'^1\. The following new provisions')
    begin = entry_instant(prefix)
    change = unique_span(publication, r'^B\. Effective with respect', r'^Annex II\s*$')
    modern = entry_instant(change)
    transit = [r for r in rows if 'in transit on the final mode of transit' in r['description']]
    if len(transit)!=1:raise ValueError('Unreconciled forced-labor transit heading')
    clocks = re.findall(r'before 12:01 a\.m\. eastern time on (\w+ \d+, \d{4})',transit[0]['description'])
    if len(clocks)!=2 or date_at(clocks[0])!=begin:raise ValueError('Unreconciled original transit windows')
    amendment = unique_span(change, r'``\(8\) patented pharmaceutical articles', r"''")
    if not all(t in change for t in ('Subdivision (f)', 'new item (8)', '9903.05.90')):
        raise ValueError('Unreviewed July31 interaction amendment')
    original_change = unique_span(layout, r'^B\.\s+Effective with respect', r'^\s*ANNEX II\s*$')
    original_item = re.search(r'\(8\) patented pharmaceutical articles provided for in headings\s+('+H+r'[–-]'+H+r')', original_change)
    if not original_item or reporting_codes(original_item[0]) != reporting_codes(amendment):
        raise ValueError('Original/published July31 reporting amendment disagreement')
    original_items = interaction_inventory(note['f'])
    new_items = original_items + [dict(item=8, text=amendment.lstrip('`'), reporting_codes=reporting_codes(amendment), sha256=sha(canonical(amendment).encode()))]
    review = json.loads((EVIDENCE/'reviewed-interactions.json').read_bytes())
    if review['contract_version']!='sail.section301-forced-labor-interaction-review/v1':
        raise ValueError('Unsupported forced-labor interaction review')
    for item in new_items:
        accepted = review['items'].get(str(item['item']))
        if accepted is None or accepted['sha256'] != item['sha256']:
            raise ValueError('Unreviewed forced-labor interaction condition')
        item['role'] = accepted['role']
        item['qualified_codes'] = accepted.get('qualified_codes', {})
        if not set(item['qualified_codes']) <= set(item['reporting_codes']):
            raise ValueError('Qualification has no original interaction heading')
    # Reconcile every inserted original heading, including its zero/exclusion
    # roles, against the first native snapshot. Do not import a later amendment.
    baseline = ROOT/'data/hts_archives/hts_2026_rev_13.json'
    native = {r['htsno']:r for r in json.loads(baseline.read_bytes()) if r.get('htsno')}
    wanted = {r['htsno'] for r in native.values() if re.search(r'\bU\.S\. note 52\b', r.get('description',''))}
    # The transit/donation/information descriptions do not name note52; the
    # source's inserted table, not a guessed numeric range, supplies these too.
    for row in rows:
        r = native.get(row['reporting_code'])
        if r is None or canonical(row['description']) != canonical(r['description']):
            raise ValueError('Original/native forced-labor heading conflict: '+row['reporting_code'])
        for column in ('general','special'):
            if sorted(set(re.findall(r'(\d+(?:\.\d+)?)%',r.get(column,'')))) != row['percentages']:
                raise ValueError('Original/native forced-labor rate conflict: '+row['reporting_code'])
        row['native_duty_expressions']={column:r.get(column,'') for column in ('general','special','other')}
    if not wanted <= {r['reporting_code'] for r in rows}:
        raise ValueError('Unaccounted native forced-labor action')
    charge_codes = reporting_codes(re.search(r'headings ('+H+r'[–-]'+H+r') impose additional',canonical(note['a']))[1])
    actions = {}
    for row in rows:
        if row['reporting_code'] not in charge_codes:continue
        match = re.search(r'articles the product of (.*?)(?:, with an|, as provided)',row['description'])
        if not match:raise ValueError('Unparsed original action origin')
        country = match[1]
        action = actions.setdefault(country, dict(country_text=country, headings=[]))
        action['headings'].append(row)
    if {r['reporting_code'] for a in actions.values() for r in a['headings']} != set(charge_codes):
        raise ValueError('Unaccounted original charge inventory')
    operand = re.search(r'article description of heading ('+H+r") is modified by inserting ``([^`]+)'' after ``([^`]+)''", ' '.join(change.split()))
    if not operand:raise ValueError('Unparsed original heading-description amendment')
    heading_change=dict(reporting_code=operand[1],insert=operand[2],after=operand[3],from_=modern)
    f_codes={r['reporting_code'] for r in rows if 'subdivision (f) of U.S. note 52' in r['description']}
    if len(f_codes)!=1 or heading_change['reporting_code'] not in f_codes:
        raise ValueError('Unreconciled exemption carrier and amendment')
    pending=[dict(reporting_code=r['reporting_code'],description=r['description'],status='unresolved_source',
        question='Compile the original provision\'s complete scope, qualification, temporal/claim and valuation decision before pricing this path.')
        for r in rows if r['reporting_code'] not in set(charge_codes)|f_codes|{common_products['reporting_code']}]
    ftz=unique_span(publication,r'^Any product of an economy that is subject to the additional duty',r'^In accordance with the specific direction of the President')
    if not all(t in ftz for t in ('domestic status','19 CFR\n146.43','privileged foreign status','19 CFR 146.41')):
        raise ValueError('Unreviewed original forced-labor FTZ admission clause')
    sources.append(dict(id='USITC-2026_rev_13-note52-corroboration', path=str(baseline),sha256=sha(baseline.read_bytes()),
        url='https://hts.usitc.gov/reststop/exportList?release=2026HTSRev13&exportFormat=JSON',citation='First native note52 heading inventory; corroborates every original description and rate, before July31 amendment.'))
    horizon = json.loads((ROOT/'resources/shipment_rules/build_contract.json').read_bytes())
    return dict(contract_version='sail.section301-forced-labor-history/v1',from_=begin, amendment_from=modern,
        transit_until=date_at(clocks[1]),
        audit_until=horizon['audit_until'], actions=sorted(actions.values(),key=lambda a:a['country_text']),
        original_headings=rows, sources=sources, periods=[dict(from_=begin,until=modern,items=original_items),
            dict(from_=modern,until=horizon['audit_until'],items=new_items)],
        heading_amendments=[heading_change],unresolved_decisions=pending,
        common_products=common_products,
        ftz_clause=dict(text=' '.join(ftz.split()),sha256=sha(canonical(ftz).encode())),
        limitations=['The original action inventory is reconciled; executable pricing covers common-product and named Section232 exemptions.',
            'Product annexes, transit, preferences, Chapter98 valuation and FTZ pricing remain explicit unpriced decisions, not aggregate rates.'])


def compile_rules(revision_id, products, jurisdictions, jurisdiction_sources=None):
    history = load_history(); start,end = revision_window(revision_id)
    end = min([end,history['audit_until']],key=datetime.fromisoformat)
    if any(not re.fullmatch(r'\d{10}',p) for p in products):raise ValueError('Exact HTS10 required')
    sources = history['sources'] + list(jurisdiction_sources or [])
    common_products=history['common_products']
    native_path=ROOT/f'data/hts_archives/hts_{revision_id}.json'
    native=json.loads(native_path.read_bytes())
    if any(r.get('htsno')==common_products['reporting_code'] for r in native):
        pdf=ROOT/f'data/us_notes/chapter99_{revision_id}.pdf'
        raw=subprocess.check_output(['pdftotext','-layout',str(pdf),'-'],text=True)
        actual=common_product_table(native_note(raw,52)['b'])
        if any(actual[k]!=common_products[k] for k in ('reporting_code','target_reporting_codes','includes','condition_text')):
            raise ValueError('Common-product scope/amendment requires original-source reconciliation: '+revision_id)
        release=revision_id.replace('_rev_','HTSRev').replace('_basic','HTSBasic')
        for p in (native_path,pdf):
            sources.append(dict(id='USITC-'+revision_id+'-note52-common-'+p.suffix[1:],path=str(p),sha256=sha(p.read_bytes()),
                url='https://hts.usitc.gov/reststop/'+('exportList?release='+release+'&exportFormat=JSON' if p.suffix=='.json' else 'file?release='+release+'&filename=Chapter%2099'),
                citation='Native note52(b) exact table and condition reconcile with the original USTR insertion; no HTS10 widening.'))
    if any(sha(Path(s['path']).read_bytes()) != s['sha256'] for s in sources):raise ValueError('Forced-labor compilation source changed')
    ids = sorted({s['id'] for s in sources}); rules=[]; facts={}
    for action in history['actions']:
        countries = jurisdictions.get(action['country_text'])
        if not countries or any(not isinstance(c,str) or not re.fullmatch(r'\d{4}',c) for c in countries):
            raise ValueError('Unresolved original forced-labor origin: '+action['country_text'])
        aid='s301_forced_labor_'+action['headings'][0]['reporting_code'].replace('.','')
        product_rule=dict(id=aid+'_common_products',action_id=aid,authority='section_301',kind='duty',verification='verified',source_ids=ids,
            scope=dict(countries=sorted(set(countries)),hts_prefixes=common_products['includes'],**{'from':history['from_'],'until':history['audit_until']}),
            when=op('if',fact('ieepa_ftz_entry'),{'unresolved_source':'section301_forced_labor_ftz_admission_classification_and_product_exemption_history'},val(True)),
            formula=val(0),reporting_only=True,reporting_codes=[common_products['reporting_code']],legal_locator='Original U.S. note52(b)',
            source_scope_sha256=common_products['source_scope_sha256'],source_action=action)
        rules.append(product_rule)
        product_exempt={'rule_applies':product_rule['id']}
        for i,period in enumerate(history['periods']):
            tests=[]
            for item in period['items']:
                qualified=item['qualified_codes']; simple=set(item['reporting_codes'])-set(qualified)
                tests.append(reported(simple))
                for code,name in sorted(qualified.items()):
                    facts[name]=dict(type='boolean',label='Product satisfies the qualified Section232 article condition in note52(f)',description=item['text'],source_ids=ids)
                    tests.append(both(reported([code]),fact(name)))
            # Current-date Section232 candidates do not establish the heading
            # applicable to a privileged-status FTZ withdrawal. Resolve the
            # admission/rate history before using that cross-program exemption.
            facts['ieepa_ftz_entry']=dict(type='boolean',label='Entry withdrawn from a U.S. foreign-trade zone',
                description=history['ftz_clause']['text'],source_ids=ids)
            predicate=op('if',either(*tests),op('if',fact('ieepa_ftz_entry'),
                {'unresolved_source':'section301_forced_labor_ftz_admission_and_section232_reporting_history'},val(True)),val(False))
            scope=dict(countries=sorted(set(countries)),**{'from':period['from_'],'until':period['until']})
            common=dict(action_id=aid,authority='section_301',kind='duty',verification='verified',scope=scope,source_ids=ids,
                legal_locator='Original U.S. note52(f)'+('; AnnexI B July31 amendment' if i else ''),source_action=action)
            zero=dict(common,id=aid+'_s232_relief_'+str(i),when=predicate,suppressed_when=product_exempt,formula=val(0),reporting_only=True,
                reporting_codes=[next(r['reporting_code'] for r in history['original_headings'] if 'subdivision (f) of U.S. note 52' in r['description'])])
            gap=dict(common,id=aid+'_remaining_'+str(i),suppressed_when=either(product_exempt,predicate),reporting_codes=[],
                formula={'unresolved_source':'section301_forced_labor_remaining_annex_claim_valuation_and_ftz_decisions'},
                potential_reporting_codes=[r['reporting_code'] for r in action['headings']])
            rules += [zero,gap]
    # These claims change the composed Section232 reporting decision. The
    # named exemption is reevaluated from that decision; the remaining path is
    # still explicitly unpriced. This does not invent a general FL claim relief.
    claims=[dict(id=key,label=label,rule_ids=[r['id'] for r in rules],source_ids=ids) for key,label in (
        ('USMCA','USMCA'),('COLUMN1_SPECIAL','Selected Column 1 Special preference'),
        ('SECTION_232_AUTO_US_CONTENT','Commerce-approved automobile U.S. content'),
        ('SECTION_232_AUTO_IMPORT_OFFSET','Automobile import-adjustment offset'))]
    return dict(contract_version='sail.shipment-rule-fragment/v1',id='s301_forced_labor_'+revision_id,
        supported_from=start,supported_until=end,rules=rules,relations=[],coverage=[],fact_definitions=facts,claim_definitions=claims,
        sources=[{k:s[k] for k in ('id','sha256','url','citation')}|dict(status='verified') for s in sources],
        source_artifacts=[dict(source_id=s['id'],path=s['path'],sha256=s['sha256']) for s in sources],
        compiler_sha256=sha(Path(__file__).read_bytes()),compiler_dependencies={p:sha((ROOT/p).read_bytes()) for p in (
            'src/ieepa_reciprocal_later.py','src/ieepa_emergency_rules.py','src/section232_note16_rules.py','src/section232_stacking.py',
            'src/section301_sources.py','src/section122_rules.py','resources/legal_evidence/section301/forced-labor/sources.json',
            'resources/legal_evidence/section301/forced-labor/reviewed-interactions.json','resources/shipment_rules/build_contract.json','config/revision_dates.csv')},
        forced_labor_history=history,
        origin_resolution=[dict(country_text=a['country_text'],countries=sorted(set(jurisdictions[a['country_text']]))) for a in history['actions']],
        origin_resolution_source_ids=[s['id'] for s in jurisdiction_sources or []],limitations=history['limitations'])


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--history',action='store_true');parser.add_argument('--input');parser.add_argument('output')
    args=parser.parse_args();value=load_history() if args.history else compile_rules(**json.loads(Path(args.input).read_bytes()))
    Path(args.output).write_text(json.dumps(value,separators=(',',':'))+'\n')

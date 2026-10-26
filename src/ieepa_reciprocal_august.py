"""Original August country replacement table and verified retroactive changes.

Table headings, rates and country scopes are extracted independently of economic
columns. The native initial snapshot corroborates the original table before any
later retroactive replacement is applied. This is not a coverage attestation.
"""
import json
from datetime import datetime, timedelta
from pathlib import Path
import re
import subprocess
from zoneinfo import ZoneInfo
from ieepa_fentanyl_sources import ROOT, verified_source
from section301_sources import sha, unique_span

HEADING = r'9903\.\d{2}\.\d{2}'


def flat(text):
    return ' '.join(text.replace('\x00','').split())


def country(text):
    match=re.search(r'articles? the product of (?:the )?(.+?)(?:,? with an ad valorem|,? as provided)',flat(text),re.I)
    if not match:raise ValueError('Unparsed August country scope')
    return match[1].strip().rstrip(',')


def at(day):
    return datetime.strptime(day,'%B %d, %Y').replace(minute=1,tzinfo=ZoneInfo('America/New_York')).isoformat()


def load_august_country_policy():
    body,notice=verified_source('2025-15010');text=flat(body)
    signed=re.search(r'Executive Order \d+ of (\w+ \d+, \d{4})',text)
    section=unique_span(text,r'Sec\. 2\.',r'Sec\. 3\.')
    delay=re.search(r'eastern daylight time (\d+) days after the date of this order',section)
    if not signed or not delay:raise ValueError('Missing original August country commencement')
    begin=(datetime.fromisoformat(at(signed[1]))+timedelta(days=int(delay[1]))).isoformat()
    until=re.search(r'before 12:01 a\.m\. eastern daylight time on (\w+ \d+, \d{4})',section)
    baseline=re.search(r'not listed in Annex I.*?additional ad valorem rate of duty of (\d+) percent',section)
    if not until or not baseline or 'Nothing in this order shall be construed to alter or otherwise affect Executive Order 14298' not in section:
        raise ValueError('Unreviewed August continuation or transit conditions')
    path=ROOT/'resources/legal_evidence/2025-15010/white-house-annex-ii.txt'
    meta=json.loads(path.with_name('white-house-annex-ii.source.json').read_bytes())
    pdf=path.with_name('white-house-annex-ii.pdf')
    if sha(path.read_bytes())!=meta['text_sha256'] or sha(pdf.read_bytes())!=meta['sha256']:
        raise ValueError('Original August annex hash mismatch')
    extracted=subprocess.check_output(['pdftotext','-layout',str(pdf),'-'],text=True)
    if extracted.split()!=path.read_text().split():
        raise ValueError('Original August PDF and retained annex text differ in substantive tokens')
    sources=[notice,dict(id=meta['id']+'-text',path=str(path),sha256=meta['text_sha256'],url=meta['url'],citation=meta['citation']),
             dict(id=meta['id']+'-pdf',path=str(pdf),sha256=meta['sha256'],url=meta['url'],citation=meta['citation'])]
    annex=path.read_text()
    candidates=list(re.finditer(r'^([ \t]*)('+HEADING+r')\s',annex,re.M))
    if not candidates:raise ValueError('Missing original August insertion table')
    left=min(len(m[1]) for m in candidates)
    starts=[m for m in candidates if len(m[1])==left]
    first=flat(annex[:starts[0].start()])
    keep=re.search(r'Headings (.*?) and corresponding subdivisions',first)
    if not keep:raise ValueError('Unparsed terminated August predecessors')
    retired=[]
    for lo,hi in re.findall('('+HEADING+r')[–-]('+HEADING+r')',keep[1]):
        if lo[:8]!=hi[:8] or lo>hi:raise ValueError('Unreviewed August predecessor range')
        retired.extend(lo[:8]+f'{i:02}' for i in range(int(lo[-2:]),int(hi[-2:])+1))
    base_code=re.search('Heading ('+HEADING+r') of the HTSUS shall be amended',first)
    expected=re.search('inserting “'+HEADING+', and ('+HEADING+r')[–-]('+HEADING+r')”',first)
    if not base_code or not expected or expected[1][:8]!=expected[2][:8]:raise ValueError('Missing August reporting inventory')
    all_codes={expected[1][:8]+f'{i:02}' for i in range(int(expected[1][-2:]),int(expected[2][-2:])+1)}
    rows=[];transshipment=None
    for i,m in enumerate(starts):
        code=m[2]
        block=annex[m.start():starts[i+1].start() if i+1<len(starts) else len(annex)]
        lines=[re.split(r' {2,}',l.strip()) for l in block.splitlines() if l.strip() and not re.fullmatch(r'\s*\d+\s*',l)]
        description=flat(' '.join(p[1] if n==0 else p[0] for n,p in enumerate(lines)))
        percentages=sorted(set(re.findall(r'(\d+(?:\.\d+)?)%',block)))
        if 'transshipped to evade applicable duties under section 2' in description:
            if transshipment is not None or len(percentages)!=1:raise ValueError('Unparsed August transshipment decision')
            transshipment=dict(reporting_code=code,rate=float(percentages[0])/100,description=description);continue
        beginning=datetime.fromisoformat(begin).strftime('%B %-d, %Y')
        if not all(s in description for s in ('before 12:01 a.m. eastern daylight time on '+beginning,
            'before 12:01 a.m. eastern daylight time on '+until[1],'9903.01.30','9903.01.33','9903.01.34','9903.02.01')):
            raise ValueError('Unreviewed August heading transit or exceptions: '+code)
        c=country(description);kind='additional';rate=None
        if 'column 1-General equal to or greater than' in description:
            if percentages:raise ValueError('Unexpected additive rate on August floor high branch')
            kind='floor_high';rate=0
        elif 'column 1-General less than' in description:
            if len(percentages)!=1:raise ValueError('Ambiguous August combined floor rate')
            kind='floor_low';rate=float(percentages[0])/100
        else:
            if len(percentages)!=1:raise ValueError('Ambiguous August additional duty')
            rate=float(percentages[0])/100
        rows.append(dict(reporting_code=code,country_text=c,kind=kind,rate=rate,
            description=description,source_heading_sha256=sha(block.encode())))
    if not transshipment:raise ValueError('Missing original transshipment heading')
    expected_codes=all_codes-{transshipment['reporting_code']}
    if {r['reporting_code'] for r in rows}!=expected_codes or len(rows)!=len(expected_codes) or not retired:
        raise ValueError('Incomplete August original heading inventory')
    native_path=ROOT/'data/hts_archives/hts_2025_rev_18.json'
    native={r['htsno']:r for r in json.loads(native_path.read_bytes()) if r.get('htsno') in expected_codes}
    if set(native)!=expected_codes:raise ValueError('Original August native inventory differs from inserted headings')
    for row in rows:
        record=native[row['reporting_code']]
        country_key=lambda s:flat(s).casefold().replace('’',"'")
        if country_key(country(record['description']))!=country_key(row['country_text']):
            raise ValueError('August native/original country disagreement: '+row['reporting_code']+' '+repr((country(record['description']),row['country_text'])))
        for column in ('general','special'):
            raw=flat(record.get(column,''))
            rates=re.findall(r'(?<!\d)(\d+(?:\.\d+)?)%',raw)
            expected_rate=[] if row['kind']=='floor_high' else [str(int(row['rate']*100))]
            if rates!=expected_rate:raise ValueError('August native/original duty disagreement: '+row['reporting_code'])
    sources.append(dict(id='USITC-2025_rev_18-August-country-corroboration',path=str(native_path),sha256=sha(native_path.read_bytes()),
        url='https://hts.usitc.gov/reststop/exportList?release=2025HTSRev18&exportFormat=JSON',citation='Initial August country heading table, before subsequent retroactive replacements'))
    actions=[];eu=[r for r in rows if r['kind'].startswith('floor_')]
    if len(eu)!=2 or len({r['country_text'] for r in eu})!=1:raise ValueError('Unreviewed August floor country inventory')
    low=next(r for r in eu if r['kind']=='floor_low');high=next(r for r in eu if r['kind']=='floor_high')
    threshold=re.findall(r'(?:less than|equal to or greater than) (\d+) percent',low['description']+' '+high['description'])
    if len(threshold)!=2 or {float(v)/100 for v in threshold}!={low['rate']}:raise ValueError('August floor branches do not reconcile')
    for r in rows:
        if r in eu:continue
        actions.append(dict(country_text=r['country_text'],reporting_codes=[r['reporting_code']],kind='additional',rate=r['rate']))
    actions.append(dict(country_text=low['country_text'],reporting_codes=[high['reporting_code'],low['reporting_code']],
        kind='column1_general_floor',rate=low['rate']))
    japan,japan_source=verified_source('2025-17908');sources.append(japan_source)
    change=unique_span(flat(japan),r'Annex I a\.',r'b\. Effective with respect')
    date=re.search(r'on or after 12:01 a\.m\. eastern time on (\w+ \d+, \d{4})',change)
    deleted=re.search('Heading ('+HEADING+r') is hereby terminated',change)
    inserted=re.search('New headings ('+HEADING+r') and ('+HEADING+r') are inserted',change)
    if not date or at(date[1])!=begin or not deleted or not inserted or 'column 1--General' not in change:
        raise ValueError('Unreviewed Japan retroactive reciprocal floor')
    target=[r for r in actions if r['reporting_codes']==[deleted[1]]]
    if len(target)!=1 or target[0]['country_text']!='Japan':raise ValueError('Japan replacement predecessor does not reconcile')
    thresholds=re.findall(r'(?:equal to or greater than|less than) (\d+(?:\.\d+)?) percent',change)
    published_rates=re.findall(r'(\d+(?:\.\d+)?)%',change)
    if len(thresholds)!=2 or len(set(thresholds))!=1 or len(published_rates)!=2 or set(published_rates)!=set(thresholds):
        raise ValueError('Japan combined-rate table and complementary thresholds do not reconcile')
    target[0].update(kind='column1_general_floor',reporting_codes=[inserted[1],inserted[2]],
        rate=float(thresholds[0])/100,replaced_reporting_code=deleted[1],amendment_effective_from=at(date[1]),amendment_source_id=japan_source['id'])
    if len({r['country_text'] for r in actions})!=len(actions):raise ValueError('Duplicate August country treatment')
    return dict(from_=begin,transit_until=at(until[1]),actions=actions,original_headings=rows+[transshipment],
        retired_reporting_codes=sorted(retired),transshipment=transshipment,
        baseline=dict(reporting_code=base_code[1],rate=float(baseline[1])/100),sources=sources,
        snapshot_reconciliation=dict(revision='2025_rev_18',sha256=sha(native_path.read_bytes())))

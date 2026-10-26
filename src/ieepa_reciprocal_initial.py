"""Original reciprocal country decisions and June metal-portion amendment.

Extract the operative Annex III table, not the rate retained on a suspended
heading. Country-name resolution is shared with the R ingestion pipeline.
The UK aircraft framework and July suspension extension retain their own entry
instants. The next copper/country-policy horizon is not an expiration of duty.
"""
from __future__ import annotations
import argparse, json, re
from pathlib import Path
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from ieepa_reciprocal_history import annex, clean_fr
from ieepa_fentanyl_sources import verified_source, windows, ROOT
from section301_sources import sha, unique_span

HEADING = r'9903\.\d{2}\.\d{2}'


def original():
    raw, source = annex('2025-06063')
    text = clean_fr(raw[raw.index('ANNEX III'):])
    first_table=unique_span(text,r'^\s*1\. Effective with respect',r'^\s*2\. Effective with respect')
    starts=list(re.finditer(r'^\s*["“]?('+HEADING+r')\s',first_table,re.M))
    headings={}
    roles={'baseline':'Except for products described in', 'canada':'Articles the product of Canada,',
        'mexico':'Articles the product of Mexico,','transit':'Articles the product of any country that (1)',
        'column2':'Articles the product of any country identified in general note 3(b)',
        'donation':'Articles that are donations,','information':'Articles that are informational materials,',
        'products':'Articles the product of any country, classified in the subheadings enumerated',
        'section232':'Articles of iron or steel, derivative articles of iron or steel,',
        'us_content':'The U.S. content of articles the product of any country,'}
    for i,m in enumerate(starts):
        block=first_table[m.start():starts[i+1].start() if i+1<len(starts) else len(first_table)]
        lines=[re.split(r' {2,}',l.strip()) for l in block.splitlines() if l.strip()]
        description=' '.join(p[1] if j==0 else p[0] for j,p in enumerate(lines))
        role=[k for k,prefix in roles.items() if description.startswith(prefix)]
        if len(role)!=1 or role[0] in headings:raise ValueError('Unreviewed/duplicated original reciprocal decision heading')
        headings[role[0]]=dict(code=m[1],source_heading_sha256=sha(block.encode()),description=description)
    if set(headings)!=set(roles):raise ValueError('Incomplete original reciprocal decision inventory')
    # The second insertion table ends before the third numbered instruction.
    table = unique_span(text, r'^\s*2\. Effective with respect', r'^\s*3\.')
    starts = list(re.finditer(r'^\s*["“]?('+HEADING+r')\s', table, re.M))
    actions = []
    for i, m in enumerate(starts):
        block = table[m.start():starts[i+1].start() if i+1<len(starts) else len(table)]
        lines = [re.split(r' {2,}', line.strip()) for line in block.splitlines() if line.strip()]
        # First column is the heading only on the first line. The remaining
        # lines have the article description first, followed by duty columns.
        description = ' '.join(parts[1] if j==0 else parts[0] for j,parts in enumerate(lines))
        countries = re.search(r'articles the product of (.*?),? as provided', description)
        rates = set(re.findall(r'(?<!\d)(\d+(?:\.\d+)?)\s*%', block))
        if not countries or len(rates)!=1 or 'Except for goods loaded onto a vessel' not in description:
            raise ValueError('Unparsed original reciprocal heading: '+m[1])
        actions.append(dict(code=m[1],country_text=countries[1],rate=float(rates.pop())/100,
                            description=description,source_heading_sha256=sha(block.encode())))
    if len({a['code'] for a in actions})!=len(actions) or not actions:
        raise ValueError('Missing/duplicated original reciprocal heading inventory')
    # Independently reconcile every country's rate in the note with its table
    # heading. There is no rate-to-heading inference in the evaluator.
    tail=text[text.index('(xiii) Heading'):]
    note_rows=re.findall(r'^\s*(\d+)\)\s*(.*?), subject to an additional duty of\s*(\d+)\s*%',tail,re.M)
    if not note_rows or [int(r[0]) for r in note_rows]!=list(range(1,len(note_rows)+1)):
        raise ValueError('Incomplete original reciprocal country note')
    def country_names(text):
        text=text.replace(', including Hong Kong and Macau','')
        return [re.sub(r'^the ','',n.strip()) for n in re.split(r',? or |, ',text)]
    table_map={n:a['rate'] for a in actions for n in country_names(a['country_text'])}
    note_map={n.replace(', including Hong Kong and Macau',''):float(rate)/100 for _,n,rate in note_rows}
    if table_map!=note_map:raise ValueError('Original country note and reporting table disagree')
    initial, notice=verified_source('2025-06063')
    clause=unique_span(initial,r'^Sec\. 3\.',r'^\(b\)')
    dates=re.findall(r'on (April \d+, 2025)',clause)
    from section122_rules import date_at
    inception=date_at(dates[0]);country_from=date_at(dates[-1])
    rate=re.search(r'additional ad\s+valorem rate of duty of (\d+) percent',clause)
    if not rate:raise ValueError('Missing original baseline rate')
    clauses={}
    for a,b in [('i','ii'),('ii','iii'),('iv','v'),('v','vi'),('vi','vii'),('vii','viii'),('viii','ix'),('ix','x'),('x','xi'),('xi','xii'),('xii','xiii')]:
        # Unique outer subdivisions; country-note numbered items use digits.
        clauses[a]=' '.join(unique_span(text,r'\('+a+r'\) (?=Except|Heading|As|The)',r'\('+b+r'\) (?=Except|Heading|As|The)').split())
    relations={}
    for key in ('vi','vii','viii','ix','x','xi'):
        m=re.search(r'shall not apply to (.*?) provided for in headings? (.*?)\.',clauses[key])
        # A dot within a heading is not an end-of-sentence delimiter.
        target=clauses[key].split(' provided for in heading',1)[-1]
        codes=re.findall(HEADING,target)
        if not m or not codes:raise ValueError('Missing original Section 232 interaction')
        relations[key]=codes
    return dict(actions=actions,clauses=clauses,section232=relations,headings=headings,
                baseline_rate=float(rate[1])/100,baseline_code=headings['baseline']['code'],
                inception=inception,country_from=country_from,sources=[source,notice])


def initial_history():
    result=original(); sources=result['sources']
    amendments=[]
    for doc,begin,end in [('2025-06378',r'^Sec\. 2\.',r'^Sec\. 3\.'),
                          ('2025-06462',r'^Sec\. 3\.',r'^Sec\. 4\.')]:
        text,source=verified_source(doc);sources.append(source)
        clause=' '.join(unique_span(text,begin,end).split())
        replacement=re.search(r'heading ('+HEADING+r') of the HTSUS shall be amended by deleting ``(\d+)%\x27\x27 each place that it appears and by inserting ``(\d+)%\x27\x27 in lieu thereof',clause)
        at=windows(clause)['valid_from']
        if not replacement or not at:raise ValueError('Unparsed reciprocal replacement')
        amendments.append(dict(code=replacement[1],old_rate=float(replacement[2])/100,
            rate=float(replacement[3])/100,from_=at,source_id=source['id'],clause_sha256=sha(clause.encode())))
    text,source=verified_source('2025-06462')
    suspension=' '.join(unique_span(text,r'^Sec\. 2\.',r'^Sec\. 3\.').split())
    w=windows(suspension)
    from section122_rules import date_at
    dates=re.findall(r'(?:on|until) (\w+ \d+, \d{4})',suspension)
    if len(set(dates))!=2 or '10 percent' not in suspension:raise ValueError('Unparsed suspension window')
    result['suspension_from']=date_at(dates[0]);result['suspension_until']=date_at(dates[1])
    text,source=verified_source('2025-09297');sources.append(source)
    china=' '.join(unique_span(text,r'^Sec\. 2\.',r'^Sec\. 4\.').split())
    at=windows(unique_span(text,r'^Sec\. 2\.',r'^Sec\. 3\.'))['valid_from']
    if not at or 'additional ad valorem rate of duty of 10 percent' not in china or not re.search(r'heading 9903\.01\.63 and subdivision .*? hereby suspended',china):
        raise ValueError('Unparsed China suspension')
    result['china_suspension_from']=at
    duration=re.search(r'for an initial period of (\d+) days',china)
    if not duration:raise ValueError('Unparsed China suspension duration')
    result['china_suspension_until']=(datetime.fromisoformat(at).astimezone(ZoneInfo('America/New_York'))+
        timedelta(days=int(duration[1]))).isoformat()
    result['amendments']=amendments
    prior,source=verified_source('CSMS-64680374');sources.append(source)
    updated,source=verified_source('CSMS-65201773');sources.append(source)
    # The later instruction expressly applies to the April actions and
    # replaces the prior, inconsistent May 27/May 28 administrative cutoffs.
    # Keep both publications; do not perpetuate the superseded cutoff.
    if not all(s in updated for s in ('April 5, 2025, April 9, 2025, and April 10, 2025',
        'Upon further consideration, CBP is updating this guidance', '9903.01.28', '9903.01.25')):
        raise ValueError('Unreviewed reciprocal transit supersession')
    deadline=set(re.findall(r'before 12:01 a\.m\. EDT on (\w+ \d+, \d{4})',updated))
    final_dates={date_at(d) for d in deadline if date_at(d)>result['china_suspension_from']}
    if len(final_dates)!=1:raise ValueError('Ambiguous updated transit entry cutoff')
    result['transit_until']=final_dates.pop()
    initial_transit=re.search(r'9903\.01\.28: Articles.*?(?=\n)',updated)
    if not initial_transit or 'loaded onto a vessel at the port of loading and in-transit on the final mode of transport' not in initial_transit[0]:
        raise ValueError('Unreviewed transit transportation predicate')
    china_transit=re.search(r'Articles the product of China, identified in (9903\.\d{2}\.\d{2}),.*?(?=\n)',updated)
    if not china_transit or 'are subject to the 10% additional rate in lieu of the country-specific rate' not in china_transit[0]:
        raise ValueError('Missing China transit replacement')
    result['transit_source_id']=source['id'];result['transit_clause_sha256']=sha(updated.encode())
    faq,source=verified_source('CBP-IEEPA-FAQ-20261025');sources.append(source)
    if not all(s in faq for s in ('regardless of whether a claim is made under a specific Special Program Indicator (SPI) or Chapter 98 or 99 provision',
        'the U.S. bound cargo remains onboard', 'was laden onto a vessel destined for the U.S. after the cutoff date')):
        raise ValueError('Unreviewed CBP preference/transit interpretation')
    # Clause 6 changes the whole-article metal exclusion to a portion rule.
    text,source=verified_source('2025-10524');source.setdefault('id','FR-2025-10524');sources.append(source)
    first=unique_span(' '.join(re.sub(r'\[\[Page \d+\]\]', '', text).split()),r'\(2\) ',r'\(3\) ')
    result['metal_portion_from']=windows(first)['valid_from']
    if not result['metal_portion_from'] or 'non-aluminum, non-steel content' not in text:
        raise ValueError('Missing subsequent portion-policy boundary')
    for doc,metal in [('CSMS-65236374','steel'),('CSMS-65236645','aluminum')]:
        text,source=verified_source(doc);sources.append(source)
        if not all(s in text for s in ('As of June 4, 2025, the non-'+metal+' content',
            'is not subject to Reciprocal tariffs under HTS 9903.01.33')):
            raise ValueError('Unreviewed metal-portion instructions')
    text,source=verified_source('2025-12060');sources.append(source)
    next_policy=unique_span(text,r'^C\. Effective',r'^\[FR Doc\.')
    at=re.search(r'on or after 12:01 a\.m\.\s+eastern time on (\w+ \d+, \d{4})',next_policy)
    if not at or '9903.96.01' not in next_policy:raise ValueError('Missing subsequent UK sector boundary')
    aircraft=' '.join(re.sub(r'\[\[Page\s+\d+\]\]','',clean_fr(
        unique_span(next_policy,r'^``\(a\) As provided',r'^b\. U\.S\. note'))).split())
    target=re.search(r'As provided in heading ('+HEADING+r'), the additional duties imposed by heading (.*?) shall not apply',aircraft)
    if not target or not all(s in aircraft for s in ('of the United Kingdom','criteria of General Note 6','regardless of whether','subcolumn:')):
        raise ValueError('Unreviewed UK civil-aircraft eligibility clause')
    table=aircraft.split('subcolumn:',1)[1]
    products=re.findall(r'\d{4}\.\d{2}\.\d{2}',table)
    if not products or re.sub(r'\d{4}\.\d{2}\.\d{2}|[ ,;.]','',table):
        raise ValueError('Uncompiled UK aircraft product table')
    result['uk_aircraft']=dict(from_=date_at(at[1]),reporting_code=target[1],
        removed_codes=re.findall(HEADING,target[2]),products=sorted({p.replace('.','') for p in products}),
        source_id=source['id'],source_clause_sha256=sha(aircraft.encode()),condition_text=aircraft[:aircraft.index('subcolumn:')])
    if result['baseline_code'] not in result['uk_aircraft']['removed_codes']:
        raise ValueError('UK aircraft reciprocal action not reconciled')
    text,source=verified_source('EO-14316');sources.append(source)
    flat=' '.join(text.split())
    extension=unique_span(flat,r'Sec\. 2\.',r'Sec\. 3\.')
    period=re.search(r'on or after 12:01 a\.m\. eastern daylight time on (\w+ \d+, \d{4}).*?until 12:01 a\.m\. eastern daylight time on (\w+ \d+, \d{4})',extension)
    ranges=re.findall('('+HEADING+r') through ('+HEADING+r')',extension)
    suspended=set()
    for first,last in ranges:
        if first[:8]!=last[:8] or first>last:raise ValueError('Unreviewed suspension heading range')
        suspended.update(first[:8]+f'{n:02}' for n in range(int(first[-2:]),int(last[-2:])+1))
    expected={a['code'] for a in result['actions']} - {result['amendments'][0]['code']}
    if not period or suspended!=expected or date_at(period[1])!=result['suspension_until'] or 'remains in effect and is unaltered by this order' not in flat:
        raise ValueError('Unreconciled original reciprocal suspension extension')
    result['suspension_extension']=dict(from_=date_at(period[1]),until=date_at(period[2]),source_id=source['id'])
    result['policy_until']=date_at(period[2])
    if result['policy_until']>result['china_suspension_until']:
        raise ValueError('China suspension requires its own later amendment before extending this policy horizon')
    # EO 14326 continues the old non-China suspension until the new annex takes
    # effect seven days after signature. That continuation does not postpone
    # copper's independent August 1 portion amendment.
    text,source=verified_source('2025-15010');sources.append(source)
    flat=' '.join(text.split())
    signed=re.search(r'Executive Order \d+ of (\w+ \d+, \d{4})',flat)
    section=unique_span(flat,r'Sec\. 2\.',r'Sec\. 3\.')
    delay=re.search(r'eastern daylight time (\d+) days after the date of this order',section)
    continuation=re.search(r'\(e\) (.*?)(?=\(f\))',section)
    if not signed or not delay or not continuation or 'until the effective date of the modifications provided in Annex II' not in continuation[1]:
        raise ValueError('Unparsed July 31 reciprocal continuation')
    continued=set()
    for first,last in re.findall('('+HEADING+r') through ('+HEADING+r')',continuation[1]):
        if first[:8]!=last[:8] or first>last:raise ValueError('Unreviewed July 31 suspension range')
        continued.update(first[:8]+f'{n:02}' for n in range(int(first[-2:]),int(last[-2:])+1))
    if continued!=expected or 'Nothing in this order shall be construed to alter or otherwise affect Executive Order 14298' not in section:
        raise ValueError('July 31 suspension country/China treatment does not reconcile')
    replacement=(datetime.fromisoformat(date_at(signed[1]))+timedelta(days=int(delay[1]))).isoformat()
    result['july31_extension']=dict(from_=result['policy_until'],until=replacement,source_id=source['id'])
    result['policy_until']=replacement
    if replacement>result['china_suspension_until']:
        raise ValueError('China suspension requires its own later amendment before extending this policy horizon')
    text,source=verified_source('2025-14893');sources.append(source)
    flat=' '.join(text.split())
    first=unique_span(flat,r'\(1\) Except as otherwise provided',r'\(2\) The Secretary')
    result['copper_portion_from']=windows(first)['valid_from']
    clause=unique_span(flat,r'\(4\) The non-copper content',r'\(5\) If any product')
    if not result['copper_portion_from'] or not all(s in clause for s in (
        'shall apply only to the copper content', 'shall be subject to tariffs pursuant to Executive Order 14257')):
        raise ValueError('Unreviewed original copper reciprocal valuation')
    copper,source=annex('2025-14893');sources.append(source)
    heading=re.search(r'Heading ('+HEADING+r') provides the ordinary customs duty treatment of semi-',copper)
    if not heading:raise ValueError('Original copper reporting heading missing')
    result['copper_reporting_codes']=[heading[1]]
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('output');a=p.parse_args()
    Path(a.output).write_text(json.dumps(initial_history(),separators=(',',':'))+'\n')

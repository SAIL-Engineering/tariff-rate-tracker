"""Reconcile original Section 338 annexes, not a later HTS snapshot.

Scanned tables are retained as page-identified OCR and checked against the
independent descriptive annex and existing projections. No OCR spelling repair
or product-description association can broaden an operative table.
"""
from __future__ import annotations
import argparse, csv, json, re, subprocess
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
from section301_sources import sha, clean_pages, verify_revision_header
from build_contract import audit_until

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / 'resources/legal_evidence/section338'
CODE = r'(?<![\d.])\d{4}\.\d{2}\.\d{2}(?:\d{2})?(?![\d.])'


def codes(text):
    return sorted(set(c.replace('.', '') for c in re.findall(CODE, text)))


def one(pattern, text, label):
    matches = list(re.finditer(pattern, text, re.S))
    if len(matches) != 1:
        raise ValueError('Ambiguous Section 338 ' + label)
    return matches[0]


def instant(day):
    return datetime.strptime(day, '%B %d, %Y').replace(
        hour=0, minute=1, tzinfo=ZoneInfo('America/New_York')).isoformat()


def normalized_operand(text):
    return ' '.join(text.split()).replace('—','-').replace('–','-')


def replacement(text):
    m=one(r'deleting (?:the effective date )?[“"`]+(.*?)[”"\']+ and inserting\s*[“"`]*(.+?)[”"\']+ in lieu thereof',
          normalized_operand(text),'replacement operands')
    return m[1],m[2]


def replace_once(text,old,new):
    if text.count(old)!=1:raise ValueError('Section 338 replacement predecessor does not reconcile: '+old)
    return text.replace(old,new)


def heading_set(text):
    result=set()
    for m in re.finditer(r'(9903\.\d{2}\.\d{2})(?:-(9903\.\d{2}\.\d{2}))?',normalized_operand(text)):
        a,b=m.groups()
        if b and (a[:8]!=b[:8] or a>b):raise ValueError('Unreviewed Section 338 action range')
        result.update([a] if not b else [a[:8]+f'{i:02}' for i in range(int(a[-2:]),int(b[-2:])+1)])
    return result


def load_sources():
    manifest = json.loads((EVIDENCE / 'manifest.json').read_bytes())
    docs = {}; sources = []; artifacts = []
    def retain(id, path, digest, url, citation):
        p = ROOT / path
        if sha(p.read_bytes()) != digest:
            raise ValueError('Section 338 source hash mismatch: ' + id)
        sources.append(dict(id=id, sha256=digest, status='verified', url=url, citation=citation))
        artifacts.append(dict(source_id=id, path=str(p), sha256=digest))
        return p
    for source in manifest['sources']:
        doc = source['id']; url = source['url']
        p = retain('FR-' + doc, source['path'], source['sha256'], url,
                   doc + ': operative proclamation and original annexes, note 51')
        body = (subprocess.check_output(['pdftotext', '-layout', str(p), '-'], text=True)
                if p.suffix == '.pdf' else p.read_text())
        pages = []
        for item in source.get('ocr', []):
            p = retain('FR-' + Path(item['path']).stem, item['path'], item['sha256'], url,
                       'Retained OCR of original PDF page ' + Path(item['path']).stem + '; reconciled tables')
            pages.append(p.read_text())
        docs[doc] = source | dict(body=' '.join(body.split()), annex='\n'.join(pages))
    return docs, sources, artifacts


def extract():
    docs, sources, artifacts = load_sources()
    originals = sorted((d for d in docs.values() if d['kind'] == 'original'), key=lambda d: d['id'])
    delay = next(d for d in docs.values() if d['kind'] == 'delay')
    start = instant(one(r'\(1\) The effective date.*?shall be 12:01 a\.m\. eastern time on (\w+ \d+, \d{4})',
                        delay['body'], 'delayed commencement')[1])
    old_day,new_day=replacement(one(r'Accordingly,.*?(?=\(2\))',delay['body'],'delay replacement')[0])
    # The printed delay operand includes the label "effective date" before
    # the quote, so keep the dates themselves as the reconciliation keys.
    if instant(new_day)!=start:raise ValueError('Section 338 delay date disagreement')
    actions = []
    for doc in originals:
        text = doc['annex']
        # Heading identifier is taken from the actual insertion, not its position
        # in the file or a predicted sequential number.
        table = one(r'Heading (9903\.\d{2}\.\d{2}) applies to articles classifiable.*?tariff\s+schedule:(.*?)(?=\(c\)|Subdivision \(c\))', text, 'operative product table')
        heading = table[1]; products = codes(table[2])
        if not products or any(c.startswith(('98', '99')) for c in products):
            raise ValueError('Invalid Section 338 product precision')
        discovery = re.split(r'Annex I[IT]', text)[0]
        # Only column-leading identifiers are Annex I entries. Codes mentioned
        # inside a description are never memberships (e.g. an "other than" code).
        descriptive = sorted(set(c.replace('.', '') for c in re.findall(r'^\s*(' + CODE + ')', discovery, re.M)))
        if products != descriptive:
            raise ValueError('Section 338 Annex I/II scope disagreement: ' + doc['id'])
        rate = float(one(r'\(1\).*?additional ad valorem duty of (\d+) percent', doc['body'], 'rate')[1]) / 100
        original_day=one(r'\(1\).*?12:01 a\.m\. eastern time on (\w+ \d+, \d{4})',doc['body'],'original commencement')[1]
        annex_day=one(r'A\. Effective with respect.*?12:01 a\.m\. eastern time on (\w+ \d+, \d{4})',text,'original annex commencement')[1]
        if original_day!=old_day or annex_day!=old_day or not 0<rate<=.5:
            raise ValueError('Section 338 original commencement/ceiling does not reconcile')
        # Both general and special columns in the inserted heading must agree.
        heading_table = text[text.rindex('Heading /'):]
        if heading not in heading_table or re.findall(r'(\d+)%', heading_table) != [str(int(rate*100))]*2:
            raise ValueError('Section 338 heading/proclamation rate disagreement')
        if not all(s in doc['body'] for s in ('products of Canada', 'addition to any other duties', 'shall not apply to articles subject to duties pursuant to section 232')):
            raise ValueError('Unreviewed Section 338 origin/stacking rule')
        actions.append(dict(program=doc['program'], heading=heading, rate=rate, from_=start,
                            products=products, s232_exempt=True, source_id='FR-' + doc['id']))
    primary = originals[0]['annex']
    general = one(r'51\. \(a\)(.*?)(?=\(b\) The rate)', primary, 'general note')[1]
    interaction = one(r'\(c\) As provided in heading (9903\.\d{2}\.\d{2}),(.*?)(?=\(d\) As provided)', primary, '232 interaction')
    target=normalized_operand(one(r'additional duties imposed by (.*?shall) not apply',interaction[2],'initial interaction target')[1])
    for doc in originals[1:]:
        change=one(r'3\. Subdivision \(c\).*?(?=4\. Subdivision)',doc['annex'],'original action extension')
        target=replace_once(target,*replacement(change[0]))
    if heading_set(target)!={a['heading'] for a in actions}:raise ValueError('Section 338 original action/interaction inventories disagree')
    aircraft = one(r'\(d\) As provided in heading (9903\.\d{2}\.\d{2}),(.*?)(?=2\. The following new headings)', primary, 'aircraft exception')
    aircraft_codes = codes(aircraft[2].split('Special')[1])
    amendments = []
    for doc in sorted((d for d in docs.values() if d['kind']=='amendment'), key=lambda d:d['id']):
        annex = re.split(r'Annex I[IT]', doc['annex'])[-1]
        when = instant(one(r'12:01 a\.m\. eastern time on (\w+ \d+, \d{4})', annex, 'amendment commencement')[1])
        remove = codes(one(r'deleting the following subheadings:(.*?)(?=b\. inserting)', annex, 'deleted scope')[1])
        # The inserted list runs to the next numbered instruction, or to the end
        # of the document when the amendment issues no further instruction.
        insert = codes(one(r'inserting the following subheadings in numerical order:?(.*?)(?=2\. Subdivision|\[FR Doc\.|\Z)', annex, 'inserted scope')[1])
        heading=next(a['heading'] for a in actions if a['program']==doc['program'])
        # An amendment need not touch subdivision (c). A scope-only amendment
        # leaves the section 232 interaction exactly as its predecessors left
        # it, so the inventory is carried forward rather than re-derived: for
        # this heading that is cumulation, in force since the heading was
        # removed from (c), and restated in the amendment's own paragraph (1).
        subdivision_c=re.findall(r'2\. Subdivision \(c\).*?in lieu thereof',annex,re.S)
        if len(subdivision_c)>1:raise ValueError('Ambiguous Section 338 232 amendment')
        old=new=None
        if subdivision_c:
            # Original replacement operands must reconcile when amendments are
            # applied in legal order. In particular the first narrows a range's
            # first endpoint; the second replaces the resulting entire range.
            old,new=replacement(subdivision_c[0]);before=heading_set(target)
            target=replace_once(target,old,new);after=heading_set(target)
            if before^after!={heading}:raise ValueError('Unreviewed multi-action Section 338 amendment')
        else:
            after=heading_set(target)
        amendments.append(dict(id=doc['id'], program=doc['program'], effective_at=when,
                               delete=remove, insert=insert, s232_exempt=heading in after,
                               interaction_delete=old, interaction_insert=new, source_id='FR-'+doc['id']))
    return dict(contract_version='sail.section338-extraction/v1', extractor_sha256=sha(Path(__file__).read_bytes()),
                sources=sources, source_artifacts=artifacts, actions=actions, amendments=amendments,
                general_note=general, interaction=dict(reporting_code=interaction[1], text=interaction[2]),
                aircraft=dict(reporting_code=aircraft[1], text=aircraft[2], products=aircraft_codes))


def periods(x):
    result = []
    for action in x['actions']:
        state = dict(action)
        for amendment in sorted((a for a in x['amendments'] if a['program']==action['program']), key=lambda a:a['effective_at']):
            if not set(amendment['delete']) <= set(state['products']):
                raise ValueError('Section 338 deletion does not reconcile: ' + amendment['id'])
            result.append(state | {'until':amendment['effective_at']})
            state = state | dict(from_=amendment['effective_at'],
                products=sorted(set(state['products'])-set(amendment['delete'])|set(amendment['insert'])),
                s232_exempt=amendment['s232_exempt'], amendment_id=amendment['id'])
        result.append(state | {'until':audit_until()})
    return result


def semantic_words(text):
    text=re.sub(r'^.*(?:Federal Register|Presidential Documents).*$', '',text,flags=re.M)
    text=re.sub(r'^\s*\d{5}\s*$', '',text,flags=re.M)
    text=re.sub(r'^\s*\(?[1-8][.)]\s*','',text,flags=re.M)
    return re.findall(r'[\w.]+|-',text.lower().replace('—','-').replace('–','-'))


def reconcile_snapshot(x,revision,hts):
    """A later codification corroborates a state, never supplies its start date."""
    headings={a['heading'] for a in x['actions']}
    if not headings & {r.get('htsno') for r in hts}:return None
    path=ROOT/f'data/us_notes/chapter99_{revision}.pdf'
    raw=subprocess.check_output(['pdftotext','-layout',str(path),'-'],text=True)
    verify_revision_header(raw,revision)
    text=clean_pages(raw)
    starts=list(re.finditer(r'^\s*51\.\s*',text,re.M))
    if len(starts)!=1:raise ValueError('Missing/ambiguous codified note 51')
    note=text[starts[0].end():];end=re.search(r'^\s*52\.\s*',note,re.M)
    if not end:raise ValueError('Unbounded codified note 51')
    note=note[:end.start()]
    general=one(r'\(a\)(.*?)(?=\(b\)\s+The rate)',note,'codified general conditions')[1]
    # The original dairy/motor annexes extend note 51(a) to all three headings
    # and pluralize its references. No other semantic change is permitted.
    first,last=x['actions'][0]['heading'],x['actions'][-1]['heading']
    expected=' '.join(x['general_note'].split()).replace(
        f'heading {first} imposes',f'headings {first}-{last} impose').replace(
        'imposed by this heading','imposed by these headings').replace('chapters | to','chapters 1 to')
    if semantic_words(general)!=semantic_words(expected):
        raise ValueError('Unreviewed Section 338 general-note amendment')
    c=one(r'\(c\)\s+As provided.*?shall not apply to:(.*?)(?=\(d\)\s+As provided)',note,'codified 232 condition')
    if semantic_words(c[1])!=semantic_words(x['interaction']['text'].split('shall not apply to:')[1]):
        raise ValueError('Unreviewed Section 338 interaction amendment')
    d=one(r'\(d\)\s+As provided.*?shall not apply to(.*?)(?=subcolumn:)',note,'codified aircraft condition')
    if semantic_words(d[1])!=semantic_words(x['aircraft']['text'].split('shall not apply to')[1].split('subcolumn:')[0]):
        raise ValueError('Unreviewed Section 338 aircraft condition')
    if codes(note[d.end():])!=x['aircraft']['products']:raise ValueError('Unreviewed Section 338 aircraft table')
    from chapter98_rules import treatment
    if treatment(note[:c.start()])!=treatment(x['general_note']):raise ValueError('Unreviewed Section 338 Chapter 98 treatment')
    matches=list(re.finditer(r'Heading (9903\.\d{2}\.\d{2}) applies to articles classifiable',note))
    if {m[1] for m in matches}!=headings:raise ValueError('Unreviewed Section 338 action inventory')
    states=[]
    for i,m in enumerate(matches):
        scope=codes(note[m.end():matches[i+1].start() if i+1<len(matches) else c.start()])
        possible=[p for p in periods(x) if p['heading']==m[1] and p['products']==scope]
        if not possible:raise ValueError('Unreviewed Section 338 codified scope amendment: '+m[1])
        row=next(r for r in hts if r.get('htsno')==m[1])
        for column in ('general','special'):
            rates=re.findall(r'\+\s*(\d+(?:\.\d+)?)%',row.get(column,''))
            if rates!=[str(int(possible[0]['rate']*100))]:raise ValueError('Unreviewed Section 338 codified rate')
        states.append(dict(heading=m[1],scope_count=len(scope),original_state=possible[0].get('amendment_id','initial')))
    return dict(path=str(path),sha256=sha(path.read_bytes()),note_sha256=sha(note.encode()),states=states)


if __name__ == '__main__':
    p=argparse.ArgumentParser();p.add_argument('output');a=p.parse_args()
    Path(a.output).write_text(json.dumps(extract(),separators=(',',':'))+'\n')

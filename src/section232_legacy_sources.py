"""Pre-April-2026 metal evidence, bounded by each revision's complete notes.

Scope membership is a candidate, not proof of a material, use or claim condition.
Do not extract all numbers in a paragraph: exclusions and descriptive references
to other chapters are not scope additions. Printed retired headings survive as
evidence but are never chosen by maximum rate or alphabetical ordering.
"""
from __future__ import annotations
import argparse
import json
import re
import subprocess
from pathlib import Path
from section301_sources import clean_pages, sha, unique_span, verify_revision_header

ROOT = Path(__file__).resolve().parents[1]
CODE = r'(?<![\d.])\d{4}(?:\.\d{2}(?:\.\d{2}(?:\.?\d{2})?)?)?(?![\d.]\d)'


def codes(text):
    return sorted({c.replace('.', '') for c in re.findall(CODE, text)
                   if not c.startswith(('98', '99'))})


def paragraph(note, letter, following):
    lead=r'(?:The rates|Except as provided in heading|Headings? 9903|Any importer|\(A\) Effective|Subheadings? 9903)'
    starts=list(re.finditer(r'^\s*\('+letter+r'\)\s+(?='+lead+')',note,re.M))
    if len(starts)!=1:raise ValueError('Ambiguous top-level note paragraph '+letter)
    rest=note[starts[0].start():]
    end=re.search(r'^\s*\('+following+r'\)\s+(?='+lead+')',rest,re.M)
    if not end:raise ValueError('Missing note paragraph end '+following)
    return rest[:end.start()].strip()



def scoped_lists(note, number, letter, following, kind, heading, metal):
    text = paragraph(note, letter, following)
    records = []
    def record(body, includes, excludes=(), condition=None, suffix=''):
        if not includes or any(len(c) not in (4,6,8,10) for c in includes):
            raise ValueError('Invalid metal scope')
        records.append(dict(id=f'n{number}_{letter}{suffix}', metal=metal,
            derivative=kind!='primary', reporting_code=heading,
            locator=f'U.S. note {number}({letter})'+suffix, includes=sorted(set(includes)),
            excludes=sorted(set(excludes)), condition_text=condition,
            source_text=body, source_text_sha256=sha(body.encode())))
    if kind=='primary':
        enumeration=text.split('Any reference above')[0]
        enumeration=enumeration[re.search(r'^\s*\(i\)',enumeration,re.M).start():]
        exclusions=re.findall(r'\(except[^)]*\)',enumeration)
        clean=re.sub(r'\(except[^)]*\)','',enumeration)
        # Castings/forgings are narrower than the basket subheading. Keep the
        # description as a predicate instead of treating every suffix as cast.
        cast=re.search(r'castings and forgings[^;]*',clean)
        if cast:
            record(cast[0],codes(cast[0]),condition=' '.join(cast[0].split()),suffix='_castings')
            clean=clean[:cast.start()]+clean[cast.end():]
        record(text,codes(clean),codes(' '.join(exclusions)))
    elif kind=='described':
        starts=list(re.finditer(r'^\s*\(([A-F])\)\s+',text,re.M))
        if not starts: raise ValueError('Missing derivative descriptions')
        for i,m in enumerate(starts):
            body=text[m.start():starts[i+1].start() if i+1<len(starts) else len(text)].strip()
            # Only "described in"/"numbers ... only" establishes membership;
            # 8701 to 8705, 8305 and explicitly excluded suffixes are context.
            ref=re.search(r'(?:described in (?:subheading|statistical reporting numbers?)\s+)(.*?)(?:\)|only)', ' '.join(body.split()),re.S)
            if not ref:raise ValueError('Unparsed described derivative scope')
            record(body,codes(ref[1]),condition=' '.join(body.split()),suffix='_'+m[1])
    else:
        # Numbered cohorts in steel (n)/(u) have different admission dates;
        # retain each complete cohort, including its date and conditions.
        parts=re.split(r'\s+(?:and )?(?=\([23]\) all imported)', ' '.join(text.split()))
        for i,body in enumerate(parts):
            if ':' not in body:raise ValueError('Missing enumerated derivative table')
            boundary=re.search(r'United States:\s*',body)
            if not boundary:raise ValueError('Unreviewed derivative predicate')
            table=body[boundary.end():]
            table=table.split('For any derivative')[0].split('For subheadings')[0].split("(Compiler's Note:")[0]
            residual=re.sub(CODE,'',table)
            if re.sub(r'[\s;:.,]','',residual):
                raise ValueError('Unparsed metal table: '+residual[:120])
            record(body,codes(table),suffix=f'_{i+1}')
        if 'not specifically' in text:
            # Complement of the immediately preceding legacy derivative list.
            previous=paragraph(note,chr(ord(letter)-1),letter)
            selected=[]
            for body in re.split(r'\([A-F]\)',previous)[1:]:
                ref=re.search(r'described in statistical reporting numbers\s+(.*?)only',' '.join(body.split()),re.S)
                if ref:selected+=codes(ref[1])
            if not selected:raise ValueError('Unresolved statistical complement')
            for r in records:r['excludes']=sorted(set(r['excludes']+selected))
    return records, text


def extract(pdf: Path, hts: Path, revision: str) -> dict:
    raw=subprocess.check_output(['pdftotext','-layout',str(pdf),'-'],text=True)
    verify_revision_header(raw,revision)
    schedule=json.loads(hts.read_bytes())
    bycode={}
    for row in schedule:
        code=row.get('htsno','')
        if re.fullmatch(r'9903\.(?:80|81|85)\.\d{2}',code):
            if code in bycode:raise ValueError('Duplicate Section 232 source heading')
            bycode[code]=row
    x=dict(contract_version='sail.section232-legacy-extraction/v1',revision=revision,
        extractor_sha256=sha(Path(__file__).read_bytes()),
        parser_dependency_sha256=sha(Path(__file__).with_name('section301_sources.py').read_bytes()),
        sources=[dict(path=str(p.resolve()),sha256=sha(p.read_bytes())) for p in (pdf,hts)],
        regime='note16_replaced' if any(r.get('htsno')=='9903.82.02' for r in schedule) else
            'march_2025_metals' if '9903.81.87' in bycode else 'pre_march_2025',
        lists=[],clauses=[],headings=[],additional_sources=[])
    if x['regime']=='note16_replaced':return x
    text=clean_pages(raw)
    notes={n:unique_span(text,rf'^\s*{n}\.\s*\(a\)',rf'^\s*{n+1}\.\s*\(a\)') for n in (16,19)}
    # Retain the earlier quota/exclusion regimes for investigation. Do not
    # manufacture an unconditional zero or reuse the March compiler for them.
    x['notes']=[dict(number=n,text=t,sha256=sha(t.encode())) for n,t in notes.items()]
    if x['regime']=='pre_march_2025':return x
    # Note 19(m) expressly dates the new treatment; cross-checked against
    # Proclamations 10895/10896. Mere presence in a pre-effective HTS release
    # does not start the action earlier.
    m=re.search(r'on or after\s+12:01\s+a\.m\. eastern daylight time on (March 12, 2025)',notes[19])
    if not m:raise ValueError('Unresolved March metal commencement')
    x['valid_from']='2025-03-12T00:01:00-04:00'
    definitions=[(16,'j','k','primary','9903.81.87','steel'),
        (16,'l','m','described','9903.81.89','steel'),(16,'m','n','table','9903.81.90','steel'),
        (16,'n','o','table','9903.81.91','steel'),
        (19,'g','h','primary','9903.85.02','aluminum'),
        (19,'i','j','described','9903.85.04','aluminum'),(19,'j','k','table','9903.85.07','aluminum'),
        (19,'k','l','table','9903.85.08','aluminum')]
    if '9903.81.94' in bycode:
        definitions += [(16,'q','r','primary','9903.81.94','steel'),
            (16,'s','t','described','9903.81.96','steel'),(16,'t','u','table','9903.81.97','steel'),
            (16,'u','v','table','9903.81.98','steel'),
            (19,'o','p','primary','9903.85.12','aluminum'),
            (19,'q','r','described','9903.85.13','aluminum'),(19,'r','s','table','9903.85.14','aluminum'),
            (19,'s','t','table','9903.85.15','aluminum')]
    for n,letter,end,kind,heading,metal in definitions:
        lists,body=scoped_lists(notes[n],n,letter,end,kind,heading,metal)
        for record in lists:
            record['country_group']='uk' if heading in {'9903.81.94','9903.81.96','9903.81.97','9903.81.98',
                '9903.85.12','9903.85.13','9903.85.14','9903.85.15'} else 'ordinary'
        x['lists']+=lists
    for n,letter,end in [(16,'i','j'),(16,'k','l'),(19,'f','g'),(19,'h','i'),(19,'m','n')]:
        if n==19 and letter=='m' and not re.search(r'^\s*\(n\)',notes[n],re.M):
            body=notes[n][list(re.finditer(r'^\s*\(m\)',notes[n],re.M))[-1].start():]
        else:body=paragraph(notes[n],letter,end)
        x['clauses'].append(dict(locator=f'n{n}_{letter}',text=body,sha256=sha(body.encode())))
    wanted={s['reporting_code'] for s in x['lists']} | {'9903.81.88','9903.81.92','9903.81.93',
        '9903.85.09','9903.85.67','9903.85.68','9903.85.69','9903.85.70'}
    if '9903.81.94' in bycode:wanted|={'9903.81.95','9903.81.99'}
    for code in sorted(wanted):
        row=bycode[code];expression=row.get('general','').strip()
        match=re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*(?:a duty of )?([\d.]+)%(?: upon the value of the (steel|aluminum) content)?\.?',expression)
        if match:rate=float(match[1])/100;basis=match[2]+'_content_value' if match[2] else 'customs_value'
        elif re.fullmatch(r'The duty provided in the applicable subheading\.?',expression):rate=0;basis='no_change'
        else:raise ValueError('Unparsed legacy metal formula: '+expression)
        x['headings'].append(dict(code=code,description=row['description'],duty_expression=expression,
            rate=rate,valuation_basis=basis,source_row_sha256=sha(json.dumps(row,sort_keys=True).encode())))
    # A UK heading can abbreviate the content basis in the rate column; the
    # full operative subdivision still controls it (notably 9903.81.98).
    for h in x['headings']:
        controlling=[s for s in x['lists'] if s['reporting_code']==h['code']]
        for s in controlling:
            flat=' '.join(s['source_text'].split())
            if re.search(r'only apply to the declared value of the '+s['metal']+' content',flat):
                h['valuation_basis']=s['metal']+'_content_value'
    amendment=ROOT/'resources/legal_evidence/2025-10524/notice.txt'
    meta=json.loads(amendment.with_name('source.json').read_bytes())
    if meta['sha256']!=sha(amendment.read_bytes()):raise ValueError('June metal amendment hash mismatch')
    flat=' '.join(amendment.read_text().split())
    for phrase in ['June 4, 2025','shall apply only to the steel content of articles in Chapter 73',
                   'content of articles in Chapter 76','shall remain at 25']:
        if phrase not in flat:raise ValueError('Unreviewed June metal amendment')
    x['additional_sources'].append(dict(id='FR-2025-10524',path=str(amendment),**meta))
    x['content_amendment_from']='2025-06-04T00:01:00-04:00'
    return x


def matches(x,products):
    result=[]
    index={}
    for product in sorted(set(products)):
        if not re.fullmatch(r'\d{10}',product):raise ValueError('Invalid HTS10')
        for n in (4,6,8,10):index.setdefault(product[:n],[]).append(product)
    for s in x['lists']:
        for prefix in s['includes']:
            for product in index.get(prefix,[]):
                if any(product.startswith(e) for e in s['excludes']):continue
                result.append(dict(hts10=product,list_id=s['id'],scope_code=prefix,scope_grain=len(prefix),
                    metal=s['metal'],reporting_code=s['reporting_code'],country_group=s['country_group'],
                    conditional=s['condition_text'] is not None,source_locator=s['locator'],
                    source_text_sha256=s['source_text_sha256']))
    return sorted(result,key=lambda r:(r['hts10'],r['list_id'],r['scope_code']))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    for key in ('pdf','hts','revision','output'):p.add_argument('--'+key,required=True)
    a=p.parse_args();Path(a.output).write_text(json.dumps(extract(Path(a.pdf),Path(a.hts),a.revision),separators=(',',':'))+'\n')

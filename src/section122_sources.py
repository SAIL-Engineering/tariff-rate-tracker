"""Revision-bound U.S. note 2(aa) evidence; never truncate statistical scope.

Extract the three product tables and retain every other predicate verbatim.
This is not complete certification of Section 122/232, Chapter 98 or FTZ law.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import subprocess
from section301_sources import clean_pages, sha, unique_span, verify_revision_header

CODE = r'(?<![\d.])\d{4}\.\d{2}\.\d{2}(?:\.?\d{2})?(?![\d.])'


def note_clauses(raw):
    text = unique_span(clean_pages(raw), r'^\s*SUBCHAPTER III\s*$',
                       r'^\s*3\.\s+For the purposes of subheadings 9903\.41')
    matches = list(re.finditer(r'^\s*\(aa\)\s', text, re.M))
    if len(matches) != 1:
        raise ValueError('Expected exactly one Section 122 note 2(aa)')
    note = text[matches[0].start():]
    starts = list(re.finditer(r'^\s*\((i|ii|iii|iv|v|vi|vii|viii)\)\s+(?=Except as provided in headings|As provided in heading)', note, re.M))
    if [m[1] for m in starts] != ['i','ii','iii','iv','v','vi','vii','viii']:
        raise ValueError('Section 122 note subdivisions missing or ambiguous')
    return note, {m[1]: note[m.start():starts[i+1].start() if i+1<len(starts) else len(note)].strip()
                  for i,m in enumerate(starts)}


def product_rows(clauses):
    rows = []
    def emit(code, label, heading, condition, text, span):
        code = code.replace('.', '')
        if len(code) not in (8,10): raise ValueError('Unsupported Section 122 scope precision')
        rows.append(dict(scope_code=code,scope_grain='exact_hts10' if len(code)==10 else 'hts8',
            condition=condition,condition_text=text,reporting_code=heading,
            valuation_basis='customs_value',source_ref=f'U.S. note 2(aa)({label})',
            source_text=span,source_text_sha256=sha(span.encode())))
    for label, heading, condition in [('ii','9903.03.03','none'),('iv','9903.03.05','gn6_civil_aircraft')]:
        span = clauses[label]
        marker = re.search(r'\[Compiler.s note: List may.*?\]',span,re.S)
        if not marker: raise ValueError('Unrecognized Section 122 code-table introduction')
        intro,table = span[:marker.start()],span[marker.end():]
        if heading not in intro or (label=='iv' and 'general note 6' not in intro):
            raise ValueError('Section 122 table/heading or use-condition mismatch')
        codes = re.findall(CODE,table)
        if not codes or re.sub(CODE,'',table).strip():
            raise ValueError('Unparsed Section 122 table content; refusing broad exemption')
        for code in sorted(set(codes)):
            emit(code,label,heading,condition,'' if condition=='none' else ' '.join(intro.split()),span)
    span = clauses['iii']
    if '9903.03.04' not in span: raise ValueError('Description table heading mismatch')
    starts = list(re.finditer(r'^\s*\((\d+)\)\s',span,re.M))
    if not starts or [int(m[1]) for m in starts]!=list(range(1,len(starts)+1)):
        raise ValueError('Description-limited scope sequence is incomplete')
    for i,m in enumerate(starts):
        item = span[m.start():starts[i+1].start() if i+1<len(starts) else len(span)].strip()
        matches = re.findall(r'classifiable in subheading ('+CODE+r')', ' '.join(item.split()))
        if len(matches)!=1: raise ValueError('Unresolved Section 122 article-description scope')
        emit(matches[0],'iii','9903.03.04','article_description',' '.join(item.split()),item)
    if len({(r['scope_code'],r['reporting_code']) for r in rows})!=len(rows):
        raise ValueError('Duplicate Section 122 product scope')
    return rows


def extract(pdf,hts,revision):
    raw = subprocess.check_output(['pdftotext','-layout',str(pdf),'-'],text=True)
    verify_revision_header(raw,revision)
    schedule = json.loads(hts.read_bytes())
    headings = [r for r in schedule if re.fullmatch(r'9903\.03\.\d{2}',r.get('htsno',''))]
    result = dict(contract_version='sail.section122-extraction/v1',revision=revision,
        extractor_sha256=sha(Path(__file__).read_bytes()),
        parser_dependency_sha256=sha(Path(__file__).with_name('section301_sources.py').read_bytes()),
        sources=[dict(path=str(p.resolve()),sha256=sha(p.read_bytes())) for p in (pdf,hts)],
        headings=headings,clauses=[],products=[],limitations=[
            'Snapshot text is revision-bound; amendments between publications require independent evidence.',
            'Other note predicates, including Section 232 interactions, claims and FTZ treatment, remain source text until separately compiled.',
            'No complete authority coverage attestation is emitted.'])
    if not headings: return result
    base = [r for r in headings if r['htsno']=='9903.03.01']
    if len(base)!=1: raise ValueError('Missing or duplicated Section 122 charge heading')
    rate = re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*([\d.]+)%',base[0]['general'].strip())
    if not rate: raise ValueError('Unparsed Section 122 duty expression')
    note,clauses=note_clauses(raw)
    result.update(rate=float(rate[1])/100,note=note,note_sha256=sha(note.encode()),
        clauses=[dict(id=k,text=v,sha256=sha(v.encode())) for k,v in clauses.items()],
        products=product_rows(clauses))
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for key in ('pdf','hts','revision','output'): p.add_argument('--'+key,required=True)
    a=p.parse_args()
    Path(a.output).write_text(json.dumps(extract(Path(a.pdf),Path(a.hts),a.revision),indent=2)+'\n')

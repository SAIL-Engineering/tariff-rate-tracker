"""Exact, revision-bound reciprocal Annex II scope; no model-derived exemptions.

The universal list and description-limited list are distinct legal decisions.
A missing/unparsed line is an error, not a reason to broaden an HTS prefix.
"""
from __future__ import annotations
import argparse, json, re, subprocess
from pathlib import Path
from section301_sources import clean_pages, sha, unique_span, verify_revision_header

ROOT=Path(__file__).resolve().parents[1]
CODE=r'\d{4}(?:\.\d{2}(?:\.\d{2}(?:\.?\d{2})?)?)?'


def reciprocal_note(raw):
    section=unique_span(clean_pages(raw),r'^\s*SUBCHAPTER III\s*$',
        r'^\s*3\.\s+For the purposes of subheadings 9903\.41')
    start=re.search(r'^\s*\(v\)\s',section,re.M)
    if not start:raise ValueError('Missing reciprocal note 2(v)')
    note=section[start.start():]
    # The suspended China subdivision (w) is absent in later snapshots. Stop
    # at the next named action, not a nested Roman (x) within reciprocal law.
    stop=re.search(r'^\s*(?:\((?:w|y|z|aa|bb|cc|dd)\)\s|\(x\)\s*(?=\(i\)))',note,re.M)
    return note[:stop.start()] if stop else note


def product_scope(note):
    span=unique_span(note,r'^\s*\(iii\)\s*(?=(?:\(a\)\s*)?As provided)',r'^\s*\(iv\)\s*As provided')
    conditional=re.search(r'^\s*\(b\)\s',span,re.M)
    unconditional=span[:conditional.start()] if conditional else span
    marker=re.search(r'following\s+subheadings\s+of\s+the\s+HTSUS:',unconditional)
    if not marker or '9903.01.32' not in unconditional[:marker.start()]:
        raise ValueError('Unreviewed universal exemption introduction')
    table=re.sub(r'\[Compiler[’\x27]s note:.*?\]','',unconditional[marker.end():],flags=re.S)
    codes=re.findall(CODE,table)
    if not codes or re.sub(CODE,'',table).strip():
        raise ValueError('Unparsed universal reciprocal table content')
    rows=[]
    def emit(code,condition,description,reporting,locator,text):
        code=code.replace('.','')
        if len(code) not in (4,6,8,10) or code[:2]>='98':raise ValueError('Invalid reciprocal scope grain')
        rows.append(dict(scope_code=code,scope_grain=len(code),condition=condition,condition_text=description,
            reporting_code=reporting,source_locator=locator,source_scope_sha256=sha(text.encode())))
    for code in sorted(set(codes)):
        emit(code,'none','','9903.01.32','U.S. note 2(v)(iii) universal enumeration',unconditional)
    if conditional:
        body=span[conditional.start():]
        starts=list(re.finditer(r'^\s*\((\d+)\)\s',body,re.M))
        if not starts or '9903.02.78' not in body[:starts[0].start()]:
            raise ValueError('Missing description-limited reciprocal heading')
        if [int(m[1]) for m in starts]!=list(range(1,len(starts)+1)):
            raise ValueError('Incomplete conditional reciprocal inventory')
        for i,m in enumerate(starts):
            item=body[m.end():starts[i+1].start() if i+1<len(starts) else len(body)].strip()
            flat=' '.join(item.split());codes=re.findall(r'classifiable in subheading ('+CODE+r')',flat)
            if len(codes)!=1:raise ValueError('Unresolved description-limited reciprocal scope')
            emit(codes[0],'article_description',flat,'9903.02.78','U.S. note 2(v)(iii)(b)('+m[1]+')',item)
    return rows


def extract(pdf,hts,revision):
    raw=subprocess.check_output(['pdftotext','-layout',str(pdf),'-'],text=True)
    verify_revision_header(raw,revision)
    schedule=json.loads(Path(hts).read_bytes())
    headings=[r for r in schedule if r.get('htsno') in ('9903.01.32','9903.02.78')]
    result=dict(contract_version='sail.ieepa-reciprocal-scope/v1',revision=revision,
        extractor_sha256=sha(Path(__file__).read_bytes()),
        parser_dependency_sha256=sha(Path(__file__).with_name('section301_sources.py').read_bytes()),
        sources=[dict(path=str(Path(p).resolve()),sha256=sha(Path(p).read_bytes())) for p in (pdf,hts)],
        headings=headings,products=[])
    from ieepa_reciprocal_history import history, reconcile_native
    result['history']=history()
    result['history_compiler_sha256']=sha(Path(__file__).with_name('ieepa_reciprocal_history.py').read_bytes())
    result['emergency_parser_sha256']=sha(Path(__file__).with_name('ieepa_fentanyl_sources.py').read_bytes())
    if not headings:
        result['reconciliation']=reconcile_native(result,result['history'])
        return result
    if sum(r['htsno']=='9903.01.32' for r in headings)!=1:raise ValueError('Ambiguous universal reciprocal heading')
    note=reciprocal_note(raw)
    result['products']=product_scope(note)
    result['note_sha256']=sha(note.encode())
    if {r['reporting_code'] for r in result['products']}!={h['htsno'] for h in headings}:
        raise ValueError('Scope/heading inventory disagreement')
    if any(h.get('general')!='The duty provided in the applicable subheading' for h in headings):
        raise ValueError('Unreviewed reciprocal exemption expression')
    result['reconciliation']=reconcile_native(result,result['history'])
    return result


def matches(extraction,products):
    rows=[]
    for hts in sorted(set(products)):
        if not re.fullmatch(r'\d{10}',hts):raise ValueError('Exact HTS10 required')
        for r in extraction['products']:
            if hts.startswith(r['scope_code']):rows.append(dict(hts10=hts,**r))
    return rows

if __name__=='__main__':
    p=argparse.ArgumentParser()
    for k in ('pdf','hts','revision','output'):p.add_argument('--'+k,required=True)
    a=p.parse_args()
    Path(a.output).write_text(json.dumps(extract(Path(a.pdf),Path(a.hts),a.revision),separators=(',',':'))+'\n')

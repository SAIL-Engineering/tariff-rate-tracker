"""Revision-bound extraction of Chapter 99 note 16 metal scope.

Note 16(c) is an enumeration, not a license to cover whole metal chapters.
Keep every list membership: overlapping lists determine applicable metals and
weight predicates and must never be reduced by first-match or longest-prefix.
This module extracts evidence; it does not assert that HTS membership alone
establishes shipment liability or that other Section 232 actions are absent.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

from section301_sources import clean_pages, sha, unique_span, verify_revision_header

ROMANS = ('i', 'ii', 'iii', 'iv', 'v', 'vi', 'vii', 'viii', 'ix', 'x', 'xi')
HTS = r'\d{4}(?:\.\d{2}(?:\.\d{2}(?:\.?\d{2})?)?)?'


def c_references(text: str) -> list[str]:
    """Read enumerated note-16(c) references, including Roman ranges."""
    flat = ' '.join(text.split())
    references = []
    for span in re.finditer(r'\(c\)((?:\([ivx]+\)|[–,\- ]|and)+)', flat):
        tokens = list(re.finditer(r'\(([ivx]+)\)', span[1]))
        for i, token in enumerate(tokens):
            if token[1] not in ROMANS:
                raise ValueError('Unknown note 16 list reference')
            if i and re.fullmatch(r'\s*[–-]\s*', span[1][tokens[i-1].end():token.start()]):
                lo, hi = ROMANS.index(tokens[i-1][1]), ROMANS.index(token[1])
                if hi <= lo:
                    raise ValueError('Invalid note 16 list range')
                references.extend(ROMANS[lo:hi+1])
            else:
                references.append(token[1])
    return sorted(set(references), key=ROMANS.index)


def extract_note16(text: str) -> dict:
    note = unique_span(clean_pages(text), r'^\s*16\.\s*\(a\)', r'^\s*17\.\s*\(a\)')
    if not re.search(r'headings 9903\.82\.02[–-]9903\.82\.', note):
        raise ValueError('Unsupported note 16 regime')
    if 'mutually exclusive' not in note or 'full customs value' not in note:
        raise ValueError('Unrecognized note 16 valuation or interaction grammar')
    scope = unique_span(note, r'^\s*\(c\)\s', r'^\s*\(d\)\s')
    starts = list(re.finditer(r'^\s*\(([ivx]+)\)\s+(Articles of|Derivative)\s+(aluminum|steel|copper)(?:[ \t]+(articles))?[ \t]*:?', scope, re.M))
    if tuple(m[1] for m in starts) not in (ROMANS[:10], ROMANS):
        raise ValueError('Missing, reordered, or unreviewed note 16(c) list')
    lists = []
    for i, start in enumerate(starts):
        span = scope[start.start():starts[i+1].start() if i+1 < len(starts) else len(scope)].strip()
        table = scope[start.end():starts[i+1].start() if i+1 < len(starts) else len(scope)]
        table = re.sub(r'\[Compiler[’\x27]s note:.*?\]', '', table, flags=re.S).lstrip(':')
        entries = []
        for line in table.splitlines():
            if not line.strip():
                continue
            if not re.fullmatch(rf'\s*{HTS}(?:\s+{HTS})*\s*', line):
                raise ValueError(f'Unparsed note 16(c)({start[1]}) table line: {line.strip()}')
            entries.extend(code.replace('.', '') for code in line.split())
        if not entries or any(len(c) not in (4, 6, 8, 10) or c[:2] in ('98', '99') for c in entries):
            raise ValueError('Invalid note 16 scope')
        if len(entries) != len(set(entries)):
            raise ValueError('Duplicate code within note 16 list')
        lists.append(dict(id=start[1], metal=start[3], derivative=start[2] == 'Derivative',
            includes=sorted(entries), locator=f'U.S. note 16(c)({start[1]})',
            source_text=span, source_text_sha256=sha(span.encode())))
    # Full paragraphs survive extraction; never truncate a legal condition to
    # a keyword window. Downstream semantic compilers must account for them.
    clauses = []
    d_start = re.search(r'^\s*\(d\)\s', note, re.M).start()
    boundaries = [m for m in re.finditer(r'^\s*(?:16\.\s*)?\(([a-z])\)\s+', note, re.M)
                  if m[1] in ('a','b','c') or m.start() >= d_start]
    for i, m in enumerate(boundaries):
        span = note[m.start():boundaries[i+1].start() if i+1 < len(boundaries) else len(note)].strip()
        clauses.append(dict(id=m[1], text=span, sha256=sha(span.encode())))
    return dict(lists=lists, clauses=clauses, source_text_sha256=sha(note.encode()),
                mutually_exclusive=True, valuation_basis='full_customs_value')


def note16_parameters(extraction: dict) -> dict:
    """Bounded semantic values, never a copy of the newest revision's constants."""
    clauses = {c['id']: ' '.join(c['text'].split()) for c in extraction['clauses']}
    c = clauses['c'].split('(i)')[0]
    threshold = re.search(r'at least (\d+) percent of the weight', c)
    chapters = re.search(r'not in chapters ([\d, or]+) of', c)
    if not threshold or not chapters or 'aggregate weight of the listed metals' not in c:
        raise ValueError('Unreviewed weight/metal aggregation condition')
    domestic = []
    for m in re.finditer(r'For (?:derivative )?articles (?:provided for )?in (?:the )?subdivisions? (\(c\).*?), at least (\d+) percent of the (aluminum|steel|copper) content', clauses['e']):
        domestic.append(dict(list_ids=c_references(m[1]),minimum_fraction=int(m[2])/100,metal=m[3]))
    if {d['metal'] for d in domestic} != {'aluminum','steel','copper'}:
        raise ValueError('Unparsed domestic metal conditions')
    uk = re.findall(r'at least (\d+) percent of the (aluminum|steel)',clauses['d'])
    if len(uk)!=2: raise ValueError('Unparsed UK origin condition')
    parameters = dict(weight_minimum_fraction=int(threshold[1])/100,
        weight_exempt_chapters=re.findall(r'\d+',chapters[1]),domestic=domestic,
        uk_minimum_fractions={metal:int(n)/100 for n,metal in uk},
        motorcycle_lists=c_references(clauses['g']),motorcycle_chapters=re.findall(r'\d+',re.search(r'chapter ([\d, or]+) for use',clauses['g'])[1]))
    if 'k' in clauses:
        parameters['equipment_parts_lists']=c_references(clauses['k'].split('that are in chapters')[0])
        parameters['equipment_parts_chapters']=re.findall(r'\d+',re.search(r'in chapters ([\d, or]+) of the HTSUS',clauses['k'])[1])
        cap=re.findall(r'(\d+) percent of the value',clauses['j'])
        if not cap or len(set(cap))!=1:raise ValueError('Unresolved US-content cap')
        parameters['us_content_cap_fraction']=int(cap[0])/100
    return parameters


def extract(pdf: Path, hts: Path, revision: str) -> dict:
    text = subprocess.check_output(['pdftotext', '-layout', str(pdf), '-'], text=True)
    verify_revision_header(text, revision)
    schedule = json.loads(hts.read_bytes())
    headings = [r for r in schedule if re.fullmatch(r'9903\.82\.\d{2}', r.get('htsno', ''))]
    result = dict(contract_version='sail.section232-note16-extraction/v1', revision=revision,
        extractor_sha256=sha(Path(__file__).read_bytes()),
        parser_dependency_sha256=sha(Path(__file__).with_name('section301_sources.py').read_bytes()),
        sources=[dict(path=str(p.resolve()), sha256=sha(p.read_bytes())) for p in (pdf, hts)],
        active_regime=bool(headings), lists=[], clauses=[], headings=[])
    if not headings:
        # Absence of this heading family is NOT absence of Section 232.
        return result
    result.update(extract_note16(text))
    result['parameters'] = note16_parameters(result)
    if len(headings) != len({r['htsno'] for r in headings}):
        raise ValueError('Duplicate note 16 reporting heading')
    for row in headings:
        expression = row.get('general', '').strip()
        surcharge = re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*(?:a duty of\s*)?([\d.]+)%', expression, re.I)
        floor = re.fullmatch(r'([\d.]+)%', expression)
        if surcharge:
            kind, rate = 'additional_ad_valorem', float(surcharge[1])/100
        elif floor:
            kind, rate = 'column1_floor', float(floor[1])/100
        elif expression.lower() == 'no change':
            kind, rate = 'no_change', 0
        else:
            raise ValueError('Unsupported note 16 duty expression: '+expression)
        result['headings'].append(dict(code=row['htsno'], description=row['description'],
            duty_expression=expression, formula_kind=kind, rate=rate,
            list_ids=c_references(row['description']),
            source_row_sha256=sha(json.dumps(row, sort_keys=True).encode())))
    # The April 29 notice expressly reaches April 6 entries. Earlier snapshots
    # lack the new reporting heading; absence from that snapshot is not a legal
    # reason to leave the corrected historical heading unavailable.
    root = Path(__file__).resolve().parents[1]
    correction = root/'resources/legal_evidence/2026-08297/notice.txt'
    correction_meta=json.loads(correction.with_name('source.json').read_bytes())
    if correction_meta['sha256'] != sha(correction.read_bytes()):
        raise ValueError('Note 16 correction source hash mismatch')
    correction_text = correction.read_text()
    flat = ' '.join(correction_text.split())
    if not all(s in flat for s in ('on or after 12:01 a.m. Eastern Time on April 6, 2026',
        '9903.82.01', 'No change', 'do not contain any aluminum, steel, or copper')):
        raise ValueError('Unrecognized retroactive note 16 correction')
    result['additional_sources'] = [dict(id='FR-2026-08297',path=str(correction),
        sha256=sha(correction.read_bytes()),url='https://www.govinfo.gov/content/pkg/FR-2026-04-29/html/2026-08297.htm',
        citation='91 FR 23056-23057; Annex 1(A), effective April 6, 2026 00:01 Eastern; UK Tata Steel clarification.')]
    result['amendments'] = [dict(source_id='FR-2026-08297',valid_from='2026-04-06T00:01:00-04:00',
        reporting_code='9903.82.01',effect='retroactive_insertion',
        native_heading_present=any(h['code']=='9903.82.01' for h in result['headings']))]
    if not result['amendments'][0]['native_heading_present']:
        result['headings'].append(dict(code='9903.82.01',
            description='Articles provided for in subdivision (c) of U.S. note 16 to this subchapter that do not contain any aluminum, steel, or copper.',
            duty_expression='No change',formula_kind='no_change',rate=0,list_ids=[],
            source_row_sha256=sha(correction.read_bytes()),amendment_source_id='FR-2026-08297'))
    result['headings'].sort(key=lambda h:h['code'])
    result['external_headings'] = []
    for code in ('9903.85.67','9903.85.68'):
        rows=[r for r in schedule if r.get('htsno')==code]
        if len(rows)!=1:raise ValueError('Missing Russian-aluminum heading '+code)
        row=rows[0]
        rate=re.fullmatch(r'The duty provided in the applicable subheading\s*\+\s*([\d.]+)%',row.get('general','').strip())
        if not rate or 'Russia' not in row['description']:raise ValueError('Unreviewed Russian-aluminum formula')
        result['external_headings'].append(dict(code=code,description=row['description'],
            duty_expression=row['general'],formula_kind='additional_ad_valorem',rate=float(rate[1])/100,
            source_row_sha256=sha(json.dumps(row,sort_keys=True).encode())))
    # Note 19 remains printed with historical lists. Proclamation 11021 clause
    # 8 expressly retains the Russian-aluminum treatment for the new annexes;
    # record both, rather than treating a stale cross-reference as no heading.
    note19=unique_span(clean_pages(text),r'^\s*19\.\s*\(a\)',r'^\s*20\.\s*\(a\)')
    retained=unique_span(note19,r'^\s*\(m\)\s*\(A\)',r'^\s*\(n\)\s')
    if 'full value of the article' not in retained or '9903.85.68' not in retained:
        raise ValueError('Unparsed retained Russian-aluminum note')
    result['retained_note19_m']=dict(text=retained,sha256=sha(retained.encode()))
    # The ordinary modeled tier follows explicit references, not a maximum
    # across mutually exclusive headings. Claim/special headings remain intact
    # above and are not silently treated as unconditional rates.
    headings_by_code = {h['code']:h for h in result['headings']}
    clauses = {c['id']:c['text'] for c in result['clauses']}
    result['ordinary_tiers'] = []
    for code in ('9903.82.02','9903.82.09','9903.82.10'):
        heading = headings_by_code[code]
        ids = heading['list_ids'] or c_references(clauses['f'])
        if not ids:
            raise ValueError('Unresolved ordinary heading scope: '+code)
        result['ordinary_tiers'].append(dict(reporting_code=code,list_ids=ids,
            formula_kind=heading['formula_kind'],rate=heading['rate']))
    if set().union(*(set(t['list_ids']) for t in result['ordinary_tiers'])) != {s['id'] for s in result['lists']}:
        raise ValueError('Ordinary tiers do not account for the note 16 inventory')
    return result


def matches(extraction: dict, products: list[str]) -> list[dict]:
    """Return all source memberships, preserving exact statistical suffixes."""
    index: dict[str, list[str]] = {}
    for product in sorted(set(products)):
        if not re.fullmatch(r'\d{10}', product):
            raise ValueError('Invalid HTS10')
        for grain in (4, 6, 8, 10):
            index.setdefault(product[:grain], []).append(product)
    rows = []
    for scope in extraction['lists']:
        for prefix in scope['includes']:
            for product in index.get(prefix, []):
                rows.append(dict(hts10=product, scope_code=prefix, scope_grain=len(prefix),
                    list_id=scope['id'], metal=scope['metal'], derivative=scope['derivative'],
                    source_locator=scope['locator'], source_text_sha256=scope['source_text_sha256']))
    return sorted(rows, key=lambda r: (r['hts10'], r['list_id'], r['scope_code']))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--pdf', type=Path, required=True)
    p.add_argument('--hts', type=Path, required=True)
    p.add_argument('--revision', required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    args.output.write_text(json.dumps(extract(args.pdf,args.hts,args.revision),indent=2)+'\n')

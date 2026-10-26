"""Reconcile explicit USITC statistical-code events with build catalog windows.

Research/preflight evidence only. A change-record publication date, modal date,
missing endnote or missing event never supplies a duty rate or repeal date.
Wrapped/ambiguous rows remain reported rather than inferred from nearby rows.
"""
import argparse
import csv
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'src'))
from shipment_base_sources import extract_rows

ROW = re.compile(r'^\s*(\d{4}\.\d{2}\.\d{2}(?:\d{2})?)\s+'
                 r'(Established|Discontinued|Annotated|Restored|Added|Deleted)\b(.*)', re.I)
DATE = re.compile(r'\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}\b')


def parse_events(text, revision, source_sha256):
    events, unresolved = [], []
    for page, content in enumerate(text.split('\f'), 1):
        lines = content.splitlines()
        for offset, raw in enumerate(lines):
            row = ROW.match(unicodedata.normalize('NFKC', raw)); layout = 'same_line'; raw_lines = [raw]
            # Some ruled tables vertically center the short first-column code
            # beside a two-line nature cell. Only join an immediately preceding
            # otherwise code-free nature/date line, never a prior code's row.
            code_only = re.match(r'^\s*(\d{4}\.\d{2}\.\d{2}(?:\d{2})?)\s+(.*)', raw)
            if not row and code_only and offset:
                previous = lines[offset - 1]
                nature = re.match(r'^\s+(Established|Discontinued|Annotated|Restored|Added|Deleted)\b(.*)', previous, re.I)
                if nature and len(DATE.findall(previous)) == 1 and not DATE.search(raw):
                    row = ROW.match(code_only[1] + ' ' + previous.strip())
                    layout = 'centered_first_column'; raw_lines = [previous, raw]
            if not row:
                continue
            printed, action, tail = row.groups()
            code = printed.replace('.', '')
            dates = DATE.findall(tail)
            item = dict(code=code, printed_code=printed, action=action.lower(), revision=revision,
                        page=page, line=offset + 1, raw_line=raw, raw_lines=raw_lines,
                        extraction_layout=layout,source_sha256=source_sha256)
            if len(dates) != 1:
                unresolved.append(dict(**item, question='single explicit item effective date required'))
                continue
            try:
                item['effective_date'] = datetime.strptime(dates[0], '%B %d, %Y').date().isoformat()
            except ValueError:
                unresolved.append(dict(**item, question='invalid printed effective date'))
                continue
            item['printed_source'] = tail[tail.index(dates[0]) + len(dates[0]):].strip()
            # Only the ten-digit statistical-code roles are interpreted here.
            # Legal eight-digit changes require the actual instrument/annex.
            if len(code) == 10:
                item['present_after'] = action.lower() in ('established', 'restored', 'added')
                events.append(item)
            else:
                unresolved.append(dict(**item, question='legal rate-line change requires instrument and annex reconciliation'))
    return events, unresolved


def expectations(events, at):
    """Assert only explicit events; do not infer existence from missing records."""
    by_code = {}
    for e in events:
        by_code.setdefault(e['code'], []).append(e)
    result, conflicts = {}, []
    for code, rows in by_code.items():
        prior = [e for e in rows if e['effective_date'] <= at]
        if prior:
            day = max(e['effective_date'] for e in prior)
            selected = [e for e in prior if e['effective_date'] == day]
        else:
            # An explicit first establishment forbids pre-establishment use;
            # a future discontinuation does not prove prior existence.
            day = min(e['effective_date'] for e in rows)
            selected = [e for e in rows if e['effective_date'] == day]
            if not all(e['action'] in ('established','added') for e in selected):
                continue
        values = {e['present_after'] for e in selected}
        if len(values) != 1:
            conflicts.append(dict(code=code, effective_date=day, evidence=selected))
            continue
        result[code] = dict(present=next(iter(values)) if prior else False, evidence=selected)
    return result, conflicts


def audit(root=ROOT):
    calendar = root / 'config/revision_dates.csv'
    rows = [r for r in csv.DictReader(calendar.open()) if r['revision'].startswith(('2025_', '2026_'))]
    policy = sorted(rows, key=lambda r: r['effective_date'] if r['policy_effective_date'] in ('', 'NA') else r['policy_effective_date'])
    events, unresolved, sources = [], [], []
    for r in rows:
        release = r['revision'].replace('_basic', 'HTSBasic').replace('_rev_', 'HTSRev')
        p = root / 'data/hts_change_record' / (release + '_change_record.pdf')
        if not p.exists():
            unresolved.append(dict(revision=r['revision'], question='missing USITC change record'))
            continue
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        text = subprocess.check_output(['pdftotext', '-layout', str(p), '-'], text=True)
        header = unicodedata.normalize('NFKC', text[:500])
        year = r['revision'][:4]
        expected = f'{year} Revision {r["revision"].split("_rev_")[1]}' if '_rev_' in r['revision'] else year
        if not re.search(re.escape(expected) + r'(?!\d)', header):
            raise ValueError('Change-record identity mismatch: ' + str(p))
        e, q = parse_events(text, r['revision'], digest)
        events.extend(e); unresolved.extend(q)
        sources.append(dict(revision=r['revision'], path=str(p.relative_to(root)), sha256=digest,
                            url=f'https://hts.usitc.gov/reststop/file?release={release}&filename=Change%20Record',
                            parsed_statistical_events=len(e), other_or_unresolved_rows=len(q)))
    findings, conflicts = [], []
    cutoff = '2026-10-23'
    for i, r in enumerate(policy):
        start = r['effective_date'] if r['policy_effective_date'] in ('', 'NA') else r['policy_effective_date']
        n = policy[i + 1] if i + 1 < len(policy) else None
        end = min(cutoff, (n['effective_date'] if n['policy_effective_date'] in ('', 'NA') else n['policy_effective_date']) if n else cutoff)
        if start >= end:
            continue
        p = root / 'data/hts_archives' / f'hts_{r["revision"]}.json'
        native = extract_rows(json.loads(p.read_bytes()))
        inventory = {p['hts10'] for p in native['products'] + native['special_classifications']}
        boundaries = sorted({start, end} | {e['effective_date'] for e in events if start < e['effective_date'] < end})
        mismatches = []
        for a, b in zip(boundaries, boundaries[1:]):
            expected, ambiguous = expectations(events, a)
            conflicts.extend(ambiguous)
            for code, item in expected.items():
                if (code in inventory) != item['present']:
                    mismatches.append(dict(hts10=code, from_=a, until=b,status='requires_reconciliation',
                        native_present=code in inventory, expected_present=item['present'], evidence=item['evidence']))
        findings.append(dict(revision=r['revision'], from_=start, until=end,
                             native_sha256=hashlib.sha256(p.read_bytes()).hexdigest(), mismatches=mismatches))
        print(r['revision'], len(mismatches), flush=True)
    conflicts = list({(c['code'],c['effective_date']):c for c in conflicts}.values())
    return dict(contract_version='sail.classification-chronology-audit/v1',
                calendar_sha256=hashlib.sha256(calendar.read_bytes()).hexdigest(), sources=sources,
                events=events, revisions=findings, unresolved_rows=unresolved, conflicts=conflicts,
                legal_coverage_complete=False,
                limitations=['Only explicit statistical-code lifecycle events are evaluated.',
                    'Not a complete classification validity inventory; no missing event proves absence or validity.',
                    'An establishment/discontinuation can also change the goods represented by a reused identifier. A mismatch is a question, not an automatic renumbering or invalidity decision.',
                    'Chapter99, eight-digit legal changes, staged duties and endnotes require independent original-instrument reconciliation.'])


if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--output', type=Path, required=True); args = p.parse_args()
    with args.output.open('x') as stream:
        json.dump(audit(), stream, indent=2); stream.write('\n')

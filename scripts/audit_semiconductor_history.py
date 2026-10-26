#!/usr/bin/env python3
"""All-revision source reconciliation; does not calculate or rebuild rate data."""
import csv
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'src'))
from section232_semiconductors import extract, compile_rules, load_history, sha

if __name__ == '__main__':
    target = Path(sys.argv[1])
    if target.exists():
        raise SystemExit('Use a new output file')
    rows = []
    for row in csv.DictReader((ROOT/'config/revision_dates.csv').open()):
        revision = row['revision']
        if not revision.startswith(('2025_', '2026_')):
            continue
        pdf = ROOT/f'data/us_notes/chapter99_{revision}.pdf'
        hts = ROOT/f'data/hts_archives/hts_{revision}.json'
        products = sorted({r['htsno'].replace('.','') for r in json.loads(hts.read_bytes())
                           if len(r.get('htsno','').replace('.',''))==10})
        x = extract(pdf, hts, revision)
        fragment = compile_rules(x, products)
        rows.append(dict(revision=revision,sources=x['sources'],native_note_present=bool(x['clauses']),
            native_headings=len(x['headings']),compiled_rules=len(fragment['rules']),
            candidate_products=fragment['rules'][0]['scope']['hts_exact'] if fragment['rules'] else [],
            rule_sha256=sha(json.dumps(fragment,sort_keys=True).encode()),coverage_granted=False))
        print(revision, rows[-1]['native_headings'], len(rows[-1]['candidate_products']),flush=True)
    history=load_history()
    target.write_text(json.dumps(dict(kind=__doc__,compiler_sha256=sha((ROOT/'src/section232_semiconductors.py').read_bytes()),
        sources=history['sources'],periods=[{k:v for k,v in p.items() if k!='clause_a'} for p in history['periods']],
        revisions=rows),indent=2)+'\n')

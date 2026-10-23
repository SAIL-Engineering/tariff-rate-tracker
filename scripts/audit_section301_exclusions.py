"""Audit all revision-bound exclusion candidates without rebuilding rates.

First emit source-derived candidates for a read-only MotherDuck selection. With
--snapshot, compare only candidate attribution, never assert shipment eligibility.
"""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import gzip
import importlib.util
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('s301',ROOT/'src/section301_sources.py')
parser=importlib.util.module_from_spec(spec);spec.loader.exec_module(parser)


def revision_scope(row):
    revision=row['revision'];pdf=ROOT/'data/us_notes'/f'chapter99_{revision}.pdf'
    hts=ROOT/'data/hts_archives'/f'hts_{revision}.json'
    text=subprocess.check_output(['pdftotext','-layout',str(pdf),'-']).decode()
    parser.verify_revision_header(text,revision)
    data=json.loads(hts.read_text());x=parser.extract(text,data,revision)
    products={r['htsno'].replace('.','') for r in data if len(r.get('htsno','').replace('.',''))==10}
    prefix=defaultdict(set)
    for p in products: prefix[p[:8]].add(p)
    expand=lambda codes: set().union(*(prefix[c] if len(c)==8 else {c}&products for c in codes))
    instant=lambda s: datetime.fromisoformat(s.replace('Z','+00:00'))
    at=instant(row['valid_from']+'T23:59:59Z')
    active=lambda a: (not a.get('valid_from') or at>=instant(a['valid_from'])) and (not a.get('valid_until') or at<instant(a['valid_until']))
    charges={}
    for action in x['actions']:
        if not active(action): continue
        selected=set()
        for scope in action['scopes']:
            selected.update(expand(scope['includes'])-expand(scope['excludes']))
        charges[action['reporting_code']]=selected
    candidates={};all_codes=set();boundaries=set()
    for record in x['exclusions']['records']:
        for binding in record['bindings']:
            all_codes.update(expand(binding['codes']))
            boundaries.update(binding[k] for k in ['valid_from','valid_until'] if binding[k])
        windows=x['exclusions']['windows'][record['reporting_code']]
        boundaries.update(w[k] for w in windows for k in ['valid_from','valid_until','possible_from','possible_until'])
        if not any(instant(w['possible_from'])<=at<instant(w['possible_until']) for w in windows): continue
        charged=set().union(*(charges.get(c,set()) for c in record['target_reporting_codes']))
        for binding in record['bindings']:
            if not active(binding): continue
            for code in charged & expand(binding['codes']):
                candidates.setdefault(code,{}).setdefault(record['reporting_code'],[]).append(record['locator'])
    return dict(revision=revision,entry_at=at.isoformat(),pdf_sha256=parser.sha(pdf.read_bytes()),
      hts_sha256=parser.sha(hts.read_bytes()),records=len(x['exclusions']['records']),
      source_ids=sorted(s['id'] for s in x['exclusions']['sources']),
      boundaries=sorted(boundaries),candidate_products=len(candidates),
      candidate_pairs=sum(len(c) for c in candidates.values()),candidates=candidates),all_codes


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--snapshot',type=Path)
    args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    version=parser.sha((ROOT/'src/section301_sources.py').read_bytes())
    revisions=json.loads((ROOT/'docs/audits/2026-10-23-motherduck/revisions.json').read_text())['rows']
    results=list(ThreadPoolExecutor(max_workers=4).map(revision_scope,revisions))
    selection=sorted(set().union(*(codes for _,codes in results)))
    report=dict(extractor_sha256=version,audit_script_sha256=parser.sha(Path(__file__).read_bytes()),
      revisions=[r for r,_ in results],selection_hts10=selection,
      limitations=['Candidate attribution comparison only; no assumption of claim eligibility.',
        'Source-defined boundaries enumerated; revision-day comparison is not an exhaustive shipment-fact sweep.'])
    if args.snapshot:
        raw=gzip.decompress(args.snapshot.read_bytes());snapshot=json.loads(raw)
        if snapshot['access_mode']!='READ_ONLY' or snapshot['mode']!='exclusions': raise ValueError('Expected exclusion read-only snapshot')
        expected={r['revision']:r for r,_ in results};changes=[];counts=Counter();seen=set()
        for row in snapshot['rows']:
            key=(row['revision'],row['hts10'])
            if key in seen: raise ValueError('Duplicate stored identity')
            seen.add(key)
            source=expected[row['revision']]
            if row['valid_from']!=source['entry_at'][:10]: raise ValueError('Changed revision interval')
            old={r['ch99_code'] for r in json.loads(row['ch99_rules_json'] or '[]') if r.get('program')=='s301_exclusion'}
            new=set(source['candidates'].get(row['hts10'],{}))
            counts['rows_compared']+=1;counts['added_candidates']+=len(new-old);counts['removed_candidates']+=len(old-new)
            if old!=new:
                counts['changed_rows']+=1
                changes.append(dict(revision=key[0],hts10=key[1],old=sorted(old),new=sorted(new),locators=source['candidates'].get(key[1],{})))
        if any((r['revision'],p) not in seen for r,_ in results for p in r['candidates']): raise ValueError('Snapshot omits expected candidate rows')
        report.update(snapshot_sha256=parser.sha(raw),snapshot_started_at=snapshot['started_at'],snapshot_finished_at=snapshot['finished_at'],counts=dict(counts))
        (args.out/'differences.json').write_text(json.dumps(changes,indent=2)+'\n')
    if version!=parser.sha((ROOT/'src/section301_sources.py').read_bytes()): raise ValueError('Extractor changed during audit')
    (args.out/'scope.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(revisions=len(results),selection_products=len(selection),candidate_pairs=sum(r['candidate_pairs'] for r,_ in results),**report.get('counts',{}))))

if __name__=='__main__':main()

"""Compare source reconstruction with a read-only MotherDuck snapshot.

No rates, revisions, time series, or production database are built/modified.
Only the China technology-transfer charge is compared. Conditional product
descriptions are reported separately from unconditional charge differences.
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

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('s301',ROOT/'src/section301_sources.py')
parser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(parser)
EXTRACTOR_SHA=parser.sha((ROOT/'src/section301_sources.py').read_bytes())


def compare_revision(revision, rows, root):
    pdf=root/'data/us_notes'/f'chapter99_{revision}.pdf'
    hts=root/'data/hts_archives'/f'hts_{revision}.json'
    raw=subprocess.check_output(['pdftotext','-layout',str(pdf),'-']).decode()
    parser.verify_revision_header(raw,revision)
    data=json.loads(hts.read_text())
    extracted=parser.extract(raw,data,revision)
    products={r['htsno'].replace('.','') for r in data if len(r.get('htsno','').replace('.',''))==10}
    by_prefix=defaultdict(set)
    for p in products: by_prefix[p[:8]].add(p)
    at=datetime.fromisoformat(rows[0]['valid_from']+'T23:59:59+00:00')
    assert len({r['valid_from'] for r in rows})==1
    matches=defaultdict(list)
    for action in extracted['actions']:
        if action['valid_from'] and at<datetime.fromisoformat(action['valid_from']): continue
        if action['valid_until'] and at>=datetime.fromisoformat(action['valid_until']): continue
        for scope in action['scopes']:
            included=set()
            for c in scope['includes']:
                included.update(by_prefix[c] if len(c)==8 else ({c} & products))
            for p in included:
                if any(p.startswith(e) for e in scope['excludes']): continue
                matches[p].append((action,scope))
    conflicts={p:sorted({a['reporting_code'] for a,_ in pairs if a['program']=='china_technology_transfer'}) for p,pairs in matches.items()
               if len({a['reporting_code'] for a,_ in pairs if a['program']=='china_technology_transfer'})>1}
    if conflicts: raise ValueError(f'{revision}: overlapping charge actions: {conflicts}')
    if len({r['hts10'] for r in rows})!=len(rows): raise ValueError('Duplicate stored revision/product')
    changes=[]; counts=Counter(); comparisons=Counter()
    for r in rows:
        p=r['hts10']; pairs=[x for x in matches.get(p,[]) if x[0]['program']=='china_technology_transfer']
        counts['maritime_candidates']+=any(x[0]['program']=='maritime' for x in matches.get(p,[]))
        rate=pairs[0][0]['rate'] if pairs else 0
        heading=pairs[0][0]['reporting_code'] if pairs else None
        conditional=bool(pairs) and all(s['condition_text'] is not None for _,s in pairs)
        counts['stored_rows']+=1
        counts['source_matched_rows']+=bool(pairs)
        counts['conditional_rows']+=conditional
        model_changed=r['rate_301'] is None or abs(r['rate_301']-rate)>1e-9
        statutory_changed=conditional and r['statutory_rate_301'] is not None or not conditional and (
            r['statutory_rate_301'] is None or abs(r['statutory_rate_301']-rate)>1e-9)
        heading_changed=(r['ch99_code_301'] or None)!=heading
        counts['modeled_rate_changes']+=model_changed
        counts['statutory_rate_or_completeness_changes']+=statutory_changed
        counts['reporting_heading_changes']+=heading_changed
        if model_changed or statutory_changed or heading_changed:
            changes.append(dict(**r,source_charge_rate=rate,source_reporting_code=heading,
              scope_status='needs_inputs' if conditional else 'unconditional_charge_scope',
              locators=sorted({s['locator'] for _,s in pairs}),
              conditions=sorted({s['condition_text'] for _,s in pairs if s['condition_text']})))
            comparisons[(r['rate_301'],rate,conditional)]+=1
    return dict(revision=revision,entry_day=rows[0]['valid_from'],counts=dict(counts),
      pdf_sha256=parser.sha(pdf.read_bytes()),hts_sha256=parser.sha(hts.read_bytes()),
      charge_inventory=extracted['charge_inventory'],
      rate_changes=[dict(old=k[0],new=k[1],conditional=k[2],count=v) for k,v in sorted(comparisons.items(),key=str)]),changes


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--snapshot',type=Path,required=True)
    p.add_argument('--out',type=Path,required=True)
    args=p.parse_args()
    args.out.mkdir(parents=True,exist_ok=False)
    raw=gzip.decompress(args.snapshot.read_bytes())
    snapshot=json.loads(raw)
    if snapshot['access_mode']!='READ_ONLY': raise ValueError('Expected a read-only snapshot')
    groups=defaultdict(list)
    for row in snapshot['rows']: groups[row['revision']].append(row)
    results=list(ThreadPoolExecutor(max_workers=4).map(lambda r:compare_revision(r,groups[r],ROOT),sorted(groups)))
    counts=Counter(); changes=[]
    for report,rows in results:
        counts.update(report['counts']);changes.extend(rows)
    if EXTRACTOR_SHA!=parser.sha((ROOT/'src/section301_sources.py').read_bytes()):
        raise ValueError('Extractor changed during audit; rerun with a stable source version')
    report=dict(snapshot_sha256=parser.sha(raw),extractor_sha256=EXTRACTOR_SHA,
      audit_script_sha256=parser.sha(Path(__file__).read_bytes()),database=snapshot['database'],
      started_at=snapshot['started_at'],finished_at=snapshot['finished_at'],
      counts=dict(counts),revisions=[r for r,_ in results],
      limitations=['Compares the unclaimed China technology-transfer charge, not the entire duty stack.',
        'Conditional rates are aggregate assumptions; shipment liability requires the preserved description.',
        'No exclusion or Chapter 98 claim has been priced by this comparison.',
        'Stored revision days are compared at end of day; intraday boundaries are tested separately.'])
    (args.out/'comparison.json').write_text(json.dumps(report,indent=2)+'\n')
    (args.out/'differences.json.gz').write_bytes(gzip.compress(json.dumps(changes).encode(),mtime=0))
    print(json.dumps(dict(revisions=len(results),**counts),indent=2))


if __name__=='__main__': main()

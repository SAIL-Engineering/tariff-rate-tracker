"""Source-only note 16 audit and optional read-only MotherDuck reconciliation.

This does not run a revision/timeseries build. Scope disagreement is not a
replacement total: shipment predicates and other authorities remain necessary.
"""
import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
import gzip
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from section232_sources import extract, matches, sha


def audit_revision(rev):
    pdf=ROOT/'data/us_notes'/f'chapter99_{rev}.pdf'
    hts=ROOT/'data/hts_archives'/f'hts_{rev}.json'
    x=extract(pdf,hts,rev)
    products=sorted({r['htsno'].replace('.','') for r in json.loads(hts.read_bytes())
                     if len(r.get('htsno','').replace('.',''))==10 and r['htsno'][:2]<'98'})
    members=matches(x,products)
    by_hts=defaultdict(list)
    tiers={i:t['reporting_code'] for t in x.get('ordinary_tiers',[]) for i in t['list_ids']}
    labels={'9903.82.02':'annex_1a','9903.82.09':'annex_1b','9903.82.10':'annex_3'}
    for row in members:by_hts[row['hts10']].append(row)
    scopes={}
    for hts,rows in by_hts.items():
        codes={tiers[r['list_id']] for r in rows}
        if len(codes)!=1:raise ValueError('Conflicting ordinary tiers: '+rev+'/'+hts)
        code=next(iter(codes))
        scopes[hts]=dict(tier=labels[code],ordinary_reporting_code=code,
            metals=sorted({r['metal'] for r in rows}),list_ids=sorted({r['list_id'] for r in rows}),
            source_locators=sorted({r['source_locator'] for r in rows}))
    report=dict(revision=rev,active_regime=x['active_regime'],products=len(products),
        members=len(members),matched_products=len(scopes),mixed_metal_products=sum(len(s['metals'])>1 for s in scopes.values()),
        list_counts={s['id']:len(s['includes']) for s in x['lists']},headings=len(x['headings']),
        sources=x['sources'],extractor_sha256=x['extractor_sha256'],parser_dependency_sha256=x['parser_dependency_sha256'])
    return report,scopes


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--snapshot',type=Path)
    args=p.parse_args();args.out.mkdir(parents=True,exist_ok=False)
    revisions=(ROOT/'docs/audits/2026-10-23-motherduck/rebuild-revisions.txt').read_text().strip().split(',')
    results=list(ThreadPoolExecutor(max_workers=4).map(audit_revision,revisions))
    report=dict(audit_script_sha256=sha(Path(__file__).read_bytes()),revisions=[r for r,_ in results])
    if args.snapshot:
        raw=gzip.decompress(args.snapshot.read_bytes());snap=json.loads(raw)
        if snap['access_mode']!='READ_ONLY':raise ValueError('Expected read-only audit snapshot')
        scope_by_rev={r['revision']:sc for r,sc in results}
        changes=[];totals=Counter();by_rev=defaultdict(Counter)
        for row in snap['results']['scope']:
            rev=row['revision'];scope=scope_by_rev[rev].get(row['hts10'])
            expected=scope['tier'] if scope else 'outside_note16_scope'
            actual=row['s232_annex'] if row['s232_annex'] not in (None,'annex_2') else 'outside_note16_scope'
            issues=[]
            if expected!=actual:issues.append('scope_or_tier_mismatch')
            if scope and set(scope['metals'])!={row['s232_metal']}:issues.append('incomplete_or_wrong_metal_membership')
            totals['stored_rows']+=row['row_count']
            if issues:
                changes.append(dict(stored=row,source=scope,issues=issues))
                for key in issues:
                    totals[key]+=row['row_count'];by_rev[rev][key]+=row['row_count']
        report.update(snapshot_sha256=sha(raw),started_at=snap['started_at'],finished_at=snap['finished_at'],
            database=snap['database'],counts=dict(totals),by_revision={k:dict(v) for k,v in by_rev.items()},
            attribution_totals={k:sum(r[k] for r in snap['results']['attribution']) for k in
                ('row_count','action_total_disagreement','positive_without_reporting_code')})
        (args.out/'differences.json.gz').write_bytes(gzip.compress((json.dumps(changes)+'\n').encode(),mtime=0))
    (args.out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report.get('counts',dict(revisions=len(results),active_revisions=sum(r['active_regime'] for r,_ in results)))))


if __name__=='__main__':main()

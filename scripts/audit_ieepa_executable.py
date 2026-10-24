#!/usr/bin/env python3
"""All configured revision source/compiler audit; no timeseries build or DB I/O."""
import argparse,csv,gzip,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT/'src'))
from ieepa_fentanyl_sources import extract
from ieepa_emergency_rules import compile_emergency
from section301_sources import sha


def main():
    p=argparse.ArgumentParser();p.add_argument('output',type=Path);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=False)
    revisions=(ROOT/'docs/audits/2026-10-23-motherduck/rebuild-revisions.txt').read_text().strip().split(',')
    reports=[];deps=['src/ieepa_emergency_rules.py','src/ieepa_fentanyl_sources.py','src/chapter98_rules.py','src/section232_stacking.py','resources/legal_evidence/ieepa-emergency/reviewed-semantics.json']
    hashes={p:sha((ROOT/p).read_bytes()) for p in deps}
    for rev in revisions:
        pdf=ROOT/f'data/us_notes/chapter99_{rev}.pdf';hts=ROOT/f'data/hts_archives/hts_{rev}.json'
        x=extract(pdf,hts,rev)
        # Every product uses the same country-wide emergency rules. Compile the
        # entire valid HTS10 inventory, not a hand-picked example tariff line.
        products=[r['htsno'].replace('.','') for r in json.loads(hts.read_bytes()) if len(r.get('htsno','').replace('.',''))==10 and r['htsno'][:2]<'98']
        f=compile_emergency(x,products)
        reports.append(dict(revision=rev,products=len(set(products)),rule_count=len(f['rules']),
            source_versions=[dict(id=s['id'],sha256=s['sha256']) for s in f['sources']],
            supported_from=f['supported_from'],supported_until=f['supported_until'],
            rule_sha256=sha(json.dumps(f['rules'],sort_keys=True,separators=(',',':')).encode()),
            windows=sorted({(r['scope']['from'],r['scope']['until']) for r in f['rules']}),
            reportable_headings=sorted({c for r in f['rules'] for c in r['reporting_codes']}),
            no_full_coverage_attestation=not f['coverage']))
        print(rev,len(products),len(f['rules']),flush=True)
    if hashes!={p:sha((ROOT/p).read_bytes()) for p in deps}:raise ValueError('Compiler changed during audit')
    report=dict(revision_count=len(reports),compiled_rules=sum(r['rule_count'] for r in reports),revisions=reports,
        compiler_versions=hashes,timeseries_rebuilt=False,complete_legal_coverage=False)
    (a.output/'report.json').write_text(json.dumps(report,indent=2)+'\n')

if __name__=='__main__':main()

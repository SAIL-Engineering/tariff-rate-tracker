#!/usr/bin/env python3
"""Source-only scope sweep. Does not calculate a timeseries or write MotherDuck."""
import argparse,csv,json,sys
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from ieepa_reciprocal_sources import extract,ROOT
from ieepa_reciprocal_history import active_rows
from section301_sources import sha


def products(schedule):
    codes={r.get('htsno','').replace('.','') for r in schedule}
    full={c for c in codes if c.isdigit() and len(c)==10}
    return sorted(full|{c+'00' for c in codes if c.isdigit() and len(c)==8 and not any(p.startswith(c) for p in full)})


def audit(out,revisions):
    out.mkdir(parents=True,exist_ok=False)
    dates={r['revision']:r['policy_effective_date'] if r['policy_effective_date']!='NA' else r['effective_date']
        for r in csv.DictReader((ROOT/'config/revision_dates.csv').open())}
    legacy=list(csv.DictReader((ROOT/'resources/ieepa_exempt_products.csv').open()))
    summary=[];differences=[];artifacts=[]
    for rev in revisions:
        x=extract(ROOT/f'data/us_notes/chapter99_{rev}.pdf',ROOT/f'data/hts_archives/hts_{rev}.json',rev)
        p=out/(rev+'.json');p.write_text(json.dumps(x,separators=(',',':'))+'\n')
        artifacts.append(dict(path=p.name,sha256=sha(p.read_bytes())))
        valid=products(json.loads((ROOT/f'data/hts_archives/hts_{rev}.json').read_bytes()))
        at=datetime.fromisoformat(dates[rev]).replace(hour=12,tzinfo=ZoneInfo('America/New_York')).isoformat()
        active=active_rows(x['history'],at)
        actual={p for p in valid if any(p.startswith(r['scope_code']) for r in active if r['condition']=='none')}
        conditional={p for p in valid if any(p.startswith(r['scope_code']) for r in active if r['condition']!='none')}-actual
        def in_window(r):
            a,b=r.get('effective_date_start',''),r.get('effective_date_end','')
            return (a in ('','NA') or a<=dates[rev]) and (b in ('','NA') or dates[rev]<=b)
        old={r['hts10'] for r in legacy if r.get('source') in ('annex_ii','ita') and in_window(r)}&set(valid)
        active_regime=x['history']['valid_from']<=at<x['history']['valid_until']
        extra,miss=(old-actual,actual-old) if active_regime else (set(),set())
        differences.extend(dict(revision=rev,entry_day=dates[rev],hts10=p,kind=k) for k,items in [('unsupported_legacy_unconditional',extra),('missing_legacy_exemption',miss)] for p in sorted(items))
        summary.append(dict(revision=rev,entry_day=dates[rev],native_codes=len(x['products']),unconditional_products=len(actual),conditional_products=len(conditional),
            extra_legacy=len(extra),missing_legacy=len(miss),reconciliation=x['reconciliation']))
        print(rev,len(extra),len(miss),flush=True)
    (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    with (out/'scope-differences.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=['revision','entry_day','hts10','kind']);w.writeheader();w.writerows(differences)
    (out/'manifest.json').write_text(json.dumps(dict(contract_version='sail.reciprocal-scope-audit/v1',
        compiler_sha256=sha(Path(__file__).read_bytes()),legacy_csv_sha256=sha((ROOT/'resources/ieepa_exempt_products.csv').read_bytes()),
        artifacts=artifacts,limitation='Scope comparison only. Not a duty-stack oracle or release qualification.'),indent=2)+'\n')

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',required=True,type=Path);p.add_argument('--revisions',type=Path,
        default=ROOT/'docs/audits/2026-10-23-motherduck/rebuild-revisions.txt');a=p.parse_args()
    audit(a.out,a.revisions.read_text().strip().split(','))

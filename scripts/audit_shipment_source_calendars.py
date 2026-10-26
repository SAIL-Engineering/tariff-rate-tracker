"""Compare policy-selected native schedules with the overlapping raw-source calendar.

Dates select comparison snapshots, not statutory effectiveness. Differences need
original-instrument reconciliation; agreement does not certify complete law.
No rates, cached revisions, databases or workflows are written.
"""
import argparse,csv,hashlib,json,sys,re,html
from datetime import date
from functools import lru_cache
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
from shipment_base_sources import extract_rows

def digest(x):return hashlib.sha256(json.dumps(x,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
def text(x):
 s=html.unescape(x or '')
 s=re.sub(r'</?(?:i|il|b|u|sup|sub|strong|em)\s*>','',s,flags=re.I)
 s=re.sub(r'<br\s*/?>',' ',s,flags=re.I)
 return ' '.join(s.split())
@lru_cache(maxsize=3)
def inventory(revision):
 p=ROOT/f'data/hts_archives/hts_{revision}.json';data=p.read_bytes();x=extract_rows(json.loads(data));out={}
 for r in x['products']+x['special_classifications']:
  fields={}
  for k in ('general','column2','special'):
   fields[k+'_expression']=digest(dict(expression=text(r[k]['expression']),owner=r[k]['source_code']))
   column={'general':'general','column2':'other','special':'special'}[k]
   notes=[{**n,'value':text(n.get('value'))} for n in r[k]['footnotes'] if not n.get('columns') or column in n['columns']]
   fields[k+'_annotations']=digest(notes)
  fields['classification']=digest([dict(code=n['code'],description=text(n['description'])) for n in r['classification_path']])
  out[r['hts10']]=fields
 return dict(sha256=hashlib.sha256(data).hexdigest(),products=out)
def run():
 rows=[r for r in csv.DictReader((ROOT/'config/revision_dates.csv').open()) if r['revision'].startswith(('2025_','2026_'))]
 raw=sorted(rows,key=lambda r:r['effective_date']);policy=sorted(rows,key=lambda r:r['effective_date'] if r['policy_effective_date'] in ('','NA') else r['policy_effective_date'])
 cutoff='2026-10-23';result=[]
 for i,r in enumerate(policy):
  start=r['effective_date'] if r['policy_effective_date'] in ('','NA') else r['policy_effective_date']
  end=(policy[i+1]['effective_date'] if policy[i+1]['policy_effective_date'] in ('','NA') else policy[i+1]['policy_effective_date']) if i+1<len(policy) else cutoff
  end=min(end,cutoff)
  if start>=end:continue
  target=inventory(r['revision']);comparisons=[]
  for j,s in enumerate(raw):
   stop=raw[j+1]['effective_date'] if j+1<len(raw) else cutoff
   if s['effective_date']>=end or stop<=start:continue
   other=inventory(s['revision']);changes=[]
   for h in sorted(set(target['products'])|set(other['products'])):
    a=target['products'].get(h);b=other['products'].get(h)
    if a==b:continue
    fields=['product_presence'] if a is None or b is None else [k for k in a if a[k]!=b[k]]
    changes.append(dict(hts10=h,changed=fields,requested_source=a,comparison_source=b))
   comparisons.append(dict(revision=s['revision'],raw_source_date=s['effective_date'],from_=max(start,s['effective_date']),until=min(end,stop),sha256=other['sha256'],differences=changes))
  result.append(dict(revision=r['revision'],policy_frame_from=start,policy_frame_until=end,requested_raw_source_date=r['effective_date'],sha256=target['sha256'],comparisons=comparisons))
  print(r['revision'],[(c['revision'],len(c['differences'])) for c in comparisons],flush=True)
 return dict(role='snapshot_comparison_not_legal_effective_dates',legal_coverage_complete=False,calendar_sha256=hashlib.sha256((ROOT/'config/revision_dates.csv').read_bytes()).hexdigest(),revisions=result)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);args=p.parse_args()
 if args.output.exists():raise SystemExit('Use a new output path')
 args.output.write_text(json.dumps(run(),indent=2)+'\n')

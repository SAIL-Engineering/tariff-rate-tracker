import argparse,json,re,subprocess
from pathlib import Path
parser=argparse.ArgumentParser();parser.add_argument('--node',required=True);parser.add_argument('--out',required=True,type=Path);args=parser.parse_args()
root=Path.cwd();out=args.out;out.mkdir(parents=True,exist_ok=True);node=args.node
version=subprocess.check_output([node,'--version'],text=True).strip()
rows=[]
with (out/'node-complete-final.log').open('w') as log:
 for p in sorted((root/'frontend/tests').glob('*.test.mjs')):
  r=subprocess.run([node,str(p)],cwd=root/'frontend',stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  log.write(str(p.relative_to(root))+'\n'+r.stdout+'\n');log.flush()
  counts={k:int(v) for k,v in re.findall(r'^# (tests|pass|fail|cancelled|skipped) ([0-9]+)$',r.stdout,re.M)}
  rows.append(dict(file=str(p.relative_to(root)),exit_code=r.returncode,**counts))
summary=dict(node=version,files=rows,totals={k:sum(x.get(k,0) for x in rows) for k in ['tests','pass','fail','cancelled','skipped']})
(out/'node-complete-final-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary['totals']))
raise SystemExit(1 if any(x['exit_code'] or x.get('fail',0) or not x.get('tests') for x in rows) else 0)

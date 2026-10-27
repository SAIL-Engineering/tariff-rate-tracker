#!/usr/bin/env python3
"""One-command WJR diagnostic; --prepare-only never runs a revision build."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
import queue
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ['src','config','resources','scripts','tests','tariff-rate-tracker.Rproj',
           'docs/audits',
           'frontend/server','frontend/migrations','frontend/scripts',
           'frontend/package.json','frontend/package-lock.json',
           'data/countries-ISO-3166-1-alpha-2.json','data/hts_change_record']
PRIMARY = ['data/hts_archives','data/us_notes','data/cache/general_notes']
SOURCE_CONTRACT = 'sail.shipment-diagnostic-source/v2'
HEARTBEAT_SECONDS = 10
REVISIONS = ['2025_rev_11','2026_rev_19']


def elapsed(start):
    minutes,seconds=divmod(int(time.monotonic()-start),60)
    return f'{minutes:02}:{seconds:02}'


def show_progress(event,start):
    total=event.get('total');done=event.get('completed')
    counted=isinstance(total,int) and total>0 and isinstance(done,int) and 0<=done<=total
    bar=('['+'#'*(20*done//total)+'-'*(20-20*done//total)+f'] {done}/{total} ') if counted else ''
    print(f"[{elapsed(start)}] {event.get('phase','Task')} {bar}{event.get('detail','')}",flush=True)


@contextmanager
def activity(label):
    start=time.monotonic();stop=threading.Event()
    def beat():
        while not stop.wait(HEARTBEAT_SECONDS):print(f'[{elapsed(start)}] {label}: working',flush=True)
    print(label+'...',flush=True);worker=threading.Thread(target=beat,daemon=True);worker.start()
    try:yield
    finally:stop.set();worker.join()


def completed_build(output,frozen):
    """Check completion metadata; the original manifest's byte pins are verified next."""
    report=json.loads((output/'diagnostic-build.json').read_text())
    manifest=json.loads((output/'release.json').read_text())
    if report.get('mode')!='diagnostic' or report.get('publication_qualified') is not False or manifest.get('preparation_mode')!='diagnostic':
        raise RuntimeError('Only completed local diagnostic builds can be resumed')
    if manifest.get('contract_version')!='sail.tariff-release/v8':raise RuntimeError('Unsupported completed diagnostic contract')
    if report.get('dataset_version')!=frozen['dataset_version'] or manifest.get('dataset_version')!=frozen['dataset_version']:
        raise RuntimeError('Completed build dataset version differs from the pinned source; use its original --ref')
    if sorted(report.get('revisions',{}))!=sorted(REVISIONS) or sorted(manifest.get('required_revisions',[]))!=sorted(REVISIONS) or sorted(r.get('revision','') for r in manifest.get('revisions',[]))!=sorted(REVISIONS):
        raise RuntimeError('Incomplete diagnostic revision inventory; resume requires both completed revisions')
    for name,row in report['revisions'].items():
        if row.get('revision')!=name or any(not isinstance(row.get(k),int) or row[k]<=0 for k in ('rows','products','countries')):
            raise RuntimeError('Incomplete diagnostic revision counts: '+name)
    return dict(revisions=REVISIONS,manifest=output/'release.json')


def committed_files(root,commit):
    """Git's complete selected inventory, including runtime evidence in audits."""
    raw=subprocess.check_output(['git','-C',str(root),'ls-tree','-r','-z',commit,'--',*ARCHIVE])
    entries=[]
    for record in raw.split(b'\0'):
        if not record:continue
        info,name=record.split(b'\t',1);mode,kind,oid=info.decode().split()
        if kind!='blob' or mode not in ('100644','100755'):
            raise RuntimeError('Unsupported frozen source entry: '+name.decode())
        entries.append(dict(path=name.decode(),mode=mode,git_oid=oid))
    if not entries:raise RuntimeError('Committed diagnostic source inventory is empty')
    return entries


def verify_archive(snapshot,entries,object_format):
    """Check bytes against Git, not only the narrower shipment dataset context."""
    checked=[]
    for entry in entries:
        path=snapshot/entry['path']
        if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to(snapshot.resolve()):
            raise RuntimeError('Missing or non-independent frozen committed source: '+entry['path'])
        blob=hashlib.new(object_format);digest=hashlib.sha256()
        blob.update(('blob '+str(path.stat().st_size)+'\0').encode())
        with path.open('rb') as stream:
            for block in iter(lambda:stream.read(1024*1024),b''):
                blob.update(block);digest.update(block)
        if blob.hexdigest()!=entry['git_oid']:
            raise RuntimeError('Frozen committed source mismatch: '+entry['path'])
        checked.append(dict(entry,sha256=digest.hexdigest()))
    identity=hashlib.sha256(json.dumps(checked,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return dict(object_format=object_format,files=checked,sha256=identity)


def context(snapshot):
    try:
        result=subprocess.run([sys.executable,str(snapshot/'src/shipment_build_context.py'),
            '--root',str(snapshot),'--output',str(snapshot/'current-source-context.json')],
            check=True,capture_output=True,text=True)
        return json.loads((snapshot/'current-source-context.json').read_text())
    except (subprocess.CalledProcessError,OSError,ValueError) as e:
        raise RuntimeError('Frozen snapshot context validation failed: '+str(e)) from e


def prepare(root,ref,snapshot):
    commit=subprocess.check_output(['git','-C',str(root),'rev-parse',ref+'^{commit}'],text=True).strip()
    entries=committed_files(root,commit)
    object_format=subprocess.check_output(['git','-C',str(root),'rev-parse','--show-object-format'],text=True).strip()
    if snapshot.exists():
        manifest=json.loads((snapshot/'diagnostic-source.json').read_text())
        if manifest.get('contract_version')!=SOURCE_CONTRACT:
            raise RuntimeError('Frozen snapshot uses older incomplete packaging; choose a new snapshot directory')
        archive=verify_archive(snapshot,entries,object_format)
        if manifest['source_commit']!=commit or archive!=manifest['source_archive'] or context(snapshot)['dataset_version']!=manifest['dataset_version']:
            raise RuntimeError('Frozen snapshot changed or belongs to another commit; use a new snapshot directory')
        return manifest
    if snapshot==root or snapshot.is_relative_to(root):
        raise RuntimeError('Diagnostic snapshot must be outside the working checkout')
    missing=[name for name in PRIMARY if not (root/name).is_dir()]
    if missing:raise RuntimeError('Missing primary source directories: '+', '.join(missing))
    modules=root/'frontend/node_modules'
    if not modules.is_dir():raise RuntimeError('Install the tracker frontend dependencies before preparing diagnostics')
    snapshot.parent.mkdir(parents=True,exist_ok=True)
    stage=Path(tempfile.mkdtemp(prefix='.shipment-source-',dir=snapshot.parent))
    try:
        print('Preparing frozen committed source '+commit[:12]+' (no revision build).',flush=True)
        archive=stage/'source.tar'
        with archive.open('wb') as stream:
            subprocess.run(['git','-C',str(root),'archive',commit,*ARCHIVE],stdout=stream,check=True)
        subprocess.run(['tar','-xf',str(archive),'-C',str(stage)],check=True);archive.unlink()
        source_archive=verify_archive(stage,entries,object_format)
        for name in PRIMARY:
            print('Freezing '+name+' independently of the working checkout...',flush=True)
            target=stage/name;target.parent.mkdir(parents=True,exist_ok=True)
            # Reflinks use independent copy-on-write extents where supported;
            # otherwise cp performs a full copy. Never symlink primary inputs.
            subprocess.run(['cp','-a','--reflink=auto',str(root/name),str(target)],check=True)
        (stage/'.here').touch()
        (stage/'frontend/node_modules').symlink_to(modules,target_is_directory=True)
        frozen=context(stage)
        manifest=dict(contract_version=SOURCE_CONTRACT,source_commit=commit,dataset_version=frozen['dataset_version'],
                      source_archive=source_archive,
                      snapshot=str(snapshot),primary_inputs_independently_copied=PRIMARY,
                      dependencies='Existing installed Node/R dependencies; no credentials copied')
        (stage/'diagnostic-source.json').write_text(json.dumps(manifest,indent=2)+'\n')
        stage.rename(snapshot)
        return manifest
    finally:
        if stage.exists():shutil.rmtree(stage)


def run_logged(command,snapshot,log,env):
    start=time.monotonic();last='starting'
    with log.open('x') as stream:
        process=subprocess.Popen(command,cwd=snapshot,env=env,stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT,text=True,bufsize=1,start_new_session=True)
        messages=queue.Queue()
        def read_output():
            try:
                for line in process.stdout:messages.put(line)
            finally:messages.put(None)
        reader=threading.Thread(target=read_output,daemon=True);reader.start()
        try:
            while True:
                try:line=messages.get(timeout=HEARTBEAT_SECONDS)
                except queue.Empty:
                    print(f'[{elapsed(start)}] working; last activity: {last}',flush=True);continue
                if line is None:break
                stream.write(line);stream.flush();shown=line.strip()
                if not shown:continue
                if shown.startswith('DIAGNOSTIC_PROGRESS '):
                    event=json.loads(shown[len('DIAGNOSTIC_PROGRESS '):]);last=event.get('detail',event.get('phase','working'))
                    show_progress(event,start)
                else:
                    last=shown[:200]
                    if shown.startswith('{'):
                        try:
                            value=json.loads(shown);last=str(value.get('status',value.get('manifest','report ready')))
                        except ValueError:pass
                    print(f'[{elapsed(start)}] {last}',flush=True)
            status=process.wait()
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGTERM)
                try:process.wait(timeout=5)
                except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait()
            raise
        finally:reader.join(timeout=1);process.stdout.close()
    if status:
        lines=log.read_text().splitlines()
        # R prints its root error before a backtrace and potentially lengthy
        # warning trailer. A tail alone can hide the reason the build stopped.
        start=next((i for i,line in enumerate(lines)
                    if re.match(r'^(?:Error\b|\w*(?:Error|Exception):)',line)),None)
        if start is None:
            excerpt=lines[-25:]
        else:
            end=next((i for i in range(start+1,min(start+20,len(lines)))
                      if lines[i].startswith(('Backtrace:','Warning messages:'))),min(start+20,len(lines)))
            excerpt=lines[start:end]
        print('\n'.join(excerpt),file=sys.stderr)
        raise RuntimeError('Diagnostic failed; retain '+str(log))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref',default='HEAD',help='Committed tracker source to freeze')
    parser.add_argument('--source-root',type=Path,default=ROOT)
    parser.add_argument('--snapshot-root',type=Path)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--prepare-only',action='store_true')
    parser.add_argument('--resume',type=Path,help='Reuse a completed two-revision diagnostic; never rerun its calculations')
    parser.add_argument('--tooling-ref',default='HEAD',help='Committed validation/delivery tooling, frozen separately from build inputs')
    args=parser.parse_args();root=args.source_root.resolve()
    if args.resume and (args.output or args.prepare_only):raise RuntimeError('--resume cannot be combined with --output or --prepare-only')
    commit=subprocess.check_output(['git','-C',str(root),'rev-parse',args.ref+'^{commit}'],text=True).strip()
    # Preserve old failed copies/logs; never silently reuse the incomplete v1 package.
    snapshot=(args.snapshot_root or Path('/tmp')/('wjr-shipment-source-'+commit[:12]+'-v2')).resolve()
    with activity('Checking and freezing build source'):frozen=prepare(root,commit,snapshot)
    print('Frozen source ready: '+str(snapshot),flush=True)
    if args.prepare_only:return
    tooling_commit=subprocess.check_output(['git','-C',str(root),'rev-parse',args.tooling_ref+'^{commit}'],text=True).strip()
    tooling_snapshot=Path('/tmp')/('wjr-shipment-source-'+tooling_commit[:12]+'-v2')
    with activity('Checking and freezing delivery tooling'):tooling=prepare(root,tooling_commit,tooling_snapshot)
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output=(args.resume or args.output or Path('/tmp')/('wjr-shipment-diagnostic-'+stamp)).resolve()
    if (not args.resume and output.exists()) or output==root or output.is_relative_to(root) or output.is_relative_to(snapshot) or output.is_relative_to(tooling_snapshot):
        raise RuntimeError('Choose a new output directory outside both source checkouts')
    output.parent.mkdir(parents=True,exist_ok=True)
    logs=Path(str(output)+('-recovery-'+stamp if args.resume else '')+'-logs');logs.mkdir(exist_ok=False)
    env=os.environ.copy()
    node=Path('/home/wijreid/.nvm/versions/node/v22.22.3/bin')
    if node.is_dir():env['PATH']=str(node)+os.pathsep+env['PATH']
    revisions=','.join(REVISIONS);overall=time.monotonic()
    show_progress(dict(phase='Overall',completed=0,total=3,detail='Full logs: '+str(logs)),overall)
    if args.resume:
        completed=completed_build(output,frozen)
        run_logged(['node','frontend/scripts/verify-shipment-release-manifest.mjs','--manifest',str(completed['manifest'])],
            tooling_snapshot,logs/'original-artifacts.log',env)
        print('Reusing completed build: no R revision calculation will run.',flush=True)
    else:
        run_logged(['Rscript','scripts/build_shipment_diagnostics.R','--revisions='+revisions,
            '--countries=2010,1220,5700,4120,4280,5880,5800,5830','--cohort','--output='+str(output)],
            snapshot,logs/'build.log',env)
    archive=verify_archive(snapshot,committed_files(root,commit),frozen['source_archive']['object_format'])
    if archive!=frozen['source_archive'] or context(snapshot)['dataset_version']!=frozen['dataset_version']:
        raise RuntimeError('Frozen source changed during the build; do not qualify this output')
    show_progress(dict(phase='Overall',completed=1,total=3,detail='Build verified; pinning emitted artifacts'),overall)
    manifest=output/('release-recovery-'+stamp+'.json' if args.resume else 'release.json')
    run_logged(['node','frontend/scripts/create-shipment-release-manifest.mjs',
        '--normalized',str(output/'normalized'),'--rates',str(output/'rates'),
        '--revisions',revisions,'--mode','diagnostic','--output',str(manifest)],
        tooling_snapshot,logs/'manifest.log',env)
    show_progress(dict(phase='Overall',completed=2,total=3,detail='Checking cells and staging local DuckDB'),overall)
    report=logs/'prepare.json'
    database=output/('diagnostic-recovery-'+stamp+'.duckdb' if args.resume else 'diagnostic.duckdb')
    run_logged(['node','frontend/scripts/prepare-shipment-release.mjs','--manifest',str(manifest),
        '--database',str(database),'--progress','--report',str(report)],tooling_snapshot,logs/'prepare.log',env)
    prepared=json.loads(report.read_text())
    if prepared['status']!='prepared_diagnostic':raise RuntimeError('Unexpected diagnostic release status')
    summary=dict(source_commit=commit,source_archive_sha256=frozen['source_archive']['sha256'],
                 tooling_commit=tooling_commit,tooling_archive_sha256=tooling['source_archive']['sha256'],
                 resumed=bool(args.resume),revision_build_rerun=False if args.resume else True,
                 artifact_manifest=str(manifest),database=str(database),
                 frozen_source_manifest=str(snapshot/'diagnostic-source.json'),
                 output=str(output),logs=str(logs),preparation=prepared,
                 legal_coverage_complete=False,production_qualified=False)
    result=output/('diagnostic-result-recovery-'+stamp+'.json' if args.resume else 'diagnostic-result.json')
    with result.open('x') as stream:stream.write(json.dumps(summary,indent=2)+'\n')
    show_progress(dict(phase='Overall',completed=3,total=3,detail='Diagnostic checks passed'),overall)
    print('Result: '+str(result),flush=True)
    print('This verifies emitted artifacts; complete legal coverage remains unfinished. Nothing was published or activated.')


if __name__=='__main__':
    try:main()
    except (RuntimeError,OSError,subprocess.CalledProcessError,ValueError) as e:
        print(str(e),file=sys.stderr);sys.exit(1)

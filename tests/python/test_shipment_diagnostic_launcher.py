"""A diagnostic must keep working while the main checkout changes."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / 'scripts/run_shipment_diagnostic.py'


def repository(tmp_path):
    root = tmp_path / 'repo'; root.mkdir()
    for folder in ('src','config','resources','scripts','tests','frontend/server',
                   'frontend/migrations','frontend/scripts','data/hts_change_record'):
        p = root / folder; p.mkdir(parents=True, exist_ok=True); (p / 'fixture.txt').write_text('committed source')
    for name in ('tariff-rate-tracker.Rproj','frontend/package.json','frontend/package-lock.json',
                 'data/countries-ISO-3166-1-alpha-2.json'):
        (root / name).write_text('{}')
    (root/'src/shipment_build_context.py').write_bytes((ROOT/'src/shipment_build_context.py').read_bytes())
    evidence=root/'docs/audits/legal-fixture/original/proclamation.pdf'
    evidence.parent.mkdir(parents=True)
    evidence.write_bytes(b'committed primary legal evidence')
    (root/'frontend/node_modules').mkdir()
    subprocess.run(['git','init','-q',str(root)],check=True)
    subprocess.run(['git','-C',str(root),'add','.'],check=True)
    subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                    'commit','-qm','fixture'],check=True)
    for folder in ('data/hts_archives','data/us_notes','data/cache/general_notes'):
        p=root/folder;p.mkdir(parents=True);(p/'primary.json').write_text('{"original":true}')
    return root


def invoke(root,snapshot):
    return subprocess.run([sys.executable,str(LAUNCHER),'--prepare-only','--source-root',str(root),
                           '--snapshot-root',str(snapshot)],capture_output=True,text=True)


def test_diagnostic_freezes_committed_code_and_independent_primary_bytes(tmp_path):
    root=repository(tmp_path);snapshot=tmp_path/'frozen'
    (root/'src/fixture.txt').write_text('ongoing uncommitted change')
    r=invoke(root,snapshot);assert r.returncode==0,r.stderr
    assert (snapshot/'src/fixture.txt').read_text()=='committed source'
    assert not (snapshot/'data/hts_archives').is_symlink()
    original=(snapshot/'data/hts_archives/primary.json').read_bytes()
    (root/'data/hts_archives/primary.json').write_text('{"new":true}')
    assert (snapshot/'data/hts_archives/primary.json').read_bytes()==original
    assert (snapshot/'diagnostic-source.json').exists()
    assert not (snapshot/'normalized').exists()
    assert invoke(root,snapshot).returncode==0


def test_changed_frozen_source_cannot_be_reused_as_the_same_diagnostic(tmp_path):
    root=repository(tmp_path);snapshot=tmp_path/'frozen'
    r=invoke(root,snapshot);assert r.returncode==0,r.stderr
    (snapshot/'src/fixture.txt').write_text('damaged')
    # The source version also hashes .R/.py/.json rather than arbitrary text.
    (snapshot/'src/shipment_build_context.py').write_text('raise RuntimeError("changed frozen source")')
    r=invoke(root,snapshot)
    assert r.returncode!=0
    assert 'frozen' in r.stderr.lower() or 'snapshot' in r.stderr.lower()


def test_frozen_snapshot_contains_the_committed_audit_evidence(tmp_path):
    root=repository(tmp_path);snapshot=tmp_path/'frozen'
    name='docs/audits/legal-fixture/original/proclamation.pdf'
    (root/name).write_bytes(b'ongoing audit evidence edit')
    (root/'.env').write_text('private configuration must not be copied')
    r=invoke(root,snapshot);assert r.returncode==0,r.stderr
    assert (snapshot/name).read_bytes()==b'committed primary legal evidence'
    assert not (snapshot/'.env').exists()


def test_missing_frozen_audit_evidence_is_rejected_before_the_build(tmp_path):
    root=repository(tmp_path);snapshot=tmp_path/'frozen'
    r=invoke(root,snapshot);assert r.returncode==0,r.stderr
    evidence=snapshot/'docs/audits/legal-fixture/original/proclamation.pdf'
    # On the defective launcher the file is absent from the initial copy.
    evidence.unlink(missing_ok=True)
    binaries=tmp_path/'bin';binaries.mkdir();marker=tmp_path/'build-started'
    command=binaries/'Rscript';command.write_text('#!/bin/sh\ntouch "'+str(marker)+'"\nexit 1\n');command.chmod(0o755)
    env=dict(os.environ,PATH=str(binaries)+os.pathsep+os.environ['PATH'])
    r=subprocess.run([sys.executable,str(LAUNCHER),'--source-root',str(root),
                      '--snapshot-root',str(snapshot),'--output',str(tmp_path/'output')],
                     capture_output=True,text=True,env=env)
    assert r.returncode!=0
    assert not marker.exists(), 'A missing legal source was accepted until the R build'
    assert 'proclamation.pdf' in r.stderr


def test_changed_frozen_audit_evidence_cannot_reuse_the_old_dataset_pin(tmp_path):
    root=repository(tmp_path);snapshot=tmp_path/'frozen'
    r=invoke(root,snapshot);assert r.returncode==0,r.stderr
    evidence=snapshot/'docs/audits/legal-fixture/original/proclamation.pdf'
    evidence.parent.mkdir(parents=True,exist_ok=True)
    evidence.write_bytes(b'damaged legal evidence')
    r=invoke(root,snapshot)
    assert r.returncode!=0, 'The dataset check omitted a changed runtime legal source'
    assert 'proclamation.pdf' in r.stderr


def test_legacy_snapshot_is_not_accepted_as_a_verified_source_package(tmp_path):
    root=repository(tmp_path);snapshot=tmp_path/'frozen'
    r=invoke(root,snapshot);assert r.returncode==0,r.stderr
    path=snapshot/'diagnostic-source.json';manifest=json.loads(path.read_text())
    manifest.pop('contract_version');manifest.pop('source_archive');path.write_text(json.dumps(manifest))
    r=invoke(root,snapshot)
    assert r.returncode!=0
    assert 'older incomplete packaging' in r.stderr


def test_failed_source_validation_does_not_leave_an_incomplete_snapshot(tmp_path):
    root=repository(tmp_path);snapshot=tmp_path/'frozen'
    (root/'src/shipment_build_context.py').write_text('raise RuntimeError("invalid source context")')
    subprocess.run(['git','-C',str(root),'add','src/shipment_build_context.py'],check=True)
    subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                    'commit','-qm','invalid context'],check=True)
    r=invoke(root,snapshot)
    assert r.returncode!=0
    assert not snapshot.exists()
    assert not list(tmp_path.glob('.shipment-source-*'))

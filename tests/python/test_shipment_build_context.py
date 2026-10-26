import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

SPEC = importlib.util.spec_from_file_location('context', Path(__file__).parents[2] / 'src/shipment_build_context.py')
context = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(context)


def test_dataset_changes_with_source_or_compiler_but_not_generated_rates(tmp_path):
    (tmp_path / 'src').mkdir()
    (tmp_path / 'src/a.R').write_text('legal logic')
    first = context.build_context(tmp_path)
    assert first['evidence_status'] == 'unresolved_source'
    assert not len(first['evidence_snapshot_id']) == 64
    (tmp_path / 'output').mkdir()
    (tmp_path / 'output/rates.parquet').write_bytes(b'modeled rates')
    assert first == context.build_context(tmp_path)
    (tmp_path / 'src/a.R').write_text('amended legal logic')
    assert first['dataset_version'] != context.build_context(tmp_path)['dataset_version']


def test_pin_checks_export_identity_and_every_artifact(tmp_path):
    pin = tmp_path / 'snapshot'
    pin.mkdir()
    publication = {'schema_version': 8}
    (pin / 'publication-manifest.json').write_bytes(context.canonical(publication))
    (pin / 'evidence.jsonl').write_text('{}\n')
    manifest = dict(contract_version='sail.duty-evidence/v1', served_schema_version=8,
                    coverage_status='requires_reconciliation', extractor_version=2,
                    publication_manifest_sha256=hashlib.sha256(context.canonical(publication)).hexdigest(),
                    tables=[dict(path='evidence.jsonl', rows=1, sha256=hashlib.sha256(b'{}\n').hexdigest())])
    manifest['snapshot_id'] = hashlib.sha256(context.canonical(manifest)).hexdigest()
    path = pin / 'manifest.json'
    path.write_bytes(context.canonical(manifest))
    result = context.build_context(tmp_path, path)
    assert result['evidence_snapshot_id'] == manifest['snapshot_id']
    assert result['evidence_status'] == 'pinned_requires_reconciliation'
    assert result['evidence_pin']['coverage_status'] == 'requires_reconciliation'
    (pin / 'evidence.jsonl').write_text('{"changed":true}\n')
    with pytest.raises(ValueError, match='hash mismatch'):
        context.build_context(tmp_path, path)


def test_configured_absent_pin_is_an_error(tmp_path):
    with pytest.raises((ValueError, FileNotFoundError)):
        context.build_context(tmp_path, tmp_path / 'absent.json')


def test_customs_reference_manifest_does_not_bypass_payload_hashes(tmp_path):
    # Reuse the real exporter's separate reference-manifest structure.
    root = tmp_path / 'ref'
    root.mkdir()
    (root / 'data.json').write_text('[]')
    reference = {'datasets': {'gn': {'file': 'data.json', 'sha256': hashlib.sha256(b'[]').hexdigest()}}}
    (root / 'manifest.json').write_bytes(context.canonical(reference))
    pin = {'path': 'ref/manifest.json', 'manifest_sha256': context.sha(root / 'manifest.json')}
    context.check_reference(tmp_path, pin)
    (root / 'data.json').write_text('["changed"]')
    with pytest.raises(ValueError, match='hash mismatch'):
        context.check_reference(tmp_path, pin)


def test_external_grant_snapshot_changes_dataset_identity(tmp_path):
    root = tmp_path / 'repo'
    root.mkdir()
    grants = tmp_path / 'grants.json'
    value = dict(contract_version='sail.section232-grants/v1', snapshot_id='synthetic-empty-inventory',
                 as_of='2026-10-22T00:00:00Z', sources=[], grants=[])
    grants.write_bytes(context.canonical(value))
    first = context.build_context(root, grant_path=grants)
    value['as_of'] = '2026-10-23T00:00:00Z'
    grants.write_bytes(context.canonical(value))
    assert first['dataset_version'] != context.build_context(root, grant_path=grants)['dataset_version']

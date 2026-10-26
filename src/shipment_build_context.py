"""Content-address ordinary builds and validate the existing TI interchange.

Read-only; no database/network fallback, source collection or publication.
An export pin proves reproducibility, never legal or historical completeness.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False,
                       allow_nan=False) + '\n').encode()


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def checked_file(root, name, expected):
    if not isinstance(name, str) or not name or not isinstance(expected, str) or len(expected) != 64:
        raise ValueError('Incomplete evidence artifact identity')
    path = (root / name).resolve(strict=True)
    if not path.is_relative_to(root.resolve()) or path == root.resolve():
        raise ValueError('Evidence artifact escapes snapshot')
    if sha(path) != expected:
        raise ValueError('Evidence artifact hash mismatch: ' + name)
    return path


def check_reference(root, reference):
    path = checked_file(root, reference['path'], reference['manifest_sha256'])
    manifest = json.loads(path.read_bytes())
    for entry in manifest.get('datasets', {}).values():
        for field, hash_field in (('file', 'sha256'), ('changes_file', 'changes_sha256')):
            if entry.get(field):
                checked_file(path.parent, entry[field], entry[hash_field])


def read_evidence_pin(path):
    path = path.resolve(strict=True)
    manifest = json.loads(path.read_bytes())
    identity = manifest.get('snapshot_id')
    unsigned = {k: v for k, v in manifest.items() if k != 'snapshot_id'}
    if (manifest.get('contract_version') != 'sail.duty-evidence/v1'
            or manifest.get('served_schema_version') != 8 or manifest.get('extractor_version') != 2):
        raise ValueError('Unsupported trade-intelligence evidence contract/schema')
    if identity != hashlib.sha256(canonical(unsigned)).hexdigest():
        raise ValueError('Evidence snapshot identity/hash mismatch')
    if manifest.get('coverage_status') != 'requires_reconciliation' or not manifest.get('tables'):
        raise ValueError('Evidence coverage and inventory required')
    root = path.parent
    for table in manifest['tables']:
        item = checked_file(root, table['path'], table['sha256'])
        with item.open('rb') as stream:
            if sum(1 for _ in stream) != table['rows']:
                raise ValueError('Evidence row inventory mismatch')
    checked_file(root, 'publication-manifest.json', manifest['publication_manifest_sha256'])
    # Reference publication is separately content-addressed by the exporter.
    reference = manifest.get('customs_reference')
    if reference:
        check_reference(root, reference)
    return dict(snapshot_id=identity, manifest_sha256=sha(path), contract_version=manifest['contract_version'],
                served_schema_version=8, extractor_version=manifest.get('extractor_version'),
                coverage_status=manifest['coverage_status'],
                publication_manifest_sha256=manifest['publication_manifest_sha256'],
                table_inventory=manifest['tables'], customs_reference=reference)


def input_files(root):
    # These are source inputs, never economic Parquet outputs or local secrets.
    paths = []
    for directory in ('src', 'config', 'resources',
                      'data/hts_archives', 'data/us_notes', 'data/cache/general_notes'):
        base = root / directory
        if base.exists():
            paths.extend(p for p in base.rglob('*') if p.is_file() and p.suffix.lower() in
                         ('.r', '.py', '.json', '.csv', '.yaml', '.yml', '.pdf', '.txt', '.gz'))
    paths.extend(p for p in (root / 'resources/census_codes.csv',
                            root / 'frontend/server/generated/shipmentRules.js',
                            root / 'frontend/server/generated/shipmentWide.js') if p.exists())
    return sorted(set(paths))


def read_grant_pin(path):
    path = path.resolve(strict=True)
    value = json.loads(path.read_bytes())
    if value.get('contract_version') != 'sail.section232-grants/v1' or not value.get('snapshot_id'):
        raise ValueError('Unsupported configured Commerce grant snapshot')
    for source in value['sources']:
        checked_file(path.parent, source['path'], source['sha256'])
    # Scope, grants and claim semantics remain validated by the existing grant
    # compiler. This transitive source pin is for build/cache identity only.
    return dict(snapshot_id=value['snapshot_id'], snapshot_sha256=sha(path), as_of=value['as_of'],
                sources=[dict(id=s['id'], sha256=s['sha256']) for s in value['sources']])


def build_context(root, evidence_path=None, grant_path=None):
    root = root.resolve()
    inventory = [dict(path=str(p.relative_to(root)), sha256=sha(p)) for p in input_files(root)]
    pin = read_evidence_pin(evidence_path) if evidence_path else None
    inputs = dict(contract_version='sail.shipment-build-inputs/v1', sources=inventory,
                  evidence_snapshot=pin, commerce_grants=read_grant_pin(grant_path) if grant_path else None)
    return dict(dataset_version='shipment-' + hashlib.sha256(canonical(inputs)).hexdigest(),
                evidence_snapshot_id=pin['snapshot_id'] if pin else 'unresolved_trade_intelligence_snapshot',
                evidence_status='pinned_requires_reconciliation' if pin else 'unresolved_source',
                evidence_pin=pin, input_manifest=inputs)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--evidence', type=Path)
    parser.add_argument('--grants', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.write_bytes(canonical(build_context(args.root, args.evidence, args.grants)))

"""The audited build window, read from the one file that states it.

`resources/shipment_rules/build_contract.json` is the single statement of the
window a build may emit rules for. Compilers used to repeat its end instant as
a literal, which meant extending the horizon silently left some of them behind:
an action period beginning after a stale literal produced an interval whose end
preceded its start, and the bundle carrying it was rejected whole, far from the
file that was actually out of date. Read the window from here instead, and name
the contract in `compiler_dependencies` so a change to it re-compiles.
"""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATH = 'resources/shipment_rules/build_contract.json'


@lru_cache(maxsize=1)
def contract():
    x = json.loads((ROOT / PATH).read_bytes())
    if x.get('contract_version') != 'sail.shipment-build/v1':
        raise ValueError('Unsupported shipment build specification')
    for key in ('audit_from', 'audit_until'):
        if not isinstance(x.get(key), str) or not x[key]:
            raise ValueError('Incomplete audited build window: ' + key)
    if x['audit_from'] >= x['audit_until']:
        raise ValueError('Audited build window does not advance')
    return x


def audit_from():
    return contract()['audit_from']


def audit_until():
    return contract()['audit_until']

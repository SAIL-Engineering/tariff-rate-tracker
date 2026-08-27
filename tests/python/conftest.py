"""Shared helpers for the hts_automation test suite.

Everything here runs the real builder functions in-process on small fixture
slices cut from actual revision files — no network, no secrets.
"""
from pathlib import Path
from types import SimpleNamespace

import pytest

import build_hts_corpus as bhc

FIXTURES = Path(__file__).parent / "fixtures"
AUTOMATION = Path(__file__).parents[2] / "scripts" / "hts_automation"


@pytest.fixture
def fixtures() -> Path:
    return FIXTURES


@pytest.fixture
def us_chapters() -> Path:
    return AUTOMATION / "chapters.json"


@pytest.fixture
def ca_chapters() -> Path:
    return AUTOMATION / "chapters_ca.json"


def build(csv_path: Path, chapters_path: Path, *, source_format="usitc",
          jurisdiction="US", revision="test_rev"):
    """Run the full in-process pipeline the way main() does."""
    loaders = {"usitc": bhc.load_rows, "cbsa": bhc.load_rows_cbsa,
               "taric": bhc.load_rows_taric, "dga": bhc.load_rows_dga}
    rows, stats = loaders[source_format](csv_path)
    chapters = bhc.load_chapters(chapters_path)
    roots = bhc.build_tree(rows)
    records, depth_hist, truncated = bhc.flatten_tree_to_records(
        roots, chapters, jurisdiction, revision)
    nodes = bhc.collect_node_index(roots)
    by_code = {r["code"]: r for r in records}
    return SimpleNamespace(rows=rows, stats=stats, roots=roots, nodes=nodes,
                           records=records, by_code=by_code,
                           depth_hist=depth_hist, truncated=truncated)

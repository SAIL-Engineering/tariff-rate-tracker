"""uk_tariff adapter: convert mapping, dedupe, hash stability, gate modes."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

from acquire import uk_tariff as uk                     # noqa: E402
from check_upstream import UpstreamCheck                # noqa: E402
import refresh                                          # noqa: E402

COLS = uk.COMMODITY_COLUMNS


def _write_commodities(path: Path, rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=COLS)
        w.writeheader()
        for i, r in enumerate(rows, 1):
            w.writerow({"id": str(i), "commodity__validity_start": "2021-01-01",
                        "commodity__validity_end": "#NA",
                        "parent__code": "#NA", "parent__suffix": "#NA", **r})


BASE = [
    {"commodity__sid": "1", "commodity__code": "0100000000",
     "commodity__suffix": "80", "commodity__description": "LIVE ANIMALS",
     "parent__sid": "#NA"},
    {"commodity__sid": "2", "commodity__code": "0101000000",
     "commodity__suffix": "80", "commodity__description": "Live horses",
     "parent__sid": "1"},
    {"commodity__sid": "3", "commodity__code": "0101210000",
     "commodity__suffix": "10", "commodity__description": "Horses",
     "parent__sid": "2"},
    {"commodity__sid": "4", "commodity__code": "0101210000",
     "commodity__suffix": "80",
     "commodity__description": "Pure-bred breeding animals",
     "parent__sid": "3"},
]


def test_convert_preorder_indent_and_leaves(tmp_path):
    src = tmp_path / "commodities.csv"
    _write_commodities(src, BASE)
    out = tmp_path / "canonical.csv"
    stats = uk.convert(src, {"4"}, out)
    rows = list(csv.DictReader(out.open(encoding="utf-8-sig")))
    assert [(r["GOODS_CODE"], r["SUFFIX"], r["INDENT"], r["IS_LEAF"])
            for r in rows] == [
        ("0100000000", "80", "0", "1" if False else "0") if False else
        ("0100000000", "80", "0", "0"),
        ("0101000000", "80", "1", "0"),
        ("0101210000", "10", "2", ""),
        ("0101210000", "80", "3", "1"),
    ]
    assert stats["coded"] == 3 and stats["conditions"] == 1
    assert rows[0]["DESCRIPTION"] == "Live animals"     # shout-case fixed


def test_convert_childless_node_without_measures_is_leaf(tmp_path):
    src = tmp_path / "c.csv"
    _write_commodities(src, BASE)                       # sid 4 NOT declarable
    out = tmp_path / "o.csv"
    stats = uk.convert(src, set(), out)
    rows = {(r["GOODS_CODE"], r["SUFFIX"]): r
            for r in csv.DictReader(out.open(encoding="utf-8-sig"))}
    assert rows[("0101210000", "80")]["IS_LEAF"] == "1"
    assert stats["leaves_without_measures"] == 1


def test_convert_drops_superseded_duplicates(tmp_path):
    rows = BASE + [{
        "commodity__sid": "9", "commodity__code": "0101210000",
        "commodity__suffix": "80", "commodity__description": "Old node",
        "parent__sid": "3", "commodity__validity_start": "2019-01-01",
    }]
    src = tmp_path / "c.csv"
    with src.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=COLS)
        w.writeheader()
        for i, r in enumerate(rows, 1):
            w.writerow({"id": str(i),
                        "commodity__validity_start": r.get(
                            "commodity__validity_start", "2023-09-16"),
                        "commodity__validity_end": "#NA",
                        "parent__code": "#NA", "parent__suffix": "#NA", **r})
    out = tmp_path / "o.csv"
    stats = uk.convert(src, {"4"}, out)
    got = [r for r in csv.DictReader(out.open(encoding="utf-8-sig"))
           if (r["GOODS_CODE"], r["SUFFIX"]) == ("0101210000", "80")]
    assert len(got) == 1                                # newest kept
    assert stats["superseded_dropped"] == 1


def test_convert_end_dated_rows_dropped(tmp_path):
    src = tmp_path / "c.csv"
    rows = [dict(BASE[0]), dict(BASE[1])]
    with src.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=COLS)
        w.writeheader()
        w.writerow({"id": "1", "commodity__validity_start": "2021-01-01",
                    "commodity__validity_end": "#NA", "parent__code": "#NA",
                    "parent__suffix": "#NA", **rows[0]})
        w.writerow({"id": "2", "commodity__validity_start": "2021-01-01",
                    "commodity__validity_end": "2022-01-01",   # long expired
                    "parent__code": "#NA", "parent__suffix": "#NA", **rows[1]})
    out = tmp_path / "o.csv"
    stats = uk.convert(src, set(), out)
    assert stats["end_dated_dropped"] == 1
    assert stats["rows"] == 1


def test_convert_missing_parent_fails(tmp_path):
    src = tmp_path / "c.csv"
    _write_commodities(src, [dict(BASE[1])])            # parent sid 1 absent
    with pytest.raises(SystemExit):
        uk.convert(src, set(), tmp_path / "o.csv")


def test_classification_hash_ignores_row_order_but_not_content(tmp_path):
    a, b, c = tmp_path / "a.csv", tmp_path / "b.csv", tmp_path / "c.csv"
    _write_commodities(a, BASE)
    _write_commodities(b, list(reversed(BASE)))
    changed = [dict(r) for r in BASE]
    changed[3]["commodity__description"] = "Pure-bred racing animals"
    _write_commodities(c, changed)
    assert uk.classification_hash(a) == uk.classification_hash(b)
    assert uk.classification_hash(a) != uk.classification_hash(c)


def test_version_patch():
    assert uk.version_patch("v4.0.1591") == 1591
    with pytest.raises(SystemExit):
        uk.version_patch("weird")


# ─── gate: rates_only outcome flows through gate_if_new ──────────────

def test_gate_rates_only_sets_flag_and_returns(tmp_path, monkeypatch):
    class _Adapter:
        def check_latest(self, spec, args):
            return UpstreamCheck(
                status="available", rev_id="2026_rev_1591",
                year=2026, rev_num=1591, effective_date="2026-09-01",
                detail="nomenclature unchanged",
                extras={"mode": "rates_only", "version": "v4.0.1600"})
    args = argparse.Namespace(if_new=True, plan_only=False, revision=None)
    spec = {"code": "GB", "registry": str(tmp_path / "gb_revisions.csv"),
            "acquire": {"adapter": "uk_tariff", "options": {}}}
    refresh.gate_if_new(spec, _Adapter(), args)          # must NOT exit
    assert args.rates_only is True
    assert args.upstream_extras["version"] == "v4.0.1600"


def test_gate_full_mode_still_compares_against_supabase(tmp_path, monkeypatch):
    import check_upstream
    class _Adapter:
        def check_latest(self, spec, args):
            return UpstreamCheck(
                status="available", rev_id="2026_rev_1591",
                year=2026, rev_num=1591, effective_date="2026-09-01",
                extras={"mode": "full", "version": "v4.0.1591"})
    monkeypatch.setattr(check_upstream, "supabase_latest",
                        lambda c: (2026, 1591))
    args = argparse.Namespace(if_new=True, plan_only=False, revision=None)
    spec = {"code": "GB", "registry": str(tmp_path / "r.csv"),
            "acquire": {"adapter": "uk_tariff", "options": {}}}
    with pytest.raises(SystemExit) as exc:               # up to date -> skip
        refresh.gate_if_new(spec, _Adapter(), args)
    assert exc.value.code == 0

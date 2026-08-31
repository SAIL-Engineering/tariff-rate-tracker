"""Gate + check_latest tests: pure logic, all network mocked."""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import check_upstream                                    # noqa: E402
import refresh                                           # noqa: E402
from check_upstream import UpstreamCheck                 # noqa: E402


def _args(**kw):
    d = dict(if_new=True, plan_only=False, revision=None, skip_scrape=False)
    d.update(kw)
    return argparse.Namespace(**d)


def _spec(tmp_path, code="CA"):
    reg = tmp_path / f"{code.lower()}_revisions.csv"
    return {"code": code, "registry": str(reg),
            "acquire": {"adapter": "manual", "options": {}}}


class _Adapter:
    def __init__(self, check):
        self._check = check

    def check_latest(self, spec, args):
        return self._check


# ─── gate decision table ─────────────────────────────────────────────

def test_gate_no_check_latest_proceeds(tmp_path, monkeypatch, capsys):
    adapter = SimpleNamespace()          # no check_latest attribute
    refresh.gate_if_new(_spec(tmp_path), adapter, _args())
    assert "cannot check upstream" in capsys.readouterr().out


def test_gate_in_progress_exits_zero(tmp_path):
    adapter = _Adapter(UpstreamCheck(status="in_progress", detail="uploading"))
    with pytest.raises(SystemExit) as exc:
        refresh.gate_if_new(_spec(tmp_path), adapter, _args())
    assert exc.value.code == 0


def test_gate_supabase_unreachable_is_an_error(tmp_path, monkeypatch):
    adapter = _Adapter(UpstreamCheck(status="available", rev_id="2026_rev_3",
                                     year=2026, rev_num=3))
    monkeypatch.setattr(check_upstream, "supabase_latest",
                        lambda c: (_ for _ in ()).throw(RuntimeError("down")))
    with pytest.raises(SystemExit) as exc:
        refresh.gate_if_new(_spec(tmp_path), adapter, _args())
    assert "refusing to guess" in str(exc.value.code)


def test_gate_first_revision_proceeds(tmp_path, monkeypatch):
    adapter = _Adapter(UpstreamCheck(status="available", rev_id="2026_rev_1",
                                     year=2026, rev_num=1))
    monkeypatch.setattr(check_upstream, "supabase_latest", lambda c: None)
    refresh.gate_if_new(_spec(tmp_path), adapter, _args())    # no exit


def test_gate_newer_upstream_proceeds(tmp_path, monkeypatch, capsys):
    adapter = _Adapter(UpstreamCheck(status="available", rev_id="2026_rev_3",
                                     year=2026, rev_num=3))
    monkeypatch.setattr(check_upstream, "supabase_latest", lambda c: (2026, 2))
    refresh.gate_if_new(_spec(tmp_path), adapter, _args())
    assert "NEW revision 2026_rev_3" in capsys.readouterr().out


def test_gate_newer_upstream_notes_resume(tmp_path, monkeypatch, capsys):
    spec = _spec(tmp_path)
    with open(spec["registry"], "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["revision", "effective_date"])
        w.writeheader()
        w.writerow({"revision": "2026_rev_3", "effective_date": "2026-08-06"})
    adapter = _Adapter(UpstreamCheck(status="available", rev_id="2026_rev_3",
                                     year=2026, rev_num=3))
    monkeypatch.setattr(check_upstream, "supabase_latest", lambda c: (2026, 2))
    refresh.gate_if_new(spec, adapter, _args())
    assert "resuming an interrupted rollout" in capsys.readouterr().out


def test_gate_up_to_date_exits_zero(tmp_path, monkeypatch):
    adapter = _Adapter(UpstreamCheck(status="available", rev_id="2026_rev_2",
                                     year=2026, rev_num=2))
    monkeypatch.setattr(check_upstream, "supabase_latest", lambda c: (2026, 2))
    with pytest.raises(SystemExit) as exc:
        refresh.gate_if_new(_spec(tmp_path), adapter, _args())
    assert exc.value.code == 0


def test_gate_registry_ahead_exits_zero_with_warning(tmp_path, monkeypatch, capsys):
    adapter = _Adapter(UpstreamCheck(status="available", rev_id="2026_rev_1",
                                     year=2026, rev_num=1))
    monkeypatch.setattr(check_upstream, "supabase_latest", lambda c: (2026, 2))
    with pytest.raises(SystemExit) as exc:
        refresh.gate_if_new(_spec(tmp_path), adapter, _args())
    assert exc.value.code == 0
    assert "AHEAD of" in capsys.readouterr().out


def test_gate_non_numeric_revnum_proceeds(tmp_path, monkeypatch, capsys):
    adapter = _Adapter(UpstreamCheck(status="available", rev_id="2026_rev_basic",
                                     year=2026, rev_num="basic"))
    monkeypatch.setattr(check_upstream, "supabase_latest", lambda c: (2026, 2))
    refresh.gate_if_new(_spec(tmp_path), adapter, _args())
    assert "non-numeric" in capsys.readouterr().out


def test_gate_writes_github_output(tmp_path, monkeypatch):
    out = tmp_path / "gh_output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    adapter = _Adapter(UpstreamCheck(status="available", rev_id="2026_rev_2",
                                     year=2026, rev_num=2,
                                     effective_date="2026-08-06"))
    monkeypatch.setattr(check_upstream, "supabase_latest", lambda c: (2026, 1))
    refresh.gate_if_new(_spec(tmp_path), adapter, _args())
    text = out.read_text()
    assert "gate=proceed" in text
    assert "REV_ID=2026_rev_2" in text
    assert "EFFECTIVE_DATE=2026-08-06" in text


# ─── EU three-way state ──────────────────────────────────────────────

def _eu_check(monkeypatch, candidates, incomplete):
    from acquire import eu_taric
    vendor = SimpleNamespace(
        make_session=lambda: None,
        DEFAULT_ROOT_ID="root",
        discover_release_candidates=lambda *a, **k: (candidates, incomplete),
        select_release=lambda cands, req: max(
            cands, key=lambda c: c.release_month),
    )
    monkeypatch.setitem(sys.modules, "acquire.vendor.eu_taric_downloader", vendor)
    spec = {"code": "EU", "acquire": {"adapter": "eu_taric", "options": {}}}
    return eu_taric.check_latest(spec, _args())


def _cand(month):
    return SimpleNamespace(release_month=month)


def test_eu_complete_release_is_available(monkeypatch):
    chk = _eu_check(monkeypatch, [_cand("2026-08")], [])
    assert (chk.status, chk.rev_id, chk.rev_num) == ("available", "2026_rev_8", 8)
    assert chk.effective_date == "2026-08-01"


def test_eu_newer_incomplete_is_in_progress(monkeypatch):
    chk = _eu_check(monkeypatch, [_cand("2026-08")],
                    [("2026-09", ["Measure exclusions.xlsx"])])
    assert chk.status == "in_progress"
    assert "2026-09" in chk.detail and "Measure exclusions" in chk.detail


def test_eu_older_incomplete_is_ignored(monkeypatch):
    chk = _eu_check(monkeypatch, [_cand("2026-08")],
                    [("2026-07", ["Nomenclature EN.xlsx"])])
    assert chk.status == "available"
    assert chk.rev_id == "2026_rev_8"


# ─── CBSA offset mapping ─────────────────────────────────────────────

def test_cbsa_offset_mapping(monkeypatch):
    from acquire import cbsa
    latest = SimpleNamespace(revision="T2026-1", revision_number=1,
                             effective_date="2026-08-06")
    vendor = SimpleNamespace(
        make_session=lambda: None,
        discover_language=lambda *a, **k: [latest],
        choose_latest_revision=lambda revs, lang: (latest, revs),
    )
    monkeypatch.setitem(sys.modules, "acquire.vendor.cbsa_canadian_tariff", vendor)
    spec = {"code": "CA", "acquire": {"adapter": "cbsa",
                                      "options": {"revision_number_offset": 1}}}
    chk = cbsa.check_latest(spec, _args())
    assert (chk.rev_id, chk.year, chk.rev_num) == ("2026_rev_2", 2026, 2)
    assert chk.effective_date == "2026-08-06"


# ─── append_registry header guard ────────────────────────────────────

def test_append_registry_refuses_foreign_schema(tmp_path, capsys):
    reg = tmp_path / "revision_dates.csv"
    original = ("revision,effective_date,policy_effective_date,needs_review\n"
                "2026_rev_17,2026-08-24,2026-08-24,FALSE\n")
    reg.write_text(original)
    spec = {"code": "US", "registry": str(reg)}
    ctx = {"revision": "2026_rev_18", "effective_date": "2026-09-01",
           "effective_date_label": "September 1, 2026"}
    refresh.append_registry(spec, ctx)
    assert reg.read_text() == original          # untouched, not truncated
    assert "different schema" in capsys.readouterr().out


def test_append_registry_still_writes_own_schema(tmp_path):
    reg = tmp_path / "ca_revisions.csv"
    spec = {"code": "CA", "registry": str(reg)}
    ctx = {"revision": "2026_rev_2", "effective_date": "2026-08-06",
           "effective_date_label": "August 6, 2026",
           "source_url": "https://x", "source_sha256": "abc"}
    refresh.append_registry(spec, ctx)
    rows = list(csv.DictReader(open(reg)))
    assert rows[0]["revision"] == "2026_rev_2"
    refresh.append_registry(spec, ctx)          # merge, not duplicate
    assert len(list(csv.DictReader(open(reg)))) == 1

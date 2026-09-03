"""Taiwan duty engine: three-column structure, per-line Column II origin
sets, levy markers, coverage floor."""
import csv
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[2] / "scripts" / "hts_automation"))

import build_duty_rates as bdr  # noqa: E402
from acquire import tw_customs  # noqa: E402


def _nomenclature(tmp_path, codes):
    p = tmp_path / "tw_tariff_2026_rev_729.csv"
    with p.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["GOODS_CODE", "SUFFIX", "INDENT",
                                           "DESCRIPTION", "UNIT", "IS_LEAF",
                                           "START_DATE"])
        w.writeheader()
        for c in codes:
            w.writerow({"GOODS_CODE": c, "SUFFIX": "80", "INDENT": 5,
                        "DESCRIPTION": "x", "UNIT": "", "IS_LEAF": "1",
                        "START_DATE": ""})
    return p


def _row(code, col1="2.5%", col2="0% (PA,GT,NI,SV,HN,NZ,SG)", col3="5%",
         levy=""):
    return {"code": code, "zh": "中文", "en": "english", "col1": col1,
            "col2": col2, "col3": col3, "unit_qty": "KGM", "unit_wt": "KGM",
            "levy": levy, "import_reg": "", "export_reg": ""}


def _run(tmp_path, monkeypatch, rows):
    monkeypatch.setattr(tw_customs, "parse_main_xls", lambda p: rows)
    nom = _nomenclature(tmp_path, [r["code"] for r in rows])
    return bdr.build_tw(tmp_path / "fake.xls", "TW", "2026_rev_729", nom)


def test_three_columns(tmp_path, monkeypatch):
    records, treatments, coverage = _run(tmp_path, monkeypatch,
                                         [_row("01012100003")])
    by_t = {r["treatment"]: r for r in records}
    assert by_t["erga_omnes"]["rate_text"] == "2.5%"
    assert not by_t["erga_omnes"].get("informational")
    pref = [r for r in records if r["treatment"].startswith("pref_")]
    assert len(pref) == 1 and pref[0]["rate_text"] == "0%"
    assert pref[0]["conditional"] is True
    assert by_t["general_non_wto"]["informational"] is True
    tmap = {t["treatment"]: t for t in treatments}
    key = pref[0]["treatment"]
    assert tmap[key]["origin_countries"] == ["GT", "HN", "NI", "NZ", "PA", "SG", "SV"]


def test_multiple_column2_groups(tmp_path, monkeypatch):
    rows = [_row("03029200008", col2="0% (PA,NZ,SG) 12.5% (GT,NI,SV,HN)")]
    records, treatments, _ = _run(tmp_path, monkeypatch, rows)
    prefs = sorted((r["treatment"], r["rate_text"]) for r in records
                   if r["treatment"].startswith("pref_"))
    assert prefs == [("pref_gt-hn-ni-sv", "12.5%"),
                     ("pref_nz-pa-sg", "0%")]


def test_specific_rates_verbatim(tmp_path, monkeypatch):
    rows = [_row("04070021005", col1="NT$11.3/KGM or 15% whichever is higher")]
    records, _, _ = _run(tmp_path, monkeypatch, rows)
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["rate_text"] == "NT$11.3/KGM or 15% whichever is higher"
    assert erga["rate_kind"] != "ad_valorem" or "ad_valorem" not in erga


def test_levy_marker_and_glossary(tmp_path, monkeypatch):
    rows = [_row("01022900004", levy="R")]
    records, _, _ = _run(tmp_path, monkeypatch, rows)
    levy = next(r for r in records if r["treatment"] == "levy_rule")
    assert levy["informational"] is True
    assert "tariff-rate quota" in levy["rate_text"]


def test_unparseable_column2_trips(tmp_path, monkeypatch):
    rows = [_row("01012100003", col2="0% for some countries")]
    with pytest.raises(SystemExit):
        _run(tmp_path, monkeypatch, rows)


def test_coverage_floor(tmp_path, monkeypatch):
    rows = [_row(f"0101210000{i}", col1="") for i in range(3)]
    with pytest.raises(SystemExit):
        _run(tmp_path, monkeypatch, rows)

"""build_my: ad valorem / specific / compound import duty (unit from column 4),
Appendix B quota lines, SST/excise/cess as taxes, unresolved and unreadable
cells flagged, export duty absent, artifact shape."""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import build_duty_rates as bdr                          # noqa: E402

FIXTURE = Path(__file__).parent / "fixtures" / "my_duty_rates_slice.csv"
REV = "2025_rev_1101"


def _build(path=FIXTURE):
    return bdr.build_my(path, "MY", REV)


def _by(records, digits):
    return {r["treatment"]: r for r in records if r["digits"] == digits}


def _mutated(tmp_path, changes: dict[str, dict]):
    with FIXTURE.open(newline="", encoding="utf-8") as fh:
        rd = csv.DictReader(fh)
        fields, rows = rd.fieldnames, list(rd)
    for r in rows:
        r.update(changes.get(r["GOODS_CODE"], {}))
    p = tmp_path / "my_tariff_test.csv"
    with p.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    return p


def test_ad_valorem_and_free():
    records, _, _ = _build()
    mfn = _by(records, "0103100000")["MFN"]
    assert mfn["rate_text"] == "0%" and mfn["rate_kind"] == "free"
    assert not mfn.get("conditional")


def test_specific_amount_takes_the_unit_of_quantity():
    # P.U. (A) 384 para 3(b): a sum of money is "upon every unit specified in
    # column (4)" — 2204.21.11 is printed "l  RM 7.00".
    records, _, _ = _build()
    mfn = _by(records, "2204211100")["MFN"]
    assert mfn["rate_text"] == "RM 7.00 per l"
    assert mfn["source_text"] == "RM 7.00"
    assert mfn["rate_kind"] == "other" and "ad_valorem" not in mfn
    assert mfn["components"] == [{"type": "specific", "amount": 7.0,
                                  "currency": "MYR", "per": "l",
                                  "unit_source": "unit_of_quantity"}]
    cigars = _by(records, "2402100000")["MFN"]
    assert cigars["rate_text"] == "RM200.00 per kg"


def test_stated_unit_is_kept_verbatim():
    records, _, _ = _build()
    samsu = _by(records, "2208901000")["MFN"]
    assert samsu["rate_text"] == "RM 26.50 per 100% vol. per litre"
    assert samsu["components"][0]["per"] == "100% vol. per litre"
    assert samsu["components"][0]["unit_source"] == "stated"
    assert "source_text" not in samsu
    stick = _by(records, "2402202000")["MFN"]
    assert stick["components"][0]["per"] == "stk"


def test_compound_keeps_both_components():
    records, _, _ = _build()
    mfn = _by(records, "0807110000")["MFN"]
    assert mfn["rate_text"] == "5% and RM0.65 per kg"
    assert mfn["rate_kind"] == "compound"
    assert mfn["ad_valorem"] == 0.05          # the % component only (partial)
    assert mfn["combine"] == "sum"
    assert [c["type"] for c in mfn["components"]] == ["ad_valorem", "specific"]
    assert mfn["components"][1]["amount"] == 0.65


def test_whichever_higher_is_never_an_ad_valorem():
    records, _, _ = _build()
    for digits, per in (("4808902000", "kg"), ("8414804200", "each")):
        mfn = _by(records, digits)["MFN"]
        assert mfn["combine"] == "greater_of"
        assert mfn["rate_kind"] == "other" and "ad_valorem" not in mfn
        assert mfn["rate_text"].endswith("whichever is the higher")
        assert mfn["components"][1]["per"] == per


def test_trq_out_quota_is_conditional_mfn_in_quota_informational():
    records, _, _ = _build()
    by = _by(records, "0103910000")
    mfn = by["MFN"]
    assert mfn["rate_text"] == "20%" and mfn["conditional"] is True
    assert mfn["rate_basis"] == "trq_appendix_b"
    assert "15%" in mfn["quota_note"]
    assert "Department of Veterinary Services" in mfn["quota_note"]
    q = by["quota_in"]
    assert q["rate_text"] == "15%" and q["informational"] is True
    assert q["category"] == "quota" and q["conditional"] is True
    assert q["conditions"] == ["Quota set by Department of Veterinary Services"]
    # 0% in-quota stays a real 0% quota row, never the applied rate
    cabbage = _by(records, "0704901000")
    assert cabbage["MFN"]["rate_text"] == "90%"
    assert cabbage["quota_in"]["rate_kind"] == "free"


def test_unresolved_surfaces_as_unresolved_not_zero(tmp_path, monkeypatch):
    monkeypatch.setattr(bdr, "STATIC_MFN_FLOOR_PCT", 0.0)
    p = _mutated(tmp_path, {"0103100000": {"IMPORT_RATE": "",
                                           "IMPORT_RATE_BASIS": "unresolved"}})
    records, treatments, _ = _build(p)
    by = _by(records, "0103100000")
    assert "MFN" not in by
    flagged = by["unknown_MFN"]
    assert flagged["needs_review"] == "unresolved"
    assert flagged["rate_kind"] == "none" and "ad_valorem" not in flagged
    assert flagged["informational"] is True
    assert any(t["treatment"] == "unknown_MFN" for t in treatments)


def test_unknown_import_rate_pattern_is_flagged(tmp_path, monkeypatch):
    monkeypatch.setattr(bdr, "STATIC_MFN_FLOOR_PCT", 0.0)
    p = _mutated(tmp_path, {"0807110000": {"IMPORT_RATE": "5% plus levy"}})
    records, _, _ = _build(p)
    flagged = _by(records, "0807110000")["unknown_MFN"]
    assert flagged["rate_text"] == "5% plus levy"
    assert flagged["needs_review"] == "unrecognised"


def test_mfn_coverage_floor_trips(tmp_path):
    p = _mutated(tmp_path, {"0807110000": {"IMPORT_RATE": "5% plus levy"}})
    with pytest.raises(SystemExit, match="floor"):
        _build(p)


def test_taxes_are_informational():
    records, _, _ = _build()
    sst = _by(records, "0807110000")["SST"]
    assert sst["category"] == "tax" and sst["informational"] is True
    assert sst["rate_text"] == "5%"
    alt = _by(records, "3307419000")["SST"]
    assert alt["combine"] == "alternatives" and alt["conditional"] is True
    assert alt["source_text"] == "10%/0%" and "ad_valorem" not in alt
    fuel = _by(records, "2710121100")["SST"]
    assert fuel["components"][0]["per"] == "litre"
    excise = _by(records, "2204211100")["EXCISE"]
    assert excise["rate_text"] == "RM165.00 per 100% vol. per litre"
    assert _by(records, "4001101100")["CESS_3"]["rate_kind"] == "free"


def test_tax_amounts_without_a_unit_are_flagged_not_completed():
    # The column-(4) unit rule belongs to the Customs Duties Order; it does not
    # reach the portal's excise/cess columns.
    records, _, _ = _build()
    for digits, col, text, reason in (
            ("2402100000", "EXCISE", "RM440.00", "unit_not_stated"),
            ("2207201100", "EXCISE", "RM1.21 and 15%", "unit_not_stated"),
            ("2403919000", "EXCISE", "NA", "not_a_rate"),
            ("4001101100", "CESS_1", "RM0.10", "unit_not_stated"),
            ("4001101100", "CESS_2", "RM.0.04", "unrecognised")):
        by = _by(records, digits)
        assert col not in by
        flagged = by[f"unknown_{col}"]
        assert flagged["rate_text"] == text
        assert flagged["needs_review"] == reason
        assert flagged["category"] == "unknown"


def test_export_duty_and_internal_nodes_are_not_emitted():
    records, treatments, _ = _build()
    assert not any("EXPORT" in r["treatment"].upper() for r in records)
    assert not any(r["digits"] == "29034300" for r in records)   # 8-digit node
    assert not any(r["digits"] == "0103" for r in records)


def test_cli_writes_the_three_artifacts(tmp_path, monkeypatch):
    out = tmp_path / "out"
    monkeypatch.setattr(sys, "argv", [
        "build_duty_rates.py", str(FIXTURE), "--source-format", "my",
        "--jurisdiction", "MY", "--revision", REV, "--out-dir", str(out)])
    assert bdr.main() == 0
    index = json.loads((out / f"my_{REV}.rates.index.json").read_text())
    assert index["inherit"] == "exact"
    assert set(index["chapters"]) >= {"01", "08", "22", "84"}
    tdoc = json.loads((out / "my.treatments.json").read_text())
    keys = {t["treatment"] for t in tdoc["treatments"]}
    assert {"MFN", "quota_in", "SST", "EXCISE", "CESS_1"} <= keys
    for t in tdoc["treatments"]:
        assert {"treatment", "name", "origin_countries",
                "conditional"} <= t.keys()
    assert "P.U. (A) 384" in tdoc["coverage"]["source"]

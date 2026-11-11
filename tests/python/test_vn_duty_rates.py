"""build_vn: MFN vs ordinary columns, TRQ (NHN) split, expired temporary
windows serve the base rate, Chapter 98 cross-references and '150% thuế MFN'
flagged, Decree provenance, VAT bands, artifact shape."""
from __future__ import annotations

import csv
import datetime as dt
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import build_duty_rates as bdr                          # noqa: E402

FIXTURE = Path(__file__).parent / "fixtures" / "vn_duty_rates_slice.csv"
REV = "2026_rev_405"
AFTER_WINDOW = dt.date(2026, 11, 11)


def _build(path=FIXTURE, snapshot=AFTER_WINDOW):
    return bdr.build_vn(path, "VN", REV, snapshot_date=snapshot)


def _by(records, digits):
    return {r["treatment"]: r for r in records if r["digits"] == digits}


def _mutated(tmp_path, changes: dict[str, dict], extra_rows=()):
    with FIXTURE.open(newline="", encoding="utf-8") as fh:
        rd = csv.DictReader(fh)
        fields, rows = rd.fieldnames, list(rd)
    for r in rows:
        r.update(changes.get(r["GOODS_CODE"], {}))
    for extra in extra_rows:
        rows.append({**{f: "" for f in fields}, **extra})
    p = tmp_path / "vn_tariff_test.csv"
    with p.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    return p


def test_mfn_and_ordinary_columns_never_swapped():
    records, _, _ = _build()
    by = _by(records, "01012100")
    assert by["MFN"]["rate_text"] == "0%" and by["MFN"]["rate_kind"] == "free"
    assert not by["MFN"].get("informational")
    gen = by["general_non_mfn"]
    assert gen["rate_text"] == "5%" and gen["informational"] is True
    assert gen["category"] == "general_rate"


def test_decree_provenance_on_mfn_rows():
    records, treatments, _ = _build()
    mfn = _by(records, "39011092")["MFN"]
    assert mfn["regulation_id"] == "199/2025/NĐ-CP"
    assert mfn["regulation_effective"] == "2025-07-08"
    assert "regulation_id" not in _by(records, "39011092")["general_non_mfn"]
    t = next(t for t in treatments if t["treatment"] == "MFN")
    assert "26/2023/NĐ-CP" in t["legal_basis"]
    assert t["legal_basis"].index("26/2023") < t["legal_basis"].index("199/2025")


def test_trq_out_of_quota_is_mfn_in_quota_informational():
    records, _, _ = _build()
    by = _by(records, "04072100")
    assert by["MFN"]["rate_text"] == "80%" and by["MFN"]["conditional"] is True
    assert "40%" in by["MFN"]["quota_note"]
    assert by["MFN"]["source_text"] == "40 (NHN: 80)"
    q = by["quota_in"]
    assert q["rate_text"] == "40%" and q["category"] == "quota"
    assert q["informational"] is True and q["conditional"] is True
    assert q["regulation_id"] == "26/2023/NĐ-CP"
    # the ordinary column's TRQ is split the same way
    assert by["general_non_mfn"]["rate_text"] == "120%"
    assert by["quota_in_general_non_mfn"]["rate_text"] == "60%"
    assert _by(records, "17011200")["general_non_mfn"]["rate_text"] == "120%"


def test_expired_window_serves_the_base_rate():
    records, _, _ = _build()
    by = _by(records, "27101971")
    mfn = by["MFN"]
    assert mfn["rate_text"] == "7%" and mfn["ad_valorem"] == 0.07
    assert "2026-03-09 to 2026-04-30" in mfn["note"]
    assert "expired" in mfn["note"] and "NĐ72" in mfn["note"]
    assert mfn["source_text"] == "7 (0% từ 09/3-30/4 theo NĐ72)"
    assert "temporary_rate" not in by
    assert not any(r["rate_text"] == "0%" for r in records
                   if r["digits"] == "27101971")


def test_open_window_adds_an_informational_row_never_the_mfn():
    records, treatments, _ = _build(snapshot=dt.date(2026, 4, 5))
    by = _by(records, "27101971")
    assert by["MFN"]["rate_text"] == "7%"                 # still the base
    tmp = by["temporary_rate"]
    assert tmp["rate_text"] == "0%" and tmp["informational"] is True
    assert tmp["valid_until"] == "2026-04-30"
    assert any(t["treatment"] == "temporary_rate" for t in treatments)


def test_chapter98_cross_reference_flagged_verbatim():
    records, _, coverage = _build()
    for digits in ("87021010", "87032113"):
        by = _by(records, digits)
        assert "MFN" not in by and "general_non_mfn" not in by
        x = by["unknown_MFN"]
        assert x["rate_text"].startswith("Theo hướng dẫn tại")
        assert x["needs_review"] == "cross_reference"
        assert x["category"] == "unknown" and x["informational"] is True
        assert "ad_valorem" not in x and "Chapter 98" in x["note"]
        rel = by["unknown_general_non_mfn"]
        assert rel["rate_text"] == "150% thuế MFN"
        assert rel["needs_review"] == "relative_to_mfn"
    assert _by(records, "87032113")["unknown_MFN"]["regulation_id"] == \
        "73/2025/NĐ-CP"


def test_chapter98_lines_are_ordinary_leaves():
    records, _, _ = _build()
    by = _by(records, "98041500")
    assert by["MFN"]["rate_text"] == "27%"
    assert by["general_non_mfn"]["rate_text"] == "40.5%"
    assert "VAT" not in by                         # the source prints none


def test_vat_bands_are_an_informational_tax():
    records, _, _ = _build()
    vat = _by(records, "04072100")["VAT"]
    assert vat["rate_text"] == "*/5%/8%/10%" and vat["source_text"] == "*/5/8/10"
    assert vat["category"] == "tax" and vat["conditional"] is True
    assert "ad_valorem" not in vat


def test_blank_and_unknown_cells_flagged_not_zero(tmp_path, monkeypatch):
    monkeypatch.setattr(bdr, "STATIC_MFN_FLOOR_PCT", 0.0)
    p = _mutated(tmp_path, {"39011092": {"MFN_RATE": "5 (xem ghi chú)"}},
                 extra_rows=[{"GOODS_CODE": "984917", "DISPLAY": "9849.17",
                              "IS_LEAF": "1", "CHAPTER": "98"}])
    records, _, _ = _build(p)
    blank = _by(records, "984917")["unknown_MFN"]
    assert blank["needs_review"] == "no_rate_in_source"
    assert blank["rate_kind"] == "none" and blank["rate_text"] == ""
    odd = _by(records, "39011092")
    assert "MFN" not in odd
    assert odd["unknown_MFN"]["needs_review"] == "unrecognised"
    assert odd["unknown_MFN"]["rate_text"] == "5 (xem ghi chú)"


def test_mfn_coverage_floor_trips(tmp_path):
    p = _mutated(tmp_path, {"39011092": {"MFN_RATE": ""}})
    with pytest.raises(SystemExit, match="floor"):
        _build(p)


def test_cli_writes_the_three_artifacts(tmp_path, monkeypatch):
    out = tmp_path / "out"
    monkeypatch.setattr(sys, "argv", [
        "build_duty_rates.py", str(FIXTURE), "--source-format", "vn",
        "--jurisdiction", "VN", "--revision", REV, "--out-dir", str(out),
        "--snapshot-date", AFTER_WINDOW.isoformat()])
    assert bdr.main() == 0
    index = json.loads((out / f"vn_{REV}.rates.index.json").read_text())
    assert index["inherit"] == "exact"
    ch98 = json.loads((out / index["chapters"]["98"]).read_text())
    assert {r["digits"] for r in ch98["records"]} == {"98041500"}
    tdoc = json.loads((out / "vn.treatments.json").read_text())
    keys = {t["treatment"] for t in tdoc["treatments"]}
    assert {"MFN", "general_non_mfn", "VAT", "quota_in",
            "unknown_MFN"} <= keys
    assert "temporary_rate" not in keys
    assert tdoc["coverage"]["provides"] and tdoc["coverage"]["excludes"]

"""build_sg: blank = nil, specific duties verbatim, PREF with unknown origins,
excise as tax, unreadable cells flagged, artifact shape."""
from __future__ import annotations

import csv
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import build_duty_rates as bdr                          # noqa: E402

FIXTURE = Path(__file__).parent / "fixtures" / "sg_duty_rates_slice.csv"
REV = "2022_rev_101"


def _build(path=FIXTURE):
    return bdr.build_sg(path, "SG", REV)


def _by(records, digits):
    return {r["treatment"]: r for r in records if r["digits"] == digits}


def _mutated(tmp_path, changes: dict[str, dict]):
    """Copy the fixture with some cells overwritten, keyed by GOODS_CODE."""
    with FIXTURE.open(newline="", encoding="utf-8") as fh:
        rd = csv.DictReader(fh)
        fields, rows = rd.fieldnames, list(rd)
    for r in rows:
        r.update(changes.get(r["GOODS_CODE"], {}))
    p = tmp_path / "sg_tariff_test.csv"
    with p.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    return p


def test_blank_full_duty_is_explicit_nil():
    records, _, _ = _build()
    mfn = _by(records, "01012100")["MFN"]
    assert mfn["rate_text"] == "Free" and mfn["rate_kind"] == "free"
    assert mfn["ad_valorem"] == 0.0
    assert mfn["rate_basis"] == "blank_nil"
    assert not mfn.get("conditional") and not mfn.get("informational")


def test_every_leaf_has_one_mfn_and_headings_get_none():
    records, _, _ = _build()
    with FIXTURE.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    leaves = {r["GOODS_CODE"] for r in rows if r["IS_LEAF"] == "1"}
    mfn = [r["digits"] for r in records if r["treatment"] == "MFN"]
    assert sorted(mfn) == sorted(leaves)
    assert not any(r["digits"] in ("0101", "2203") for r in records)


def test_beer_specific_duty_verbatim_never_a_percentage():
    records, _, _ = _build()
    mfn = _by(records, "22030011")["MFN"]
    assert mfn["rate_text"] == "$16.00 per litre of alcohol"
    assert mfn["rate_kind"] == "other" and "ad_valorem" not in mfn
    assert mfn["components"] == [{"type": "specific", "amount": 16.0,
                                  "currency": "SGD",
                                  "per": "litre of alcohol",
                                  "unit_source": "stated"}]
    assert "rate_basis" not in mfn
    samsu = _by(records, "22089010")["MFN"]
    assert samsu["rate_text"] == "$8.00 per litre of alcohol"


def test_pref_is_conditional_with_unknown_origins_flagged():
    records, treatments, _ = _build()
    pref = _by(records, "22030011")["PREF"]
    assert pref["rate_text"] == "Free" and pref["conditional"] is True
    t = next(t for t in treatments if t["treatment"] == "PREF")
    assert t["origin_countries"] == []          # never applies to an origin
    assert t["transcription_pending"] is True
    assert t["conditional"] is True and t["applies"] is None


def test_excise_is_informational_tax():
    records, _, _ = _build()
    ad_val = _by(records, "87021010")["EXCISE"]
    assert ad_val["category"] == "tax" and ad_val["informational"] is True
    assert ad_val["rate_text"] == "20%" and ad_val["ad_valorem"] == 0.2
    specific = _by(records, "24011010")["EXCISE"]
    assert specific["rate_text"] == "$535.00 per kgm"
    assert specific["rate_kind"] == "other" and "ad_valorem" not in specific
    assert specific["components"][0]["per"] == "kgm"
    dal = _by(records, "27101221")["EXCISE"]
    assert dal["components"][0] == {"type": "specific", "amount": 7.9,
                                    "currency": "SGD", "per": "dal",
                                    "unit_source": "stated"}


def test_cents_amounts_are_specific_in_major_currency_units():
    records, _, _ = _build()
    clove = _by(records, "24022020")["EXCISE"]
    assert clove["rate_text"] == ("58.9 cents for every gram or part thereof "
                                  "of each stick of cigarette")
    assert clove["rate_kind"] == "other" and "ad_valorem" not in clove
    assert clove["components"] == [{
        "type": "specific", "currency": "SGD",
        "per": "every gram or part thereof of each stick of cigarette",
        "unit_source": "stated", "amount": 0.589,
        "as_printed": "58.9 cents"}]
    lpg = _by(records, "27112110")["EXCISE"]
    assert lpg["components"][0]["amount"] == 0.2
    assert lpg["components"][0]["per"] == "kgm"


def test_and_inside_a_unit_clause_is_not_a_compound():
    records, _, _ = _build()
    diesel = _by(records, "27101971")["EXCISE"]
    assert "combine" not in diesel and len(diesel["components"]) == 1
    assert diesel["components"][0]["amount"] == 2.0
    assert "Protection and Management" in diesel["components"][0]["per"]
    assert diesel["rate_text"].startswith("$2.00 per dal of diesel fuel")


def test_unreadable_cells_are_flagged_not_dropped_or_zeroed(tmp_path):
    # The text a PDF parse once scrambled across the Pref/Excise columns of
    # these lines; the builder must carry it verbatim and flag it.
    p = _mutated(tmp_path, {
        "24022020": {"DUTY_PREF": "every part",
                     "EXCISE": "cents for gram or thereof of each stick"},
        "27112110": {"DUTY_PREF": "20", "EXCISE": "cents per kgm"}})
    records, treatments, _ = _build(p)
    for digits, pref_text in (("24022020", "every part"),
                              ("27112110", "20")):
        by = _by(records, digits)
        assert "PREF" not in by and "EXCISE" not in by
        flagged = by["unknown_PREF"]
        assert flagged["rate_text"] == pref_text
        assert flagged["informational"] is True
        assert flagged["category"] == "unknown"
        assert flagged["needs_review"] == "unrecognised"
        assert flagged["source_column"] == "DUTY_PREF"
        assert "ad_valorem" not in flagged
        assert by["unknown_EXCISE"]["source_column"] == "EXCISE"
        assert by["MFN"]["rate_basis"] == "blank_nil"
    names = {t["treatment"] for t in treatments}
    assert {"unknown_PREF", "unknown_EXCISE"} <= names


def test_unreadable_full_duty_is_flagged_and_not_mfn(tmp_path, monkeypatch):
    # one bad leaf in an 11-leaf slice is 9% — below the real-edition floor
    monkeypatch.setattr(bdr, "STATIC_MFN_FLOOR_PCT", 0.0)
    p = _mutated(tmp_path, {"22030019": {"DUTY_FULL": "see Order"}})
    records, _, _ = _build(p)
    by = _by(records, "22030019")
    assert "MFN" not in by
    assert by["unknown_MFN"]["rate_text"] == "see Order"
    assert by["unknown_MFN"]["needs_review"] == "unrecognised"


def test_mfn_coverage_floor_trips(tmp_path):
    p = _mutated(tmp_path, {"22030019": {"DUTY_FULL": "see Order"}})
    with pytest.raises(SystemExit, match="floor"):
        _build(p)


def test_all_blank_full_column_fails_rather_than_publishing_nil(tmp_path):
    p = _mutated(tmp_path, {c: {"DUTY_FULL": ""}
                            for c in ("22030011", "22030019", "22089010")})
    with pytest.raises(SystemExit, match="blank on every SG leaf"):
        _build(p)


def test_missing_column_is_a_schema_failure(tmp_path):
    p = tmp_path / "bad.csv"
    p.write_text("GOODS_CODE,DISPLAY,IS_LEAF,DUTY_FULL,EXCISE\n"
                 "01012100,0101.21.00,1,,\n", encoding="utf-8")
    with pytest.raises(SystemExit, match="DUTY_PREF"):
        _build(p)


def test_cli_writes_the_three_artifacts(tmp_path, monkeypatch):
    out = tmp_path / "out"
    monkeypatch.setattr(sys, "argv", [
        "build_duty_rates.py", str(FIXTURE), "--source-format", "sg",
        "--jurisdiction", "SG", "--revision", REV, "--out-dir", str(out)])
    assert bdr.main() == 0
    index = json.loads((out / f"sg_{REV}.rates.index.json").read_text())
    assert index["inherit"] == "exact" and index["revision"] == REV
    ch22 = json.loads((out / index["chapters"]["22"]).read_text())
    assert ch22["jurisdiction"] == "SG" and ch22["chapter"] == "22"
    for rec in ch22["records"]:
        assert {"code", "digits", "treatment", "rate_text",
                "rate_kind"} <= rec.keys()
    tdoc = json.loads((out / "sg.treatments.json").read_text())
    mfn = next(t for t in tdoc["treatments"] if t["treatment"] == "MFN")
    assert mfn["applies"] == "all_origins" and mfn["conditional"] is False
    cov = tdoc["coverage"]
    assert cov["provides"] and cov["excludes"] and cov["source"]
    assert REV in cov["as_of"]

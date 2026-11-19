"""Taiwan duty engine: three-column structure, per-line Column II origin
sets, levy markers, coverage floor -- and the provisional (機動) cuts of
config/duty_overlays/tw.json."""
import copy
import csv
import datetime as dt
import json
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


def _run(tmp_path, monkeypatch, rows, overlay=None, snapshot=None):
    """No overlay unless given: these tests pin what the SCHEDULE says."""
    monkeypatch.setattr(tw_customs, "parse_main_xls", lambda p: rows)
    nom = _nomenclature(tmp_path, [r["code"] for r in rows])
    return bdr.build_tw(tmp_path / "fake.xls", "TW", "2026_rev_729", nom,
                        snapshot_date=snapshot,
                        overlay=overlay if overlay is not None else {})


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


# ── provisional cuts (config/duty_overlays/tw.json) ──────────────────────────

OVERLAY = json.loads((Path(__file__).parents[2] / "config" / "duty_overlays"
                      / "tw.json").read_text(encoding="utf-8"))
BEEF_C2 = "0% (PA,GT,NI,SV,HN,NZ,SG,SZ,BZ)"
MILK_C2 = "0% (NI,HN,NZ,SG) 10% (PA,GT,SV)"
WHEAT_C2 = "0% (NZ,SG) 6.5% (PA,GT,NI,SV,HN)"


def _cut_rows():
    """The covered leaves as the schedule xls prints them, plus the
    neighbours that must stay untouched."""
    beef8 = ["02011010", "02011090", "02012010", "02012020", "02012090",
             "02013010", "02013020", "02013090", "02021010", "02021090",
             "02022010", "02022020", "02022090", "02023010", "02023020",
             "02023090"]
    rows = [_row(c + "003", col1="NT$10/KGM", col2=BEEF_C2,
                 col3="NT$38/KGM or 30% whichever is higher") for c in beef8]
    rows += [_row("02012090905", col1="NT$10/KGM", col2=BEEF_C2)]  # 2nd leaf
    rows += [
        _row("04021000903", col1="10%", col2=MILK_C2, col3="15%"),
        _row("04021000100", col1="10%", col2=MILK_C2, col3="15%"),  # goat
        _row("04022100900", col1="10%", col2="0% (NI,HN,NZ,SG,PY) 10% (PA,GT,SV)"),
        _row("04051000009", col1="5%", col2="0% (PA,GT,NI,SV,HN,NZ,SG)"),
        _row("04059010000", col1="8%", col2="0% (PA,GT,NI,SV,HN,NZ,SG)"),
        _row("10011900104", col1="6.5%", col2=WHEAT_C2),
        _row("10019900107", col1="6.5%", col2=WHEAT_C2),
        _row("15079000007", col1="5%", col2="0% (PA,GT,NI,SV,HN,NZ,SG)"),
        _row("15071000002", col1="5%", col2="0% (PA,GT,NI,SV,HN,NZ,SG)"),  # crude oil
    ]
    return rows


def _by(records, digits):
    return {r["treatment"]: r for r in records if r["digits"] == digits}


def test_shipped_overlay_cites_both_notices():
    ids = {a["regulation_id"]: a for a in OVERLAY["rate_amendments"]}
    assert set(ids) == {"台財關字第1151026272號", "台財關字第1151027003號"}
    for a in ids.values():
        assert (a["valid_from"], a["valid_until"]) == ("2026-10-01", "2027-03-31")
        assert "關稅法第七十一條" in a["legal_basis"]
        (inst,) = a["instruments"]
        assert inst["url"].startswith("https://gazette.nat.gov.tw/")
        assert len(inst["sha256"]) == 64 and len(inst["annex_sha256"]) == 64
    assert len(ids["台財關字第1151026272號"]["lines"]) == 22
    # 2304.00.90.10-8 is held back until Ch. 23 Additional Note 1 is read.
    assert "2304.00.90.10-8" in OVERLAY["_unresolved"]


def test_in_force_the_provisional_rate_is_served_dated(tmp_path, monkeypatch):
    records, treatments, coverage = _run(
        tmp_path, monkeypatch, _cut_rows(), overlay=OVERLAY,
        snapshot=dt.date(2026, 11, 19))
    beef = _by(records, "02011010003")
    assert beef["erga_omnes"]["rate_text"] == "NT$5/KGM"
    assert (beef["erga_omnes"]["valid_from"], beef["erga_omnes"]["valid_until"]) == (
        "2026-10-01", "2027-03-31")
    assert beef["erga_omnes"]["regulation_id"] == "台財關字第1151026272號"
    assert beef["erga_omnes"]["temporary_basis"].startswith("台財關字第1151026272號")
    nxt = beef["erga_omnes_scheduled"]
    assert (nxt["rate_text"], nxt["valid_from"]) == ("NT$10/KGM", "2027-04-01")
    assert nxt["category"] == "scheduled_rate" and nxt["informational"]
    # Column II was already free on beef: untouched, undated.
    (pref,) = [r for t, r in beef.items() if t.startswith("pref_")]
    assert pref["rate_text"] == "0%" and "valid_until" not in pref
    # Column III never changes.
    assert beef["general_non_wto"]["rate_text"].startswith("NT$38/KGM")
    # Every leaf under an 8-digit scope is cut, not only the first.
    assert _by(records, "02012090905")["erga_omnes"]["rate_text"] == "NT$5/KGM"
    assert _by(records, "15079000007")["erga_omnes"]["rate_text"] == "0%"
    assert _by(records, "04051000009")["erga_omnes"]["rate_text"] == "2.5%"
    assert _by(records, "04059010000")["erga_omnes"]["rate_text"] == "4%"
    names = {t["treatment"]: t for t in treatments}
    assert names["erga_omnes_scheduled"]["category"] == "scheduled_rate"
    assert "台財關字第1151026272號" in coverage["as_of"]


def test_column_ii_is_cut_only_for_the_printed_origin_group(tmp_path, monkeypatch):
    records, _, _ = _run(tmp_path, monkeypatch, _cut_rows(), overlay=OVERLAY,
                         snapshot=dt.date(2026, 11, 19))
    milk = _by(records, "04021000903")
    assert milk["erga_omnes"]["rate_text"] == "5%"
    assert milk["pref_gt-pa-sv"]["rate_text"] == "5%"
    assert milk["pref_gt-pa-sv_scheduled"]["rate_text"] == "10%"
    assert milk["pref_hn-ni-nz-sg"]["rate_text"] == "0%"
    assert "valid_until" not in milk["pref_hn-ni-nz-sg"]
    wheat = _by(records, "10011900104")
    assert wheat["erga_omnes"]["rate_text"] == "0%"
    assert wheat["pref_gt-hn-ni-pa-sv"]["rate_text"] == "0%"
    assert wheat["pref_nz-sg"]["rate_text"] == "0%" and "valid_until" not in wheat["pref_nz-sg"]


def test_a_printed_ccc_leaf_does_not_spread_to_its_siblings(tmp_path, monkeypatch):
    records, _, _ = _run(tmp_path, monkeypatch, _cut_rows(), overlay=OVERLAY,
                         snapshot=dt.date(2026, 11, 19))
    goat = _by(records, "04021000100")     # same 8 digits, not CCC0402.10.00.90-3
    assert goat["erga_omnes"]["rate_text"] == "10%"
    assert "valid_until" not in goat["erga_omnes"]
    assert "erga_omnes_scheduled" not in goat
    crude = _by(records, "15071000002")    # neighbouring heading, not cut
    assert crude["erga_omnes"]["rate_text"] == "5%" and "valid_until" not in crude["erga_omnes"]


def test_window_edges(tmp_path, monkeypatch):
    def beef_on(day):
        records, _, _ = _run(tmp_path, monkeypatch, _cut_rows(), overlay=OVERLAY,
                             snapshot=day)
        return _by(records, "02011010003")
    before = beef_on(dt.date(2026, 9, 30))
    assert before["erga_omnes"]["rate_text"] == "NT$10/KGM"
    assert "not yet in force" in before["erga_omnes"]["note"]
    assert "erga_omnes_scheduled" not in before
    assert beef_on(dt.date(2026, 10, 1))["erga_omnes"]["rate_text"] == "NT$5/KGM"
    assert beef_on(dt.date(2027, 3, 31))["erga_omnes"]["rate_text"] == "NT$5/KGM"
    after = beef_on(dt.date(2027, 4, 1))
    assert after["erga_omnes"]["rate_text"] == "NT$10/KGM"
    assert "ended" in after["erga_omnes"]["note"]


def test_a_schedule_that_has_moved_on_stops_the_build(tmp_path, monkeypatch):
    rows = _cut_rows()
    rows[0]["col1"] = "NT$8/KGM"      # the schedule now prints another rate
    with pytest.raises(SystemExit, match="expects Column I 'NT\\$10/KGM'"):
        _run(tmp_path, monkeypatch, rows, overlay=OVERLAY, snapshot=dt.date(2026, 11, 19))
    rows = _cut_rows()
    (milk,) = [r for r in rows if r["code"] == "04021000903"]
    milk["col2"] = "0% (NI,HN,NZ,SG) 8% (PA,GT,SV)"       # Column II moved on
    with pytest.raises(SystemExit, match="expects pref_gt-pa-sv '10%'"):
        _run(tmp_path, monkeypatch, rows, overlay=OVERLAY, snapshot=dt.date(2026, 11, 19))


def test_a_scope_that_covers_nothing_or_twice_stops_the_build(tmp_path, monkeypatch):
    rows = [r for r in _cut_rows() if not r["code"].startswith("1507")]
    with pytest.raises(SystemExit, match="covers no leaf"):
        _run(tmp_path, monkeypatch, rows, overlay=OVERLAY, snapshot=dt.date(2026, 11, 19))
    twice = copy.deepcopy(OVERLAY)
    twice["rate_amendments"][1]["lines"].append({"scope": "0405.10.00",
                                                 "column_1": ["5%", "0%"]})
    with pytest.raises(SystemExit, match="cut by both"):
        _run(tmp_path, monkeypatch, _cut_rows(), overlay=twice, snapshot=dt.date(2026, 11, 19))

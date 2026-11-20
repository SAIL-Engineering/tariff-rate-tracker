"""build_kr: precedence, class mapping, variants, blank!=0, unknown tripwire."""
from __future__ import annotations

import csv
import datetime as dt
import sys
import zipfile
from pathlib import Path
from xml.sax.saxutils import escape

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

import build_duty_rates as bdr                          # noqa: E402

SNAP = dt.date(2026, 9, 2)
CLASSES = Path(__file__).resolve().parents[2] / "config" / "kr_rate_classes.json"
RATE_HDR = ["품목번호", "관세율구분", "관세율", "단위당세액", "기준가격",
            "적용국가구분", "용도세율구분", "적용개시일", "적용만료일"]


def _rates_xlsx(tmp_path, rows, sheets=("1.1",)):
    p = tmp_path / "rates.xlsx"
    def sheet_xml(rws):
        out = ['<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>']
        for ri, row in enumerate(rws, 1):
            out.append(f'<row r="{ri}">')
            for ci, val in enumerate(row):
                col = chr(ord("A") + ci)
                out.append(f'<c r="{col}{ri}" t="inlineStr"><is><t>{escape(str(val))}</t></is></c>')
            out.append('</row>')
        out.append('</sheetData></worksheet>')
        return "".join(out)
    names = list(sheets)
    ct = ('<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
          + "".join(f'<Override PartName="/xl/worksheets/sheet{i+1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' for i in range(len(names)))
          + '</Types>')
    wb = ('<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
          + "".join(f'<sheet name="{escape(n)}" sheetId="{i+1}" r:id="rId{i+1}"/>' for i, n in enumerate(names))
          + '</sheets></workbook>')
    rels = ('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + "".join(f'<Relationship Id="rId{i+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i+1}.xml"/>' for i in range(len(names)))
            + '</Relationships>')
    with zipfile.ZipFile(p, "w") as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr("xl/workbook.xml", wb)
        z.writestr("xl/_rels/workbook.xml.rels", rels)
        for i in range(len(names)):
            rws = [RATE_HDR] + (rows if i == 0 else [])
            z.writestr(f"xl/worksheets/sheet{i+1}.xml", sheet_xml(rws))
    return p


def _nomenclature(tmp_path, leaves=("0101211000",)):
    p = tmp_path / "kr.csv"
    with p.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["GOODS_CODE", "SUFFIX", "INDENT", "DESCRIPTION", "UNIT",
                    "IS_LEAF", "START_DATE"])
        for leaf in leaves:
            w.writerow([leaf, "80", "5", "x", "U", "1", "2013-01-01"])
    return p


def _row(hsk="0101211000", cls="A", rate="8", unit_tax="", base="",
         country="1", use="", start="20260101", end="20261231"):
    return [hsk, cls, rate, unit_tax, base, country, use, start, end]


def _build(tmp_path, rows, leaves=("0101211000",), overlay=None, snap=SNAP):
    """No overlay unless given: these tests pin what the KCS FILE says."""
    return bdr.build_kr(_rates_xlsx(tmp_path, rows), "KR", "2026_rev_101",
                        nomenclature_csv=_nomenclature(tmp_path, leaves),
                        snapshot_date=snap, classes_json=CLASSES,
                        rates_date="20260211",
                        overlay=overlay if overlay is not None else {})


def test_applied_rate_c_wins_when_lower(tmp_path):
    records, treatments, coverage = _build(tmp_path, [
        _row(cls="A", rate="8"), _row(cls="C", rate="5"),
    ])
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["rate_text"] == "5%" and erga["source_class"] == "C"
    # raw inputs stay visible but informational
    basis = [r for r in records if r.get("category") == "rate_basis"]
    assert {r["rate_class"] for r in basis} == {"A", "C"}


def test_applied_rate_c_ignored_when_higher(tmp_path):
    records, _, _ = _build(tmp_path, [
        _row(cls="A", rate="3"), _row(cls="C", rate="5"),
    ])
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["rate_text"] == "3%" and erga["source_class"] == "A"


def test_provisional_beats_basic(tmp_path):
    records, _, _ = _build(tmp_path, [
        _row(cls="A", rate="8"), _row(cls="B", rate="12"),
    ])
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["source_class"] == "B"           # tier 6 beats tier 7 outright


def test_fta_rows_conditional_with_family(tmp_path):
    records, treatments, _ = _build(tmp_path, [
        _row(cls="A", rate="8"), _row(cls="FUS1", rate="0", country="2"),
    ])
    pref = next(r for r in records if r["treatment"] == "pref_FUS1")
    assert pref["conditional"] is True
    t = next(t for t in treatments if t["treatment"] == "pref_FUS1")
    assert t["origin_countries"] == ["US"]
    assert "KORUS" in t["name"] or "US" in t["name"]


def test_special_measures_informational_additive(tmp_path):
    records, _, _ = _build(tmp_path, [
        _row(cls="A", rate="8"), _row(cls="I", rate="35.9", country="2"),
    ])
    ad = next(r for r in records if r.get("category") == "anti_dumping")
    assert ad["informational"] and ad.get("additive") is True


def test_unknown_class_tripwire(tmp_path, capsys):
    records, _, _ = _build(tmp_path, [
        _row(cls="A", rate="8"), _row(cls="ZZZ9", rate="1"),
    ])
    unk = next(r for r in records if r.get("category") == "unknown")
    assert unk["treatment"] == "unknown_ZZZ9" and unk["informational"]
    assert "UNKNOWN rate classes" in capsys.readouterr().out


def test_blank_components_never_zero(tmp_path):
    records, _, _ = _build(tmp_path, [
        _row(cls="A", rate="", unit_tax="1276", base="21603"),
    ])
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert "0%" not in erga["rate_text"]
    assert "₩1276 per unit" in erga["rate_text"]
    assert "(base price ₩21603)" in erga["rate_text"]


def test_expired_and_future_rows_dropped(tmp_path):
    records, _, _ = _build(tmp_path, [
        _row(cls="A", rate="8"),
        _row(cls="A", rate="99", end="20260210"),          # expired
        _row(cls="FUS1", rate="7", start="20270101"),      # future
    ])
    erga = next(r for r in records if r["treatment"] == "erga_omnes")
    assert erga["rate_text"] == "8%"
    assert not any(r["treatment"] == "pref_FUS1" for r in records)


def test_class_variants_stay_distinguishable(tmp_path):
    records, _, _ = _build(tmp_path, [
        _row(cls="A", rate="8"),
        _row(cls="E2A1", rate="7", country="2"),
        _row(cls="E2A2", rate="0", country="2"),
    ])
    treats = {r["treatment"] for r in records}
    assert "pref_apta_bd_e2a1" in treats and "pref_apta_bd_e2a2" in treats


def test_coverage_floor_trips_without_a_rows(tmp_path):
    with pytest.raises(SystemExit):
        _build(tmp_path, [_row(cls="FUS1", rate="0", country="2")])


# ── quota tariff annexes (config/duty_overlays/kr.json) ──────────────────────

import copy                                              # noqa: E402
import json                                              # noqa: E402

OVERLAY = json.loads((Path(__file__).resolve().parents[2] / "config" / "duty_overlays"
                      / "kr.json").read_text(encoding="utf-8"))
NOV = dt.date(2026, 11, 19)
# Leaves under every annex scope (the build stops on a scope that covers none),
# plus neighbours that must stay untouched.
QUOTA_LEAVES = ("1803100000", "1804000000", "1805000000", "1806100000",
                "2711121000", "2711130000", "2711110000", "2711210000",
                "2008200000", "2008190000", "2009290000", "2009490000",
                "2009790000", "2306600000")


def _quota_rows():
    """Base rates run past the annex (a real A row carries no 2026 end date)."""
    def base(**kw):
        return _row(**{"end": "20271231", **kw})
    rows = [base(hsk=h, cls="A", rate="5") for h in ("1803100000", "1804000000",
                                                      "1805000000")]
    rows += [base(hsk="1803100000", cls="C", rate="19.7"),
             # the KCS file's H1 quota row: expired by the validity filter
             _row(hsk="1803100000", cls="P3", rate="0", start="20260101", end="20260630"),
             base(hsk="1806100000", cls="A", rate="8"),                  # sweetened: not cut
             base(hsk="2711121000", cls="A", rate="3"),
             # a stale H2 row from the superseded annex: dropped while the decree is in force
             _row(hsk="2711121000", cls="P3", rate="1", start="20260701", end="20261231"),
             base(hsk="2711130000", cls="A", rate="3"),
             base(hsk="2711110000", cls="A", rate="3"),
             base(hsk="2711210000", cls="A", rate="3"),
             base(hsk="2008200000", cls="A", rate="45"), base(hsk="2008200000", cls="C", rate="45"),
             base(hsk="2008190000", cls="A", rate="45"),
             base(hsk="2009290000", cls="A", rate="54"),
             base(hsk="2009490000", cls="A", rate="50"),
             base(hsk="2009790000", cls="A", rate="45"),
             base(hsk="2306600000", cls="A", rate="3")]
    return rows


def _by(records, digits):
    return {r["treatment"]: r for r in records if r["digits"] == digits}


def _quota_build(tmp_path, snap=NOV, overlay=None, rows=None):
    return _build(tmp_path, rows or _quota_rows(), leaves=QUOTA_LEAVES,
                  overlay=overlay if overlay is not None else OVERLAY, snap=snap)


def test_shipped_overlay_cites_decree_36450_annex5():
    (a,) = OVERLAY["quota_tariffs"]
    assert a["regulation_id"] == "대통령령 제36450호"
    assert (a["promulgated"], a["valid_from"], a["valid_until"]) == (
        "2026-06-30", "2026-07-01", "2026-12-31")
    assert a["annex"].startswith("별표 5")
    assert len(a["instruments"][0]["annex_sha256"]) == 64
    by = {ln["scope"]: ln for ln in a["lines"]}
    for s in ("1803.10", "1804.00", "1805.00"):
        assert (by[s]["rate_pct"], by[s]["volume"]) == (0, "all")
    assert by["2008.20"]["rate_pct"] == 15 and by["2008.20"]["volume"] == {"amount": 8000, "unit": "t"}
    assert a["not_modelled"], "lines with a specification or sub-item are listed, not guessed"


def test_all_volume_quota_tariff_is_the_applied_rate_dated(tmp_path):
    records, treatments, coverage = _quota_build(tmp_path)
    cocoa = _by(records, "1803100000")
    erga = cocoa["erga_omnes"]
    assert (erga["rate_text"], erga["source_class"]) == ("0%", "할당관세")
    assert (erga["valid_from"], erga["valid_until"]) == ("2026-07-01", "2026-12-31")
    assert erga["regulation_id"] == "대통령령 제36450호"
    nxt = cocoa["erga_omnes_scheduled"]
    assert (nxt["rate_text"], nxt["valid_from"], nxt["source_class"]) == ("5%", "2027-01-01", "A")
    assert nxt["informational"] and nxt["category"] == "scheduled_rate"
    for h in ("1804000000", "1805000000", "2711130000", "2711110000", "2711210000"):
        assert _by(records, h)["erga_omnes"]["rate_text"] == "0%"
    names = {t["treatment"]: t for t in treatments}
    assert names["erga_omnes_scheduled"]["category"] == "scheduled_rate"
    assert "대통령령 제36450호" in coverage["as_of"]


def test_a_stale_kcs_quota_row_is_superseded(tmp_path):
    records, _, _ = _quota_build(tmp_path)
    lpg = _by(records, "2711121000")
    assert lpg["erga_omnes"]["rate_text"] == "0%"
    assert not any(r.get("rate_class") == "P3" for r in records if r["digits"] == "2711121000")


def test_a_finite_quota_never_replaces_the_applied_rate(tmp_path):
    records, treatments, _ = _quota_build(tmp_path)
    pine = _by(records, "2008200000")
    assert pine["erga_omnes"]["rate_text"] == "45%" and "valid_until" not in pine["erga_omnes"]
    assert "erga_omnes_scheduled" not in pine
    q = pine["quota_art71"]
    assert q["rate_text"] == "15%" and q["informational"] and q["conditional"]
    assert q["category"] == "quota"
    assert (q["valid_from"], q["valid_until"]) == ("2026-07-01", "2026-12-31")
    assert "8,000 t" in q["conditions"][0]
    assert {t["treatment"]: t for t in treatments}["quota_art71"]["category"] == "quota"


def test_neighbours_are_untouched(tmp_path):
    records, _, _ = _quota_build(tmp_path)
    sweet = _by(records, "1806100000")
    assert sweet["erga_omnes"]["rate_text"] == "8%" and "erga_omnes_scheduled" not in sweet
    other = _by(records, "2008190000")
    assert other["erga_omnes"]["rate_text"] == "45%" and "quota_art71" not in other


def test_window_edges(tmp_path):
    def cocoa_on(day):
        return _by(_quota_build(tmp_path, snap=day)[0], "1803100000")
    before = cocoa_on(dt.date(2026, 6, 30))
    assert before["erga_omnes"]["rate_text"] == "5%" and "erga_omnes_scheduled" not in before
    assert cocoa_on(dt.date(2026, 7, 1))["erga_omnes"]["rate_text"] == "0%"
    assert cocoa_on(dt.date(2026, 12, 31))["erga_omnes"]["rate_text"] == "0%"
    after = cocoa_on(dt.date(2027, 1, 1))
    assert after["erga_omnes"]["rate_text"] == "5%" and "erga_omnes_scheduled" not in after
    pine_after = _by(_quota_build(tmp_path, snap=dt.date(2027, 1, 1))[0], "2008200000")
    assert "quota_art71" not in pine_after


def test_bad_annex_entries_stop_the_build(tmp_path):
    with pytest.raises(SystemExit, match="covers no HSK leaf"):
        _build(tmp_path, _quota_rows(), leaves=QUOTA_LEAVES[:-1], overlay=OVERLAY, snap=NOV)
    twice = copy.deepcopy(OVERLAY)
    twice["quota_tariffs"][0]["lines"].append(
        {"scope": "1803.10", "rate_pct": 0, "volume": "all", "page": 3})
    with pytest.raises(SystemExit, match="covered twice"):
        _quota_build(tmp_path, overlay=twice)
    rows = [r for r in _quota_rows() if r[0] != "1804000000"] + [
        _row(hsk="1804000000", cls="A", rate="", unit_tax="1200")]
    with pytest.raises(SystemExit, match="not a plain percentage"):
        _quota_build(tmp_path, rows=rows)

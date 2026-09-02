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


def _build(tmp_path, rows, leaves=("0101211000",)):
    return bdr.build_kr(_rates_xlsx(tmp_path, rows), "KR", "2026_rev_101",
                        nomenclature_csv=_nomenclature(tmp_path, leaves),
                        snapshot_date=SNAP, classes_json=CLASSES,
                        rates_date="20260211")


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

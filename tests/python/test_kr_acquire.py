"""kr_kcs adapter: hierarchy merge, longest-prefix parents, bilingual
canonical emission, master reconciliation, gate outcomes."""
from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

from acquire import kr_kcs as kr                        # noqa: E402


def _hier_xlsx(tmp_path, sheets):
    """Minimal xlsx via the same zip layout _xlsx_lite reads."""
    import zipfile
    from xml.sax.saxutils import escape
    tmp_path.mkdir(parents=True, exist_ok=True)
    p = tmp_path / "hier.xlsx"
    ct = ('<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
          '<Default Extension="xml" ContentType="application/xml"/>'
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
          + "".join(f'<Override PartName="/xl/worksheets/sheet{i+1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
                    for i in range(len(sheets))) + '</Types>')
    wb = ('<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
          + "".join(f'<sheet name="{escape(n)}" sheetId="{i+1}" r:id="rId{i+1}"/>'
                    for i, n in enumerate(sheets)) + '</sheets></workbook>')
    rels = ('<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            + "".join(f'<Relationship Id="rId{i+1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{i+1}.xml"/>'
                      for i in range(len(sheets))) + '</Relationships>')
    def sheet_xml(rows):
        out = ['<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>']
        for ri, row in enumerate(rows, 1):
            out.append(f'<row r="{ri}">')
            for ci, val in enumerate(row):
                col = chr(ord("A") + ci)
                out.append(f'<c r="{col}{ri}" t="inlineStr"><is><t>{escape(str(val))}</t></is></c>')
            out.append('</row>')
        out.append('</sheetData></worksheet>')
        return "".join(out)
    with zipfile.ZipFile(p, "w") as z:
        z.writestr("[Content_Types].xml", ct)
        z.writestr("_rels/.rels", '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>')
        z.writestr("xl/workbook.xml", wb)
        z.writestr("xl/_rels/workbook.xml.rels", rels)
        for i, (_n, rows) in enumerate(sheets.items()):
            z.writestr(f"xl/worksheets/sheet{i+1}.xml", sheet_xml(rows))
    return p


HDR = ["HS부호", "한글품목명", "영문품목명"]


def _basic_sheets():
    return {
        "HS2단위": [["HS2단위", "한글품목명", "영문품목명"], ["01", "제1류 동물", "Live animals"]],
        "HS4단위": [["HS4단위", "한글품목명", "영문품목명"], ["0101", "말", "Horses"]],
        "HS6단위(5단위포함)": [["HS6단위", "한글품목명", "영문품목명"],
                          ["01012", "말들", "Horses :"],
                          ["010121", "번식용", "Pure-bred"]],
        "HS8단위(7, 9단위포함)": [["HS8단위", "한글품목명", "영문품목명"],
                             ["010121100", "구단위", "Nine-digit level"]],
        "HS10단위": [["HS10단위", "한글품목명", "영문품목명"],
                   ["0101211000", "농가 사육용", "For farm breeding"],
                   ["0101211001", "기타", "Other"]],
    }


def _master_xlsx(tmp_path, codes):
    rows = [["HS부호", "적용시작일자", "적용종료일자", "한글품목명", "영문품목명", "", "", "", "", "수량단위코드"]]
    for c in codes:
        rows.append([c, "41275", "", "이름", "name", "", "", "", "", "U"])
    return _hier_xlsx(tmp_path / "m", {"Sheet 1": rows})


def test_convert_longest_prefix_parents_and_bilingual(tmp_path):
    hier = _hier_xlsx(tmp_path, _basic_sheets())
    master = _master_xlsx(tmp_path, ["0101211000", "0101211001"])
    out = tmp_path / "kr.csv"
    stats = kr.convert(hier, master, out)
    rows = list(csv.DictReader(out.open(encoding="utf-8-sig")))
    codes = [(r["GOODS_CODE"], r["INDENT"]) for r in rows]
    # pre-order with longest-prefix depth: 01(0) 0101(1) 01012(2) 010121(3)
    # 010121100(4 — the 9-digit intermediate) and both 10-digit codes at 5
    # (their longest existing prefix is the 9-digit node, never a fixed 8).
    assert ("01", "0") in codes and ("01012", "2") in codes
    d = {r["GOODS_CODE"]: r for r in rows}
    assert d["010121100"]["INDENT"] == "4"
    assert d["0101211000"]["INDENT"] == "5"      # parent = 9-digit level
    assert d["0101211000"]["IS_LEAF"] == "1"
    assert d["010121"]["IS_LEAF"] == "0"
    assert d["0101211000"]["UNIT"] == "U"
    assert d["0101211000"]["START_DATE"] == "2013-01-01"   # excel serial 41275
    ko = list(csv.DictReader((tmp_path / "kr.ko.csv").open(encoding="utf-8-sig")))
    dko = {r["GOODS_CODE"]: r for r in ko}
    assert dko["0101211000"]["DESCRIPTION"] == "농가 사육용"
    assert stats["only_in_hierarchy"] == 0 and stats["only_in_master"] == 0


def test_convert_reports_reconciliation_exceptions(tmp_path, capsys):
    hier = _hier_xlsx(tmp_path, _basic_sheets())
    master = _master_xlsx(tmp_path, ["0101211000", "9999999999"])
    kr.convert(hier, master, tmp_path / "kr.csv")
    outp = capsys.readouterr().out
    assert "RECONCILE" in outp
    assert "9999999999" in outp or "master" in outp


def test_header_change_trips(tmp_path):
    sheets = _basic_sheets()
    sheets["HS2단위"][0] = ["HS2단위", "품목명", "영문품목명"]   # renamed column
    with pytest.raises(SystemExit):
        kr.parse_hierarchy(_hier_xlsx(tmp_path, sheets))


def test_rev_mapping():
    assert kr._rev_from_file_date("20260101") == ("2026_rev_101", 2026, 101)
    assert kr._rev_from_file_date("20261115") == ("2026_rev_1115", 2026, 1115)


def test_gate_modes(tmp_path, monkeypatch):
    monkeypatch.setattr(kr, "STATE_PATH", tmp_path / "state.json")
    kr.save_state({"corpus_revision": "2026_rev_101",
                   "corpus_effective": "2026-01-01",
                   "hierarchy_file_date": "20260101", "hierarchy_modified": "x",
                   "master_file_date": "20260101", "master_modified": "x",
                   "rates_file_date": "20260211", "rates_modified": "y"})
    metas = {"hierarchy": {"file_date": "20260101", "dateModified": "x", "alternateName": ""},
             "master": {"file_date": "20260101", "dateModified": "x", "alternateName": ""},
             "rates": {"file_date": "20260211", "dateModified": "y", "alternateName": ""}}
    monkeypatch.setattr(kr, "_session", lambda: None)
    monkeypatch.setattr(kr, "fetch_metadata",
                        lambda s, d: metas[{v: k for k, v in kr.DATASETS.items()}[d]])
    args = argparse.Namespace()
    chk = kr.check_latest({"code": "KR"}, args)
    assert chk.extras["mode"] == "full" and chk.rev_id == "2026_rev_101"

    metas["rates"] = {"file_date": "20260901", "dateModified": "z", "alternateName": ""}
    chk = kr.check_latest({"code": "KR"}, args)
    assert chk.extras["mode"] == "rates_only"

    metas["hierarchy"] = {"file_date": "20270101", "dateModified": "w", "alternateName": ""}
    chk = kr.check_latest({"code": "KR"}, args)
    assert chk.extras["mode"] == "full" and chk.rev_id == "2027_rev_101"

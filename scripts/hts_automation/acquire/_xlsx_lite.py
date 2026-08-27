"""Minimal stdlib XLSX sheet reader (zip + XML), used by the EU adapter.

openpyxl is the production converter inside the vendored downloader; this
fallback keeps offline builds and CI working on a bare python3. Handles shared
strings, inline strings, and multi-sheet workbooks. Values come back as the
raw stored strings — good enough for the TARIC exports, whose code and date
columns are text.
"""
from __future__ import annotations

import re
import zipfile
from xml.etree import ElementTree as ET

_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
_RELS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"


def _col_letters(ref: str) -> str:
    m = re.match(r"([A-Z]+)", ref or "")
    return m.group(1) if m else ""


def read_sheets(path: str) -> dict[str, list[dict[str, str]]]:
    """{sheet_name: [ {col_letter: value, ...}, ... ]}"""
    z = zipfile.ZipFile(path)
    shared: list[str] = []
    if "xl/sharedStrings.xml" in z.namelist():
        root = ET.fromstring(z.read("xl/sharedStrings.xml"))
        for si in root.findall(f"{_NS}si"):
            shared.append("".join(t.text or "" for t in si.iter(f"{_NS}t")))
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    sheets = [(s.get("name"), s.get(f"{_RELS}id"))
              for s in wb.iter(f"{_NS}sheet")]
    rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
    rmap = {r.get("Id"): r.get("Target") for r in rels}
    out: dict[str, list[dict[str, str]]] = {}
    for name, rid in sheets:
        tgt = rmap[rid].lstrip("/")
        if not tgt.startswith("xl/"):
            tgt = "xl/" + tgt
        rows: list[dict[str, str]] = []
        for _, el in ET.iterparse(z.open(tgt)):
            if el.tag == f"{_NS}row":
                row: dict[str, str] = {}
                for c in el:
                    ref = c.get("r") or ""
                    t = c.get("t")
                    v = c.find(f"{_NS}v")
                    if v is None:
                        isel = c.find(f"{_NS}is")
                        val = ("".join(x.text or "" for x in isel.iter())
                               if isel is not None else "")
                    else:
                        val = v.text or ""
                        if t == "s":
                            val = shared[int(val)]
                    row[_col_letters(ref)] = val
                rows.append(row)
                el.clear()
        out[name] = rows
    return out


def first_sheet(path: str) -> list[dict[str, str]]:
    sheets = read_sheets(path)
    return next(iter(sheets.values()))

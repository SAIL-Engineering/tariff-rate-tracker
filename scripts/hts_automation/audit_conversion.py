#!/usr/bin/env python3
"""audit_conversion.py -- check the Singapore, Malaysia and Vietnam conversions
against their own sources, WITHOUT reusing the parsers' code.

A parser cannot vouch for itself: a check that reads the page the way the parser
does shares its blind spots. (The first audit, on 2026-11-11, sliced Singapore's
duty columns by vertical position exactly as the parser did, and so missed the
cigarette excise that the parser had scrambled.) Every check here reads the
source by a different route: `pdftotext -layout` instead of bounding boxes, the
xlsx through zipfile instead of openpyxl, Malaysia's ezHS portal instead of its
gazette, and the other two ASEAN books instead of the one under test.

Run it after any parser change and before publishing a new edition:

  python3 -I scripts/hts_automation/audit_conversion.py              # SG, MY, VN
  python3 -I scripts/hts_automation/audit_conversion.py -j MY --json report.json

Exit status 1 when any gate fails. A check whose source file is absent is
reported as skipped, not passed.

CHECKS
  cross_source   SG, MY and VN all use AHTN 2022, so their English text for the
                 ~11,400 shared eight-digit lines should agree. Where two agree
                 and the third is a strict prefix of them, the third was cut
                 short (gate: 0). Other differences are mostly each book's own
                 typography and wording, and are reported, not gated.
  hygiene        Text no description should ever contain: a sub-chapter heading,
                 a flattened super/subscript ("g/m 2", "H BO 3 3", "23 o C"), a
                 line-break hyphen followed by a space (gate: 0 for the PDFs).
  containment    Every SG/MY description's words occur in order on its own PDF
                 page or the next (gate: 0).
  page_breaks    MY: text at the top of a page, above its first code, that
                 continues the last row of the previous page is in that row
                 (gate: 0 lost).
  portal         MY: import rate and unit equal the ezHS portal's; no gazette
                 description is a truncated prefix of the portal's (gate: 0).
  sg_duties      SG: each row's customs and excise text, as `pdftotext -layout`
                 lays it out from the code line down to the next code line,
                 equals the parsed FULL + PREF + EXCISE words (gate: 0).
  workbook       VN: every code, English and Vietnamese description, MFN and
                 ordinary rate equals the workbook cell (gate: 0).
"""
from __future__ import annotations

import argparse
import csv
import html
import json
import re
import subprocess
import sys
import unicodedata
import zipfile
from collections import Counter, defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET

REPO = Path(__file__).resolve().parents[2]
SOURCES = {
    "SG": {"pdf": "data/sg_tariff_source/.sg_download/stcced2022.pdf"},
    "MY": {"pdf": "data/my_tariff_source/.my_download/PUA_384.pdf",
           "html": "data/my_tariff_source/.my_download/ezhs_pdk2025.html"},
    "VN": {"xlsx": "data/vn_tariff_source/.vn_download/vn_tariff.xlsx"},
}
SAMPLES = 8


# ── shared helpers ───────────────────────────────────────────────────────────

def digits(s: str) -> str:
    return re.sub(r"\D", "", s or "")


def alnum(s: str) -> str:
    """Letters and digits only, after NFKC (so "cm³" is "cm3") and with the
    degree sign read as the "o" the PDFs print it as."""
    s = unicodedata.normalize("NFKC", (s or "").replace("\u00b0", "o"))
    return re.sub(r"[^a-z0-9]", "", s.lower())


def tokens(s: str) -> list[str]:
    """Letter runs and digit runs, so a glued "h3bo3" or "23oc" compares with the
    page's "h", "3", "bo", "3" whichever way the page split it."""
    s = unicodedata.normalize("NFKC", (s or "").replace("\u00b0", "o")).lower()
    return re.findall(r"[a-z]+|[0-9]+", s)


def strip_dashes(s: str) -> str:
    return re.sub(r"^[\s\-–:]+", "", s or "")


def canonical_csv(cc: str, lang: str = "") -> Path | None:
    """The newest data/<cc>_tariff_source/<cc>_tariff_<year>_rev_<n>.csv."""
    found = sorted((REPO / "data" / f"{cc.lower()}_tariff_source").glob(
        f"{cc.lower()}_tariff_*_rev_*{'.' + lang if lang else ''}.csv"))
    found = [p for p in found if p.name.count(".") == (2 if lang else 1)]
    return found[-1] if found else None


def read_rows(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


_LAYOUT: dict = {}


def layout_pages(pdf: Path) -> list[str]:
    """pdftotext -layout, one string per PDF page (index 0 = page 1)."""
    if pdf not in _LAYOUT:
        out = subprocess.run(["pdftotext", "-layout", str(pdf), "-"],
                             capture_output=True, text=True, check=True).stdout
        _LAYOUT[pdf] = out.split("\f")
    return _LAYOUT[pdf]


def result(name: str, ok: bool | None, counts: dict, samples: list | None = None) -> dict:
    return {"check": name, "status": "skipped" if ok is None else ("pass" if ok else "FAIL"),
            "counts": counts, "samples": (samples or [])[:SAMPLES]}


# ── cross-source ─────────────────────────────────────────────────────────────

def eight_digit_text(cc: str, rows: list[dict]) -> dict:
    """code8 -> description of that AHTN line. Malaysia states its eight-digit
    lines as ten-digit ones ending 00, or as an internal eight-digit node."""
    if cc != "MY":
        return {digits(r["GOODS_CODE"]): r["DESCRIPTION"] for r in rows
                if len(digits(r["GOODS_CODE"])) == 8}
    eight = {digits(r["GOODS_CODE"]): r["DESCRIPTION"] for r in rows
             if len(digits(r["GOODS_CODE"])) == 8}
    kids = defaultdict(list)
    for r in rows:
        d = digits(r["GOODS_CODE"])
        if len(d) == 10:
            kids[d[:8]].append(r["DESCRIPTION"])
    out = dict(eight)
    for stem, texts in kids.items():
        if stem not in out and len(texts) == 1:
            out[stem] = texts[0]
    return out


def check_cross_source(rows: dict, pdfs: dict | None = None) -> list[dict]:
    if len(rows) < 3:
        return [result("cross_source", None, {"reason": "needs all three of SG, MY, VN"})]
    text = {cc: eight_digit_text(cc, r) for cc, r in rows.items()}
    shared = sorted(set.intersection(*(set(t) for t in text.values())))
    counts, truncated, odd = Counter(), [], Counter()
    for code in shared:
        keys = {cc: alnum(strip_dashes(text[cc][code])) for cc in text}
        if len(set(keys.values())) == 1:
            counts["identical_letters_and_digits"] += 1
            continue
        for cc in keys:
            others = [k for o, k in keys.items() if o != cc]
            if others[0] == others[1] != keys[cc]:
                odd[cc] += 1
                tail = others[0][len(keys[cc]):]
                if others[0].startswith(keys[cc]) and tail not in ("s", "es"):
                    other_text = text[next(o for o in keys if o != cc)][code]
                    # Confirm in the source's own printed row; the workbook check
                    # already proves VN's text is the workbook's.
                    if cc == "VN":
                        counts["VN_shorter_in_source"] += 1
                    elif pdfs and pdfs.get(cc) and not _row_prints(
                            rows[cc], cc, code, other_text, pdfs[cc]):
                        counts[f"{cc}_shorter_in_source"] += 1
                    else:
                        truncated.append({"jurisdiction": cc, "code": code,
                                          "text": text[cc][code], "others": other_text})
                break
        else:
            counts["all_three_differ"] += 1
    counts["shared_codes"] = len(shared)
    for cc, n in odd.items():
        counts[f"{cc}_differs_from_the_other_two"] = n
    counts["truncated"] = len(truncated)
    return [result("cross_source", not truncated, dict(counts), truncated)]


def _row_prints(rows: list[dict], cc: str, code8: str, text: str, pdf: Path) -> bool:
    """Whether the book prints `text` in the row for `code8`."""
    row = next((r for r in rows if digits(r["GOODS_CODE"]).startswith(code8)
                and r.get("PDF_PAGE")), None)
    if row is None:
        return True
    return _contained(tokens(strip_dashes(text)),
                      row_block(layout_pages(pdf), int(row["PDF_PAGE"]), row["DISPLAY"]))


# ── hygiene ──────────────────────────────────────────────────────────────────

HYGIENE = {
    "subchapter_heading": re.compile(r"SUB-?\s?CHAPTER\s+[IVXLC]+"),
    "flattened_script": re.compile(
        r"\b(?:m|cm|mm|g/m|g/cm|kg/m|km)\s[23]\b|\b10\s-\d|\d\so\sC\b"
        r"|\b[A-Z][a-z]?\s(?:[A-Z][a-z]?\s)?\d\s\d\b|\bVitamin B\b(?!\d)"),
    # "mono- or disodium" is HS text (a suspended hyphen); "beet- pulp" is not.
    "hyphen_then_space": re.compile(r"[a-z0-9]- (?!(?:or|and|nor|to)\b)[a-z0-9]"),
}


def check_hygiene(cc: str, rows: list[dict], from_pdf: bool) -> list[dict]:
    out = []
    for name, rx in HYGIENE.items():
        hits = [{"code": r["DISPLAY"], "text": r["DESCRIPTION"]} for r in rows
                if rx.search(r["DESCRIPTION"] or "")]
        gated = from_pdf or name == "subchapter_heading"
        out.append(result(f"hygiene.{name}", (not hits) if gated else True,
                          {"rows": len(hits), "gated": gated}, hits))
    return out


# ── PDF containment ──────────────────────────────────────────────────────────

def _contained(need: list[str], hay: list[str]) -> bool:
    """`need` in order within `hay`, each needed token matching one hay token or
    the concatenation of up to four. A one- or two-digit token that is not found
    in order may be a sub/superscript that `pdftotext -layout` moved to an
    adjacent line; it is excused only if it occurs on the page at all."""
    i = 0
    present = set(hay)
    for w in need:
        if w.isdigit() and len(w) <= 2 and w in present:
            j = _find(w, hay, i)
            if j is not None:
                i = j
            continue
        j = _find(w, hay, i)
        if j is None:
            j = _find_split(w, hay, i)
        if j is None:
            return False
        i = j
    return True


def _find_split(w: str, hay: list[str], i: int, window: int = 60) -> int | None:
    """A word hyphenated across lines that `-layout` set apart: "wheel-" ends one
    line and "barrows" starts a later one, with the next row's code between."""
    if len(w) < 6:
        return None
    for cut in range(3, len(w) - 2):
        a = _find(w[:cut], hay, i)
        if a is None:
            continue
        b = _find(w[cut:], hay[:a + window], a)
        if b is not None:
            return b
    return None


def _find(w: str, hay: list[str], i: int) -> int | None:
    """Index just past the first match of `w` at or after `i`, else None."""
    while i < len(hay):
        acc = ""
        for k in range(4):
            if i + k >= len(hay):
                break
            acc += hay[i + k]
            if acc == w:
                return i + k + 1
            if not w.startswith(acc):
                break
        i += 1
    return None


def check_containment(cc: str, rows: list[dict], pdf: Path) -> list[dict]:
    pages = layout_pages(pdf)
    toks = [tokens(p) for p in pages]
    fails, n = [], 0
    for r in rows:
        # A heading the gazette never printed, its text taken from the portal.
        if not r.get("PDF_PAGE") or r.get("IMPORT_RATE_BASIS") == "not_printed":
            continue
        need = tokens(strip_dashes(r["DESCRIPTION"]))
        if not need:
            continue
        n += 1
        p = int(r["PDF_PAGE"])
        hay = sum((toks[i] for i in (p - 1, p) if 0 <= i < len(toks)), [])
        if not _contained(need, hay):
            fails.append({"code": r["DISPLAY"], "pdf_page": p, "text": r["DESCRIPTION"]})
    return [result("containment", not fails, {"rows_checked": n, "not_on_page": len(fails)}, fails)]


# ── Malaysia: page breaks and the portal ─────────────────────────────────────

def check_my_page_breaks(rows: list[dict], pdf: Path) -> list[dict]:
    pages = layout_pages(pdf)
    code_line = re.compile(r"^\s{0,14}(\d{2}\.\d{2}|\d{4}\.\d{2}(?:\.\d{2})?(?:\s\d{2})?)\s")
    header_end = re.compile(r"quantity\s+import duty|Rate of\s+Rate of", re.IGNORECASE)
    last = {}
    for r in rows:
        if r.get("PDF_PAGE"):
            last[int(r["PDF_PAGE"])] = r
    lost, kept = [], 0
    for k in range(15, min(1366, len(pages))):
        pno, lines = k + 1, pages[k].splitlines()
        h = max([i for i, ln in enumerate(lines) if header_end.search(ln)] or [-1])
        if h < 0:
            continue
        cont = []
        for ln in lines[h + 1:]:
            s = ln.strip()
            if not s or re.fullmatch(r"\d+", s) or "P.U. (A)" in s:
                continue
            if code_line.match(ln) or s.startswith(("-", "–")) or \
                    re.match(r"(Chapter|Bab|Section|Bahagian|Notes?|Nota|SUB-?CHAPTER)\b", s):
                break
            cont.append(s)
        prev = last.get(pno - 1)
        if cont and prev:
            if alnum(" ".join(cont))[:20] in alnum(prev["DESCRIPTION"]):
                kept += 1
            else:
                lost.append({"code": prev["DISPLAY"], "pdf_page": pno - 1,
                             "lost": " ".join(cont)[:120]})
    return [result("page_breaks", not lost, {"continuations": kept + len(lost),
                                             "lost": len(lost)}, lost)]


def row_block(pages: list[str], pdf_page: int, display: str) -> list[str]:
    """Tokens of one row as `pdftotext -layout` prints it: the line carrying its
    code, then the following lines up to the next code or dash row, running onto
    the next page if the row does."""
    code_rx = re.compile(r"^\s{0,14}(\d{2}\.\d{2}\s+)?\d{4}\.\d{2}")
    want = re.sub(r"\s+", r"\\s*", re.escape(display.strip()))
    out: list[str] = []
    started = False
    for k in (pdf_page - 1, pdf_page):
        if not 0 <= k < len(pages):
            continue
        for ln in pages[k].splitlines():
            if not started:
                if re.search(rf"(?<![\d.]){want}(?![\d])", ln):
                    started = True
                    out += tokens(ln)
                continue
            if code_rx.match(ln) or re.match(r"^\s{10,}-\s", ln):
                return out
            out += tokens(ln)
    return out


def read_portal(path: Path) -> dict:
    page = path.read_text(encoding="utf-8", errors="replace")
    body = page[page.find("<tbody>"):page.find("</tbody>")]
    out = {}
    for tr in re.findall(r"<tr>(.*?)</tr>", body, re.S):
        c = [html.unescape(re.sub(r"<[^>]+>", "", x)).strip() for x in re.split(r"<td>", tr)[1:]]
        if len(c) >= 10 and c[1] and c[2]:
            out[c[0] + c[1] + c[2]] = {"unit": c[3], "desc": c[4], "import": c[5]}
    return out


def check_my_portal(rows: list[dict], path: Path, pdf: Path | None = None) -> list[dict]:
    portal = read_portal(path)
    mine = {digits(r["GOODS_CODE"]): r for r in rows if len(digits(r["GOODS_CODE"])) == 10}
    both = sorted(set(mine) & set(portal))
    squash = lambda v: re.sub(r"[\s\"']+", "", (v or "").lower())
    rate = [{"code": c, "gazette": mine[c]["IMPORT_RATE"], "portal": portal[c]["import"]}
            for c in both if mine[c]["IMPORT_RATE_BASIS"] == "schedule"
            and squash(mine[c]["IMPORT_RATE"]) != squash(portal[c]["import"])]
    unit = [{"code": c, "gazette": mine[c]["UNIT"], "portal": portal[c]["unit"]}
            for c in both if squash(mine[c]["UNIT"]) != squash(portal[c]["unit"])]
    # A gazette description that is a strict prefix of the portal's is a
    # truncation only if the gazette ITSELF prints the longer text for that row.
    # The two sources disagree in places ("Of hardened protein" in the gazette,
    # "proteins" on the portal); the gazette is the legal text.
    pages = layout_pages(pdf) if pdf and pdf.is_file() else None
    cut, wording = [], 0
    for c in both:
        theirs, ours = alnum(strip_dashes(portal[c]["desc"])), alnum(mine[c]["DESCRIPTION"])
        if not (theirs.startswith(ours) and len(theirs) > len(ours)):
            continue
        if pages and not _contained(tokens(strip_dashes(portal[c]["desc"])),
                                    row_block(pages, int(mine[c]["PDF_PAGE"]), mine[c]["DISPLAY"])):
            wording += 1
            continue
        cut.append({"code": c, "gazette": mine[c]["DESCRIPTION"], "portal": portal[c]["desc"]})
    return [result("portal.import_rate", not rate, {"compared": len(both), "differ": len(rate)}, rate),
            result("portal.unit", not unit, {"compared": len(both), "differ": len(unit)}, unit),
            result("portal.truncated_description", not cut,
                   {"truncated": len(cut), "portal_wording_differs_from_gazette": wording}, cut)]


# ── Singapore: duty columns from the layout text ─────────────────────────────

UNIT_CODES = r"(?:CEN|CTM|GWH|KGM|LTR|MIL|MTK|MTQ|MTR|NMB|TEN|TNE|TPR|VAL)"
UNIT_TAILS = {code[k:] for code in UNIT_CODES[3:-1].split("|") for k in (1, 2)}


def check_sg_duties(rows: list[dict], pdf: Path) -> list[dict]:
    """Each code row's duty text, as pdftotext -layout sets it: everything right
    of the unit column, from the code's own line down to the next code line."""
    pages = layout_pages(pdf)
    code_line = re.compile(r"^\s{0,12}(\d{2}\.\d{2}\s+)?(\d{4}\.\d{2}(?:\.\d{2})?)\s")
    unit_rx = re.compile(rf"\s{UNIT_CODES}(?:\s|$)")
    expect: dict = {}
    open_code = None
    for k, page in enumerate(pages):
        lines = page.splitlines()
        marker = next((i for i, ln in enumerate(lines) if re.search(r"\(1\)\s+\(2\)\s+\(3\)", ln)), None)
        if marker is None:
            open_code = None
            continue
        ends = [m.end() for ln in lines if code_line.match(ln)
                for m in [unit_rx.search(ln)] if m]
        if not ends:
            continue
        default_edge = sorted(ends)[len(ends) // 2]
        for ln in lines[marker + 1:]:
            m = code_line.match(ln)
            if m:
                open_code = digits(m.group(2))
                expect.setdefault(open_code, [])
            if re.match(r"^\s*(?:CHAPTER|Chapter|SECTION|Section|Notes?\.|SUB-?\s?CHAPTER)\b", ln):
                open_code = None          # full-width chapter or note text follows
            if open_code is None or re.fullmatch(r"\s*\d{1,3}\s*", ln):
                continue
            # This line's own unit, if it has one, ends the description side;
            # otherwise the page's usual unit column does.
            unit = unit_rx.search(ln)
            edge = unit.end() if unit else default_edge
            cell = ln[edge:].split()
            if cell and edge and not ln[edge - 1].isspace() and not ln[edge:edge + 1].isspace():
                cell = cell[1:]           # the tail of a word cut by the edge
            if cell and cell[0] in UNIT_TAILS:
                cell = cell[1:]           # the tail of a unit code cut by the edge
            expect[open_code] += cell
    bad, n = [], 0
    for r in rows:
        d = digits(r["GOODS_CODE"])
        if len(d) < 6 or d not in expect:
            continue
        got = " ".join(v for v in (r["DUTY_FULL"], r["DUTY_PREF"], r["EXCISE"]) if v).split()
        want = expect[d]
        if want or got:
            n += 1
            # Same words, or the same characters split differently ("c igarette").
            if Counter(w.lower() for w in want) != Counter(w.lower() for w in got) \
                    and Counter(alnum("".join(want))) != Counter(alnum("".join(got))):
                bad.append({"code": r["DISPLAY"], "layout": " ".join(want), "parsed": " ".join(got)})
    return [result("sg_duties", not bad, {"rows_with_duty_text": n, "differ": len(bad)}, bad)]


# ── Vietnam: the workbook, read with zipfile ─────────────────────────────────

NS = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
      "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships"}
VN_COLS = {5: "code", 6: "vi", 7: "en", 8: "unit_vi", 10: "ordinary", 13: "mfn"}   # F G H I K N of BT2026


def read_workbook(path: Path, sheet: str = "BT2026") -> list[dict]:
    z = zipfile.ZipFile(path)
    wb = ET.fromstring(z.read("xl/workbook.xml"))
    rid = next(s.get(f"{{{NS['r']}}}id") for s in wb.find("m:sheets", NS) if s.get("name") == sheet)
    rels = ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))
    target = "xl/" + next(r.get("Target") for r in rels if r.get("Id") == rid).lstrip("/").replace("xl/", "", 1)
    shared = [] if "xl/sharedStrings.xml" not in z.namelist() else [
        "".join(t.text or "" for t in si.iter(f"{{{NS['m']}}}t"))
        for si in ET.fromstring(z.read("xl/sharedStrings.xml")).findall("m:si", NS)]

    def col(ref: str) -> int:
        n = 0
        for ch in re.match(r"[A-Z]+", ref).group():
            n = n * 26 + ord(ch) - 64
        return n - 1

    out = []
    with z.open(target) as fh:
        for _ev, el in ET.iterparse(fh):
            if el.tag != f"{{{NS['m']}}}row":
                continue
            rec = {"row": int(el.get("r") or 0)}
            for c in el.findall("m:c", NS):
                i = col(c.get("r"))
                if i in VN_COLS:
                    v, t = c.find("m:v", NS), c.get("t")
                    if t == "s" and v is not None:
                        rec[VN_COLS[i]] = shared[int(v.text)]
                    elif t == "inlineStr":
                        rec[VN_COLS[i]] = "".join(x.text or "" for x in c.iter(f"{{{NS['m']}}}t"))
                    else:
                        rec[VN_COLS[i]] = v.text if v is not None else ""
            out.append(rec)
            el.clear()
    return out


def check_vn_workbook(rows_en: list[dict], rows_vi: list[dict], path: Path,
                      repairs: list[dict] = ()) -> list[dict]:
    """The parsed CSV against the workbook, cell by cell. `repairs` are the code
    repairs the parser recorded in its notes manifest (source_anomalies with a
    `repaired_to`). Each is re-checked here rather than trusted: the workbook
    cell at that sheet row must be the repaired code with exactly its seventh
    digit missing (what the four BT2026 defects are: '9849170' for 9849.17.20,
    the subheading kept, one digit dropped), its corresponding code must match,
    and the parsed row must otherwise agree with the workbook like any other."""
    ws = lambda s: re.sub(r"\s+", " ", (s or "").replace(" ", " ")).strip()

    def num(s: str) -> str:
        s = ws(s)
        try:
            f = float(s)
            return str(int(f)) if f == int(f) else repr(f)
        except ValueError:
            return s

    book = read_workbook(path)
    by_row = {rec["row"]: rec for rec in book}
    src: dict = {}
    for rec in book:
        d = digits(rec.get("code", ""))
        if len(d) >= 4:
            src.setdefault(d, rec)
    bad_repairs, truncated = [], set()
    for fix in repairs:
        rec, to = by_row.get(fix.get("sheet_row"), {}), fix.get("repaired_to", "")
        cut = digits(rec.get("code", ""))
        problem = ("no such workbook row" if not rec else
                   "workbook cell is not the repaired code less its seventh digit"
                   if not (len(to) == 8 and cut == to[:6] + to[7:]) else
                   "corresponding code differs"
                   if ws(rec.get("unit_vi")) != fix.get("corresponding_code") else
                   "no authority cited" if not fix.get("authority") else None)
        if problem:
            bad_repairs.append({"repair": fix, "problem": problem})
            continue
        truncated.add(cut)
        src[to] = rec
    en = {digits(r["GOODS_CODE"]): r for r in rows_en if digits(r["GOODS_CODE"])}
    vi = {digits(r["GOODS_CODE"]): r for r in rows_vi if digits(r["GOODS_CODE"])}
    diffs = []
    for d in sorted(set(src) & set(en)):
        s, e = src[d], en[d]
        if e.get("DESCRIPTION_SOURCE", "source") == "source" and ws(s.get("en")) != ws(e["DESCRIPTION"]):
            diffs.append({"code": d, "field": "en", "workbook": s.get("en"), "parsed": e["DESCRIPTION"]})
        if d in vi and ws(s.get("vi")) != ws(vi[d]["DESCRIPTION"]):
            diffs.append({"code": d, "field": "vi", "workbook": s.get("vi"), "parsed": vi[d]["DESCRIPTION"]})
        for field, column in (("mfn", "MFN_RATE"), ("ordinary", "ORDINARY_RATE")):
            if num(s.get(field)) != num(e[column]):
                diffs.append({"code": d, "field": field, "workbook": s.get(field), "parsed": e[column]})
    missing = sorted(set(en) - set(src))
    unparsed = set(src) - set(en) - truncated
    return [result("workbook", not diffs and not missing and not unparsed and not bad_repairs,
                   {"codes_compared": len(set(src) & set(en)), "differences": len(diffs),
                    "codes_not_in_workbook": len(missing),
                    "workbook_codes_not_parsed": len(unparsed),
                    "repairs_confirmed": len(repairs) - len(bad_repairs),
                    "repairs_rejected": len(bad_repairs)},
                   diffs + missing + sorted(unparsed) + bad_repairs)]


# ── driver ───────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-j", "--jurisdiction", action="append", choices=["SG", "MY", "VN"],
                    help="repeatable; default all three")
    ap.add_argument("--json", type=Path, help="write the full report here")
    args = ap.parse_args()
    wanted = args.jurisdiction or ["SG", "MY", "VN"]

    rows, report = {}, {}
    for cc in ("SG", "MY", "VN"):
        path = canonical_csv(cc)
        if path:
            rows[cc] = read_rows(path)
            report.setdefault(cc, {"csv": str(path.relative_to(REPO)), "checks": []})
    src = {cc: {k: REPO / v for k, v in paths.items()} for cc, paths in SOURCES.items()}

    for cc in wanted:
        if cc not in rows:
            report[cc] = {"csv": None, "checks": [result("canonical_csv", False, {"reason": "not found"})]}
            continue
        checks = report[cc]["checks"]
        checks += check_hygiene(cc, rows[cc], from_pdf=cc in ("SG", "MY"))
        if cc in ("SG", "MY"):
            pdf = src[cc]["pdf"]
            if pdf.is_file():
                checks += check_containment(cc, rows[cc], pdf)
                checks += check_my_page_breaks(rows[cc], pdf) if cc == "MY" else check_sg_duties(rows[cc], pdf)
            else:
                checks.append(result("pdf_checks", None, {"reason": f"{pdf} not found"}))
        if cc == "MY":
            page = src["MY"]["html"]
            checks += check_my_portal(rows["MY"], page, src["MY"]["pdf"]) if page.is_file() else \
                [result("portal", None, {"reason": f"{page} not found"})]
        if cc == "VN":
            book, vi = src["VN"]["xlsx"], canonical_csv("VN", "vi")
            stem = canonical_csv("VN").name.removeprefix("vn_tariff_").removesuffix(".csv")
            manifest = REPO / "data" / "hts_notes" / f"vn_{stem}" / f"vn_{stem}.notes.manifest.json"
            repairs = [a for a in json.loads(manifest.read_text(encoding="utf-8"))
                       .get("source_anomalies", []) if a.get("repaired_to")] \
                if manifest.is_file() else []
            checks += check_vn_workbook(rows["VN"], read_rows(vi) if vi else [], book, repairs) \
                if book.is_file() else [result("workbook", None, {"reason": f"{book} not found"})]
    report["ALL"] = {"checks": check_cross_source(
        rows, {cc: src[cc]["pdf"] for cc in ("SG", "MY") if src[cc]["pdf"].is_file()})}

    failed = 0
    for cc, block in report.items():
        if cc != "ALL" and cc not in wanted:
            continue
        print(f"\n== {cc}" + (f"  ({block['csv']})" if block.get("csv") else ""))
        for c in block["checks"]:
            failed += c["status"] == "FAIL"
            print(f"  {c['status']:<7} {c['check']:<34} {json.dumps(c['counts'], ensure_ascii=False)}")
            if c["status"] == "FAIL":
                for s in c["samples"]:
                    print(f"            {json.dumps(s, ensure_ascii=False)[:220]}")
    if args.json:
        args.json.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"\n{'FAILED: ' + str(failed) + ' gate(s)' if failed else 'all gates pass'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

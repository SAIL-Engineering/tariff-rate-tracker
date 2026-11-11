#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""parse_sg_stcced.py — parse Singapore's STCCED into the tariff + legal-notes corpora.

SOURCE
  Singapore Trade Classification, Customs and Excise Duties (STCCED), 2022 edition
  — the current edition. Published as a single 655-page PDF:
      https://file.go.gov.sg/stcced2022.pdf
  linked from
      https://www.customs.gov.sg/doing-business/business-resources/
      hs-classification-of-goods/understanding-hs-classification/

  Singapore publishes no machine-readable tariff file, so unlike every other
  jurisdiction in config/jurisdictions/ there is no acquire adapter and no
  scheduled refresh: the PDF is downloaded by hand and this script is run
  against it. That is why `sg.json` lists `"adapter": "manual"` and omits the
  `verify`/`publish` automation the API-backed jurisdictions use.

WHY COORDINATES AND NOT `pdftotext -layout`
  The book is a 7-column table. Under `-layout` poppler re-flows each page to
  fit the text it found, so the apparent column positions drift page to page and
  a wrapped duty value ("$16.00" / "per litre" / "of alcohol", three printed
  lines for one cell) cannot be reattached to its row. Under `-bbox-layout`
  every word carries its own x/y, and the underlying geometry turns out to be
  exact: the `(1)`...`(7)` column-marker row is present on all 636 book pages
  and its x positions have ZERO variance across them —

      (1) HEADING    x=23.5     (5) CUSTOMS DUTY, FULL  x=451.4
      (2) SUBHEADING x=65.6     (6) CUSTOMS DUTY, PREF  x=478.9
      (3) DESCRIPTION x=249.8   (7) EXCISE DUTY         x=523.2
      (4) UNIT OF QUANTITY x=417.4

  So columns are assigned by absolute x, and a cell that spans several printed
  lines is joined within its own column. Extraction is mechanical: no OCR, no
  model call, no timestamp in the output.

HIERARCHY
  Singapore prints the nesting depth directly, as the dash prefix on the
  description ("-", "- -", "- - -", "- - - -"). That is used verbatim as the
  indent rather than being inferred from code length, and uncoded dash rows
  ("- Horses :") are emitted with an empty code so build_hts_corpus.build_tree()
  treats them as the condition rows they are. See THE DASH-DEPTH GATE in
  validate() for why this is checked against digit-prefix parentage rather than
  trusted.

CURATION (three things a mechanical read gets wrong, each handled explicitly)
  1. TABLES INSIDE NOTES. Twelve pages carry a data table inside a chapter note
     — Chapter 11 Note 2's cereal starch/ash/sieve criteria, Chapter 27's
     petroleum test methods, and so on — each with its own `(1)`...`(n)` column
     header row. Those marker rows are NOT the page header (that is why the page
     header is located as the marker row with y < 75), and linearising such a
     table by reading order yields "Wheat and 45% 2.5% 80% - rye". They are
     emitted as pipe tables in the note text and kept structurally in `tables`.
  2. CASING. The document mixes "SECTION I" with "Section II", so every
     structural header is matched case-insensitively. With that, the counts
     reconcile exactly: 21 sections, 98 chapters, 96 Note(s). blocks and 38
     Subheading Note(s). blocks.
  3. A MISPLACED HEADING. On printed page 404 (PDF 423) heading "73.09" is set
     in the subheading column. A c2 value shaped like a 4-digit heading is
     promoted to c1; the count of promotions is asserted in validate().

OUTPUTS (under --out-dir, default data/sg_tariff_source)
  sg_tariff_2022_rev_101.csv            canonical rows for load_rows_sg()
  sg_tariff_2022_rev_101.csv.meta.json  effective date, read by acquire/manual.py
  sg_2022_rev_101.reference.json        abbreviations, symbols, units of quantity
  sg_2022_rev_101.toc.json              section/chapter titles with printed start pages
and under --notes-dir (default data/hts_notes/sg_2022_rev_101)
  sg_2022_rev_101.notes.json            cite_id -> record sidecar
  sg_2022_rev_101.notes.gri.jsonl       GRI family, for Pinecone
  sg_2022_rev_101.notes.section.jsonl   section-note family
  sg_2022_rev_101.notes.chapter.jsonl   chapter + subheading note family
  sg_2022_rev_101.notes.manifest.json   counts, hashes, poppler version
and
  scripts/hts_automation/chapters_sg.json   chapter/section index (from the book)

USAGE
  python3 scripts/hts_automation/parse_sg_stcced.py data/sg_tariff_source/stcced2022.pdf
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import shutil
import subprocess
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pdf_text  # noqa: E402  (shared repairs; see its docstring)
import notes_contract  # noqa: E402  (the US notes record shape)

REPO_ROOT = Path(__file__).resolve().parents[2]

JURISDICTION = "SG"
# The standard {year}_rev_{number} id every jurisdiction uses. Dated editions
# take MMDD of the effective date as the number (CH 901, KR 101, TW 729): the
# 2022 edition, effective 1 January 2022, is 2022_rev_101.
REVISION = "2022_rev_101"
# The PDF states no commencement date of its own; this is the HS 2022 edition date.
EFFECTIVE_DATE = "2022-01-01"
EDITION_LABEL = "STCCED 2022"
PDF_URL = "https://file.go.gov.sg/stcced2022.pdf"
LANDING_URL = ("https://www.customs.gov.sg/doing-business/business-resources/"
               "hs-classification-of-goods/understanding-hs-classification/")

# Page map, 1-based PDF pages. Pages 1-5 are the cover, preface and foreword and
# carry no classification content; the user-facing instruction to ignore them
# matches what is there. Printed page 1 is PDF page 20, so printed = pdf - 19.
PAGES_GRI = (6, 8)
PAGES_ABBREV = (9, 10)
PAGE_UNITS = 11
PAGES_TOC = (12, 18)
FIRST_BOOK_PAGE = 20
PRINTED_OFFSET = FIRST_BOOK_PAGE - 1

# Column boundaries in PDF points, from the zero-variance marker centres above.
# Column 3 is wide running text (word starts observed from x=86 to x=400); the
# unit/duty columns are narrow and right-aligned, so their edges sit between the
# observed clusters rather than midway between the markers.
#
# The PREF/EXCISE edge is 486, not the 500 first chosen. Every genuine
# preferential cell in the book is "Free", starting at x=480.7; a long excise
# cell starts as far left as x=489 (the cigarette rate "58.9 cents for every
# gram or part thereof of each stick of cigarette" at 498.6-499.8, the diesel
# and LPG conditions at 489-497), and nothing at all starts between 481 and
# 489. At 500 those words were read as preferential duty: 2402.20.20 got a
# preferential rate of "every part" and its excise lost its words.
COL_EDGES = ((0.0, 35.0, "c1"), (35.0, 86.0, "c2"), (86.0, 400.0, "c3"),
             (400.0, 436.0, "c4"), (436.0, 466.0, "c5"), (466.0, 486.0, "c6"),
             (486.0, 1000.0, "c7"))

# The units of quantity are a closed vocabulary, printed in full on page XIII
# (PDF 11) and parsed into the reference file; validate() asserts this set
# equals what was parsed there, so it cannot drift from the source.
#
# It is needed during binning because column (4) is only 36pt wide and its
# neighbours encroach from both sides by a fraction of a point: the tail of a
# long description lands at x>=400 (the characters "a", ":", "." and a stray
# digit, 96 occurrences) and the third line of a wrapped duty cell begins at
# x=435.6, four tenths of a point inside the boundary ("of", in "$16.00 per
# litre / of alcohol", 8 occurrences). Geometry alone cannot separate them;
# the vocabulary can, and a token that is not a unit is handed to whichever
# neighbour it is nearer. Left unhandled this gave nine codes a unit of ":"
# or "a" and silently dropped "of" from every wrapped duty rate.
UNIT_CODES = frozenset({
    "CEN", "CTM", "GWH", "KGM", "LTR", "MIL", "MTK",
    "MTQ", "MTR", "NMB", "TEN", "TNE", "TPR", "VAL",
})
COL_UNIT_CENTRE = 417.4

RE_MARKER = re.compile(r"^\((\d)\)$")
RE_SECTION_HDR = re.compile(r"^SECTION\s+([IVXLC]+)$", re.IGNORECASE)
RE_CHAPTER_HDR = re.compile(r"^CHAPTER\s+(\d{1,2})$", re.IGNORECASE)
RE_NOTE_HDR = re.compile(r"^NOTES?\.$", re.IGNORECASE)
RE_SUBHEADING_NOTE_HDR = re.compile(r"^SUB-?HEADING\s+NOTES?\.$", re.IGNORECASE)
RE_HEADING_CODE = re.compile(r"^(\d{2})\.(\d{2})$")
RE_SUB_CODE = re.compile(r"^(\d{4})\.(\d{2})(?:\.(\d{2}))?$")
RE_NOTE_NUM = re.compile(r"^(\d{1,2})\.$")
RE_SUBPARA = re.compile(r"^\(([A-Za-z0-9]{1,4})\)$")
RE_RULE_HDR = re.compile(r"^Rule\s+(\d)$", re.IGNORECASE)
RE_FOLIO = re.compile(r"^\d{1,3}$")
RE_RESERVED = re.compile(r"^\(?Reserved", re.IGNORECASE)

# Cross-references inside note prose. Singapore dots its codes (heading 03.01,
# subheading 2204.21), so these are normalised to bare digits to match the
# refs_* convention build_hts_notes.py established for the US corpus.
RE_REF_HEADING = re.compile(r"\b(\d{2})\.(\d{2})\b")
RE_REF_SUBHEADING = re.compile(r"\b(\d{4})\.(\d{2})\b")
RE_REF_CHAPTER = re.compile(r"\bChapters?\s+(\d{1,2})\b", re.IGNORECASE)
RE_REF_SECTION = re.compile(r"\bSections?\s+([IVXLC]+)\b")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def poppler_version() -> str:
    out = subprocess.run(["pdftotext", "-v"], capture_output=True, text=True)
    first = (out.stderr or out.stdout or "").splitlines()
    return first[0].strip() if first else "unknown"


def join_text(head: str, tail: str) -> str:
    """Append a wrapped fragment.

    This used to drop the hyphen whenever a line ended in one and the next began
    in lowercase, on the theory that it was a typesetter's word break. It mostly
    is not: Harmonized System text is full of real hyphens, and the rule fused
    "1,2-dichloroethane" into "1,2dichloroethane" and "pre-cooked" into
    "precooked" on about 145 lines. Whether a line-break hyphen survives is now
    decided by the book's own vocabulary; see pdf_text.join_wrapped().
    """
    return pdf_text.join_wrapped(head, tail, norm)


def norm(text: str) -> str:
    """NFKC, collapse whitespace, normalise the curly quotes the PDF uses."""
    text = unicodedata.normalize("NFKC", text or "")
    text = (text.replace(" ", " ").replace("’", "'")
                .replace("‘", "'").replace("“", '"')
                .replace("”", '"').replace("–", "-")
                .replace("—", "-"))
    return pdf_text.tidy_hyphens(" ".join(text.split()))


@dataclass(frozen=True)
class Word:
    x: float
    y: float
    text: str
    x1: float = 0.0
    y1: float = 0.0


@dataclass
class Line:
    """One visual line, its words already binned into the seven table columns."""
    page: int
    y: float
    cols: dict
    x0: float

    def col(self, name: str) -> str:
        return self.cols.get(name, "")

    @property
    def all_text(self) -> str:
        return " ".join(self.cols[c] for c in ("c1", "c2", "c3", "c4", "c5", "c6", "c7")
                        if self.cols.get(c))


def load_pages(pdf: Path, workdir: Path) -> list[list[Word]]:
    """pdftotext -bbox-layout, then one Word list per PDF page."""
    if shutil.which("pdftotext") is None:
        sys.exit("ERROR: pdftotext (poppler-utils) is required")
    xml = workdir / "stcced_bbox.xml"
    subprocess.run(["pdftotext", "-bbox-layout", str(pdf), str(xml)], check=True)
    ns = "{http://www.w3.org/1999/xhtml}"
    raw: list[list[tuple]] = []
    current: list | None = None
    for event, el in ET.iterparse(str(xml), events=("start", "end")):
        tag = el.tag.replace(ns, "")
        if event == "start" and tag == "page":
            current = []
            raw.append(current)
        elif event == "end" and tag == "word":
            if current is not None and (el.text or "").strip():
                current.append((float(el.get("xMin")), float(el.get("yMin")),
                                float(el.get("xMax")), float(el.get("yMax")), el.text))
            el.clear()
    # Glue sub/superscripts to their words first ("H BO 3 3" -> "H3BO3"), then
    # learn the book's vocabulary for line-break hyphens. Both in pdf_text.
    pages = [[Word(x0, y0, t, x1, y1) for x0, y0, x1, y1, t in pdf_text.merge_scripts(ws)]
             for ws in raw]
    pdf_text.set_vocabulary(pdf_text.Vocabulary(w.text for ws in pages for w in ws))
    return pages


def column_of(x: float) -> str:
    for lo, hi, name in COL_EDGES:
        if lo <= x < hi:
            return name
    return "c7"


def page_lines(words: list[Word], *, table: bool) -> list[Line]:
    """Cluster a page's words into visual lines.

    `table` selects the column model. For book pages the seven table columns
    apply and everything above the page's own marker row is furniture. For the
    front matter (GRIs, abbreviations, contents) there is no table, so the whole
    width is read as one column and nothing is dropped.
    """
    if table:
        # The page header's marker row is the (N) row near the top. A note that
        # contains its own table also emits (1)...(n) further down the page, and
        # taking the lowest such row here would discard most of the page.
        tops = [w.y for w in words if RE_MARKER.match(w.text or "") and w.y < 75.0]
        cut = (max(tops) if tops else 65.0) + 2.0
        words = [w for w in words if w.y > cut]
    # A word set in a TALLER face than the body is placed by its bottom edge,
    # which is where the baseline is. Its top sits higher than its neighbours':
    # the "58.9" of the cigarette excise is 12.1pt in an 8.1pt body, its top
    # 3.2pt above its code line, so by top edge it formed a line of its own above
    # 2402.90.20 and was read as the previous row's preferential duty. Only 26
    # words in the book's tables are taller; everything else is unaffected.
    heights = sorted(w.y1 - w.y for w in words if w.y1 > w.y)
    body = heights[len(heights) // 2] if heights else 0.0

    def line_key(w: Word) -> float:
        if body and w.y1 - w.y > 1.2 * body:
            return w.y1 - body
        return w.y

    buckets: dict[float, list[Word]] = defaultdict(list)
    for w in words:
        buckets[round(line_key(w), 1)].append(w)
    ys = sorted(buckets)
    clusters: list[list[float]] = []
    for y in ys:
        # 1.5pt: the body face is ~10pt on ~10.3pt leading, and the (4)/(5)/(6)
        # markers sit 0.5pt below (1)/(2)/(3) on the same printed line.
        if clusters and y - clusters[-1][-1] <= 1.5:
            clusters[-1].append(y)
        else:
            clusters.append([y])
    out: list[Line] = []
    for cluster in clusters:
        ws = sorted((w for y in cluster for w in buckets[y]), key=lambda w: w.x)
        if not ws:
            continue
        cols: dict[str, list[str]] = defaultdict(list)
        for w in ws:
            col = column_of(w.x) if table else "c3"
            if table and col == "c4" and w.text not in UNIT_CODES:
                col = "c3" if w.x < COL_UNIT_CENTRE else "c5"
            cols[col].append(w.text)
        joined = {k: norm(" ".join(v)) for k, v in cols.items()}
        joined = {k: v for k, v in joined.items() if v}
        out.append(Line(page=0, y=min(cluster), cols=joined, x0=ws[0].x))
    return out


# ── front matter ─────────────────────────────────────────────────────────────

def parse_gri(pages: list[list[Word]]) -> list[dict]:
    """Pages 6-8: the six General Interpretative Rules.

    Singapore prints the WCO rules verbatim and then adds its own worked
    `Examples:` under most of them. The examples are part of the published
    document and are useful retrieval signal, so they are kept — but in a
    separate `examples` list as well as in the text, so a consumer can tell the
    operative rule from the illustration. They are Singapore's gloss, not
    treaty text, and nothing downstream should cite them as the rule itself.
    """
    lines: list[Line] = []
    for pno in range(PAGES_GRI[0], PAGES_GRI[1] + 1):
        for ln in page_lines(pages[pno - 1], table=False):
            ln.page = pno
            lines.append(ln)
    records: list[dict] = []
    preamble: list[str] = []
    current: dict | None = None
    mode = "preamble"
    for ln in lines:
        text = ln.all_text
        if not text:
            continue
        # The printed folio here is a roman numeral (VIII, IX, X), not a digit.
        if re.fullmatch(r"[IVXLC]+", text):
            continue
        if re.fullmatch(r"GENERAL RULES FOR THE INTERPRETATION OF THE", text, re.I) \
                or re.fullmatch(r"HARMONIZED SYSTEM", text, re.I):
            continue
        m = RE_RULE_HDR.match(text)
        if m:
            if current:
                records.append(current)
            current = {"number": m.group(1), "body": [], "examples": []}
            mode = "body"
            continue
        if re.fullmatch(r"Examples?\s*:", text, re.IGNORECASE):
            mode = "examples"
            continue
        if current is None:
            preamble.append(text)
            continue
        # An Examples block ends where the rule resumes. Rule 3 alternates
        # body and examples - (a), Examples, (b), Examples, (c) - so staying
        # in examples mode until the next "Rule N" header swallowed the rest
        # of the rule into the final example AND duplicated it in the body.
        if mode == "examples" and re.match(r"^\([a-z]\)\s", text):
            mode = "body"
        if mode == "examples":
            # Example bullets are printed with an en-dash lead.
            stripped = text.lstrip("-–• ").strip()
            if text.startswith("-") or not current["examples"]:
                current["examples"].append(stripped)
            else:
                current["examples"][-1] = join_text(current["examples"][-1], stripped)
        else:
            current["body"].append(text)
    if current:
        records.append(current)
    for rec in records:
        rec["body"] = norm(" ".join(rec["body"]))
    return [{"preamble": norm(" ".join(preamble))}] + records


def parse_reference(pages: list[list[Word]]) -> dict:
    """Pages 9-11: ABBREVIATIONS AND SYMBOLS, then UNITS OF QUANTITY.

    These are not notes and are not law, but they decode the tariff: column (4)
    carries bare unit codes (NMB, KGM, LTR, VAL ...) that mean nothing without
    this table, and the duty columns use the symbols. Emitted as a reference
    file so the Explorer can expand a unit code and the classifier prompt can
    be given the glossary rather than guessing.
    """
    def pairs(pno: int) -> list[tuple[str, str]]:
        out = []
        for ln in page_lines(pages[pno - 1], table=False):
            text = ln.all_text
            if not text or re.fullmatch(r"[IVXLC]+", text):
                continue
            if re.fullmatch(r"(ABBREVIATIONS AND SYMBOLS|UNITS OF QUANTITY)", text, re.I):
                continue
            # "KGM   Kilogram(s)" — the symbol is the first whitespace-run.
            m = re.match(r"^(\S+)\s+(.+)$", text)
            if m:
                out.append((m.group(1), m.group(2)))
        return out

    abbreviations = {}
    for pno in range(PAGES_ABBREV[0], PAGES_ABBREV[1] + 1):
        for sym, meaning in pairs(pno):
            abbreviations[sym] = meaning
    units = dict(pairs(PAGE_UNITS))
    return {
        "jurisdiction": JURISDICTION,
        "revision": REVISION,
        "edition": EDITION_LABEL,
        "source_url": PDF_URL,
        "landing_url": LANDING_URL,
        "abbreviations": abbreviations,
        "units_of_quantity": units,
    }


def parse_toc(pages: list[list[Word]]) -> dict:
    """Pages 12-18: LIST OF SECTION AND CHAPTER TITLES.

    Used only to cross-check the chapter inventory and to record each chapter's
    printed start page. The authoritative titles are the ones printed in the
    book itself (parse_book), because those are what a reader of the chapter
    sees; the contents page abbreviates some of them.
    """
    chapters: dict[int, dict] = {}
    pending: dict | None = None
    for pno in range(PAGES_TOC[0], PAGES_TOC[1] + 1):
        for ln in page_lines(pages[pno - 1], table=False):
            text = ln.all_text
            if not text or re.fullmatch(r"[IVXLC]+|Page", text, re.IGNORECASE):
                continue
            m = re.match(r"^Chapter\s+(\d{1,2})\s+(.*)$", text, re.IGNORECASE)
            if m:
                number = int(m.group(1))
                rest = m.group(2)
                page_m = re.search(r"\s(\d{1,3})$", rest)
                printed = int(page_m.group(1)) if page_m else None
                title = rest[: page_m.start()] if page_m else rest
                pending = {"chapter": number, "toc_title": norm(title),
                           "printed_start_page": printed}
                chapters[number] = pending
                continue
            if pending is not None and not RE_SECTION_HDR.match(text) \
                    and not re.match(r"^Section Notes?\.", text, re.IGNORECASE):
                # A wrapped contents line, possibly carrying the page number.
                page_m = re.search(r"\s(\d{1,3})$", text)
                tail = text[: page_m.start()] if page_m else text
                if page_m and pending["printed_start_page"] is None:
                    pending["printed_start_page"] = int(page_m.group(1))
                pending["toc_title"] = norm(pending["toc_title"] + " " + tail)
    return chapters


# ── the book ─────────────────────────────────────────────────────────────────

@dataclass
class TariffRow:
    page: int
    printed_page: int
    section: str
    chapter: int
    heading: str          # dotted, e.g. "01.01", "" on non-heading rows
    code: str             # dotted operative code, "" on a condition row
    digits: str
    description: str
    indent: int
    unit: str = ""
    duty_full: str = ""
    duty_pref: str = ""
    excise: str = ""

    def add(self, line: Line) -> None:
        """Fold a continuation line into this row, per column.

        A cell may run to several printed lines independently of its
        neighbours: the duty cell "$16.00 / per litre / of alcohol" is three
        lines while the description beside it is one. Joining per column rather
        than per line is the whole reason for reading coordinates.
        """
        if line.col("c3"):
            self.description = join_text(self.description, line.col("c3"))
        if line.col("c4"):
            self.unit = norm(self.unit + " " + line.col("c4"))
        if line.col("c5"):
            self.duty_full = join_text(self.duty_full, line.col("c5"))
        if line.col("c6"):
            self.duty_pref = join_text(self.duty_pref, line.col("c6"))
        if line.col("c7"):
            self.excise = join_text(self.excise, line.col("c7"))


@dataclass
class NoteBlock:
    kind: str             # section_note | chapter_note | subheading_note
    section: str
    chapter: int | None
    number: str
    page: int
    printed_page: int
    parts: list = field(default_factory=list)   # [("para"|"sub", label, text)]
    tables: list = field(default_factory=list)


@dataclass
class BookParse:
    rows: list = field(default_factory=list)
    notes: list = field(default_factory=list)
    chapters: dict = field(default_factory=dict)   # number -> {title, section}
    sections: dict = field(default_factory=dict)   # roman -> {title}
    promoted_headings: list = field(default_factory=list)
    source_anomalies: list = field(default_factory=list)
    stats: Counter = field(default_factory=Counter)


def _dash_depth(text: str) -> tuple[int, str]:
    """Strip the printed dash prefix and return (depth, remaining text).

    "- - - Oxen" -> (3, "Oxen"). Only a dash followed by a space counts, so a
    hyphenated word or a range ("2,2'-oxydiethanol", "20.01 - 20.05") is not
    mistaken for nesting.
    """
    depth = 0
    rest = text
    while True:
        m = re.match(r"^-\s+", rest)
        if not m:
            break
        depth += 1
        rest = rest[m.end():]
    if depth == 0 and rest.startswith("-") and not re.match(r"^-\S", rest):
        depth, rest = 1, rest[1:].strip()
    return depth, rest.strip()


def find_table_header(words: list[Word]) -> float | None:
    """The y of this page's embedded-table column-header row, or None.

    A header row is >=3 column markers sharing a baseline whose labels, read
    left to right, run (1),(2),(3)... from one. That test matters because the
    pattern alone is ambiguous: notes enumerate their third level as "(1)",
    "(2)" and cite columns inline ("the aperture indicated in Column (4) or
    (5)"). Across the whole book six candidate rows carry two or more markers
    below the page header and exactly ONE satisfies the test — the Chapter 11
    cereal table, printed page 53. Keying off the loosest match instead picked
    up the inline "Column (4) or (5)" reference on that same page and read the
    table against two columns rather than five.
    """
    rows: dict[float, list[Word]] = defaultdict(list)
    for w in words:
        if RE_MARKER.match(w.text or "") and w.y > 100.0:
            rows[round(w.y, 1)].append(w)
    for y in sorted(rows):
        ms = sorted(rows[y], key=lambda w: w.x)
        labels = [(w.text or "").strip("()") for w in ms]
        if len(ms) >= 3 and labels == [str(i + 1) for i in range(len(labels))]:
            return y
    return None


# A columnar line leaves a wide horizontal gap between cells; running prose does
# not. Measured on the one table in the book: its title lines gap by 61-121pt,
# while the note prose immediately above them gaps by at most 44pt. 50pt sits
# between the two with margin. This only governs recovery of the printed column
# TITLES, which are a convenience: the note's operative text refers to its
# columns by number ("that indicated in Column (2)"), and the numbers are always
# emitted, so a title this misses costs nothing legally.
TITLE_MIN_GAP = 50.0
MAX_TITLE_LINES = 8


def extract_note_table(words: list[Word], header_y: float) -> dict | None:
    """Read the table whose column-header row sits at `header_y`."""
    ms = sorted((w for w in words
                 if abs(w.y - header_y) <= 2.0 and RE_MARKER.match(w.text or "")),
                key=lambda w: w.x)
    if len(ms) < 3:
        return None
    labels = [(w.text or "").strip("()") for w in ms]
    centres = [w.x for w in ms]
    edges = [0.0] + [(a + b) / 2.0 for a, b in zip(centres, centres[1:])] + [1000.0]

    def cell_of(x: float) -> int:
        for i in range(len(edges) - 1):
            if edges[i] <= x < edges[i + 1]:
                return i
        return len(centres) - 1

    def grouped(predicate) -> list[tuple[float, list[Word]]]:
        buckets: dict[float, list[Word]] = defaultdict(list)
        for w in words:
            if predicate(w.y):
                buckets[round(w.y, 1)].append(w)
        return [(y, sorted(buckets[y], key=lambda w: w.x)) for y in sorted(buckets)]

    def max_gap(ws: list[Word]) -> float:
        return max((b.x - a.x for a, b in zip(ws, ws[1:])), default=0.0)

    # Column titles: walk up from the header row while the line stays columnar.
    # Captured as verbatim lines, NOT forced into the column grid. The printed
    # header spans columns: "Rate of passage through a sieve with an aperture
    # of" sits over (4) and (5) jointly, with "315 micrometres (microns)" and
    # "500 micrometres (microns)" beneath each. Binning that by x splits the
    # phrase mid-sentence ("Rate of passage | through a"), which reads as
    # nonsense. The note cites its columns by number in any case, so the titles
    # are a caption and the numbers are the key.
    caption: list[str] = []
    y_from = header_y
    for y, ws in reversed(grouped(lambda y: y < header_y - 2.0)):
        if len(caption) >= MAX_TITLE_LINES or max_gap(ws) < TITLE_MIN_GAP:
            break
        caption.append(norm(" ".join(w.text for w in ws)))
        y_from = y
    caption.reverse()

    # Data rows: everything below, until the note numbering or the tariff table
    # resumes. A row with content in column 1 only continues the row above it
    # ("Maize (corn)" / "and grain" / "sorghum" is one cereal, not three).
    data: list[list[str]] = []
    y_to = header_y
    for y, ws in grouped(lambda y: y > header_y + 2.0):
        text = norm(" ".join(w.text for w in ws))
        head = ws[0].text or ""
        if RE_NOTE_NUM.match(head) or RE_HEADING_CODE.match(head) \
                or RE_SUB_CODE.match(head) or RE_FOLIO.fullmatch(text):
            break
        cells = [""] * len(centres)
        for w in ws:
            i = cell_of(w.x)
            cells[i] = norm(cells[i] + " " + w.text)
        if data and cells[0] and not any(cells[1:]):
            data[-1][0] = norm(data[-1][0] + " " + cells[0])
            y_to = y
            continue
        if any(cells):
            data.append(cells)
            y_to = y
    if not data:
        return None
    return {"columns": labels, "caption": caption, "rows": data,
            "y_from": y_from, "y_to": y_to}


# CURATED COLUMN TITLES — the one place in this parser where a human reading of
# the page supplies what geometry cannot.
#
# The Chapter 11 table's header is two-dimensional: "Rate of passage through a
# sieve with an aperture of" spans columns (4) and (5) jointly, and "315
# micrometres (microns)" / "500 micrometres (microns)" sit beneath it, one per
# column. No left-to-right read of the words recovers that, so the five titles
# are written out here as the printed page states them. The raw caption lines
# are kept beside them in `caption` so this transcription stays checkable
# against the source, and it is applied only when the column count agrees.
CURATED_TABLE_TITLES = {
    ("11", "2"): [
        "Cereal",
        "Starch Content",
        "Ash Content",
        "Rate of passage through a sieve with an aperture of 315 micrometres "
        "(microns)",
        "Rate of passage through a sieve with an aperture of 500 micrometres "
        "(microns)",
    ],
}


def render_note_table(table: dict) -> str:
    """Pipe table, column numbers first because the note cites them by number."""
    width = len(table["columns"])

    def row(cells: list[str]) -> str:
        padded = [c if c else "-" for c in (list(cells) + [""] * (width - len(cells)))]
        return "| " + " | ".join(padded[:width]) + " |"

    lines = []
    titles = table.get("titles")
    if titles and len(titles) == width:
        lines.append(row(titles))
    elif table.get("caption"):
        # No curated reading for this table: give the printed header lines as
        # they stand rather than inventing a grid for them.
        for caption_line in table["caption"]:
            lines.append(caption_line)
    lines.append(row([f"({c})" for c in table["columns"]]))
    lines.append("|" + "|".join([" --- "] * width) + "|")
    for data_row in table["rows"]:
        lines.append(row(data_row))
    return "\n".join(lines)


# A row whose code and description sit on slightly different baselines. The
# stitch distance is set from measurement, not taste: in the whole 636-page book
# exactly three rows are split this way —
#
#   printed p8   0301.11.10  description 3.0pt BELOW the code
#   printed p8   0301.19.90  description 6.7pt ABOVE the code
#   printed p290 53.05       description 3.0pt BELOW the code
#
# — while a cell that genuinely wraps does so on a 10.32pt leading (measured on
# the beer duties, "$16.00" / "per litre" / "of alcohol"). 8pt therefore catches
# all three splits and can never swallow a wrap or the next row, which sits
# ~17pt away. Left unstitched, 0301.11.10 lands at indent 0 and adopts five
# unrelated children, and 0301.19.90 loses its description entirely.
STITCH_MAX_GAP = 8.0


def stitch_split_rows(lines: list[Line]) -> int:
    """Merge a code-only line with an adjacent description-only line, in place."""
    merges = 0
    i = 0
    while i < len(lines):
        ln = lines[i]
        has_code = bool(ln.col("c1") or ln.col("c2"))
        if not has_code or ln.col("c3"):
            i += 1
            continue
        for j in (i + 1, i - 1):
            if not 0 <= j < len(lines):
                continue
            other = lines[j]
            if other.col("c1") or other.col("c2") or not other.col("c3"):
                continue
            if abs(other.y - ln.y) > STITCH_MAX_GAP:
                continue
            for col, value in other.cols.items():
                if value and not ln.cols.get(col):
                    ln.cols[col] = value
                elif value and col != "c3":
                    ln.cols[col] = norm(ln.cols[col] + " " + value)
            ln.y = min(ln.y, other.y)
            lines.pop(j)
            merges += 1
            if j < i:
                i -= 1
            break
        i += 1
    return merges


def parse_book(pages: list[list[Word]], toc: dict) -> BookParse:
    """Walk PDF pages 20..end as one continuous table, carrying state across pages.

    Region model: after a `Chapter N` or `SECTION x` header we are in that
    unit's note region, and we stay there until the first coded tariff row of
    the chapter. Notes are never interleaved with tariff lines in this book —
    validate() asserts that, because if it were ever false the note text and the
    product descriptions would silently merge.
    """
    out = BookParse()
    section = ""
    chapter: int | None = None
    region = "none"            # none | section_title | chapter_title | notes | tariff
    note_kind = ""
    note_col_x = 0.0
    used_numbers: dict = defaultdict(set)
    current_note: NoteBlock | None = None
    current_row: TariffRow | None = None
    title_buf: list[str] = []
    in_subchapter_title = False

    def close_note() -> None:
        nonlocal current_note
        if current_note is not None:
            out.notes.append(current_note)
            current_note = None

    def close_row() -> None:
        nonlocal current_row
        if current_row is not None:
            out.rows.append(current_row)
            current_row = None

    def flush_title() -> None:
        nonlocal title_buf
        text = norm(" ".join(title_buf))
        title_buf = []
        if not text:
            return
        if region == "section_title":
            out.sections.setdefault(section, {})["title"] = text
        elif region == "chapter_title" and chapter is not None:
            out.chapters.setdefault(chapter, {"section": section})["title"] = text

    for pno in range(FIRST_BOOK_PAGE, len(pages) + 1):
        words = pages[pno - 1]
        printed = pno - PRINTED_OFFSET
        lines = page_lines(words, table=True)
        page_bottom = max((ln.y for ln in lines), default=0.0)
        out.stats["stitched_rows"] += stitch_split_rows(lines)
        for ln in lines:
            ln.page = pno
        # Locate an embedded note table on this page, if any, so its grid is
        # consumed as a table rather than read as note prose. Only a row of
        # consecutive column markers counts — see find_table_header().
        header_y = find_table_header(words)
        page_table = extract_note_table(words, header_y) if header_y is not None else None
        table_attached = False

        for ln in lines:
            if page_table is not None \
                    and page_table["y_from"] - 0.5 <= ln.y <= page_table["y_to"] + 0.5:
                # Inside the table's own span: attach the grid once to the note
                # that is open, and consume the grid's lines so its cells are
                # never read as prose. The span is bounded by the extracted
                # table itself, so note text below the table still parses — an
                # earlier version skipped to the next note number and silently
                # dropped the remainder of several notes.
                if not table_attached:
                    if current_note is not None:
                        current_note.tables.append(page_table)
                        out.stats["note_tables"] += 1
                    else:
                        out.stats["note_table_unattached"] += 1
                    table_attached = True
                continue

            c1, c2, c3 = ln.col("c1"), ln.col("c2"), ln.col("c3")
            whole = ln.all_text

            # Printed folio: a bare number alone near the foot of the page.
            # Only the page's LOWEST line can be the folio: a wrapped description
            # may end in a lone number ("... in Chapter" / "87").
            if whole and RE_FOLIO.fullmatch(whole) and ln.y >= page_bottom - 1.0 \
                    and len(ln.cols) == 1:
                out.stats["folio"] += 1
                continue
            if not whole:
                continue

            # One page sets a heading in the subheading column (see CURATION 3).
            if not c1 and c2 and RE_HEADING_CODE.match(c2):
                out.promoted_headings.append((pno, c2))
                c1, c2 = c2, ""
                ln.cols["c1"] = c1
                ln.cols.pop("c2", None)

            # ---- structural headers -------------------------------------
            m = RE_SECTION_HDR.match(whole)
            if m:
                flush_title(); close_note(); close_row()
                section = m.group(1).upper()
                # The chapter in hand belongs to the section just ended. Section
                # XI prints its own Subheading Notes between this header and
                # chapter 50, and while the chapter persisted they were filed as
                # SHN-49-*, attributing the textile-blend rule that governs
                # chapters 50-63 to a chapter in Section X -- with the record's
                # own `section` field saying XI. flush_title() already guards on
                # `chapter is not None`, and a chapter header always precedes
                # that chapter's rows, so nothing else reads it in between.
                chapter = None
                out.sections.setdefault(section, {})
                region = "section_title"
                out.stats["section_hdr"] += 1
                continue
            m = RE_CHAPTER_HDR.match(whole)
            if m:
                flush_title(); close_note(); close_row()
                chapter = int(m.group(1))
                out.chapters.setdefault(chapter, {"section": section})
                region = "chapter_title"
                out.stats["chapter_hdr"] += 1
                continue
            if RE_NOTE_HDR.match(whole):
                flush_title(); close_note(); close_row()
                # A Note. block under a SECTION header is a section note; under a
                # Chapter header (or continuing a chapter's note run) it is a
                # chapter note. Nothing else can reach here, because `region` is
                # only ever set by those two headers or by the first coded row.
                note_kind = "section_note" if region == "section_title" else "chapter_note"
                region = "notes"
                note_col_x = ln.x0
                out.stats["note_hdr"] += 1
                continue
            if RE_SUBHEADING_NOTE_HDR.match(whole):
                flush_title(); close_note(); close_row()
                note_kind = "subheading_note"
                region = "notes"
                note_col_x = ln.x0
                out.stats["subheading_note_hdr"] += 1
                continue

            if region in ("section_title", "chapter_title"):
                # Centred title text, possibly several lines. A coded row or a
                # Note. header ends it; both are handled above.
                if c1 or c2:
                    flush_title()
                    region = "tariff"
                else:
                    title_buf.append(whole)
                    continue

            # ---- tariff rows --------------------------------------------
            heading_code = c1 if RE_HEADING_CODE.match(c1 or "") else ""
            sub_code = c2 if RE_SUB_CODE.match(c2 or "") else ""
            if heading_code or sub_code:
                close_note()
                close_row()
                region = "tariff"
                in_subchapter_title = False
                depth, desc = _dash_depth(c3)
                indent = 0 if heading_code and not sub_code else depth
                if heading_code and sub_code:
                    # "02.05  0205.00.00  Meat of horses..." — one heading whose
                    # only line is itself. The operative code is the 8-digit one
                    # and it sits at the heading's own level.
                    indent = 0
                    out.stats["heading_with_single_line"] += 1
                code = sub_code or heading_code
                digits = re.sub(r"\D", "", code)
                current_row = TariffRow(
                    page=pno, printed_page=printed, section=section,
                    chapter=chapter if chapter is not None else 0,
                    heading=heading_code or (code[:5] if len(code) >= 5 else ""),
                    code=code, digits=digits, description=desc, indent=indent,
                    unit=ln.col("c4"), duty_full=ln.col("c5"),
                    duty_pref=ln.col("c6"), excise=ln.col("c7"))
                out.stats["coded_row"] += 1
                continue

            if region == "tariff":
                # SUB-CHAPTER HEADINGS (chapters 28, 29, 69): "SUB-CHAPTER II"
                # and its capitalised title, printed between tariff lines. Read
                # as continuation they were glued onto the line above: 26 rows
                # such as 2805.40.00 "Mercury SUB-CHAPTER II INORGANIC ACIDS ...".
                if not c1 and not c2 and pdf_text.RE_SUBCHAPTER.match(whole):
                    close_row()
                    in_subchapter_title = True
                    out.stats["subchapter_hdr"] += 1
                    continue
                if in_subchapter_title and not c1 and not c2 \
                        and pdf_text.is_caps_title(whole):
                    out.stats["subchapter_title_line"] += 1
                    continue
                in_subchapter_title = False
                depth, desc = _dash_depth(c3)
                if c3 and depth > 0:
                    # Uncoded dash row: a CONDITION row ("- Horses :"). It gets
                    # its own entry with an empty code so build_tree() treats it
                    # as the grouping label it is rather than a product line.
                    close_row()
                    # A condition row wraps like any other: "- Collections and
                    # collectors' pieces of zoological, botanical, mineralogical,"
                    # / "anatomical or paleontological interest :" is one label
                    # over two printed lines. It becomes `current_row` so the
                    # continuation attaches to it; appending it straight to
                    # out.rows instead truncated 279 such labels, and a
                    # truncated condition is a wrong edge condition on every
                    # child beneath it.
                    current_row = TariffRow(
                        page=pno, printed_page=printed, section=section,
                        chapter=chapter if chapter is not None else 0,
                        heading="", code="", digits="", description=desc,
                        indent=depth, unit=ln.col("c4"), duty_full=ln.col("c5"),
                        duty_pref=ln.col("c6"), excise=ln.col("c7"))
                    out.stats["condition_row"] += 1
                    continue
                if current_row is not None:
                    current_row.add(ln)
                    out.stats["continuation"] += 1
                else:
                    out.stats["orphan_text"] += 1
                continue

            # ---- note bodies ---------------------------------------------
            if region == "notes":
                first = whole.split(" ")[0]
                m_num = RE_NOTE_NUM.match(first)
                m_sub = RE_SUBPARA.match(first)
                # A NOTE NUMBER IS A COLUMN POSITION, NOT JUST A PATTERN.
                #
                # Notes nest three deep and the third level is numbered too, so
                # "1." and "2." appear both as notes and as sub-sub-items.
                # Chapter 48 Note 5 is the clearest case: 5 -> (A) -> (a) -> 1.
                # Matching on the pattern alone restarts the note numbering
                # mid-note and collided on N-48-1.
                #
                # Measured over every numbered line in the book, a real note
                # number sits 0.0-4.6pt from its block's own "Note(s)." header
                # (470 lines) and a nested item sits 15.4-58.8pt in (19 lines).
                # Nothing falls between, so 8pt separates them with no
                # judgement call.
                # The header is not always flush with its notes: on Chapter 4's
                # page (PDF p.45) "Notes." sits at x=92.4 and every note number
                # at 110.4, so all six notes (and both subheading notes) read
                # as items nested in the first. A nested item needs a note to
                # nest in, so the first "1." of a block, with no note open yet,
                # sets the block's note column wherever it is.
                if (m_num and current_note is None and m_num.group(1) == "1"
                        and abs(ln.x0 - note_col_x) > 8.0):
                    note_col_x = ln.x0
                    out.stats["note_column_from_first_note"] += 1
                if m_num and abs(ln.x0 - note_col_x) > 8.0:
                    if current_note is not None:
                        kind_, label, text = current_note.parts[-1]
                        current_note.parts[-1] = (
                            kind_, label, join_text(text, whole))
                        out.stats["note_nested_item"] += 1
                        continue
                    m_num = None
                if m_num:
                    scope_key = (note_kind, section,
                                 chapter if note_kind != "section_note" else None)
                    number = m_num.group(1)
                    body_peek = whole[len(first):].strip()
                    first_label = RE_SUBPARA.match(body_peek.split(" ")[0]
                                                   if body_peek else "")
                    # A MISPRINTED NOTE NUMBER IN THE SOURCE.
                    #
                    # On printed page 274 the book sets "3." where Section XI
                    # Note 2(B) begins, so Note 2 reads (A) and Note "3" reads
                    # (B), (C) — and the real Note 3 follows, also starting at
                    # (A). The text itself settles it: (B) opens "For the
                    # purposes of the above rule" and (C) says "paragraphs (A)
                    # and (B) above", so (B) and (C) are parts of Note 2. A note
                    # cannot begin at (B).
                    #
                    # The test is the LABEL, not a repeated number: the
                    # misprinted "3." is printed BEFORE the real Note 3, so at
                    # the moment it is read the number has not been used yet.
                    # What gives it away is that it opens at (B) — and a note's
                    # own subparagraph sequence always starts at its first
                    # label, so a note opening at a non-first label is never
                    # well formed. Such a block is folded into the note already
                    # open and the anomaly is recorded rather than silently
                    # repaired. It fires exactly once in this edition; validate()
                    # asserts that count, so a second occurrence in a future
                    # edition fails the build instead of being absorbed.
                    if (current_note is not None and first_label
                            and first_label.group(1) not in ("A", "a", "1", "i", "I")):
                        current_note.parts.append(
                            ("sub", first_label.group(1),
                             body_peek[len(first_label.group(0)):].strip()))
                        out.source_anomalies.append({
                            "printed_page": printed,
                            "pdf_page": pno,
                            "scope": f"{note_kind} {section or chapter}",
                            "printed_number": number,
                            "resolved_as": f"continuation of note {current_note.number}",
                            "first_label": first_label.group(1),
                            "reason": "a note cannot begin at a non-opening "
                                      "subparagraph label; the text back-references "
                                      "the preceding note",
                        })
                        out.stats["note_misnumbered"] += 1
                        continue
                    used_numbers[scope_key].add(number)
                    close_note()
                    current_note = NoteBlock(
                        kind=note_kind, section=section, chapter=chapter,
                        number=m_num.group(1), page=pno, printed_page=printed)
                    body = whole[len(first):].strip()
                    # "2. (A) Products from the milling..." — a note whose first
                    # token after the number is itself a subparagraph label.
                    m_inner = RE_SUBPARA.match(body.split(" ")[0] if body else "")
                    if m_inner:
                        label = m_inner.group(1)
                        current_note.parts.append(
                            ("sub", label, body[len(m_inner.group(0)):].strip()))
                    else:
                        current_note.parts.append(("para", "", body))
                    out.stats["note_number"] += 1
                elif m_sub and current_note is not None:
                    current_note.parts.append(
                        ("sub", m_sub.group(1), whole[len(first):].strip()))
                    out.stats["note_subpara"] += 1
                elif current_note is not None:
                    kind_, label, text = current_note.parts[-1]
                    current_note.parts[-1] = (kind_, label, join_text(text, whole))
                    out.stats["note_continuation"] += 1
                else:
                    # Prose under a Note. header before any "1." — the single
                    # unnumbered note form ("Note." then a bare paragraph).
                    current_note = NoteBlock(
                        kind=note_kind, section=section, chapter=chapter,
                        number="1", page=pno, printed_page=printed)
                    current_note.parts.append(("para", "", whole))
                    out.stats["note_unnumbered"] += 1
                continue

            out.stats["unclassified"] += 1

        flush_title()
    close_note()
    close_row()
    return out


# ── notes corpus ─────────────────────────────────────────────────────────────

# Anchored so a code inside a longer code is not mistaken for a shorter one:
# "2204.21" must not yield heading "0421", and "0101.21.00" must not yield
# subheading "010121" twice over.
RE_H4 = re.compile(r"(?<![\d.])(\d{2})\.(\d{2})(?![\d.])")
RE_S6 = re.compile(r"(?<![\d.])(\d{4})\.(\d{2})(?![\d.])")
RE_S8 = re.compile(r"(?<![\d.])(\d{4})\.(\d{2})\.(\d{2})(?![\d.])")

SECTION_OF_CHAPTER_FALLBACK = ""


def extract_refs(text: str) -> dict:
    headings = {a + b for a, b in RE_H4.findall(text)}
    subheadings = {a + b for a, b in RE_S6.findall(text)}
    for a, b, c in RE_S8.findall(text):
        subheadings.add(a + b)
    chapters = set()
    for m in re.finditer(r"\bChapters?\s+(\d{1,2})(?:\s+(?:to|or|and)\s+(\d{1,2}))?",
                         text, re.IGNORECASE):
        chapters.add(m.group(1).zfill(2).lstrip("0") or "0")
        if m.group(2):
            chapters.add(m.group(2).lstrip("0") or "0")
    sections = set(RE_REF_SECTION.findall(text))
    return {
        "refs_headings": sorted(headings),
        "refs_subheadings": sorted(subheadings),
        "refs_chapters": sorted(chapters, key=lambda c: int(c)),
        "refs_sections": sorted(sections),
    }


def note_text(block: NoteBlock) -> tuple[str, list]:
    """Render a note block to prose, plus its tables as pipe tables."""
    chunks = []
    for kind, label, text in block.parts:
        text = norm(text)
        if not text:
            continue
        chunks.append(f"({label}) {text}" if kind == "sub" and label else text)
    body = norm(" ".join(chunks))
    key = (str(block.chapter), block.number)
    for table in block.tables:
        if table and key in CURATED_TABLE_TITLES:
            titles = CURATED_TABLE_TITLES[key]
            if len(titles) == len(table["columns"]):
                table["titles"] = titles
    rendered = [render_note_table(t) for t in block.tables if t]
    if rendered:
        body = body + "\n" + "\n".join(rendered)
    return body, rendered


def build_note_records(book: BookParse, gri: list[dict], source_sha: str) -> dict:
    """One record per note, schema-identical to the US corpus from
    build_hts_notes.py so the Explorer sidecar reader and pinecone_sync need no
    Singapore-specific branch."""
    records: dict[str, dict] = {}

    def put(cite_id: str, scope: str, kind: str, number: str, label: str,
            body: str, *, section: str | None, chapter: str | None,
            page: int, printed_page: int | None, examples: list, tables: list) -> None:
        if not body.strip():
            return
        if cite_id in records:
            raise SystemExit(f"ERROR: duplicate cite_id {cite_id}")
        refs = extract_refs(body)
        records[cite_id] = {
            "_id": f"{JURISDICTION}|{REVISION}|{kind}|{scope}|{number}",
            "chapter": chapter,
            "chunk_text": body,
            "cite_id": cite_id,
            "content_sha256": sha256_text(body),
            "display_text": f"[{cite_id}] {label}: {body}",
            "examples": examples,
            "jurisdiction": JURISDICTION,
            "kind": kind,
            "note_number": number,
            "page": page,
            "printed_page": printed_page,
            "paragraph": None,
            "revision": REVISION,
            "section": section,
            "source_sha256": source_sha,
            "source_url": PDF_URL,
            "tables": tables,
            **refs,
        }

    # General Interpretative Rules. Singapore's own name for them is GIR, but
    # `kind` stays "gri" to match the US corpus the readers already handle.
    preamble = gri[0].get("preamble", "")
    if preamble:
        put("GRI-PREAMBLE", "GRI", "gri", "0",
            "General Interpretative Rules, preamble", preamble,
            section=None, chapter=None, page=PAGES_GRI[0], printed_page=None,
            examples=[], tables=[])
    for rule in gri[1:]:
        number = rule["number"]
        body = rule["body"]
        examples = rule.get("examples") or []
        if examples:
            body = norm(body + " Examples: " + " ".join(
                e if e.endswith(".") else e + "." for e in examples))
        put(f"GRI-{number}", "GRI", "gri", number,
            f"General Interpretative Rule {number}", body,
            section=None, chapter=None, page=PAGES_GRI[0], printed_page=None,
            examples=examples, tables=[])

    for block in book.notes:
        body, tables = note_text(block)
        if block.kind == "section_note":
            cite = f"SN-{block.section}-{block.number}"
            label = f"Section {block.section}, Note {block.number}"
            scope, chapter = block.section, None
        elif block.kind == "subheading_note" and block.chapter is None:
            # Section XI's own Subheading Notes. Section scope is what makes them
            # retrievable for every chapter they bind, and it matches the cite
            # the Malaysian order produces for the same two notes.
            cite = f"SHN-{block.section}-{block.number}"
            label = f"Section {block.section}, Subheading Note {block.number}"
            scope, chapter = block.section, None
        elif block.kind == "subheading_note":
            cite = f"SHN-{block.chapter}-{block.number}"
            label = f"Chapter {block.chapter}, Subheading Note {block.number}"
            scope, chapter = str(block.chapter), str(block.chapter)
        else:
            cite = f"N-{block.chapter}-{block.number}"
            label = f"Chapter {block.chapter}, Note {block.number}"
            scope, chapter = str(block.chapter), str(block.chapter)
        put(cite, scope, block.kind, block.number, label, body,
            section=block.section or None, chapter=chapter,
            page=block.page, printed_page=block.printed_page,
            examples=[], tables=tables)
    return records


# ── validation ───────────────────────────────────────────────────────────────

EXPECTED = {"sections": 21, "chapters": 98, "note_hdr": 96,
            "subheading_note_hdr": 38, "promoted_headings": 1,
            "stitched_rows": 3, "note_misnumbered": 1, "note_tables": 1,
            "note_table_unattached": 0,
            # Blocks whose notes sit further in than their header (Chapter 4's
            # notes and subheading notes, and one more): the first "1." sets
            # the column. Before this, Chapter 4's six notes read as one.
            "note_column_from_first_note": 3, "note_nested_item": 10}

# Matching a number cannot catch a family that produces NOTHING, and a count
# pinned at zero would enshrine the absence. The Malaysian order shipped for
# months with no section notes and no interpretative rules because its gates
# compared only the counts it happened to list; this asserts presence instead.
REQUIRED_NOTE_KINDS = ("chapter_note", "subheading_note", "section_note", "gri")


def validate(book: BookParse, notes: dict, toc: dict,
             reference: dict | None = None) -> list[str]:
    """Hard gates first, then the reconciliations worth printing either way.

    Every count here was measured against the PDF before the parser was written,
    so a mismatch means the parse changed, not that the expectation was guessed.
    """
    errors: list[str] = []
    got = {
        "sections": len(book.sections),
        "chapters": len(book.chapters),
        "note_hdr": book.stats["note_hdr"],
        "subheading_note_hdr": book.stats["subheading_note_hdr"],
        "folio": book.stats["folio"],
        "promoted_headings": len(book.promoted_headings),
        "stitched_rows": book.stats["stitched_rows"],
        "note_misnumbered": book.stats["note_misnumbered"],
        "note_column_from_first_note": book.stats["note_column_from_first_note"],
        "note_nested_item": book.stats["note_nested_item"],
        "note_tables": book.stats["note_tables"],
        "note_table_unattached": book.stats["note_table_unattached"],
    }
    for key, want in EXPECTED.items():
        if got[key] != want:
            errors.append(f"{key}: parsed {got[key]}, expected {want}")

    kinds = Counter(r["kind"] for r in notes.values())
    for kind in REQUIRED_NOTE_KINDS:
        if not kinds.get(kind):
            errors.append(f"note family {kind!r} is empty - the book carries it, "
                          f"so nothing should reduce it to zero")

    if reference is not None:
        parsed_units = set(reference.get("units_of_quantity") or {})
        if parsed_units != set(UNIT_CODES):
            errors.append(
                f"UNIT_CODES disagrees with the parsed units table: "
                f"only in constant {sorted(set(UNIT_CODES) - parsed_units)}, "
                f"only in page XIII {sorted(parsed_units - set(UNIT_CODES))}")

    if book.stats["orphan_text"]:
        errors.append(f"{book.stats['orphan_text']} text line(s) had no row to "
                      f"attach to — a description would be lost")
    if book.stats["unclassified"]:
        errors.append(f"{book.stats['unclassified']} line(s) matched no rule")

    # Every chapter 1..98 must be present; 77 is reserved and carries no codes.
    missing = sorted(set(range(1, 99)) - set(book.chapters))
    if missing:
        errors.append(f"chapters absent from the book: {missing}")

    coded = [r for r in book.rows if r.digits]
    seen: dict[str, TariffRow] = {}
    for row in coded:
        if len(row.digits) not in (4, 6, 8):
            errors.append(f"{row.code} (p{row.printed_page}): {len(row.digits)} digits")
        if row.digits in seen:
            errors.append(f"duplicate code {row.code} on printed pages "
                          f"{seen[row.digits].printed_page} and {row.printed_page}")
        else:
            seen[row.digits] = row
        if row.chapter and row.digits[:2] != f"{row.chapter:02d}":
            errors.append(f"{row.code} (p{row.printed_page}) sits in chapter "
                          f"{row.chapter}")

    # THE DASH-DEPTH GATE.
    #
    # The indent is taken from the printed dash prefix, which is a typographic
    # signal, not a checked one. This asserts it against the independent truth
    # of digit-prefix parentage: the nearest shallower CODED row above a coded
    # row must be its code prefix. If a dash were ever dropped or doubled in
    # typesetting, a product would silently inherit the wrong parent — the exact
    # failure documented for Canada in build_hts_corpus.py, where a dozen
    # Chapter 99 provisions adopted an unrelated sibling.
    stack: list[TariffRow] = []
    violations = 0
    for row in book.rows:
        while stack and stack[-1].indent >= row.indent:
            stack.pop()
        if row.digits and stack:
            ancestors = [a for a in stack if a.digits]
            if ancestors:
                parent = ancestors[-1]
                if not row.digits.startswith(parent.digits):
                    violations += 1
                    if violations <= 10:
                        errors.append(
                            f"dash depth disagrees with code parentage: "
                            f"{row.code} (indent {row.indent}, printed page "
                            f"{row.printed_page}) under {parent.code} "
                            f"(indent {parent.indent})")
        stack.append(row)
    if violations > 10:
        errors.append(f"... and {violations - 10} further dash-depth violations")
    return errors


def reconcile(book: BookParse, toc: dict) -> list[str]:
    """Non-fatal cross-checks, always printed: the contents page against the
    book, and the unit-of-quantity column against tree leaves."""
    out = []
    mismatched = []
    for number, info in sorted(book.chapters.items()):
        book_title = norm(info.get("title", "")).rstrip(".").lower()
        toc_title = norm(toc.get(number, {}).get("toc_title", "")).rstrip(".").lower()
        if not toc_title:
            mismatched.append(f"ch {number}: absent from contents")
        elif book_title != toc_title:
            mismatched.append(f"ch {number}")
    out.append(f"contents vs book titles: {len(book.chapters) - len(mismatched)}"
               f"/{len(book.chapters)} identical"
               + (f"; differing: {', '.join(mismatched[:12])}" if mismatched else ""))

    coded = [r for r in book.rows if r.digits]
    with_unit = [r for r in coded if r.unit]
    # A row with no code-prefix descendant is a classification target.
    all_digits = {r.digits for r in coded}
    leaves = {d for d in all_digits
              if not any(o != d and o.startswith(d) for o in all_digits)}
    unit_digits = {r.digits for r in with_unit}
    out.append(f"codes {len(coded)} ({len(all_digits)} distinct); tree leaves "
               f"{len(leaves)}; rows carrying a unit of quantity {len(with_unit)}")
    out.append(f"  leaves without a unit: {len(leaves - unit_digits)}; "
               f"units on non-leaves: {len(unit_digits - leaves)}")
    duty_full = [r for r in coded if r.duty_full]
    duty_pref = [r for r in coded if r.duty_pref]
    excise = [r for r in coded if r.excise]
    out.append(f"duty columns populated: customs FULL {len(duty_full)}, "
               f"customs PREF {len(duty_pref)}, EXCISE {len(excise)} "
               f"(of {len(coded)} coded rows)")
    return out


# ── emit ─────────────────────────────────────────────────────────────────────

CSV_FIELDS = ("GOODS_CODE", "DISPLAY", "DESCRIPTION", "INDENT", "UNIT",
              "DUTY_FULL", "DUTY_PREF", "EXCISE", "IS_LEAF", "SECTION",
              "CHAPTER", "PDF_PAGE", "PRINTED_PAGE")


def write_csv(book: BookParse, path: Path) -> int:
    """The canonical tabular form load_rows_sg() reads.

    Condition rows are kept, with an empty GOODS_CODE. They are not products,
    but they carry the statutory text that distinguishes their children ("-
    Horses :" above two codes that merely say "Pure-bred breeding animals" and
    "Other"), and build_tree() needs them to place those children correctly.
    """
    coded = {r.digits for r in book.rows if r.digits}
    leaves = {d for d in coded if not any(o != d and o.startswith(d) for o in coded)}
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for row in book.rows:
            writer.writerow({
                "GOODS_CODE": row.digits,
                "DISPLAY": row.code,
                "DESCRIPTION": row.description,
                "INDENT": row.indent,
                "UNIT": row.unit,
                "DUTY_FULL": row.duty_full,
                "DUTY_PREF": row.duty_pref,
                "EXCISE": row.excise,
                "IS_LEAF": "1" if row.digits and row.digits in leaves else "",
                "SECTION": row.section,
                "CHAPTER": f"{row.chapter:02d}" if row.chapter else "",
                "PDF_PAGE": row.page,
                "PRINTED_PAGE": row.printed_page,
            })
    return len(book.rows)


def write_chapters(book: BookParse, path: Path) -> None:
    """chapters_sg.json, in the shape make_chapters.py produces for the others:
    one object per chapter with its own and its section's title."""
    out = []
    for number in sorted(book.chapters):
        info = book.chapters[number]
        section = info.get("section", "")
        out.append({
            "chapter": f"{number:02d}",
            "description": norm(info.get("title", "")).rstrip("."),
            "section": section,
            "sectionTitle": norm(book.sections.get(section, {}).get("title", "")).rstrip("."),
        })
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2,
                               sort_keys=False) + "\n", encoding="utf-8")


def write_notes(records: dict, out_dir: Path, source_sha: str,
                pdf_path: Path, book: BookParse) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"sg_{REVISION}"
    # The US record shape (notes_contract): section chapters, cross-references
    # and a record per lettered paragraph, before anything is written or
    # counted, so the sidecar, the JSONL and the manifest all agree.
    records = notes_contract.finalize(records, refs=extract_refs)
    sidecar = out_dir / f"{stem}.notes.json"
    sidecar.write_text(json.dumps(records, ensure_ascii=False, indent=2,
                                  sort_keys=True) + "\n", encoding="utf-8")

    # Three independently searchable Pinecone families, matching the US split.
    families = {"gri": ("gri",),
                "section": ("section_note",),
                "chapter": ("chapter_note", "subheading_note")}
    artifact_sha = {}
    for family, kinds in families.items():
        rows = [records[c] for c in sorted(records)
                if records[c]["kind"] in kinds]
        fp = out_dir / f"{stem}.notes.{family}.jsonl"
        with fp.open("w", encoding="utf-8") as fh:
            for rec in rows:
                # The US record as the notes index holds it: its fields only,
                # no nulls (Pinecone rejects an explicit null). The sidecar
                # keeps the full shape.
                fh.write(json.dumps(notes_contract.pinecone_record(rec),
                                    ensure_ascii=False, sort_keys=True) + "\n")
        artifact_sha[fp.name] = sha256_file(fp)
    artifact_sha[sidecar.name] = sha256_file(sidecar)

    by_kind = Counter(r["kind"] for r in records.values())
    by_chapter = Counter(r["chapter"] for r in records.values() if r["chapter"])
    by_section = Counter(r["section"] for r in records.values() if r["section"])
    manifest = {
        "artifact_sha256": dict(sorted(artifact_sha.items())),
        "counts": {
            "by_chapter": {k: by_chapter[k] for k in sorted(by_chapter, key=int)},
            "by_kind": dict(sorted(by_kind.items())),
            "by_section": dict(sorted(by_section.items())),
            "total": len(records),
        },
        "edition": EDITION_LABEL,
        "jurisdiction": JURISDICTION,
        "landing_url": LANDING_URL,
        "note_tables": book.stats["note_tables"],
        "parsed_chapters": sorted(book.chapters),
        "parsed_gri": any(r["kind"] == "gri" for r in records.values()),
        "pdf_sha256": {pdf_path.name: source_sha},
        "poppler_version": poppler_version(),
        "reserved_chapters": [77],
        "revision": REVISION,
        "schema_version": 1,
        "source_urls": {pdf_path.name: PDF_URL},
    }
    mf = out_dir / f"{stem}.notes.manifest.json"
    mf.write_text(json.dumps(manifest, ensure_ascii=False, indent=2,
                             sort_keys=True) + "\n", encoding="utf-8")
    return manifest


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pdf", type=Path, help="stcced2022.pdf")
    ap.add_argument("--out-dir", type=Path,
                    default=REPO_ROOT / "data" / "sg_tariff_source")
    ap.add_argument("--notes-dir", type=Path,
                    default=REPO_ROOT / "data" / "hts_notes" / f"sg_{REVISION}")
    ap.add_argument("--chapters-out", type=Path,
                    default=Path(__file__).resolve().parent / "chapters_sg.json")
    ap.add_argument("--workdir", type=Path, default=None,
                    help="where the bbox XML is written (default: --out-dir)")
    ap.add_argument("--no-validate", action="store_true",
                    help="report the gates but do not fail on them")
    args = ap.parse_args()

    if not args.pdf.is_file():
        return int(bool(sys.stderr.write(f"ERROR: no such PDF: {args.pdf}\n"))) or 2
    workdir = args.workdir or args.out_dir
    workdir.mkdir(parents=True, exist_ok=True)
    source_sha = sha256_file(args.pdf)

    print(f"Reading {args.pdf.name} ({args.pdf.stat().st_size:,} bytes)")
    print(f"  sha256 {source_sha}")
    pages = load_pages(args.pdf, workdir)
    print(f"  {len(pages)} PDF pages; book pages {FIRST_BOOK_PAGE}..{len(pages)} "
          f"(printed 1..{len(pages) - PRINTED_OFFSET})")

    gri = parse_gri(pages)
    print(f"  GRI: {len(gri) - 1} rules + preamble")
    reference = parse_reference(pages)
    print(f"  reference: {len(reference['abbreviations'])} abbreviations, "
          f"{len(reference['units_of_quantity'])} units of quantity")
    toc = parse_toc(pages)
    print(f"  contents: {len(toc)} chapters")

    book = parse_book(pages, toc)
    print(f"  book: {book.stats['coded_row']} coded rows, "
          f"{book.stats['condition_row']} condition rows, "
          f"{len(book.notes)} note blocks")

    records = build_note_records(book, gri, source_sha)

    print("\n--- reconciliation ---")
    for line in reconcile(book, toc):
        print("  " + line)
    print("\n--- row classes ---")
    for key, value in sorted(book.stats.items()):
        print(f"  {key:26s} {value}")

    errors = validate(book, records, toc, reference)
    print("\n--- gates ---")
    if errors:
        for err in errors:
            print(f"  FAIL {err}")
        if not args.no_validate:
            print(f"\n{len(errors)} gate failure(s); nothing written.")
            return 3
    else:
        print("  all gates pass")

    args.out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = args.out_dir / f"sg_tariff_{REVISION}.csv"
    n = write_csv(book, csv_path)
    # The manual acquisition adapter reads the effective date from this
    # sidecar, exactly as it does for the Dominican Republic's transcription.
    csv_path.with_name(csv_path.name + ".meta.json").write_text(json.dumps({
        "effective_date": EFFECTIVE_DATE,
        # A date, as every schedule's label is meant to be (it prints as "effective
        # <label>" and beside the History revision pill); the edition is
        # edition_label.
        "effective_date_label": "{d:%B} {d.day}, {d.year}".format(
            d=__import__("datetime").date.fromisoformat(EFFECTIVE_DATE)),
        "edition_label": f"{EDITION_LABEL} edition",
        "source": PDF_URL,
        "source_sha256": source_sha,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.out_dir / f"sg_{REVISION}.reference.json").write_text(
        json.dumps(reference, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (args.out_dir / f"sg_{REVISION}.toc.json").write_text(
        json.dumps([toc[k] for k in sorted(toc)], ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")
    write_chapters(book, args.chapters_out)
    manifest = write_notes(records, args.notes_dir, source_sha, args.pdf, book)

    print(f"\nWrote {n:,} rows -> {csv_path}")
    print(f"Wrote {manifest['counts']['total']:,} note records -> {args.notes_dir}")
    for kind, count in manifest["counts"]["by_kind"].items():
        print(f"    {kind:18s} {count}")
    print(f"Wrote {args.chapters_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

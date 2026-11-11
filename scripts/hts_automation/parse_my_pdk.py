#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""parse_my_pdk.py — parse Malaysia's Customs Duties Order into the tariff corpus.

SOURCES — TWO, AND BOTH ARE NEEDED
  1. The ezHS public tariff portal, which serves the WHOLE schedule as one
     server-rendered HTML page (~5.7 MB, 13,502 rows, no API and no session):
         https://ezhs.customs.gov.my/public-tariff?tariff=<token>&km=<key>
     Its table carries fifteen columns, against the gazette's six:
         HEADER | SUB | ITEM | UNIT | DESCRIPTION | IMPORT RATE | EKSPORT RATE
         | TRQ | SST | EXCISE | CESS 1 | CESS 2 | CESS 3 | IMPPRO | EKSPRO
     so sales tax, excise, cess and tariff-rate-quota flags come for free. The
     `km` key is per scheme and stable; only the date inside the base64 `tariff`
     token rotates, so --fetch resolves the current link from the portal's home
     page rather than hard-coding one that will expire.
  2. P.U. (A) 384, the gazetted Customs Duties Order 2025 (in force
     1 November 2025), 1,466 pages:
         https://www.customs.gov.my/images/06-prosedur/perintah-kastam/perintah/PUA_384.pdf
     The portal has no legal notes and no chapter titles, so the section notes,
     chapter notes, subheading notes and chapter headings are read from here.

  WHY NOT THE PDF ALONE: it carries six columns and no sales tax, excise or
  cess.

  WHY THE PORTAL CANNOT CARRY THE STRUCTURE: its DataTable is SORTED, not in
  document order. Of 1,231 headings exactly one has a condition row after a
  coded row, and within a heading every blank-code row precedes every coded one
  — under 0105 the indent runs 0,1,1,3,3 then 2,2,2..., which no printed page
  ever did. The hierarchy here is the dash depth printed beside each line, and
  dash depth is meaningless once the lines are reordered: build_tree() would
  parent "- - Weighing less than 50 kg" to "- Pure-bred breeding animals"
  instead of to the "- Other:" that governs it. The dash-depth gate in
  validate() caught this at 6,852 violations.

  So the GAZETTE is the structural source — it is also the legal instrument —
  and the portal is joined onto it by 10-digit code, which is safe: the portal
  has zero duplicate codes. From the portal come the four things the gazette
  does not print: SST, excise, cess and the TRQ flag. See also THE TRQ GAP.

THE TRQ GAP — the reason this script reads both
  38 coded rows in the portal have an EMPTY import rate, and the portal's own
  TRQ column flags only 27 of them. In the gazette every one of those rows
  reads "TRQ as specified in Appendix B" — they are tariff-rate-quota lines:
  pork carcasses, poultry cuts, live swine. Taking the portal's blank at face
  value publishes quota-controlled meat as duty-free, which is the single worst
  error available in this dataset. So a blank import rate on a coded row is
  never emitted as a rate: it is recorded as
  IMPORT_RATE_BASIS=trq_appendix_b, and validate() asserts the count against
  the gazette so a change in either source fails the build.

CODES
  The gazette prints the 10-digit line as "0101.21.00 00" — two tokens in the
  Subheading column — and the heading as "01.01" in the Heading column. Shorter
  forms are real internal nodes: a heading alone, and the HS single-dash level
  (0401.1, 2208.3). Hierarchy is the dash depth printed in the description,
  exactly as Singapore's STCCED prints it.

PAGES (1-based, this edition)
  16-1366  First Schedule, the main tariff table
  1367     Appendix A
  1371     Appendix B — goods subject to tariff rate quota
  1377     Appendix C
  1461     Second Schedule        1464  Third Schedule
  Only the main table and Appendix B are read; the rest are out of scope and
  are recorded as such rather than silently skipped.

USAGE
  python3 scripts/hts_automation/parse_my_pdk.py \
      --html data/my_tariff_source/.my_download/ezhs_pdk2025.html \
      --pdf  data/my_tariff_source/.my_download/PUA_384.pdf
  python3 scripts/hts_automation/parse_my_pdk.py --fetch --pdf <pdf>
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
import urllib.request
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from html.parser import HTMLParser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pdf_text  # noqa: E402  (shared repairs; see its docstring)
import notes_contract  # noqa: E402  (the US notes record shape)

REPO_ROOT = Path(__file__).resolve().parents[2]

JURISDICTION = "MY"
# The standard {year}_rev_{number} id every jurisdiction uses. Dated editions
# take MMDD of the effective date as the number (CH 901, KR 101, TW 729): the
# Order in force from 1 November 2025 is 2025_rev_1101.
REVISION = "2025_rev_1101"
EDITION_LABEL = "Customs Duties Order 2025 (P.U. (A) 384)"
IN_FORCE = "2025-11-01"
PORTAL_HOME = "https://ezhs.customs.gov.my/"
PORTAL_SCHEME = "PDK 2025"
PDF_URL = ("https://www.customs.gov.my/images/06-prosedur/perintah-kastam/"
           "perintah/PUA_384.pdf")
UA = "sail-tariff-tracker/1.0"

EXPECTED_COLUMNS = ["HEADER", "SUB", "ITEM", "UNIT", "DESCRIPTION",
                    "IMPORT RATE", "EKSPORT RATE", "TRQ", "SST", "EXCISE",
                    "CESS 1", "CESS 2", "CESS 3", "IMPPRO", "EKSPRO"]

TRQ_BASIS = "trq_appendix_b"

RE_CHAPTER_HDR = re.compile(r"^CHAPTER\s+(\d{1,2})$", re.IGNORECASE)
# The terminator is "." everywhere but once: Chapter 40 is headed "Chapter Notes:",
# which matched nothing, so its nine notes were read as the chapter TITLE (a
# 4,940-character title in chapters_my.json) and chapter 40 had no notes at all.
RE_NOTE_HDR = re.compile(r"^(?:CHAPTER\s+)?NOTES?[.:]$", re.IGNORECASE)
RE_SUBHEADING_NOTE_HDR = re.compile(r"^SUB-?HEADING\s+NOTES?[.:]$", re.IGNORECASE)
# Malaysia prints a third category after the HS notes: its own National Notes,
# which define terms the schedule relies on ("airtight container", "Fish ball")
# and are operative. They are the analogue of the US Additional U.S. Notes.
# Until this was matched, a National Note's "1." was read as a second note 1 of
# whichever block preceded it and 30 blocks were dropped as duplicate cites.
RE_NATIONAL_NOTE_HDR = re.compile(r"^NATIONAL\s+NOTES?[.:]$", re.IGNORECASE)
RE_NOTE_NUM = re.compile(r"^(\d{1,2})\.$")
# The gazette heads section notes "Section Note." / "Section Notes.", which
# RE_NOTE_HDR cannot match: it allows only an optional CHAPTER prefix. Those
# blocks therefore matched nothing, note_kind stayed empty, and every section
# note in the order was skipped -- notes.section.jsonl came out empty. The
# chapter counts were never inflated, because the text was dropped rather than
# misfiled.
RE_SECTION_NOTE_HDR = re.compile(r"^SECTION\s+NOTES?[.:]$", re.IGNORECASE)
# Section headings matter for attribution, not just for titles: a section note
# is printed between its SECTION heading and that section's first chapter, so
# the chapter in hand still belongs to the PREVIOUS section. Without resetting
# it the note would be filed under the wrong section -- and the existing
# "chapter is None" fallback could never fire, since nothing cleared it.
RE_SECTION_HDR = re.compile(r"^SECTION\s+([IVXL]+)$", re.IGNORECASE)
# "1.   Rule 1:" in the Second Schedule.
RE_GRI_HDR = re.compile(r"^(\d)\.\s+Rule\s+(\d)\s*:?\s*$", re.IGNORECASE)
RE_GRI_SKIP = re.compile(
    r"^(JADUAL\s+KEDUA/SECOND\s+SCHEDULE"
    r"|\[Perenggan\s+\d+/Paragraph\s+\d+\]"
    r"|RUKUN\s+TAFSIRAN.*"
    r"|GENERAL\s+RULES\s+FOR\s+THE\s+INTERPRETATION.*)$", re.IGNORECASE)
# Pages 1461-1463, after the First Schedule's table ends at 1366 and outside the
# Appendix B window, which is why the rules were never read. The Third Schedule
# (abbreviations) begins at 1464 and bounds this one.
PAGE_SECOND_SCHEDULE = (1461, 1463)
# Where the First Schedule's TEXT begins -- one page before PAGE_MAIN, which is
# the first page of the tariff GRID. Page 15 carries "JADUAL PERTAMA/FIRST
# SCHECULE" (the gazette's own typo), SECTION I, Section I's notes and the
# Chapter 1 header; page 16 opens with the "(1) (2) (3)" column row. Guarding
# section detection at PAGE_MAIN would drop Section I's notes by exactly one
# page, which is what hid them. Everything before this is the contents list,
# where the section names recur and must not be read as headings.
PAGE_FIRST_SCHEDULE = 15
RE_SUBPARA = re.compile(r"^\(([A-Za-z0-9]{1,4})\)$")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def norm(text: str) -> str:
    text = unicodedata.normalize("NFKC", text or "")
    text = (text.replace(" ", " ").replace("’", "'")
                .replace("‘", "'").replace("“", '"')
                .replace("”", '"').replace("–", "-")
                .replace("—", "-"))
    return pdf_text.tidy_hyphens(" ".join(text.split()))


def join_text(head: str, tail: str) -> str:
    """Append a wrapped fragment. A line-break hyphen survives or not on the
    gazette's own evidence; see pdf_text.join_wrapped()."""
    return pdf_text.join_wrapped(head, tail, norm)


# ── ezHS portal ──────────────────────────────────────────────────────────────

class TariffTable(HTMLParser):
    """Row/cell reader tolerant of the portal's malformed markup.

    Every description cell closes with `</a>` where `</td>` belongs, so a
    regex over `<td>...</td>` merges the description with the import rate
    beside it and silently shifts every later column left by one. Tracking
    cell starts instead of ends reads all 13,502 rows at exactly 15 cells.
    """

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.rows: list[list[str]] = []
        self.header: list[str] = []
        self._row: list[str] | None = None
        self._cell: list[str] | None = None
        self._is_header = False

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self._row = []
            self._cell = None
            self._is_header = False
        elif tag in ("td", "th"):
            if self._cell is not None and self._row is not None:
                self._row.append(norm("".join(self._cell)))
            self._cell = []
            if tag == "th":
                self._is_header = True

    def handle_endtag(self, tag):
        if tag == "tr" and self._row is not None:
            if self._cell is not None:
                self._row.append(norm("".join(self._cell)))
            row = self._row
            if self._is_header or "HEADER" in row:
                if not self.header:
                    self.header = row
            elif any(c for c in row):
                self.rows.append(row)
            self._row = None
            self._cell = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)


def resolve_portal_url(scheme: str = PORTAL_SCHEME) -> str:
    """Read the current link for one scheme off the portal home page.

    The `tariff` token embeds a date that rotates, so a hard-coded URL stops
    working; the `km` key beside it is per scheme and has stayed fixed.
    """
    request = urllib.request.Request(PORTAL_HOME, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=120) as response:
        page = response.read().decode("utf-8", "replace")
    for href, text in re.findall(
            r'<a[^>]+href="([^"]*public-tariff[^"]*)"[^>]*>(.*?)</a>', page, re.S):
        label = norm(re.sub(r"<[^>]+>", " ", text))
        if label.upper().startswith(scheme.upper()):
            return href if href.startswith("http") else PORTAL_HOME.rstrip("/") + "/" + href.lstrip("/")
    raise SystemExit(f"ERROR: no {scheme!r} link on {PORTAL_HOME}")


def fetch_portal(url: str, dest: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=300) as response:
        dest.write_bytes(response.read())


@dataclass
class Line:
    header: str
    sub: str
    item: str
    unit: str
    description: str
    import_rate: str
    export_rate: str
    trq: str
    sst: str
    excise: str
    cess: tuple
    imppro: str
    ekspro: str
    indent: int = 0
    digits: str = ""
    display: str = ""
    import_rate_basis: str = ""


def _dash_depth(text: str) -> tuple[int, str]:
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
    return depth, rest.strip().rstrip(":").strip()


def _display(digits: str) -> str:
    """Malaysian printed form: 0101 / 0401.1 / 0101.30 / 0101.21.00 00."""
    if len(digits) <= 4:
        return digits
    if len(digits) <= 6:
        return f"{digits[:4]}.{digits[4:]}"
    return f"{digits[:4]}.{digits[4:6]}.{digits[6:8]} {digits[8:]}"


def parse_portal(path: Path) -> tuple[list, Counter]:
    parser = TariffTable()
    parser.feed(path.read_text(encoding="utf-8", errors="replace"))
    if parser.header != EXPECTED_COLUMNS:
        raise SystemExit(
            "ERROR: the portal's columns changed.\n"
            f"  expected {EXPECTED_COLUMNS}\n  got      {parser.header}")
    stats = Counter()
    lines: list[Line] = []
    last_header = ""
    for row in parser.rows:
        if len(row) != 15:
            stats["bad_cell_count"] += 1
            continue
        header, sub, item, unit, desc = row[0], row[1], row[2], row[3], row[4]
        if not header:
            # One condition row in the schedule has no heading of its own;
            # it belongs to the heading above it.
            header = last_header
            stats["header_inherited"] += 1
        last_header = header
        depth, text = _dash_depth(desc)
        digits = f"{header}{sub}{item}"
        line = Line(header=header, sub=sub, item=item, unit=unit,
                    description=text, import_rate=row[5], export_rate=row[6],
                    trq=row[7], sst=row[8], excise=row[9],
                    cess=(row[10], row[11], row[12]),
                    imppro=row[13], ekspro=row[14],
                    indent=depth, digits=digits, display=_display(digits))
        if item:
            stats["coded_row"] += 1
            if not line.import_rate:
                # See THE TRQ GAP in the module docstring. Never emit this as
                # a rate of zero.
                line.import_rate_basis = TRQ_BASIS
                stats["trq_blank_rate"] += 1
            else:
                line.import_rate_basis = "schedule"
        elif sub:
            stats["intermediate_row"] += 1
        else:
            stats["condition_or_heading_row"] += 1
        lines.append(line)
    stats["rows"] = len(lines)
    return lines, stats


# ── the gazette: chapter titles and legal notes ──────────────────────────────
#
# The portal carries neither, so P.U. (A) 384 supplies them. Unlike Singapore's
# STCCED this needs no column geometry: everything read here sits above the
# tariff table, and `pdftotext -layout` keeps the leading indent that separates
# a note number from a nested item.

@dataclass
class NoteBlock:
    kind: str
    section: str | None
    chapter: int | None
    number: str
    page: int
    parts: list = field(default_factory=list)


@dataclass
class GazetteParse:
    chapters: dict = field(default_factory=dict)
    notes: list = field(default_factory=list)
    gri: list = field(default_factory=list)
    stats: Counter = field(default_factory=Counter)
    anomalies: list = field(default_factory=list)


def pdf_lines(pdf: Path) -> list[tuple[int, int, str]]:
    """(page, indent, text) for every non-blank line, furniture dropped."""
    if shutil.which("pdftotext") is None:
        sys.exit("ERROR: pdftotext (poppler-utils) is required")
    out = subprocess.run(["pdftotext", "-layout", str(pdf), "-"],
                         capture_output=True, check=True)
    text = out.stdout.decode("utf-8", "replace")
    lines: list[tuple[int, int, str]] = []
    for page, page_text in enumerate(text.split("\f"), start=1):
        for raw in page_text.splitlines():
            raw = raw.replace(" ", " ").rstrip()
            stripped = norm(raw)
            if not stripped:
                continue
            # Running header and the printed folio.
            if stripped == "P.U. (A) 384" or re.fullmatch(r"\d{1,4}", stripped):
                continue
            indent = len(raw) - len(raw.lstrip(" "))
            lines.append((page, indent, stripped))
    return lines


# Chapter 77 is reserved in the HS and carries no codes; 98 and 99 do not exist
# in the Malaysian order, whose schedule ends at 97.
HS_SECTIONS = ((1, 5, "I"), (6, 14, "II"), (15, 15, "III"), (16, 24, "IV"),
               (25, 27, "V"), (28, 38, "VI"), (39, 40, "VII"), (41, 43, "VIII"),
               (44, 46, "IX"), (47, 49, "X"), (50, 63, "XI"), (64, 67, "XII"),
               (68, 70, "XIII"), (71, 71, "XIV"), (72, 83, "XV"), (84, 85, "XVI"),
               (86, 89, "XVII"), (90, 92, "XVIII"), (93, 93, "XIX"),
               (94, 96, "XX"), (97, 97, "XXI"))


def section_of(chapter: int) -> str:
    for first, last, roman in HS_SECTIONS:
        if first <= chapter <= last:
            return roman
    return ""


def parse_gazette(pdf: Path) -> GazetteParse:
    """Chapter titles plus section, chapter and subheading notes.

    The gazette prints "Chapter Note." / "Chapter Notes." where the WCO text
    says "Notes.", and heads section notes "Section Note." / "Section Notes."
    between a SECTION heading and that section's first chapter. Both headers are
    matched explicitly, and a SECTION heading clears the chapter in hand so the
    note is attributed to the section it introduces rather than to the previous
    section's last chapter.

    The Second Schedule's General Interpretative Rules are collected in the same
    pass, since they sit on pages this loop already walks and a second
    pdftotext run over 1,467 pages would buy nothing.
    """
    out = GazetteParse()
    chapter: int | None = None
    section = ""
    note_kind = ""
    note_col: int | None = None
    current: NoteBlock | None = None
    awaiting_title = False
    title_parts: list[str] = []
    in_table = False

    def close_note() -> None:
        nonlocal current
        if current is not None and current.parts:
            out.notes.append(current)
        current = None

    def flush_title() -> None:
        nonlocal awaiting_title, title_parts
        if awaiting_title and chapter is not None and title_parts:
            out.chapters[chapter] = {
                "title": norm(" ".join(title_parts)).rstrip("."),
                "section": section_of(chapter),
            }
        awaiting_title = False
        title_parts = []

    for page, indent, text in pdf_lines(pdf):
        # The Second Schedule holds the six rules. English only: unlike the rest
        # of the gazette, only its heading is bilingual, so there is no Malay
        # body to separate out here.
        if PAGE_SECOND_SCHEDULE[0] <= page <= PAGE_SECOND_SCHEDULE[1]:
            if RE_GRI_SKIP.match(text):
                continue
            m = RE_GRI_HDR.match(text)
            if m:
                close_note()
                out.gri.append({"number": m.group(2), "page": page, "body": []})
                out.stats["gri_rules"] += 1
                continue
            if out.gri:
                out.gri[-1]["body"].append(text)
            continue
        # The table header row marks the start of the tariff grid; notes and
        # titles only ever appear above it.
        if re.match(r"^\(1\)\s+\(2\)", text) or text.startswith("Kepala/"):
            in_table = True
            flush_title()
            close_note()
            continue
        m = RE_CHAPTER_HDR.match(text)
        if m:
            flush_title()
            close_note()
            chapter = int(m.group(1))
            section = section_of(chapter)
            awaiting_title = True
            in_table = False
            out.stats["chapter_hdr"] += 1
            continue
        # Guarded to the First Schedule: the front matter lists the sections and
        # their notes as contents entries, and resetting state there would
        # attribute real notes to whatever the table of contents last named.
        if page >= PAGE_FIRST_SCHEDULE and RE_SECTION_HDR.match(text):
            flush_title()
            close_note()
            section = RE_SECTION_HDR.match(text).group(1).upper()
            chapter = None
            note_kind = ""
            in_table = False
            out.stats["section_hdr"] += 1
            continue
        if page >= PAGE_FIRST_SCHEDULE and RE_SECTION_NOTE_HDR.match(text):
            flush_title()
            close_note()
            note_kind = "section_note"
            note_col = None
            in_table = False
            out.stats["section_note_hdr"] += 1
            continue
        if RE_SUBHEADING_NOTE_HDR.match(text):
            flush_title()
            close_note()
            note_kind = "subheading_note"
            note_col = None
            in_table = False
            out.stats["subheading_note_hdr"] += 1
            continue
        if RE_NATIONAL_NOTE_HDR.match(text):
            flush_title()
            close_note()
            note_kind = "national_note"
            note_col = None
            in_table = False
            out.stats["national_note_hdr"] += 1
            continue
        if RE_NOTE_HDR.match(text):
            flush_title()
            close_note()
            # "Chapter Note." names itself; a bare "Notes." before any chapter
            # header in this section is a section note.
            note_kind = ("chapter_note" if text.lower().startswith("chapter")
                         or chapter is not None else "section_note")
            if not text.lower().startswith("chapter") and chapter is None:
                note_kind = "section_note"
            note_col = None
            in_table = False
            out.stats["note_hdr"] += 1
            continue
        if awaiting_title:
            # Centred chapter title, possibly several lines; a note header or
            # the table ends it, and both are handled above.
            title_parts.append(text)
            continue
        if in_table or not note_kind:
            continue

        first = text.split(" ")[0]
        m_num = RE_NOTE_NUM.match(first)
        m_sub = RE_SUBPARA.match(first)
        if m_num:
            # A note number is a column position, as in the STCCED: notes nest
            # and the inner levels are numbered too. The first numbered line
            # after a header fixes the column; anything indented further is a
            # nested item, not a new note.
            if note_col is None:
                note_col = indent
            if indent > note_col + 6:
                if current is not None:
                    kind_, label, body = current.parts[-1]
                    current.parts[-1] = (kind_, label, join_text(body, text))
                    out.stats["note_nested_item"] += 1
                    continue
            # Inner levels can also sit AT the note column: Chapter 85 Note
            # 12's MCO definitions ("1. 'Components' may be discrete ... 2.
            # 'Silicon based' means ...") and national note 1 to Chapter 27's
            # definitions each opened a "note 1" that collided with the real
            # one. Note numbers only go up within a block (a skipped number is
            # still a new note), so one that does not is part of the note open.
            if (current is not None and current.number.isdigit()
                    and int(m_num.group(1)) <= int(current.number)):
                kind_, label, body = current.parts[-1]
                current.parts[-1] = (kind_, label, join_text(body, text))
                out.stats["note_number_not_rising"] += 1
                continue
            close_note()
            body = text[len(first):].strip()
            current = NoteBlock(kind=note_kind, section=section,
                                chapter=chapter if note_kind != "section_note" else None,
                                number=m_num.group(1), page=page)
            inner = RE_SUBPARA.match(body.split(" ")[0] if body else "")
            if inner:
                current.parts.append(("sub", inner.group(1),
                                      body[len(inner.group(0)):].strip()))
            else:
                current.parts.append(("para", "", body))
            out.stats["note_number"] += 1
        elif m_sub and current is not None:
            current.parts.append(("sub", m_sub.group(1),
                                  text[len(first):].strip()))
            out.stats["note_subpara"] += 1
        elif current is not None:
            kind_, label, body = current.parts[-1]
            current.parts[-1] = (kind_, label, join_text(body, text))
            out.stats["note_continuation"] += 1
        else:
            current = NoteBlock(kind=note_kind, section=section,
                                chapter=chapter if note_kind != "section_note" else None,
                                number="1", page=page)
            current.parts.append(("para", "", text))
            out.stats["note_unnumbered"] += 1
    flush_title()
    close_note()
    return out


# ── notes corpus ─────────────────────────────────────────────────────────────
#
# Schema-identical to the US and Singapore corpora from build_hts_notes.py and
# parse_sg_stcced.py, so the Explorer sidecar reader and pinecone_sync need no
# Malaysia-specific branch.

RE_H4 = re.compile(r"(?<![\d.])(\d{2})\.(\d{2})(?![\d.])")
RE_S6 = re.compile(r"(?<![\d.])(\d{4})\.(\d{2})(?![\d.])")


def extract_refs(text: str) -> dict:
    headings = {a + b for a, b in RE_H4.findall(text)}
    subheadings = {a + b for a, b in RE_S6.findall(text)}
    chapters = set()
    for m in re.finditer(r"\bChapters?\s+(\d{1,2})(?:\s+(?:to|or|and)\s+(\d{1,2}))?",
                         text, re.IGNORECASE):
        chapters.add(m.group(1).lstrip("0") or "0")
        if m.group(2):
            chapters.add(m.group(2).lstrip("0") or "0")
    sections = set(re.findall(r"\bSections?\s+([IVXLC]+)\b", text))
    return {"refs_headings": sorted(headings),
            "refs_subheadings": sorted(subheadings),
            "refs_chapters": sorted(chapters, key=int),
            "refs_sections": sorted(sections)}


# Note text the PDF's layout scrambles, repaired only on the exact text read.
# Chapter 71 Note 3 (PDF p.777): the label "(p)" is printed level with the
# second line of its paragraph, so it was read into the middle of it ("... an
# age exceeding one (p) hundred years") and paragraph (p) ran on as part of
# (o). Singapore's STCCED and the HS print "(p) Original sculptures ...".
NOTE_TEXT_REPAIRS = {
    "N-71-3": (("; or Original sculptures", "; or (p) Original sculptures"),
               (" exceeding one (p) hundred years", " exceeding one hundred years")),
}


def build_note_records(gazette: GazetteParse, source_sha: str) -> dict:
    records: dict[str, dict] = {}
    for block in gazette.notes:
        body = norm(" ".join(
            (f"({label}) {text}" if kind == "sub" and label else text)
            for kind, label, text in block.parts if norm(text)))
        if not body:
            continue
        if block.kind == "section_note":
            cite = f"SN-{block.section}-{block.number}"
            label = f"Section {block.section}, Note {block.number}"
            scope, chapter = block.section or "", None
        elif block.kind == "subheading_note":
            # Section XI prints its OWN Subheading Notes, between the SECTION
            # heading and chapter 50, so there is no chapter to hang them on.
            # They used to take whatever chapter was last seen -- the previous
            # section's last -- which filed the textile-blend rule that governs
            # chapters 50-63 under a chapter that does not govern it, while the
            # record's own `section` field said XI. Section scope is the honest
            # answer, and it is what makes the note retrievable for every
            # chapter it actually binds.
            if block.chapter is None:
                cite = f"SHN-{block.section}-{block.number}"
                label = (f"Section {block.section}, "
                         f"Subheading Note {block.number}")
                scope, chapter = block.section or "", None
            else:
                cite = f"SHN-{block.chapter}-{block.number}"
                label = f"Chapter {block.chapter}, Subheading Note {block.number}"
                scope, chapter = str(block.chapter), str(block.chapter)
        elif block.kind == "national_note":
            cite = f"NN-{block.chapter}-{block.number}"
            label = f"Chapter {block.chapter}, National Note {block.number}"
            scope, chapter = str(block.chapter), str(block.chapter)
        else:
            cite = f"N-{block.chapter}-{block.number}"
            label = f"Chapter {block.chapter}, Note {block.number}"
            scope, chapter = str(block.chapter), str(block.chapter)
        # A chapter-scoped kind with no chapter would stringify to the literal
        # "None" -- a cite nothing can resolve and a manifest key that is not a
        # number. Record it rather than writing it, so a new shape in a future
        # edition is visible instead of silently malformed.
        if chapter == "None":
            gazette.anomalies.append({
                "cite_id": cite, "pdf_page": block.page, "kind": block.kind,
                "reason": "a chapter-scoped note appeared with no chapter in "
                          "scope; attributed to its section instead",
            })
            gazette.stats["note_without_chapter"] += 1
            cite = f"{cite.split('-')[0]}-{block.section}-{block.number}"
            scope, chapter = block.section or "", None
        for old, new in NOTE_TEXT_REPAIRS.get(cite, ()):
            if body.count(old) != 1:
                raise SystemExit(f"ERROR: {cite}: expected the scrambled text "
                                 f"{old!r} once; the source changed, review "
                                 f"NOTE_TEXT_REPAIRS")
            body = body.replace(old, new)
            gazette.stats["note_text_repaired"] += 1
        if cite in records:
            # Two blocks claim the same number. Both are real text — one is a
            # note continuing across a page break whose header repeats, the
            # other a Chapter 85 subheading note that reads as a chapter note —
            # so the second is kept under a suffixed cite rather than dropped.
            # The US corpus already cites at that granularity (N-39-2(a)), and
            # losing operative text to a key collision would be the worse
            # outcome. Each one is recorded, and validate() holds the count.
            suffix = "b"
            while f"{cite}{suffix}" in records:
                suffix = chr(ord(suffix) + 1)
            gazette.anomalies.append({
                "cite_id": cite, "kept_as": f"{cite}{suffix}",
                "pdf_page": block.page, "kind": block.kind,
                "reason": "a second note block claims this number; kept under a "
                          "suffixed cite so no operative text is lost",
            })
            gazette.stats["duplicate_cite"] += 1
            cite = f"{cite}{suffix}"
        records[cite] = {
            "_id": f"{JURISDICTION}|{REVISION}|{block.kind}|{scope}|{block.number}",
            "chapter": chapter,
            "chunk_text": body,
            "cite_id": cite,
            "content_sha256": sha256_text(body),
            "display_text": f"[{cite}] {label}: {body}",
            "examples": [],
            "jurisdiction": JURISDICTION,
            "kind": block.kind,
            "note_number": block.number,
            "page": block.page,
            "printed_page": None,
            "paragraph": None,
            "revision": REVISION,
            "section": block.section or None,
            "source_sha256": source_sha,
            "source_url": PDF_URL,
            "tables": [],
            **extract_refs(body),
        }
    # The Second Schedule's rules. Same record shape and the same GRI-<n> cite
    # convention the US and Singapore corpora use, so the sidecar reader and
    # pinecone_sync need no per-jurisdiction branch. There is no preamble to
    # keep: the gazette goes straight from the schedule's heading into "Rule 1",
    # where Singapore's book prints an introductory paragraph first.
    for rule in gazette.gri:
        body = norm(" ".join(rule["body"]))
        if not body:
            continue
        number = rule["number"]
        cite = f"GRI-{number}"
        label = f"General Interpretative Rule {number}"
        records[cite] = {
            "_id": f"{JURISDICTION}|{REVISION}|gri|GRI|{number}",
            "chapter": None,
            "chunk_text": body,
            "cite_id": cite,
            "content_sha256": sha256_text(body),
            "display_text": f"[{cite}] {label}: {body}",
            "examples": [],
            "jurisdiction": JURISDICTION,
            "kind": "gri",
            "note_number": number,
            "page": rule["page"],
            "printed_page": None,
            "paragraph": None,
            "revision": REVISION,
            "section": None,
            "source_sha256": source_sha,
            "source_url": PDF_URL,
            "tables": [],
            **extract_refs(body),
        }
    return records



# ── the gazette's tariff table ───────────────────────────────────────────────

PAGE_MAIN = (16, 1366)        # First Schedule, the main tariff table
PAGE_APPENDIX_B = (1371, 1376)   # goods subject to tariff rate quota

# COLUMN BOUNDARIES ARE MEASURED FROM THE DATA, NOT FROM THE COLUMN CAPTIONS.
#
# The "(1) (2) (3)..." marker row gives the centre of each printed caption, and
# the Description caption is centred over a very wide column: its marker sits at
# x=345 while its text starts at x=227. A boundary placed midway between the
# markers therefore lands at x=255 and swallows the leading "- -" of every
# description into the Subheading column, which both corrupts the code and
# flattens every indent to zero. That is what a first pass here did.
#
# The data positions, over all 1,158 main-table pages, are tight enough to fix
# the boundaries outright (p5..p95 in parentheses):
#   heading code   x 69-90          subheading code  x 125-133  (127.7-129.5)
#   statistical 00 x 188-194        description      x >= 227.7
#   unit           x 511-519        import rate      x ~590     export x ~690
# Appendix B is laid out differently and gets its own set: unit at x 441-444,
# in-quota rate at x ~500, out-quota at x ~578, agency at x 634-698. Its column
# (5) holds both quota rates under one caption, split at the caption's own x.
#
# This gazette also prints the marker row ABOVE the column names, the opposite
# of Singapore's STCCED, so the body cannot be found by cutting at the marker
# row: the names sit between it and the first data row. The cut is made below
# the lowest line that is nothing but header vocabulary.
# The fourth header line, "quantity  import duty  export duty", needs the bare
# "import" and "duty": with only "import/" and "duti" here it was never consumed
# as header, sat in the body of every page, and was discarded as orphan text --
# most of the 542 the old gate pinned. Once rows correctly carry across page
# breaks it attached to the previous page's last row instead ("0%" became
# "0% import duty"), which is how it surfaced.
HEADER_WORDS = frozenset("""
kepala/ heading subkepala/ subheading perihalan/ description unit kuantiti/
quantity of kadar duti import/ eksport/ rate export tarif kuota/ tariff quota
agensi yang menetapkan kuota agency determined the in-quota out-quota dalam
luar import duty
""".split())

# (col1, col2, col3, col4, col5) upper bounds; col6 takes the rest.
EDGES_MAIN = (110.0, 215.0, 480.0, 555.0, 650.0)
EDGES_APPENDIX_B = (110.0, 215.0, 430.0, 470.0, 616.0)
APPENDIX_B_QUOTA_SPLIT = 545.0

RE_MARKER_N = re.compile(r"^\((\d)\)$")
RE_GZ_HEADING = re.compile(r"^(\d{2})\.(\d{2})$")
RE_GZ_SUB = re.compile(r"^(\d{4})\.(\d{2})(?:\.(\d{2}))?$")


@dataclass(frozen=True)
class Word:
    x: float
    y: float
    text: str
    x1: float = 0.0
    y1: float = 0.0


def load_bbox_pages(pdf: Path, workdir: Path) -> list:
    if shutil.which("pdftotext") is None:
        sys.exit("ERROR: pdftotext (poppler-utils) is required")
    xml = workdir / f"{pdf.stem}_bbox.xml"
    if not xml.is_file():
        workdir.mkdir(parents=True, exist_ok=True)
        subprocess.run(["pdftotext", "-bbox-layout", str(pdf), str(xml)], check=True)
    from xml.etree import ElementTree as ET
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
    # learn the gazette's vocabulary for line-break hyphens. Both in pdf_text.
    pages = [[Word(x0, y0, t, x1, y1) for x0, y0, x1, y1, t in pdf_text.merge_scripts(ws)]
             for ws in raw]
    pdf_text.set_vocabulary(pdf_text.Vocabulary(w.text for ws in pages for w in ws))
    return pages


def page_grid(words: list, expect: int = 6):
    """The body cut y for one page, or None if the page carries no table.

    Only the vertical cut is computed here; the horizontal boundaries are the
    measured constants above. The marker row is still located, because its
    presence is what says this page has a table at all.
    """
    # The marker row is searched over the WHOLE page, not just its top. On a
    # chapter-opening page the chapter heading, its title and its notes come
    # first and the table's header follows them: on page 21 the markers sit at
    # y=335. Restricting the search to the top of the page skipped 193 pages of
    # the main table outright, which cost 220 heading rows and left their
    # subheadings parented to whatever heading preceded them — "0202.10.00 00"
    # under "01.06". Searching the full page is safe because the test is strict:
    # six or more markers sharing a baseline whose labels read (1),(2),(3)...
    # consecutively from one. A page with no such row genuinely has no table —
    # the rest of the 193 are chapter openings that are all notes.
    rows: dict = defaultdict(list)
    for w in words:
        if RE_MARKER_N.match(w.text or ""):
            rows[round(w.y, 1)].append(w)
    best = None
    for y in sorted(rows):
        group = sorted(rows[y], key=lambda w: w.x)
        labels = [(w.text or "").strip("()") for w in group]
        if len(group) >= expect and labels == [str(i + 1) for i in range(len(labels))]:
            best = (y, group)
            break
    if best is None:
        return None
    marker_y, _markers = best

    # The header block: every line below the marker row made only of header
    # vocabulary. The body starts under the lowest such line.
    lines: dict = defaultdict(list)
    for w in words:
        if w.y > marker_y:
            lines[round(w.y, 1)].append(w)
    cut = marker_y
    for y in sorted(lines):
        tokens = [norm(w.text).lower().rstrip(":") for w in lines[y]]
        if tokens and all(t in HEADER_WORDS for t in tokens):
            cut = y
        elif y > cut + 30.0:
            break
    return cut + 3.0


def page_rows(words: list, edges: tuple, cut: float) -> list:
    """Visual lines below `cut`, each binned into the section's columns."""
    bottom = max((w.y for w in words), default=0.0)
    buckets: dict = defaultdict(list)
    for w in words:
        if w.y > cut:
            buckets[round(w.y, 1)].append(w)
    ys = sorted(buckets)
    clusters: list = []
    for y in ys:
        if clusters and y - clusters[-1][-1] <= 2.0:
            clusters[-1].append(y)
        else:
            clusters.append([y])

    def column_of(x: float) -> int:
        for i, upper in enumerate(edges):
            if x < upper:
                return i
        return len(edges)

    out = []
    for cluster in clusters:
        ws = sorted((w for y in cluster for w in buckets[y]), key=lambda w: w.x)
        if not ws:
            continue
        cols: dict = defaultdict(list)
        for w in ws:
            cols[column_of(w.x)].append(w)
        joined = {i: norm(" ".join(w.text for w in v)) for i, v in cols.items()}
        text = norm(" ".join(w.text for w in ws))
        # The printed folio: a number alone on the page's LOWEST line. Any lone
        # number was dropped before, which cut the last line of wrapped
        # descriptions that end in one -- 2009.12.00 00 "... a Brix value not
        # exceeding" lost its "20", 8501.33.10 00 "... vehicles in Chapter"
        # its "87".
        if re.fullmatch(r"\d{1,4}", text) and len(cols) == 1 and min(cluster) >= bottom - 1.0:
            continue
        if text == "P.U. (A) 384":
            continue
        out.append((min(cluster), joined, cols))
    return out


@dataclass
class GzLine:
    page: int
    heading: str
    code: str
    digits: str
    description: str
    indent: int
    unit: str = ""
    import_rate: str = ""
    export_rate: str = ""
    import_rate_basis: str = ""

    def add(self, cols: dict) -> None:
        """Fold a continuation line in, per column."""
        self.description = join_text(self.description, cols.get(2, ""))
        if cols.get(3):
            self.unit = norm(self.unit + " " + cols[3])
        if cols.get(4):
            self.import_rate = join_text(self.import_rate, cols[4])
        if cols.get(5):
            self.export_rate = join_text(self.export_rate, cols[5])


# The Subheading cell, as printed: "0101.21.00 00", or "0101.30" at the HS
# single-dash level. Anchored, because stray text does reach this column — a
# stranded "20)." and a "Chapter97." were both read as codes 20 and 97 before
# this was required to match.
RE_GZ_CELL = re.compile(r"^(\d{4})\.(\d{2})(?:\.(\d{2}))?(?:\s*(\d{2}))?$")


def _gz_code(col1: str) -> tuple[str, str]:
    raw = norm(col1)
    if not raw:
        return "", ""
    m = RE_GZ_CELL.match(raw)
    if not m:
        return "", ""
    digits = "".join(g for g in m.groups() if g)
    return raw.replace(" ", ""), digits


# Every fragment the table walk discards, as (pdf_page, text). Counting them
# hid data loss: the gate pinned 542 discards as "expected" while 100 of them
# were the wrapped ends of real descriptions. validate() now checks WHAT was
# discarded, not just how much.
GZ_ORPHANS: list = []
RE_HEADER_LINE = re.compile(r"quantity import duty export duty", re.IGNORECASE)


def parse_gazette_table(pages: list, lo: int, hi: int) -> tuple[list, Counter, list]:
    """The First Schedule's main table: structure, descriptions, duty rates."""
    stats = Counter()
    GZ_ORPHANS.clear()
    lines: list[GzLine] = []
    current: GzLine | None = None
    heading = ""
    in_subchapter_title = False
    last_chapter: int | None = None

    def close() -> None:
        nonlocal current
        if current is not None:
            lines.append(current)
        current = None

    for pno in range(lo, min(hi, len(pages)) + 1):
        words = pages[pno - 1]
        chapter_opened_here = False
        cut = page_grid(words, expect=6)
        if cut is None:
            # A page of notes or a schedule boundary: nothing on it continues
            # the last tariff line.
            close()
            in_subchapter_title = False
            stats["page_without_table"] += 1
            continue
        stats["page_with_table"] += 1
        for _y, cols, _raw in page_rows(words, EDGES_MAIN, cut):
            c0, c1, c2 = cols.get(0, ""), cols.get(1, ""), cols.get(2, "")
            whole = norm(" ".join(cols[k] for k in sorted(cols) if cols[k]))
            if not whole:
                continue
            # Structural headers sit in the description column; the notes and
            # chapter titles are read separately, from the text layer.
            #
            # A CHAPTER HEADER IS "Chapter N" OPENING THE NEXT CHAPTER, NOT ANY
            # LINE THAT BEGINS WITH THE WORD. The earlier test, any line starting
            # "Chapter" or "Bab", fired on 40 lines of which 11 were headers. The
            # other 29 were wrapped descriptions -- "Chapter:", "Chapter, other
            # than edible fats and oils or", even "Chapter 87:" and a bare
            # "Chapter 94" inside 44.xx -- and each closed its row and was
            # discarded, cutting the description short. Chapter 77 is reserved
            # in the HS, so after 76 the next header is 77 (if the book prints the
            # reserved chapter, as Singapore's does) or 78.
            m_chapter = (re.fullmatch(r"(?:CHAPTER|Chapter|Bab)\s+(\d{1,2})", whole)
                         if not c0 and not c1 else None)
            if m_chapter and last_chapter is not None:
                allowed = {last_chapter + 1} | ({78} if last_chapter == 76 else set())
                if int(m_chapter.group(1)) not in allowed:
                    m_chapter = None
                    stats["chapter_word_in_text"] += 1
            if m_chapter or RE_NOTE_HDR.match(whole) or RE_SUBHEADING_NOTE_HDR.match(whole):
                close()
                chapter_opened_here = chapter_opened_here or bool(m_chapter)
                stats["structural_line"] += 1
                continue
            # SUB-CHAPTER HEADINGS (chapters 28, 29, 69). "SUB-CHAPTER II" and
            # its capitalised title sit between tariff lines; read as
            # continuation they were glued onto the line above ("Mercury
            # SUB-CHAPTER II INORGANIC ACIDS ..."). They describe no tariff line.
            if not c0 and not c1 and pdf_text.RE_SUBCHAPTER.match(whole):
                close()
                in_subchapter_title = True
                stats["subchapter_hdr"] += 1
                continue
            if in_subchapter_title and not c0 and not c1 \
                    and pdf_text.is_caps_title(whole):
                stats["subchapter_title_line"] += 1
                continue
            in_subchapter_title = False
            head_m = RE_GZ_HEADING.match(c0) if c0 else None
            code, digits = _gz_code(c1)
            if head_m:
                heading = c0
            if head_m or digits:
                close()
                last_chapter = int((digits or head_m.group(1))[:2])
                depth, text = _dash_depth(c2)
                if head_m and not digits:
                    depth = 0
                    digits = head_m.group(1) + head_m.group(2)
                    code = c0
                elif head_m and digits:
                    # A heading whose only line is itself.
                    depth = 0
                    stats["heading_with_single_line"] += 1
                current = GzLine(page=pno, heading=heading or (code[:5] if code else ""),
                                 code=code, digits=digits, description=text,
                                 indent=depth, unit=cols.get(3, ""),
                                 import_rate=cols.get(4, ""),
                                 export_rate=cols.get(5, ""))
                stats["coded_row"] += 1
                continue
            if c2:
                depth, text = _dash_depth(c2)
                if depth > 0 and not re.match(r"^-\s*$", c2):
                    # An uncoded dash row: a condition row, which build_tree()
                    # needs in order to place the codes nested beneath it.
                    close()
                    current = GzLine(page=pno, heading=heading, code="", digits="",
                                     description=text, indent=depth,
                                     unit=cols.get(3, ""),
                                     import_rate=cols.get(4, ""),
                                     export_rate=cols.get(5, ""))
                    stats["condition_row"] += 1
                    continue
            if current is not None:
                current.add(cols)
                stats["continuation"] += 1
            else:
                # What may legitimately be discarded: the header line that some
                # pages repeat below the column markers, and -- on a page where a
                # chapter opens mid-page -- that chapter's title and notes, which
                # parse_gazette() reads from the text layer. Anything else is
                # text that belongs to a tariff line, and validate() fails on it.
                if RE_HEADER_LINE.fullmatch(whole):
                    why = "page_header"
                elif chapter_opened_here:
                    why = "chapter_title_or_note"
                else:
                    why = "unexplained"
                stats["orphan_text"] += 1
                stats[f"orphan_{why}"] += 1
                GZ_ORPHANS.append((pno, why, whole))
        # A ROW DOES CONTINUE ACROSS A PAGE BREAK. Every page restarts with its
        # own header block, and the previous version took that to mean every row
        # ended with its page. 103 rows wrap onto the next page, and closing here
        # orphaned the wrapped text: 0305.31.00 00 stopped at "Catla catla,"
        # while page 52 carried "Labeo spp., Osteochilus hasselti, ...". The row
        # stays open; the next page's first coded or dash line closes it, as on
        # any other line. Pages with no table (above) still close it.
    close()
    for ln in lines:
        if not ln.digits:
            continue
        if len(ln.digits) == 8:
            # AN EIGHT-DIGIT CODE IS A REAL INTERNAL NODE, NOT A TRUNCATION.
            #
            # On printed page 287 the gazette sets
            #     2903.43.00      - - Fluoromethane (HFC-41), ...
            #     2903.43.00 10   - - - Fluoromethane (HFC-41)
            #     2903.43.00 20   - - - 1,1-difluoroethane (HFC-152a)
            # so "2903.43.00" is the parent of three ten-digit lines. Padding it
            # to 2903430000, as a first pass did, invents a code that the
            # schedule does not contain and makes it a sibling of its own
            # children. These are left at eight digits; the portal agrees,
            # printing a two-digit ITEM for exactly these lines.
            stats["eight_digit_node"] += 1
        if len(ln.digits) != 10:
            continue
        rate = ln.import_rate
        if re.search(r"TRQ", rate, re.IGNORECASE):
            # The gazette states the quota by reference: "TRQ as specified in
            # Appendix B". Keeping that text as the rate would be read as a
            # rate; the real figures come from parse_appendix_b().
            ln.import_rate_basis = TRQ_BASIS
            ln.import_rate = ""
            stats["trq_referenced"] += 1
        elif rate:
            ln.import_rate_basis = "schedule"
        else:
            ln.import_rate_basis = "unresolved"
            stats["import_rate_missing"] += 1
    # WHERE THE PRINTED DASH AND THE CODE DISAGREE, RECORD IT — DO NOT RESHAPE.
    #
    # The dash depth is typographic and the gazette sets it wrong in a handful
    # of places. On printed page 149, 1515.60.00 00 is set at "- -" inside
    # 1515.50's one-dash group, though 151550 is not a prefix of 151560. On page
    # 421, 3827.63.90 30 is printed with no dash prefix at all while all five of
    # its siblings carry "- - - -", so it reads as a root.
    #
    # An earlier pass here rewrote those indents from the code prefixes. That is
    # wrong twice over. The ancestor count cannot reproduce the printed depth in
    # general, because an uncoded condition row ("- Other:") occupies a level
    # and has no code to count — deriving 0103.91.00 00's depth from prefixes
    # makes it a sibling of the condition that governs it and discards the edge
    # condition. And mutating an indent mid-walk cascades: correcting one line
    # moved 3827.63 to the root and manufactured five new conflicts below it.
    #
    # So the printed depth stands, every conflict is recorded in the manifest
    # with its page, and validate() asserts the count. These are facts about the
    # source, and a reader can see exactly which lines they are.
    anomalies: list = []
    present = {ln.digits for ln in lines if ln.digits}
    stack: list = []
    seen_before: list = []
    for ln in lines:
        # The orphan test comes BEFORE the pop: an indent-0 row empties the
        # stack, so testing afterwards could never see the ancestor that proves
        # the indent wrong.
        if ln.digits and len(ln.digits) >= 8 and ln.indent == 0:
            # A LINE PRINTED WITH NO DASH PREFIX AT ALL.
            #
            # On printed page 421, "3827.63.90 30" is set with no dashes while
            # all five of its siblings carry "- - - -", and 3803.00.00 00 the
            # same way. At indent 0 such a line becomes a ROOT, and every row
            # after it nests underneath — which made two reportable lines into
            # internal nodes and tripped build_hts_corpus's official-leaf check.
            #
            # This is the one indent that is corrected, and the rule is narrow
            # on purpose: a code of eight digits or more, printed at depth zero,
            # that nonetheless has one of its own code prefixes present above
            # it. Depth then comes from the ancestor count, which cannot
            # cascade because nothing else is touched. The broader "trust the
            # code over the dash" rule was tried and rejected: correcting a
            # 6-digit code moved 3827.63 to the root and manufactured five new
            # conflicts below it.
            # Its siblings are the lines that share its parent — same length,
            # same code but the last pair — and they are printed correctly, so
            # their indent is the answer. Counting prefixes instead gave 2
            # where the siblings sit at 4, because not every intermediate level
            # is printed as its own row.
            sibling = next(
                (prev.indent for prev in reversed(seen_before)
                 if prev.digits and len(prev.digits) == len(ln.digits)
                 and prev.digits[:-2] == ln.digits[:-2] and prev.indent > 0),
                None)
            prefixes = [k for k in range(4, len(ln.digits))
                        if ln.digits[:k] in present]
            depth = sibling if sibling is not None else len(prefixes)
            if depth:
                anomalies.append({
                    "code": ln.code, "pdf_page": ln.page,
                    "printed_indent": 0, "corrected_indent": depth,
                    "from": "sibling" if sibling is not None else "code prefixes",
                    "reason": "printed with no dash prefix, unlike every "
                              "sibling, so it read as a root",
                })
                ln.indent = depth
        seen_before.append(ln)
        while stack and stack[-1].indent >= ln.indent:
            stack.pop()
        if ln.digits and len(ln.digits) > 4:
            ancestors = [a for a in stack if a.digits]
            if ancestors and not ln.digits.startswith(ancestors[-1].digits):
                anomalies.append({
                    "code": ln.code,
                    "pdf_page": ln.page,
                    "printed_indent": ln.indent,
                    "reads_under": ancestors[-1].code,
                    "prefix_depth": sum(1 for k in range(4, len(ln.digits))
                                        if ln.digits[:k] in present),
                    "reason": "the printed dash depth makes this a child of a "
                              "code that is not its prefix",
                })
    stats["indent_conflict"] = len(anomalies)
    stats["lines"] = len(lines)
    return lines, stats, anomalies


def fill_missing_headings(gz: list, portal: list) -> tuple[list, list]:
    """Insert the heading rows the gazette leaves out, taken from the portal.

    The gazette omits 39 heading rows outright. Printed page 402 runs

        38.03   3803.00.00 00   Tall oil, whether or not refined.
                3804.00.10 00   - Concentrated sulphite lye

    with nothing at all for heading 38.04 and no text for "Residual lyes from
    the manufacture of wood pulp...". Left alone, 3804.00.10 00 has no ancestor
    at depth zero, so build_tree() walks up and adopts 3803.00.00 00 — making a
    reportable line an internal node and putting tall oil above sulphite lye in
    the breadcrumb of every 3804 code.

    The portal carries each of those headings, as a six-digit row with its
    description. They are inserted at depth zero immediately before the first
    line beneath them, and each insertion is recorded: this is the one place
    where a row in the output is not printed in the legal instrument.
    """
    by_heading: dict = {}
    for line in portal:
        if line.sub and not line.item and line.description:
            by_heading.setdefault(f"{line.header}{line.sub}", line)
        if not line.sub and not line.item and line.description:
            by_heading.setdefault(line.header, line)

    printed = {ln.digits for ln in gz if len(ln.digits) == 4}
    # A code of six digits or more sitting at depth zero already stands in for
    # its heading: the gazette merges the two, printing
    #     0508.00   Coral and similar materials, unworked or simply prepared
    # with no separate "05.08" row, and that row IS the heading. Requiring
    # eight digits here synthesised a duplicate 0508 beside it and left
    # 0508.00 a childless leaf. Heading 38.04 is the genuinely missing kind:
    # its first line is 3804.00.10 00 at depth one, with no ancestor at all.
    rooted = {ln.digits[:4] for ln in gz if ln.indent == 0 and len(ln.digits) >= 6}
    # Anchored to the heading's first child of ANY depth. Keying on eight-digit
    # children alone put the synthesised 38.27 after the 3827.11 that belongs
    # under it: the gazette splits heading 38.27 across a page break, its text
    # absorbed into the foot of printed page 418 and 3827.11 printed above the
    # six-digit level on 419.
    needed, first_at = [], {}
    for i, ln in enumerate(gz):
        if len(ln.digits) >= 6:
            head = ln.digits[:4]
            if head not in printed and head not in rooted and head not in first_at:
                first_at[head] = i
                needed.append(head)

    inserted: list = []
    out: list = []
    pending = {v: k for k, v in first_at.items()}
    current_heading = ""
    for i, ln in enumerate(gz):
        head = pending.get(i)
        if head:
            src = by_heading.get(f"{head}00") or by_heading.get(head)
            desc = src.description if src else ""
            dotted = f"{head[:2]}.{head[2:]}"
            record = {
                "code": _display(head), "pdf_page": ln.page,
                "description_from": "ezHS portal" if desc else None,
                "reason": "the gazette prints no heading row for this heading, "
                          "so its subheadings had no ancestor at depth zero",
            }
            # The heading goes above its whole group, not just above its first
            # coded line. Under 38.27 the gazette prints a one-dash grouping row
            # ("- Containing chlorofluorocarbons (CFCs), ...; containing carbon
            # tetrachloride; containing 1,1,1-trichloroethane ...:") before
            # 3827.11; inserting the heading after it left that group under 38.26.
            moved: list = []
            while out and not out[-1].digits and out[-1].indent > 0:
                moved.insert(0, out.pop())
            # Heading 38.27's TEXT is printed, at the foot of page 418, but with
            # no code beside it, so the table walk read it as the wrapped end of
            # the line above: 3826.00.90 00 became "Other Mixtures containing
            # halogenated derivatives of methane, ...". Where the line above ends
            # in exactly the heading's text, that text is the heading's, not the
            # line's, and is moved back.
            if desc and out:
                trimmed = _strip_trailing_text(out[-1].description, desc)
                if trimmed is not None:
                    record["text_removed_from"] = out[-1].code
                    out[-1].description = trimmed
            out.append(GzLine(page=ln.page, heading=dotted, code=_display(head),
                              digits=head, description=desc, indent=0,
                              import_rate_basis="not_printed"))
            for group in moved:
                group.heading = dotted
            out.extend(moved)
            record["grouping_rows_moved_under"] = len(moved)
            inserted.append(record)
            current_heading = dotted
        elif ln.digits and len(ln.digits) == 4:
            current_heading = ""
        # The lines beneath a synthesised heading name it, not the printed
        # heading before it (3804.00.10 00 read "38.03").
        if current_heading and ln.digits[:4] == current_heading.replace(".", ""):
            ln.heading = current_heading
        out.append(ln)
    return out, inserted


def _strip_trailing_text(text: str, tail: str) -> str | None:
    """`text` without a trailing `tail`, compared on letters and digits only;
    None when `text` does not end with it or consists of nothing else."""
    key = lambda t: re.sub(r"[^a-z0-9]", "", t.lower())
    want = key(tail)
    words = text.split()
    for k in range(len(words) - 1, 0, -1):
        if key(" ".join(words[k:])) == want:
            return " ".join(words[:k])
    return None


def parse_appendix_b(pages: list) -> tuple[dict, Counter]:
    """Appendix B: goods subject to tariff rate quota.

    Column (5) holds two sub-columns under one marker — in-quota and out-quota
    duty rate — so it is split at the marker's own x, which sits between them.
    Column (6) names the agency that sets the quota. This is what the portal
    leaves blank; see THE TRQ GAP.
    """
    stats = Counter()
    out: dict = {}
    current_code = ""
    for pno in range(PAGE_APPENDIX_B[0], min(PAGE_APPENDIX_B[1], len(pages)) + 1):
        words = pages[pno - 1]
        cut = page_grid(words, expect=6)
        if cut is None:
            stats["page_without_table"] += 1
            continue
        split = APPENDIX_B_QUOTA_SPLIT
        stats["page_with_table"] += 1
        for _y, cols, raw in page_rows(words, EDGES_APPENDIX_B, cut):
            code, digits = _gz_code(cols.get(1, ""))
            agency = cols.get(5, "")
            in_q = out_q = ""
            if split is not None and 4 in raw:
                lo_words = [w.text for w in raw[4] if w.x < split]
                hi_words = [w.text for w in raw[4] if w.x >= split]
                in_q, out_q = norm(" ".join(lo_words)), norm(" ".join(hi_words))
            if len(digits) == 10:
                current_code = digits
                out[digits] = {"in_quota": in_q, "out_quota": out_q,
                               "agency": agency, "pdf_page": pno}
                stats["trq_line"] += 1
            elif current_code and agency and not digits:
                # The agency name wraps onto the next line.
                prev = out[current_code]
                prev["agency"] = norm(prev["agency"] + " " + agency)
                stats["agency_continuation"] += 1
    return out, stats
# ── emit ─────────────────────────────────────────────────────────────────────

CSV_FIELDS = ("GOODS_CODE", "DISPLAY", "HEADING", "DESCRIPTION", "INDENT",
              "UNIT", "IMPORT_RATE", "IMPORT_RATE_BASIS", "EXPORT_RATE",
              "TRQ_IN_QUOTA", "TRQ_OUT_QUOTA", "TRQ_AGENCY", "SST", "EXCISE",
              "CESS_1", "CESS_2", "CESS_3", "IS_LEAF", "SECTION", "CHAPTER",
              "PDF_PAGE")


def write_csv(gz_lines: list, portal_by_code: dict, trq: dict, path: Path) -> int:
    """The gazette's rows, in document order, joined to the other two sources.

    Order and hierarchy come from the gazette alone. The portal supplies only
    the four columns the gazette does not print (SST, excise, cess), keyed by
    code, and Appendix B supplies the quota rates. Nothing structural is taken
    from the portal — see WHY THE PORTAL CANNOT CARRY THE STRUCTURE.
    """
    coded = {ln.digits for ln in gz_lines if len(ln.digits) == 10}
    leaves = {d for d in coded if not any(o != d and o.startswith(d) for o in coded)}
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=CSV_FIELDS)
        writer.writeheader()
        for ln in gz_lines:
            pt = portal_by_code.get(ln.digits)
            quota = trq.get(ln.digits, {})
            chapter = ln.digits[:2] if len(ln.digits) >= 2 else ""
            writer.writerow({
                "GOODS_CODE": ln.digits,
                # Regenerated from the digits so the column always shows the
                # gazette's own form ("0101.21.00 00"), not the compacted text
                # the cell happened to contain.
                "DISPLAY": _display(ln.digits) if ln.digits else "",
                "HEADING": ln.heading,
                "DESCRIPTION": ln.description,
                "INDENT": ln.indent,
                "UNIT": ln.unit,
                "IMPORT_RATE": ln.import_rate,
                "IMPORT_RATE_BASIS": ln.import_rate_basis,
                "EXPORT_RATE": ln.export_rate,
                "TRQ_IN_QUOTA": quota.get("in_quota", ""),
                "TRQ_OUT_QUOTA": quota.get("out_quota", ""),
                "TRQ_AGENCY": quota.get("agency", ""),
                "SST": pt.sst if pt else "",
                "EXCISE": pt.excise if pt else "",
                "CESS_1": pt.cess[0] if pt else "",
                "CESS_2": pt.cess[1] if pt else "",
                "CESS_3": pt.cess[2] if pt else "",
                "IS_LEAF": "1" if len(ln.digits) == 10 and ln.digits in leaves else "",
                "SECTION": section_of(int(chapter)) if chapter.isdigit() else "",
                "CHAPTER": chapter,
                "PDF_PAGE": ln.page,
            })
    return len(gz_lines)


def write_chapters(gazette: GazetteParse, path: Path) -> None:
    out = []
    for number in sorted(gazette.chapters):
        info = gazette.chapters[number]
        out.append({"chapter": f"{number:02d}",
                    "description": info["title"],
                    "section": info["section"],
                    "sectionTitle": SECTION_TITLES.get(info["section"], "")})
    path.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")


SECTION_TITLES = {}


def load_section_titles() -> None:
    """Section titles come from the shared hs_sections.json, which the other
    jurisdictions already use, rather than being transcribed again."""
    path = Path(__file__).resolve().parent / "hs_sections.json"
    for entry in json.loads(path.read_text(encoding="utf-8")):
        SECTION_TITLES[entry["section"]] = entry["sectionTitle"]


def write_notes(records: dict, out_dir: Path, gazette: GazetteParse,
                pdf: Path, pdf_sha: str, html_sha: str) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"my_{REVISION}"
    # The US record shape (notes_contract): section chapters, cross-references
    # and a record per lettered paragraph, before anything is written or
    # counted, so the sidecar, the JSONL and the manifest all agree.
    records = notes_contract.finalize(records, refs=extract_refs)
    sidecar = out_dir / f"{stem}.notes.json"
    sidecar.write_text(json.dumps(records, ensure_ascii=False, indent=2,
                                  sort_keys=True) + "\n", encoding="utf-8")
    families = {"gri": ("gri",),
                "section": ("section_note",),
                "chapter": ("chapter_note", "subheading_note", "national_note")}
    artifact_sha = {sidecar.name: sha256_file(sidecar)}
    for family, kinds in families.items():
        rows = [records[c] for c in sorted(records) if records[c]["kind"] in kinds]
        fp = out_dir / f"{stem}.notes.{family}.jsonl"
        with fp.open("w", encoding="utf-8") as fh:
            for rec in rows:
                # The US record as the notes index holds it: its fields only,
                # no nulls (Pinecone rejects an explicit null). The sidecar
                # keeps the full shape.
                fh.write(json.dumps(notes_contract.pinecone_record(rec),
                                    ensure_ascii=False, sort_keys=True) + "\n")
        artifact_sha[fp.name] = sha256_file(fp)
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
        "in_force": IN_FORCE,
        "jurisdiction": JURISDICTION,
        "parsed_chapters": sorted(gazette.chapters),
        "parsed_gri": any(r["kind"] == "gri" for r in records.values()),
        "portal_sha256": {"ezhs_pdk2025.html": html_sha},
        "pdf_sha256": {pdf.name: pdf_sha},
        "revision": REVISION,
        "schema_version": 1,
        "source_anomalies": gazette.anomalies,
        "source_urls": {pdf.name: PDF_URL, "portal": PORTAL_HOME},
    }
    (out_dir / f"{stem}.notes.manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8")
    return manifest




# ── validation ───────────────────────────────────────────────────────────────

# Every figure measured against both sources before the parser was written, so a
# mismatch means a source changed rather than that a number was guessed.
EXPECTED = {
    "portal_rows": 13502,
    "portal_coded": 11452,
    "portal_bad_cells": 0,
    "gazette_lines": 16765,
    "gazette_ten_digit": 11441,
    # Discarded table text: the 71 lines of chapter title and notes on the 11
    # pages where a chapter opens mid-page, which parse_gazette() reads from the
    # text layer (classified in parse_gazette_table). This was 542 until
    # 2026-11-11: most were a header line the header vocabulary missed, and 100
    # were the wrapped ends of real descriptions, cut at page breaks and at lines
    # beginning "Chapter". The unexplained count is the real gate.
    "gazette_orphan_text": 71,
    "gazette_orphan_unexplained": 0,
    "eight_digit_node": 11,
    "trq_referenced": 27,
    "trq_appendix_entries": 27,
    "chapter_hdr": 107,
    # Lines whose printed dash depth contradicts their code parentage. Each is
    # listed in the notes manifest's source_anomalies with its page.
    "indent_conflict": 1,
    "heading_synthesised": 2,
    # No two note blocks share a number. The two that once did were nested
    # items printed at the note column (Chapter 85 Note 12's MCO definitions,
    # Chapter 27 national note 1's); they are folded back into their note,
    # and a duplicate now means a new layout problem.
    "duplicate_cite": 0,
    "note_number_not_rising": 2,
    # NOTE_TEXT_REPAIRS: Chapter 71 Note 3's displaced "(p)", two replacements.
    "note_text_repaired": 2,
    # All 21 HS sections are headed in the First Schedule; 9 of them carry
    # section notes, and the Second Schedule holds the 6 interpretative rules.
    "section_hdr": 21,
    "section_note_hdr": 9,
    "gri_rules": 6,
    # A chapter-scoped note found with no chapter in scope. Section XI's
    # subheading notes are handled as section-scoped and do not count here.
    "note_without_chapter": 0,
}

# Matching a number cannot catch a family that produces NOTHING. EXPECTED had no
# entry for section notes or the interpretative rules, so emitting zero of both
# read as a clean pass -- the omission surfaced only when Singapore's 45 section
# notes and 7 rules were set beside Malaysia's none. Presence has to be asserted
# separately from agreement, or a gate pinned at zero would hide it again.
REQUIRED_NOTE_KINDS = ("chapter_note", "subheading_note", "national_note",
                       "section_note", "gri")


def validate(gz: list, gz_stats: Counter, portal: list, portal_stats: Counter,
             trq: dict, gazette: GazetteParse, notes: dict) -> list[str]:
    errors: list[str] = []
    ten = [ln for ln in gz if len(ln.digits) == 10]
    got = {
        "portal_rows": portal_stats["rows"],
        "portal_coded": portal_stats["coded_row"],
        "portal_bad_cells": portal_stats["bad_cell_count"],
        "gazette_lines": gz_stats["lines"],
        "gazette_ten_digit": len(ten),
        "gazette_orphan_text": gz_stats["orphan_text"],
        "gazette_orphan_unexplained": gz_stats["orphan_unexplained"],
        "eight_digit_node": gz_stats["eight_digit_node"],
        "trq_referenced": gz_stats["trq_referenced"],
        "trq_appendix_entries": len(trq),
        "chapter_hdr": gazette.stats["chapter_hdr"],
        "indent_conflict": gz_stats["indent_conflict"],
        "heading_synthesised": gz_stats["heading_synthesised"],
        "duplicate_cite": gazette.stats["duplicate_cite"],
        "note_number_not_rising": gazette.stats["note_number_not_rising"],
        "note_text_repaired": gazette.stats["note_text_repaired"],
        "section_hdr": gazette.stats["section_hdr"],
        "section_note_hdr": gazette.stats["section_note_hdr"],
        "gri_rules": gazette.stats["gri_rules"],
        "note_without_chapter": gazette.stats["note_without_chapter"],
    }
    for key, want in EXPECTED.items():
        if got[key] != want:
            errors.append(f"{key}: got {got[key]}, expected {want}")

    note_kinds = Counter(r["kind"] for r in notes.values())
    for kind in REQUIRED_NOTE_KINDS:
        if not note_kinds.get(kind):
            errors.append(f"note family {kind!r} is empty - the gazette carries "
                          f"it, so nothing should reduce it to zero")

    seen: dict = {}
    for ln in ten:
        if ln.digits in seen:
            errors.append(f"duplicate code {ln.code} (pdf pages "
                          f"{seen[ln.digits].page} and {ln.page})")
        seen[ln.digits] = ln

    # The dash-depth check itself runs in parse_gazette_table(), which records
    # every conflict with its page; EXPECTED["indent_conflict"] above is what
    # holds that number fixed. This is the gate that caught the portal being
    # sorted rather than ordered, at 6,852 violations.

    # Every quota line the main table refers to must be in Appendix B, and
    # every Appendix B line must exist in the main table. Both directions,
    # because either gap would be silent.
    referenced = {ln.digits for ln in gz if ln.import_rate_basis == TRQ_BASIS}
    if referenced - set(trq):
        errors.append(f"{len(referenced - set(trq))} line(s) cite Appendix B but "
                      f"are absent from it: {sorted(referenced - set(trq))[:5]}")
    if set(trq) - {ln.digits for ln in ten}:
        errors.append(f"{len(set(trq) - {ln.digits for ln in ten})} Appendix B "
                      f"line(s) are not in the main table")
    for digits, quota in trq.items():
        if not quota["in_quota"] or not quota["out_quota"]:
            errors.append(f"Appendix B {digits}: a quota rate is missing "
                          f"({quota['in_quota']!r} / {quota['out_quota']!r})")

    # Every gazette code must be one the portal also names, which is what makes
    # the join safe; one code each way is a known source divergence.
    portal_codes = {_portal_digits(l) for l in portal if l.item}
    unknown = [ln.digits for ln in gz
               if len(ln.digits) >= 8 and ln.digits not in portal_codes]
    if len(unknown) > 1:
        errors.append(f"{len(unknown)} gazette code(s) absent from the portal: "
                      f"{sorted(unknown)[:6]}")
    if not notes:
        errors.append("no legal notes were parsed from the gazette")
    return errors


def _portal_digits(line) -> str:
    """The portal's code. Eleven rows print a two-digit ITEM where the other
    11,441 print four: those are the eight-digit internal nodes described in
    parse_gazette_table(), not truncated ten-digit lines, so they are left as
    they are and both sources then name the same code."""
    return f"{line.header}{line.sub}{line.item}"


def reconcile(gz: list, gz_stats: Counter, portal: list, portal_stats: Counter,
              trq: dict, gazette: GazetteParse, notes: dict) -> list[str]:
    out = []
    ten = [ln for ln in gz if len(ln.digits) == 10]
    digits = {ln.digits for ln in ten}
    leaves = {d for d in digits if not any(o != d and o.startswith(d) for o in digits)}
    out.append(f"gazette: {gz_stats['lines']} lines over "
               f"{gz_stats['page_with_table']} pages -> {len(ten)} ten-digit "
               f"({len(leaves)} leaves), {gz_stats['condition_row']} condition rows")
    out.append(f"  indents: {dict(sorted(Counter(l.indent for l in gz).items()))}")
    for label, attr in (("unit", "unit"), ("import rate", "import_rate"),
                        ("export rate", "export_rate")):
        n = sum(1 for ln in ten if getattr(ln, attr))
        out.append(f"  {label:12s} on {n} of {len(ten)} ten-digit lines")
    basis = Counter(ln.import_rate_basis for ln in ten)
    out.append(f"  import_rate_basis: {dict(sorted(basis.items()))}")

    portal_codes = {_portal_digits(l): l for l in portal if l.item}
    # Both sides include the eight-digit internal nodes, or those 11 codes read
    # as a divergence when the two sources in fact agree about them.
    gz_codes = {ln.digits for ln in gz if len(ln.digits) >= 8}
    out.append(f"portal: {portal_stats['rows']} rows -> {len(portal_codes)} coded")
    out.append(f"  gazette-only codes: {len(gz_codes - set(portal_codes))} "
               f"{sorted(gz_codes - set(portal_codes))[:4]}")
    out.append(f"  portal-only codes : {len(set(portal_codes) - gz_codes)} "
               f"{sorted(set(portal_codes) - gz_codes)[:4]}")
    joined = len(gz_codes & set(portal_codes))
    out.append(f"  joined on code    : {joined} "
               f"({100.0 * joined / max(1, len(gz_codes)):.1f}% of gazette codes)")
    for label, attr in (("SST", "sst"), ("excise", "excise")):
        n = sum(1 for d in digits & set(portal_codes) if getattr(portal_codes[d], attr))
        out.append(f"    {label:8s} joined onto {n} lines")
    n_cess = sum(1 for d in digits & set(portal_codes) if any(portal_codes[d].cess))
    out.append(f"    cess     joined onto {n_cess} lines")
    out.append(f"Appendix B: {len(trq)} quota lines, agencies "
               f"{dict(Counter(v['agency'] for v in trq.values()))}")
    by_kind = Counter(r["kind"] for r in notes.values())
    out.append(f"notes: {len(notes)} records {dict(sorted(by_kind.items()))}, "
               f"{len(gazette.chapters)} chapter titles")
    if gazette.anomalies:
        out.append(f"  source anomalies recorded: {len(gazette.anomalies)}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    base = REPO_ROOT / "data" / "my_tariff_source"
    ap.add_argument("--html", type=Path, default=base / ".my_download" / "ezhs_pdk2025.html")
    ap.add_argument("--pdf", type=Path, default=base / ".my_download" / "PUA_384.pdf")
    ap.add_argument("--fetch", action="store_true",
                    help="re-download the portal page, resolving its current token")
    ap.add_argument("--out-dir", type=Path, default=base)
    ap.add_argument("--notes-dir", type=Path,
                    default=REPO_ROOT / "data" / "hts_notes" / f"my_{REVISION}")
    ap.add_argument("--chapters-out", type=Path,
                    default=Path(__file__).resolve().parent / "chapters_my.json")
    ap.add_argument("--workdir", type=Path, default=None,
                    help="where the bbox XML is cached (default: --out-dir)")
    ap.add_argument("--no-validate", action="store_true")
    args = ap.parse_args()

    load_section_titles()
    if args.fetch:
        url = resolve_portal_url()
        print(f"Resolved portal URL:\n  {url}")
        args.html.parent.mkdir(parents=True, exist_ok=True)
        fetch_portal(url, args.html)
    for path, label in ((args.html, "portal HTML"), (args.pdf, "gazette PDF")):
        if not path.is_file():
            print(f"ERROR: missing {label}: {path}", file=sys.stderr)
            return 2

    html_sha, pdf_sha = sha256_file(args.html), sha256_file(args.pdf)
    print(f"Portal  {args.html.name} ({args.html.stat().st_size:,} bytes)\n  sha256 {html_sha}")
    print(f"Gazette {args.pdf.name} ({args.pdf.stat().st_size:,} bytes)\n  sha256 {pdf_sha}")

    workdir = args.workdir or args.out_dir
    pages = load_bbox_pages(args.pdf, workdir)
    print(f"  {len(pages)} PDF pages; main table {PAGE_MAIN[0]}..{PAGE_MAIN[1]}, "
          f"Appendix B {PAGE_APPENDIX_B[0]}..{PAGE_APPENDIX_B[1]}")

    portal, portal_stats = parse_portal(args.html)
    gz, gz_stats, gz_anomalies = parse_gazette_table(pages, *PAGE_MAIN)
    gz, synthesised = fill_missing_headings(gz, portal)
    gz_stats["heading_synthesised"] = len(synthesised)
    gz_stats["lines"] = len(gz)
    gz_anomalies.extend(synthesised)
    trq, trq_stats = parse_appendix_b(pages)
    gazette = parse_gazette(args.pdf)
    gazette.anomalies.extend(gz_anomalies)
    records = build_note_records(gazette, pdf_sha)
    portal_by_code = {_portal_digits(l): l for l in portal if l.item}

    print("\n--- reconciliation ---")
    for line in reconcile(gz, gz_stats, portal, portal_stats, trq, gazette, records):
        print("  " + line)
    print("\n--- counts ---")
    merged = {f"gz_{k}": v for k, v in gz_stats.items()}
    merged.update({f"portal_{k}": v for k, v in portal_stats.items()})
    merged.update({f"notes_{k}": v for k, v in gazette.stats.items()})
    merged.update({f"appb_{k}": v for k, v in trq_stats.items()})
    for key, value in sorted(merged.items()):
        print(f"  {key:30s} {value}")

    errors = validate(gz, gz_stats, portal, portal_stats, trq, gazette, records)
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
    csv_path = args.out_dir / f"my_tariff_{REVISION}.csv"
    n = write_csv(gz, portal_by_code, trq, csv_path)
    # The manual acquisition adapter reads the effective date from this
    # sidecar, exactly as it does for the Dominican Republic's transcription.
    csv_path.with_name(csv_path.name + ".meta.json").write_text(json.dumps({
        "effective_date": IN_FORCE,
        # A date, as every schedule's label is meant to be (it prints as "effective
        # <label>" and beside the History revision pill); the edition is
        # edition_label.
        "effective_date_label": "{d:%B} {d.day}, {d.year}".format(
            d=__import__("datetime").date.fromisoformat(IN_FORCE)),
        "edition_label": EDITION_LABEL,
        "source": PDF_URL,
        "source_sha256": pdf_sha,
        "portal_sha256": html_sha,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_chapters(gazette, args.chapters_out)
    manifest = write_notes(records, args.notes_dir, gazette, args.pdf, pdf_sha, html_sha)
    print(f"\nWrote {n:,} rows -> {csv_path}")
    print(f"Wrote {manifest['counts']['total']:,} note records -> {args.notes_dir}")
    for kind, count in manifest["counts"]["by_kind"].items():
        print(f"    {kind:18s} {count}")
    print(f"Wrote {args.chapters_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

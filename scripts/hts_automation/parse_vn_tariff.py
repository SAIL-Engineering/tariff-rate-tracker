#!/usr/bin/env python3
"""Parse Vietnam's Import-Export Tariff workbook into the corpus row contract.

Unlike Singapore and Malaysia, whose hierarchy had to be recovered from the dash
depth printed in a PDF, this source states its structure outright. On the BT2026
sheet column 1 of a coded row IS the indent depth (0-6) and column 2 is a row
TYPE code, so sections, chapters, sub-chapters, note headers and each note
paragraph level are labelled rather than inferred. That makes this the most
reliable of the three ASEAN sources, and the gates below are correspondingly
about completeness rather than geometry.

Three things the source does NOT give, each handled explicitly:

  * No General Interpretative Rules. A search for the General Rules finds
    nothing: Vietnam enacts them in the Decree, not in this compilation. The
    note families are therefore section and chapter only, and REQUIRED_NOTE_KINDS
    asserts exactly those - copying Malaysia's five would fail on a family the
    source genuinely lacks.
  * English stops at Chapter 98. All 666 coded rows without an English
    description are in chapter 98 (rows 19054-19901, Vietnam's national special
    provisions). Chapters 1-97 - the substantive schedule - are 100% bilingual,
    so the English corpus needs no external source.
  * Four malformed codes. '9849170\xa0' x3 and '9849190\xa0' carry seven digits
    and a trailing non-breaking space, with no English: each is the code with
    its seventh digit dropped (9849.17.20 -> '9849170'). The issuing instrument
    prints them in full -- Decree 26/2023/NĐ-CP Annex II, printed pp. 846-847:
    9849.17.10, 9849.17.20, 9849.17.90 and 9849.19.10 -- so CODE_REPAIRS
    restores them, but only when the cell and its corresponding code are
    exactly what was checked against that page. Each repair is recorded in
    the notes manifest's source_anomalies.
  * One wrong effective date. The workbook gives Decree 144/2024/NĐ-CP's
    signing date (01/11/2024) as the effective date of its 63 lines; the
    Decree's Art. 2(1) makes it effective 16/12/2024. DATE_REPAIRS corrects it.

Two rate columns are easy to confuse and must not be: `NK TT` (col 10) is the
ORDINARY rate, which applies absent MFN or FTA eligibility, while `NK uu dai`
(col 13) is the PREFERENTIAL rate - the MFN duty. The ordinary rate is the higher
of the two by construction. Each rate column is followed by its enacting Decree
(`Van ban`) and effective date (`Ngay hieu luc`), so a rate can be cited.

Usage:
  python3 scripts/hts_automation/parse_vn_tariff.py
  python3 scripts/hts_automation/parse_vn_tariff.py --no-validate
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import notes_contract  # noqa: E402  (the US notes record shape)

try:
    import openpyxl
except ImportError:  # pragma: no cover
    sys.exit("ERROR: openpyxl is required (pip install openpyxl)")

REPO_ROOT = Path(__file__).resolve().parents[2]
JURISDICTION = "VN"
# The standard {year}_rev_{number} id every jurisdiction uses. Dated editions
# take MMDD of the effective date as the number (CH 901, KR 101, TW 729): the
# workbook as at 5 April 2026 is 2026_rev_405.
REVISION = "2026_rev_405"
EFFECTIVE_DATE = "2026-04-05"
EDITION_LABEL = "Import-Export Tariff workbook as at 5 April 2026"
SHEET = "BT2026"
SOURCE_URL = ("https://docs.google.com/spreadsheets/d/"
              "1Tv3kzX5M-HOA0GoFjaGydTrHWD8piDh5/export?format=xlsx")

# ── Column map (0-indexed), from the header row ──────────────────────
C_INDENT, C_TYPE = 1, 2
C_CODE, C_DESC_VI, C_DESC_EN = 5, 6, 7
C_UNIT_VI, C_UNIT_EN = 8, 9
C_ORDINARY, C_ORDINARY_DOC, C_ORDINARY_DATE = 10, 11, 12
C_MFN, C_MFN_DOC, C_MFN_DATE = 13, 14, 15
C_VAT = 16
HEADER_ROW = 2          # 0-indexed; row 3 in the sheet
FIRST_DATA_ROW = 5

# Row TYPE codes. 18..24 are coded tariff rows at indent 0..6; the rest are
# structure and notes.
T_SECTION, T_SECTION_TITLE = "1", "2"
T_CHAPTER, T_CHAPTER_TITLE = "3", "4"
T_SUBCHAPTER, T_SUBCHAPTER_TITLE = "5", "6"
# Types 7 and 8 are BOTH "a notes header" and neither names its own scope. Type
# 7 is labelled `Chú giải phần` ("section note") but appears 75 times UNDER a
# chapter against 7 times without, so the label is a misnomer and keying off it
# misfiles chapter notes as section notes. What actually discriminates is the
# context plus the column-1 marker: `Chú giải PN` (PN = phân nhóm = subheading,
# printed in English as "Subheading Notes") is a subheading note, and otherwise a
# header under an open chapter is a chapter note while one before the section's
# first chapter is a section note.
T_NOTES_HDRS = {"7", "8"}
MARKER_SUBHEADING_NOTE = "Chú giải PN"
T_NOTE_PARA = {"9", "10", "11", "12"}     # "1.", "(a)", "(1)", "(iii)"
# Type 14 ("BT", body text) is a note's unlabelled paragraph: the definition
# under "(a) Bars and rods" in Section XV Note 9, the closing paragraph of
# Chapter 9 Note 1. 160 rows; dropping them cut whole definitions out of the
# notes. Types 15 ("XEM BẢNG 1", a pointer to a table in another sheet), 16
# (Vietnamese "(*)" remarks) and 17 ("(SEN)" pointers to the AHTN Supplementary
# Explanatory Notes) are not note text and stay out.
T_NOTE_BODY = "14"
T_CODE_BASE = 18
T_CODE = {str(T_CODE_BASE + d): d for d in range(7)}

RE_SECTION_NO = re.compile(r"^SECTION\s+([IVXL]+)", re.IGNORECASE)
RE_CHAPTER_NO = re.compile(r"^Chapter\s+(\d{1,2})", re.IGNORECASE)
RE_NOTE_NUM = re.compile(r"^(\d{1,2})\.")
RE_DASHES = re.compile(r"^((?:-\s*)+)")


def dash_depth(text: str) -> int:
    """Chapter 98's rows carry NO type marker, so their indent cannot be read
    from column 1 like every other coded row. They do carry the printed dash
    prefix the PDF jurisdictions use ("- - Tôm hùm Na Uy"), so the depth is
    counted from that instead. Vietnam's chapter 98 is its special-preference
    chapter -- real alternative tariff lines for specified goods, not a
    statistical annex -- so dropping it would omit lines importers actually
    declare."""
    m = RE_DASHES.match(text)
    return len(re.findall(r"-", m.group(1))) if m else 0

EXPECTED = {
    "coded_rows": 15119,
    "four_digit": 1081,
    "six_digit": 2034,
    "eight_digit": 12004,
    # The four seven-digit Chapter 98 cells, restored by CODE_REPAIRS; none
    # is left malformed.
    "code_repaired": 4,
    "malformed_code": 0,
    # Decree 144/2024/NĐ-CP's lines, re-dated by DATE_REPAIRS.
    "effective_date_repaired": 63,
    "rows_with_unit": 11428,
    "section_hdr": 21,
    "chapter_hdr": 97,
    # English stops at chapter 98 and nowhere else; the second gate is the one
    # that matters, because a drop anywhere in chapters 1-97 would be a parse
    # failure rather than a property of the source.
    "no_english": 666,
    "no_english_outside_ch98": 0,
    # Chapter 98's rows carry no type marker, so their indent comes from the
    # dash prefix instead of column 1.
    "row_without_type_marker": 666,
    # The AHTN schedule: the tree built from the source's own indents against the
    # source's own unit-of-quantity column. These must be EQUAL, and the gate
    # below asserts that rather than just pinning both numbers.
    "core_leaves": 11414,
    "core_rows_with_unit": 11414,
    # Chapter 98 is Vietnam's special-preference chapter: each line gives an
    # alternative rate for goods otherwise classified under a specific Chapter
    # 1-97 code, and the sheet lists one row per corresponding code. So the code
    # repeats by design, and these count the pairing rather than pretending the
    # overloaded column is a unit.
    "ch98_corresponding_pair": 573,
    "ch98_distinct_codes": 535,
    "ch98_rows": 666,
    # Chapter 98's English, composed from the Chapter 1-97 rows each line points
    # at: 451 of the 535 English-less CODED rows resolve. The 268 left without a
    # description are the ones that should not have one -- 84 chapter 98 group
    # headers plus the 184 uncoded grouping rows in that chapter, which carry
    # structure rather than goods.
    "desc_en_composed_from_corresponding": 451,
    "desc_en_absent": 268,
    # UNCODED GROUPING ROWS. Every one of these qualifies the lines nested under
    # it ("- Horses:", "- Loại khác:") and so has to reach build_tree() as a
    # condition row. 2,273 carry a coded TYPE marker with an empty code cell
    # (2,345 such rows exist; 72 of them are note bullets, below); the other 182
    # are in chapter 98, which marks nothing and is read from the dash prefix. Dropping them is not neutral: without them the row BELOW a
    # group header adopts the coded row above it, which mis-parented 2,734 lines
    # and made 504 unit-bearing codes internal nodes.
    "condition_rows": 2455,
    # Bullet lines inside note blocks that the sheet marks with a coded type
    # code; uncoded and dash-prefixed, so indistinguishable from a group header
    # except by the open note block. See parse_workbook().
    "note_bullet_as_code_row": 72,
    # ...and every one of them goes back into the note it sits in.
    "note_bullet_recovered": 72,
    # Note text the parser used to drop: unlabelled body paragraphs (type 14),
    # one of the 160 sits outside any note.
    "note_body_rows": 159,
    # Section XVI Note 6, typed 11; and the nine nested "1."/"2." items typed
    # as note starts in Chapter 48 Note 5 and Chapter 85's notes.
    "note_start_mistyped": 1,
    "note_number_nested": 9,
    # One record per note, cross-checked against Singapore, Malaysia and the US
    # by tests/python/test_notes_publish_asean.py.
    "note_records": 479,
    # Two chapter-98 rows REPEAT a code that already appeared at a shallower
    # dash depth, as the header of a nested group: 9808 (row 19086) and 9849.43
    # (row 19889, "- - Loại khác (trừ loại thuộc phân nhóm 8506.10 ...)"). They
    # are group headers, not a second tariff line, so collapse_ch98() turns them
    # into condition rows -- the same treatment the Dominican Arancel needs for
    # its three repeated 6-digit codes. Hence 2,455 + 2 in the emitted CSV.
    "condition_rows_collapsed": 2457,
    # No grouping row may qualify nothing. "- - Loại khác:" at sheet row 19500
    # did while the 9849.17 codes beneath it were malformed; with them repaired
    # it governs 9849.17.20 and 9849.17.90 again. A stranded row means a depth
    # read wrong.
    "stranded_grouping_rows": 0,
}
# The source carries section and chapter notes and NO interpretative rules, so
# only these two families may be asserted. A count that merely matches cannot
# catch a family that produces nothing (the Malaysian order shipped for months
# with none), and a gate pinned at zero would enshrine the absence.
REQUIRED_NOTE_KINDS = ("section_note", "chapter_note", "subheading_note")


# Source defects repaired against the issuing instrument. A repair fires only
# on the exact cell that was checked; anything else is left to the gates, which
# then fail, because a changed workbook needs re-checking, not re-guessing.
DECREE_26_2023_CH98 = (
    "Decree 26/2023/NĐ-CP Annex II (Phụ lục II), Chapter 98 list, printed "
    "pp. 846-847 (PDF pp. 406-407 of "
    "https://datafiles.chinhphu.vn/cpp/files/vbpq/2023/6/26-nd-2.pdf)")
# sheet row -> (raw code cell, corresponding Chapter 1-97 code, repaired code)
CODE_REPAIRS = {
    19499: ("9849170\xa0", "70091000", "98491710"),   # rear-view mirrors for vehicles
    19501: ("9849170\xa0", "70099100", "98491720"),   # other mirrors, unframed
    19502: ("9849170\xa0", "70099200", "98491790"),   # other mirrors, framed
    19512: ("9849190\xa0", "83012000", "98491910"),   # locks for motor vehicles
}
# MFN Decree -> (effective date as printed, corrected date, authority)
DATE_REPAIRS = {
    "144/2024/NĐ-CP": (
        "01/11/2024", "16/12/2024",
        "Decree 144/2024/NĐ-CP Art. 2(1): 'Nghị định này có hiệu lực từ ngày "
        "16 tháng 12 năm 2024'; 01/11/2024 is its signing date "
        "(https://datafiles.chinhphu.vn/cpp/files/vbpq/2024/11/144-cp.signed.pdf)"),
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def norm(value) -> str:
    """Collapse whitespace, including the non-breaking spaces this sheet uses."""
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value).replace("\xa0", " ")).strip()


def digits_of(value) -> str:
    return re.sub(r"\D", "", norm(value))


def display_of(d: str) -> str:
    """0101 -> 01.01; 010130 -> 0101.30; 01012100 -> 0101.21.00."""
    if len(d) == 4:
        return f"{d[:2]}.{d[2:]}"
    if len(d) == 6:
        return f"{d[:4]}.{d[4:]}"
    if len(d) == 8:
        return f"{d[:4]}.{d[4:6]}.{d[6:]}"
    return d


HS_SECTIONS = ((1, 5, "I"), (6, 14, "II"), (15, 15, "III"), (16, 24, "IV"),
               (25, 27, "V"), (28, 38, "VI"), (39, 40, "VII"), (41, 43, "VIII"),
               (44, 46, "IX"), (47, 49, "X"), (50, 63, "XI"), (64, 67, "XII"),
               (68, 70, "XIII"), (71, 71, "XIV"), (72, 83, "XV"), (84, 85, "XVI"),
               (86, 89, "XVII"), (90, 92, "XVIII"), (93, 93, "XIX"),
               (94, 96, "XX"), (97, 97, "XXI"))


def section_of(chapter: int) -> str:
    for lo, hi, roman in HS_SECTIONS:
        if lo <= chapter <= hi:
            return roman
    return ""


@dataclass
class Row:
    code: str
    display: str
    indent: int
    desc_en: str
    desc_vi: str
    unit: str
    corresponding: str
    mfn: str
    ordinary: str
    vat: str
    mfn_doc: str
    mfn_date: str
    section: str
    chapter: int | None
    sheet_row: int


def condition_row(indent: int, en: str, vi: str, section: str,
                  chapter: int | None, sheet_row: int) -> "Row":
    """An uncoded grouping row, in the shape build_tree() reads as a condition.

    Everything a coded row carries is absent by definition -- no code, no
    display, no unit, no rate -- so only the depth and the text are real."""
    return Row(code="", display="", indent=indent, desc_en=en, desc_vi=vi,
               unit="", corresponding="", mfn="", ordinary="", vat="",
               mfn_doc="", mfn_date="",
               section=section_of(chapter) if chapter else section,
               chapter=chapter, sheet_row=sheet_row)


@dataclass
class NoteBlock:
    kind: str
    section: str | None
    chapter: int | None
    number: str
    sheet_row: int
    parts_en: list = field(default_factory=list)
    parts_vi: list = field(default_factory=list)


@dataclass
class Parse:
    rows: list = field(default_factory=list)
    notes: list = field(default_factory=list)
    chapters: dict = field(default_factory=dict)
    sections: dict = field(default_factory=dict)
    # The workbook prints every section and chapter title in both languages;
    # the Vietnamese ones feed chapters_vn.vi.json for the Tariff Schedule toggle.
    sections_vi: dict = field(default_factory=dict)
    stats: Counter = field(default_factory=Counter)
    anomalies: list = field(default_factory=list)


def parse_workbook(path: Path) -> Parse:
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    if SHEET not in wb.sheetnames:
        sys.exit(f"ERROR: sheet {SHEET!r} not in {path.name}")
    out = Parse()
    section = ""
    chapter: int | None = None
    note_kind = ""
    current: NoteBlock | None = None
    # Chapter 98 carries NO type marker on any of its rows (see dash_depth), so
    # the only signal that we are inside it is a code beginning 98. It is the
    # last chapter in the sheet, so this latches once and never has to unlatch;
    # the else-branch is there so a reordered edition cannot silently inherit it.
    in_ch98 = False

    def close_note() -> None:
        nonlocal current
        if current is not None and (current.parts_en or current.parts_vi):
            out.notes.append(current)
        current = None

    for i, raw in enumerate(wb[SHEET].iter_rows(values_only=True), start=1):
        if i <= FIRST_DATA_ROW:
            continue
        rtype = norm(raw[C_TYPE])
        en, vi = norm(raw[C_DESC_EN]), norm(raw[C_DESC_VI])

        if rtype == T_SECTION:
            close_note()
            m = RE_SECTION_NO.match(en) or RE_SECTION_NO.match(vi.replace("PHẦN", "SECTION"))
            if m:
                section = m.group(1).upper()
            # A section note is printed between this header and the section's
            # first chapter, so the chapter in hand belongs to the section just
            # ended and must not carry over.
            chapter = None
            note_kind = ""
            out.stats["section_hdr"] += 1
            continue
        if rtype == T_CHAPTER:
            close_note()
            m = RE_CHAPTER_NO.match(en) or re.match(r"^Chương\s+(\d{1,2})", vi)
            if m:
                chapter = int(m.group(1))
                section = section or section_of(chapter)
                out.chapters.setdefault(chapter, {"section": section_of(chapter) or section})
            note_kind = ""
            out.stats["chapter_hdr"] += 1
            continue
        if rtype == T_CHAPTER_TITLE:
            if chapter is not None:
                out.chapters.setdefault(chapter, {"section": section_of(chapter) or section})
                out.chapters[chapter]["title"] = en or vi
                out.chapters[chapter]["title_vi"] = vi or en
            continue
        if rtype == T_SECTION_TITLE:
            # The section's own title, printed on the row after its header. The
            # chapters file carries it per chapter (sectionTitle), the same shape
            # chapters_sg.json and chapters_my.json use.
            if section:
                out.sections.setdefault(section, en or vi)
                out.sections_vi.setdefault(section, vi or en)
            continue
        if rtype in (T_SUBCHAPTER, T_SUBCHAPTER_TITLE):
            continue
        if rtype in T_NOTES_HDRS:
            close_note()
            marker = norm(raw[C_INDENT])
            if marker == MARKER_SUBHEADING_NOTE:
                note_kind = "subheading_note"
            elif chapter is not None:
                note_kind = "chapter_note"
            else:
                note_kind = "section_note"
            out.stats[f"{note_kind}_hdr"] += 1
            continue
        if rtype in T_NOTE_PARA or rtype == T_NOTE_BODY:
            if not note_kind:
                continue
            m = RE_NOTE_NUM.match(en) or RE_NOTE_NUM.match(vi)
            # A note starts at a type-9 row -- or at a row that opens with the
            # NEXT note's number whatever its type: Section XVI Note 6 ("6. (A)
            # Throughout the Nomenclature ...", sheet row 12733) is typed 11
            # and was read as part of Note 5. Inside an HS note nested items
            # are lettered or bracketed, never "6.".
            #
            # The reverse also happens: Chapter 48 Note 5's nested items "1.
            # weighing not more than 80 g/m2" are typed 9, and each opened a new
            # "Note 1" that collided with the real N-48-1. Note numbers only go
            # up within a block, so a typed-9 row whose number does not is part
            # of the note already open; a row of another type starts a note only
            # when it carries exactly the next number.
            starts = False
            if m:
                n = int(m.group(1))
                rising = (current is None or not current.number.isdigit()
                          or n > int(current.number))
                next_one = (current is not None and current.number.isdigit()
                            and n == int(current.number) + 1)
                if (rtype == "9" and rising) or (rtype != "9" and next_one):
                    starts = True
                    if rtype != "9":
                        out.stats["note_start_mistyped"] += 1
                elif rtype == "9":
                    out.stats["note_number_nested"] += 1
            if starts:
                close_note()
                current = NoteBlock(kind=note_kind, section=section,
                                    chapter=None if note_kind == "section_note" else chapter,
                                    number=m.group(1), sheet_row=i)
            if current is None:
                continue
            if en:
                current.parts_en.append(en)
            if vi:
                current.parts_vi.append(vi)
            out.stats[f"note_para_{rtype}"] += 1
            continue

        has_code = bool(digits_of(raw[C_CODE]))
        if has_code:
            in_ch98 = digits_of(raw[C_CODE])[:2] == "98"
        # An uncoded grouping row inside chapter 98 has neither a code nor a type
        # marker; the dash prefix is all it has, so require one. That excludes
        # the chapter's three unmarked prelude lines ("Chương 98", its title and
        # the "3. Danh mục ..." lead-in), which carry no dashes.
        is_ch98_group = in_ch98 and not rtype and not has_code and dash_depth(vi) >= 1
        if rtype in T_CODE or (has_code and not rtype) or is_ch98_group:
            if not digits_of(raw[C_CODE]) and (current is not None or note_kind):
                # NOT a grouping row. 72 bullet lines INSIDE note blocks carry a
                # coded type marker instead of a note-paragraph one -- chapter
                # 28's note 1 ("- individual nuclides, excluding, however ...")
                # and chapter 61's subheading note 3(a) defining a suit ("- one
                # suit coat or jacket the outer shell of which ..."). They are
                # uncoded and dash-prefixed, so they look exactly like a group
                # header; what tells them apart is that a note block is still
                # open, and a real group header can never be the first thing
                # after a chapter's notes (its heading row has to come first).
                # They stay out of the tree, and go into the open note's body,
                # where they belong.
                out.stats["note_bullet_as_code_row"] += 1
                if current is not None:
                    if en:
                        current.parts_en.append(en)
                    if vi:
                        current.parts_vi.append(vi)
                    out.stats["note_bullet_recovered"] += 1
                continue
            close_note()
            note_kind = ""
            d = digits_of(raw[C_CODE])
            indent = (T_CODE[rtype] if rtype in T_CODE
                      else dash_depth(vi or en))
            if not d:
                # CONDITION ROW. It has no code of its own and it is not a
                # classification target, but it OCCUPIES its indent level and
                # its text is what distinguishes the lines beneath it, so it has
                # to survive into the CSV exactly as the SG and MY parsers emit
                # theirs. build_tree() consumes a row with an empty code as a
                # condition row and nothing else.
                out.rows.append(condition_row(indent, en, vi, section,
                                              98 if in_ch98 else chapter, i))
                out.stats["condition_rows"] += 1
                continue
            if rtype not in T_CODE:
                out.stats["row_without_type_marker"] += 1
            raw_unit = norm(raw[C_UNIT_EN]) or norm(raw[C_UNIT_VI])
            fix = CODE_REPAIRS.get(i)
            if fix and raw[C_CODE] == fix[0] and raw_unit == fix[1]:
                out.anomalies.append({
                    "sheet_row": i, "raw_code": repr(raw[C_CODE]), "digits": d,
                    "reason": "seven digits and a trailing non-breaking space: "
                              "the code with its seventh digit missing",
                    "repaired_to": fix[2], "corresponding_code": fix[1],
                    "authority": DECREE_26_2023_CH98,
                })
                d = fix[2]
                out.stats["code_repaired"] += 1
            if len(d) not in (4, 6, 8):
                out.anomalies.append({
                    "sheet_row": i, "raw_code": repr(raw[C_CODE]), "digits": d,
                    "reason": "code is not 4, 6 or 8 digits; excluded from the tree",
                })
                out.stats["malformed_code"] += 1
                continue
            # The unit column is OVERLOADED by chapter. In chapters 1-97 it is
            # the unit of quantity ("kg/unit"). In chapter 98 -- Vietnam's
            # special-preference chapter -- it instead carries the corresponding
            # Chapter 1-97 code the preferential line maps to: 9844.10.90 lists
            # 8701.91.90, 8701.92.90, 8701.93.90, 8701.94.90 and 8701.95.90, one
            # row each, which is why the code repeats. Reading those as units
            # would record an HS code as a unit of quantity and break the
            # leaf cross-check, which is how this was found.
            is_ch98 = d[:2] == "98"
            corresponding = ""
            unit = raw_unit
            if is_ch98 and re.fullmatch(r"\d{6,10}", raw_unit or ""):
                corresponding, unit = raw_unit, ""
                out.stats["ch98_corresponding_pair"] += 1
            mfn_doc, mfn_date = norm(raw[C_MFN_DOC]), norm(raw[C_MFN_DATE])
            redate = DATE_REPAIRS.get(mfn_doc)
            if redate and mfn_date == redate[0]:
                mfn_date = redate[1]
                out.stats["effective_date_repaired"] += 1
            out.rows.append(Row(
                code=d, display=display_of(d), indent=indent,
                desc_en=en, desc_vi=vi, unit=unit, corresponding=corresponding,
                mfn=norm(raw[C_MFN]), ordinary=norm(raw[C_ORDINARY]),
                vat=norm(raw[C_VAT]), mfn_doc=mfn_doc,
                mfn_date=mfn_date,
                # Chapter 98 sits outside the HS section scheme, so it takes no
                # section rather than inheriting XXI from the chapter that
                # happened to precede it.
                section=section_of(int(d[:2])),
                chapter=int(d[:2]), sheet_row=i))
            out.stats["coded_rows"] += 1
            out.stats[f"digits_{len(d)}"] += 1
            if unit:
                out.stats["rows_with_unit"] += 1
            if not en:
                out.stats["no_english"] += 1
                if d[:2] != "98":
                    out.stats["no_english_outside_ch98"] += 1
            continue
    close_note()
    return out


def tree_leaves(rows: list) -> set:
    """Codes no other code extends. The source's own unit-of-quantity column is
    the independent witness: validate() requires the two to agree exactly, which
    is the same cross-check that holds Singapore and Malaysia."""
    codes = {r.code for r in rows if r.code}
    lengths = sorted({len(c) for c in codes})
    # Mark each code's shorter prefixes as internal, rather than asking of every
    # code whether any other extends it: the latter is O(n^2) and takes minutes
    # over 15,119 codes. A prefix that is not itself a code is harmless here,
    # because the result is subtracted from the code set.
    internal = set()
    for code in codes:
        for length in lengths:
            if length < len(code):
                internal.add(code[:length])
    return codes - internal


RE_LEAD_DASHES = re.compile(r"^(?:-\s+)+")


def compose_ch98_english(row, english_by_code, display_by_code):
    """English for a chapter 98 line, composed from the rows it points at.

    Chapter 98 is Vietnam's special-preference chapter and the workbook prints it
    in Vietnamese ONLY -- 535 coded rows carry no English. The chapter is not
    separate goods, though: each line gives an alternative rate for goods
    classified elsewhere, and names those Chapter 1-97 codes in the column this
    parser reads as CORRESPONDING_CODES. Those rows DO have English, in this same
    file.

    So the English is composed from source text rather than translated or left
    blank: "Goods of 0306.15.00 (Norway lobsters (Nephrops norvegicus))" for
    9804.15.00. Nothing is invented -- the description is another row's own
    English and the mapping is the one the schedule prints. It resolves 451 of
    the 535 (84.3%); the remaining 84 are group headers with no corresponding
    code, which legitimately have no description.

    The leading dashes are stripped from the borrowed text: that depth describes
    the DONOR row's position in the Chapter 1-97 tree, and carrying it over would
    assert an indent this chapter 98 row does not have.

    DESCRIPTION_SOURCE records which of the three happened, so a consumer can
    tell the schedule's own English from a composition, and never has to guess.
    """
    if row.desc_en:
        return row.desc_en, "source"
    if not row.corresponding:
        return "", "absent"
    parts = []
    for code in row.corresponding.split(";"):
        desc = english_by_code.get(code)
        if not desc:
            continue
        parts.append(f"{display_by_code.get(code, code)} ({RE_LEAD_DASHES.sub('', desc)})")
    if not parts:
        return "", "absent"
    return f"Goods of {'; '.join(parts)}", "composed_from_corresponding"


CSV_COLUMNS = ["GOODS_CODE", "DISPLAY", "DESCRIPTION", "DESCRIPTION_SOURCE", "INDENT", "UNIT",
               "CORRESPONDING_CODES", "MFN_RATE", "ORDINARY_RATE", "VAT",
               "MFN_DECREE", "MFN_EFFECTIVE", "IS_LEAF", "SECTION", "CHAPTER",
               "SHEET_ROW"]


def collapse_ch98(rows: list) -> list:
    """One row per code, with chapter 98's corresponding codes gathered.

    A chapter 98 code legitimately appears once per corresponding Chapter 1-97
    code, so the sheet holds genuine duplicates there and nowhere else. The
    corpus builder needs unique codes to build a tree, so the pairs are collapsed
    into a single semicolon-joined cell rather than dropped -- the mapping is the
    substance of the chapter and must survive."""
    out, seen = [], {}
    for r in rows:
        if not r.code:
            # A condition row has no identity to collapse on, and all of them
            # would collapse onto each other if it tried.
            out.append(r)
            continue
        if r.code in seen:
            prev = seen[r.code]
            if r.indent != prev.indent:
                # Not a pairing repeat: the chapter prints the heading's code
                # again on the header of a nested group one dash deeper. Keeping
                # it as a code would be a duplicate; dropping it would orphan
                # the lines beneath it onto their own sibling. It is a condition.
                out.append(condition_row(r.indent, r.desc_en, r.desc_vi,
                                         r.section, r.chapter, r.sheet_row))
                continue
            if r.corresponding and r.corresponding not in prev.corresponding.split(";"):
                prev.corresponding = (f"{prev.corresponding};{r.corresponding}"
                                      if prev.corresponding else r.corresponding)
            continue
        seen[r.code] = r
        out.append(r)
    return out


def write_csv(parse: Parse, path: Path, language: str) -> int:
    """One file per language, same codes and indents in the same order.

    Mirrors Taiwan's `<stem>.zh.csv` beside `<stem>.csv`: build_hts_corpus takes
    --lang and needs a per-language row set, not a per-language column."""
    rows = collapse_ch98(parse.rows)
    leaves = tree_leaves(rows)
    english_by_code = {r.code: r.desc_en for r in rows if r.desc_en}
    display_by_code = {r.code: r.display for r in rows}
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=CSV_COLUMNS)
        w.writeheader()
        for r in rows:
            if language == "vi":
                desc, src = r.desc_vi, "source" if r.desc_vi else "absent"
            else:
                desc, src = compose_ch98_english(r, english_by_code, display_by_code)
                parse.stats[f"desc_en_{src}"] += 1
            w.writerow({
                "GOODS_CODE": r.code, "DISPLAY": r.display,
                "DESCRIPTION": desc, "DESCRIPTION_SOURCE": src,
                "INDENT": r.indent, "UNIT": r.unit,
                "CORRESPONDING_CODES": r.corresponding,
                "MFN_RATE": r.mfn, "ORDINARY_RATE": r.ordinary, "VAT": r.vat,
                "MFN_DECREE": r.mfn_doc, "MFN_EFFECTIVE": r.mfn_date,
                "IS_LEAF": "1" if r.code in leaves else "0",
                "SECTION": r.section, "CHAPTER": r.chapter, "SHEET_ROW": r.sheet_row,
            })
    return len(rows)


# Chapter 98 is Vietnam's own chapter and the sheet gives it no type marker, so
# parse_workbook() never sees a chapter header for it and it would be missing
# from the chapters file -- which build_hts_corpus.py reports as "chapters with
# codes but no chapters-file entry" and then builds every chapter-98 record with
# no chapter prefix at all. Its printed Vietnamese heading is a sentence rather
# than a title ("QUY ĐỊNH MÃ HÀNG VÀ MỨC THUẾ SUẤT THUẾ NHẬP KHẨU ƯU ĐÃI
# RIÊNG ..."), and the workbook prints no English for it anywhere, so the entry
# is stated here rather than scraped.
CH98_ENTRY = {
    "chapter": "98",
    "description": "Commodity codes and separate preferential import duty rates",
    "section": "",
    "sectionTitle": "",
}
# The Vietnamese heading as printed on sheet row 19052, set in the same sentence
# case as every other chapter title.
CH98_ENTRY_VI = dict(CH98_ENTRY, description=(
    "Quy định mã hàng và mức thuế suất thuế nhập khẩu ưu đãi riêng "
    "đối với một số nhóm mặt hàng, mặt hàng"))


def write_chapters(parse: Parse, path: Path, lang: str = "en") -> None:
    """A LIST of {chapter, description, section, sectionTitle}, chapter numbers
    zero-padded -- the shape build_hts_corpus.load_chapters() reads and the
    shape chapters_sg.json and chapters_my.json already have. A dict keyed by an
    unpadded number, which this wrote first, makes load_chapters() raise on
    `c["chapter"]` before the corpus build starts."""
    vi = lang == "vi"
    sections = parse.sections_vi if vi else parse.sections
    payload = [{"chapter": f"{k:02d}",
                "description": v.get("title_vi" if vi else "title", ""),
                "section": v.get("section", ""),
                "sectionTitle": sections.get(v.get("section", ""), "")}
               for k, v in sorted(parse.chapters.items())]
    payload.append(dict(CH98_ENTRY_VI if vi else CH98_ENTRY))
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")


def build_note_records(parse: Parse, source_sha: str) -> dict:
    records: dict[str, dict] = {}
    for block in parse.notes:
        # The row prints the note's number ("1. This Chapter covers ..."); the
        # cite id and label carry it, and the US text does not repeat it.
        number = re.compile(rf"^{re.escape(block.number)}\.\s*")
        body = (number.sub("", norm(" ".join(block.parts_en)))
                or number.sub("", norm(" ".join(block.parts_vi))))
        if not body:
            continue
        body_vi = number.sub("", norm(" ".join(block.parts_vi)))
        if block.kind == "section_note":
            cite = f"SN-{block.section}-{block.number}"
            label = f"Section {block.section}, Note {block.number}"
            scope, chapter = block.section or "", None
        elif block.kind == "subheading_note" and block.chapter is None:
            # Section XI prints its own Subheading Notes before chapter 50, so
            # there is no chapter to hang them on. Section scope is what makes
            # the textile-blend rule retrievable for every chapter it binds, and
            # it matches the cite Singapore and Malaysia emit for the same notes.
            cite = f"SHN-{block.section}-{block.number}"
            label = f"Section {block.section}, Subheading Note {block.number}"
            scope, chapter = block.section or "", None
        elif block.kind == "subheading_note":
            cite = f"SHN-{block.chapter}-{block.number}"
            label = f"Chapter {block.chapter}, Subheading Note {block.number}"
            scope, chapter = str(block.chapter), str(block.chapter)
        else:
            cite = f"N-{block.chapter}-{block.number}"
            label = f"Chapter {block.chapter}, Note {block.number}"
            scope, chapter = str(block.chapter), str(block.chapter)
        # A chapter-scoped kind with no chapter would stringify to the literal
        # "None": a cite nothing resolves and a manifest key that is not a
        # number. Record it rather than writing it.
        if chapter == "None":
            parse.anomalies.append({
                "cite_id": cite, "sheet_row": block.sheet_row, "kind": block.kind,
                "reason": "a chapter-scoped note appeared with no chapter in "
                          "scope; attributed to its section instead",
            })
            parse.stats["note_without_chapter"] += 1
            cite = f"{cite.split('-')[0]}-{block.section}-{block.number}"
            scope, chapter = block.section or "", None
        if cite in records:
            suffix = "b"
            while f"{cite}{suffix}" in records:
                suffix = chr(ord(suffix) + 1)
            parse.anomalies.append({
                "cite_id": cite, "kept_as": f"{cite}{suffix}",
                "sheet_row": block.sheet_row, "kind": block.kind,
                "reason": "a second note block claims this number; kept under a "
                          "suffixed cite so no operative text is lost",
            })
            parse.stats["duplicate_cite"] += 1
            cite = f"{cite}{suffix}"
        records[cite] = {
            "_id": f"{JURISDICTION}|{REVISION}|{block.kind}|{scope}|{block.number}",
            "chapter": chapter,
            "chunk_text": body,
            "chunk_text_vi": body_vi,
            "cite_id": cite,
            "content_sha256": sha256_text(body),
            "display_text": f"[{cite}] {label}: {body}",
            "examples": [],
            "jurisdiction": JURISDICTION,
            "kind": block.kind,
            "note_number": block.number,
            "page": None,
            "printed_page": None,
            "paragraph": None,
            "revision": REVISION,
            "section": block.section or None,
            "sheet_row": block.sheet_row,
            "source_sha256": source_sha,
            "source_url": SOURCE_URL,
            "tables": [],
        }
    return records


def write_notes(records: dict, out_dir: Path, parse: Parse, source_sha: str) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    stem = f"{JURISDICTION.lower()}_{REVISION}"
    # The US record shape (notes_contract): section chapters, cross-references
    # and a record per lettered paragraph, before anything is written or
    # counted, so the sidecar, the JSONL and the manifest all agree.
    records = notes_contract.finalize(records)
    (out_dir / f"{stem}.notes.json").write_text(
        json.dumps(records, ensure_ascii=False, indent=1, sort_keys=True) + "\n",
        encoding="utf-8")
    artifact_sha = {}
    # No `gri` family: the workbook carries no interpretative rules, and writing
    # an empty file would read as "parsed, found none" rather than "not in this
    # source". See the module docstring.
    families = {"section": ("section_note",),
                "chapter": ("chapter_note", "subheading_note")}
    for family, kinds in families.items():
        rows = [r for r in records.values() if r["kind"] in kinds]
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
        "jurisdiction": JURISDICTION,
        "parsed_chapters": sorted(parse.chapters),
        "parsed_gri": False,
        "gri_absent_reason": "the workbook carries no General Interpretative "
                             "Rules; Vietnam enacts them in the Decree",
        "revision": REVISION,
        "schema_version": 1,
        "source_anomalies": parse.anomalies,
        "source_sha256": source_sha,
        "source_urls": {"workbook": SOURCE_URL},
    }
    (out_dir / f"{stem}.notes.manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def ahtn_crosscheck() -> str:
    """Set the 8-digit codes against the SG-MY verified AHTN core when both are
    built. Two independently parsed PDFs agreeing is a stronger witness than
    anything internal to this workbook."""
    # The tracked canonical CSVs, not build outputs: those live under output/
    # by revision id and are absent on a fresh checkout, which silently skipped
    # this check.
    paths = {}
    for cc in ("sg", "my"):
        found = sorted((REPO_ROOT / "data" / f"{cc}_tariff_source").glob(f"{cc}_tariff_*_rev_*.csv"))
        found = [p for p in found if p.name.count(".") == 1]   # not the .vi/.ms variants
        if found:
            paths[cc.upper()] = found[-1]
    if len(paths) < 2:
        return "  AHTN cross-check: skipped (SG/MY canonical CSVs not found)"
    sets = {}
    for cc, p in paths.items():
        with p.open(newline="", encoding="utf-8") as fh:
            codes = {re.sub(r"\D", "", r["GOODS_CODE"] or "") for r in csv.DictReader(fh)}
        sets[cc] = {c[:8] for c in codes if len(c) >= 8}
    core = sets["SG"] & sets["MY"]
    return core


def validate(parse: Parse, records: dict) -> list[str]:
    errors: list[str] = []
    collapsed = collapse_ch98(parse.rows)
    leaves = tree_leaves(collapsed)
    got = {
        "coded_rows": parse.stats["coded_rows"],
        "four_digit": parse.stats["digits_4"],
        "six_digit": parse.stats["digits_6"],
        "eight_digit": parse.stats["digits_8"],
        "malformed_code": parse.stats["malformed_code"],
        "code_repaired": parse.stats["code_repaired"],
        "effective_date_repaired": parse.stats["effective_date_repaired"],
        "rows_with_unit": parse.stats["rows_with_unit"],
        "section_hdr": parse.stats["section_hdr"],
        "chapter_hdr": parse.stats["chapter_hdr"],
        "no_english": parse.stats["no_english"],
        "no_english_outside_ch98": parse.stats["no_english_outside_ch98"],
        "condition_rows": parse.stats["condition_rows"],
        "note_bullet_as_code_row": parse.stats["note_bullet_as_code_row"],
        "note_bullet_recovered": parse.stats["note_bullet_recovered"],
        "note_body_rows": parse.stats[f"note_para_{T_NOTE_BODY}"],
        "note_start_mistyped": parse.stats["note_start_mistyped"],
        "note_number_nested": parse.stats["note_number_nested"],
        "note_records": len(records),
        "condition_rows_collapsed": sum(1 for r in collapsed if not r.code),
    }
    core = [r for r in collapsed if r.code and r.code[:2] != "98"]
    ch98 = [r for r in collapsed if r.code[:2] == "98"]
    got["core_leaves"] = sum(1 for r in core if r.code in leaves)
    got["core_rows_with_unit"] = sum(1 for r in core if r.unit)
    got["ch98_corresponding_pair"] = parse.stats["ch98_corresponding_pair"]
    got["ch98_distinct_codes"] = len(ch98)
    got["ch98_rows"] = sum(1 for r in parse.rows if r.code[:2] == "98")
    got["row_without_type_marker"] = parse.stats["row_without_type_marker"]
    got["desc_en_composed_from_corresponding"] = parse.stats["desc_en_composed_from_corresponding"]
    got["desc_en_absent"] = parse.stats["desc_en_absent"]
    # A grouping row that is not followed by something deeper governs nothing,
    # which is the signature of a depth read off the wrong column -- the failure
    # that drops a whole branch while every count still adds up.
    stranded = [r.sheet_row for i, r in enumerate(collapsed)
                if not r.code and (i + 1 >= len(collapsed)
                                   or collapsed[i + 1].indent <= r.indent)]
    got["stranded_grouping_rows"] = len(stranded)
    if stranded:
        errors.append(f"grouping rows qualifying no line: {stranded[:10]} "
                      f"(none is expected -- see EXPECTED)")
    # The strong cross-check, scoped to the AHTN schedule: two independent
    # witnesses in the same file -- the indent column and the unit column -- must
    # name the same leaf set. Chapter 98 is excluded because its unit column is
    # not a leaf marker there, which the gates above pin separately.
    if got["core_leaves"] != got["core_rows_with_unit"]:
        errors.append(f"chapters 1-97: {got['core_leaves']} tree leaves but "
                      f"{got['core_rows_with_unit']} rows carry a unit of "
                      f"quantity - the two must agree exactly")

    for key, want in EXPECTED.items():
        if got[key] != want:
            errors.append(f"{key}: parsed {got[key]}, expected {want}")

    kinds = Counter(r["kind"] for r in records.values())
    for kind in REQUIRED_NOTE_KINDS:
        if not kinds.get(kind):
            errors.append(f"note family {kind!r} is empty - the workbook carries "
                          f"it, so nothing should reduce it to zero")

    # Duplicates outside chapter 98 would be a parse failure; inside it they are
    # the (code, corresponding code) pairing the chapter is made of.
    seen: dict = {}
    for r in parse.rows:
        if not r.code:
            continue
        if r.code in seen and r.code[:2] != "98":
            errors.append(f"duplicate code {r.display} outside chapter 98 "
                          f"(sheet rows {seen[r.code]} and {r.sheet_row})")
        seen[r.code] = r.sheet_row
    return errors


def main() -> int:
    base = REPO_ROOT / "data" / "vn_tariff_source"
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--xlsx", type=Path, default=base / ".vn_download" / "vn_tariff.xlsx")
    ap.add_argument("--out-dir", type=Path, default=base)
    ap.add_argument("--notes-dir", type=Path,
                    default=REPO_ROOT / "data" / "hts_notes" / f"vn_{REVISION}")
    ap.add_argument("--chapters-out", type=Path,
                    default=Path(__file__).resolve().parent / "chapters_vn.json")
    ap.add_argument("--no-validate", action="store_true")
    args = ap.parse_args()

    if not args.xlsx.is_file():
        print(f"ERROR: no such workbook: {args.xlsx}", file=sys.stderr)
        return 2
    source_sha = sha256_file(args.xlsx)
    print(f"Reading {args.xlsx.name} ({args.xlsx.stat().st_size:,} bytes)")
    print(f"  sha256 {source_sha}")

    parse = parse_workbook(args.xlsx)
    leaves = tree_leaves(parse.rows)
    print(f"  rows: {parse.stats['coded_rows']:,} coded "
          f"({parse.stats['digits_4']:,} four-digit, {parse.stats['digits_6']:,} six, "
          f"{parse.stats['digits_8']:,} eight)")
    print(f"  tree leaves {len(leaves):,}; rows carrying a unit of quantity "
          f"{parse.stats['rows_with_unit']:,}")
    print(f"  grouping (condition) rows: {parse.stats['condition_rows']:,}")
    print(f"  sections {parse.stats['section_hdr']}, chapters {parse.stats['chapter_hdr']}, "
          f"chapter titles {len(parse.chapters)}")
    print(f"  no English: {parse.stats['no_english']} "
          f"({parse.stats['no_english_outside_ch98']} outside chapter 98)")
    if parse.stats["malformed_code"]:
        print(f"  malformed codes: {parse.stats['malformed_code']} (recorded, excluded)")
    print(f"  repaired against the issuing Decree: {parse.stats['code_repaired']} "
          f"codes, {parse.stats['effective_date_repaired']} effective dates")

    records = build_note_records(parse, source_sha)
    print(f"  notes: {len(records)} records "
          f"{dict(sorted(Counter(r['kind'] for r in records.values()).items()))}")

    stem = f"vn_tariff_{REVISION}"
    n_en = write_csv(parse, args.out_dir / f"{stem}.csv", "en")
    n_vi = write_csv(parse, args.out_dir / f"{stem}.vi.csv", "vi")
    write_chapters(parse, args.chapters_out)
    write_chapters(parse, args.chapters_out.with_suffix(".vi.json"), "vi")
    write_notes(records, args.notes_dir, parse, source_sha)
    # The manual acquisition adapter reads the effective date from this sidecar,
    # exactly as it does for the Dominican Republic's transcription.
    (args.out_dir / f"{stem}.csv.meta.json").write_text(json.dumps({
        "effective_date": EFFECTIVE_DATE,
        "effective_date_label": EDITION_LABEL,
        "source": SOURCE_URL,
        "source_sha256": source_sha,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    core = ahtn_crosscheck()
    if isinstance(core, str):
        print(core)
    else:
        mine = {r.code for r in parse.rows if len(r.code) == 8}
        missing = core - mine
        print(f"  AHTN cross-check: {len(core & mine):,} of the {len(core):,} codes "
              f"SG and MY agree on; {len(missing)} absent from VN; "
              f"{len(mine - core):,} national additions")
        if missing:
            print(f"    absent sample: {sorted(missing)[:6]}")

    print("\n--- gates ---")
    errors = validate(parse, records)
    if errors:
        for e in errors:
            print(f"  FAIL {e}")
        if not args.no_validate:
            return 1
        print("  (--no-validate: reported, not failed)")
    else:
        print("  all gates pass")
    print(f"\nWrote {n_en:,} rows -> {args.out_dir / f'{stem}.csv'}")
    print(f"Wrote {n_vi:,} rows -> {args.out_dir / f'{stem}.vi.csv'}")
    print(f"Wrote {len(records)} note records -> {args.notes_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

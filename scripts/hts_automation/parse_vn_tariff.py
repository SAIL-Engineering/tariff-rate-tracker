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
    and a trailing non-breaking space, with no English. They are recorded as
    anomalies and excluded from the tree rather than repaired into a code the
    source does not contain.

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

try:
    import openpyxl
except ImportError:  # pragma: no cover
    sys.exit("ERROR: openpyxl is required (pip install openpyxl)")

REPO_ROOT = Path(__file__).resolve().parents[2]
JURISDICTION = "VN"
REVISION = "2026_0405"
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
    "coded_rows": 15115,
    "four_digit": 1081,
    "six_digit": 2034,
    "eight_digit": 12000,
    "malformed_code": 4,
    "rows_with_unit": 11428,
    "section_hdr": 21,
    "chapter_hdr": 97,
    # English stops at chapter 98 and nowhere else; the second gate is the one
    # that matters, because a drop anywhere in chapters 1-97 would be a parse
    # failure rather than a property of the source.
    "no_english": 662,
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
    "ch98_corresponding_pair": 569,
    "ch98_distinct_codes": 531,
    "ch98_rows": 662,
}
# The source carries section and chapter notes and NO interpretative rules, so
# only these two families may be asserted. A count that merely matches cannot
# catch a family that produces nothing (the Malaysian order shipped for months
# with none), and a gate pinned at zero would enshrine the absence.
REQUIRED_NOTE_KINDS = ("section_note", "chapter_note", "subheading_note")


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
            continue
        if rtype in (T_SECTION_TITLE, T_SUBCHAPTER, T_SUBCHAPTER_TITLE):
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
        if rtype in T_NOTE_PARA:
            if not note_kind:
                continue
            m = RE_NOTE_NUM.match(en) or RE_NOTE_NUM.match(vi)
            if m and rtype == "9":
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
        if rtype in T_CODE or (has_code and not rtype):
            close_note()
            note_kind = ""
            d = digits_of(raw[C_CODE])
            if not d:
                continue
            indent = (T_CODE[rtype] if rtype in T_CODE
                      else dash_depth(vi or en))
            if rtype not in T_CODE:
                out.stats["row_without_type_marker"] += 1
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
            raw_unit = norm(raw[C_UNIT_EN]) or norm(raw[C_UNIT_VI])
            is_ch98 = d[:2] == "98"
            corresponding = ""
            unit = raw_unit
            if is_ch98 and re.fullmatch(r"\d{6,10}", raw_unit or ""):
                corresponding, unit = raw_unit, ""
                out.stats["ch98_corresponding_pair"] += 1
            out.rows.append(Row(
                code=d, display=display_of(d), indent=indent,
                desc_en=en, desc_vi=vi, unit=unit, corresponding=corresponding,
                mfn=norm(raw[C_MFN]), ordinary=norm(raw[C_ORDINARY]),
                vat=norm(raw[C_VAT]), mfn_doc=norm(raw[C_MFN_DOC]),
                mfn_date=norm(raw[C_MFN_DATE]),
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
    codes = {r.code for r in rows}
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


CSV_COLUMNS = ["GOODS_CODE", "DISPLAY", "DESCRIPTION", "INDENT", "UNIT",
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
        if r.code in seen:
            prev = seen[r.code]
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
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=CSV_COLUMNS)
        w.writeheader()
        for r in rows:
            w.writerow({
                "GOODS_CODE": r.code, "DISPLAY": r.display,
                "DESCRIPTION": r.desc_vi if language == "vi" else r.desc_en,
                "INDENT": r.indent, "UNIT": r.unit,
                "CORRESPONDING_CODES": r.corresponding,
                "MFN_RATE": r.mfn, "ORDINARY_RATE": r.ordinary, "VAT": r.vat,
                "MFN_DECREE": r.mfn_doc, "MFN_EFFECTIVE": r.mfn_date,
                "IS_LEAF": "1" if r.code in leaves else "0",
                "SECTION": r.section, "CHAPTER": r.chapter, "SHEET_ROW": r.sheet_row,
            })
    return len(rows)


def write_chapters(parse: Parse, path: Path) -> None:
    payload = {str(k): {"title": v.get("title", ""), "section": v.get("section", "")}
               for k, v in sorted(parse.chapters.items())}
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")


def build_note_records(parse: Parse, source_sha: str) -> dict:
    records: dict[str, dict] = {}
    for block in parse.notes:
        body = norm(" ".join(block.parts_en)) or norm(" ".join(block.parts_vi))
        if not body:
            continue
        body_vi = norm(" ".join(block.parts_vi))
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
                fh.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")
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
    paths = {"SG": REPO_ROOT / "output/sg_2022/sg_2022.codes.json",
             "MY": REPO_ROOT / "output/my_pdk2025/my_pdk2025.codes.json"}
    if not all(p.exists() for p in paths.values()):
        return "  AHTN cross-check: skipped (SG/MY corpora not built)"
    sets = {}
    for cc, p in paths.items():
        nodes = json.loads(p.read_text(encoding="utf-8"))["nodes"]
        sets[cc] = {c[:8] for c in nodes if len(c) >= 8}
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
        "rows_with_unit": parse.stats["rows_with_unit"],
        "section_hdr": parse.stats["section_hdr"],
        "chapter_hdr": parse.stats["chapter_hdr"],
        "no_english": parse.stats["no_english"],
        "no_english_outside_ch98": parse.stats["no_english_outside_ch98"],
    }
    core = [r for r in collapsed if r.code[:2] != "98"]
    ch98 = [r for r in collapsed if r.code[:2] == "98"]
    got["core_leaves"] = sum(1 for r in core if r.code in leaves)
    got["core_rows_with_unit"] = sum(1 for r in core if r.unit)
    got["ch98_corresponding_pair"] = parse.stats["ch98_corresponding_pair"]
    got["ch98_distinct_codes"] = len(ch98)
    got["ch98_rows"] = sum(1 for r in parse.rows if r.code[:2] == "98")
    got["row_without_type_marker"] = parse.stats["row_without_type_marker"]
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
    print(f"  sections {parse.stats['section_hdr']}, chapters {parse.stats['chapter_hdr']}, "
          f"chapter titles {len(parse.chapters)}")
    print(f"  no English: {parse.stats['no_english']} "
          f"({parse.stats['no_english_outside_ch98']} outside chapter 98)")
    if parse.stats["malformed_code"]:
        print(f"  malformed codes: {parse.stats['malformed_code']} (recorded, excluded)")

    records = build_note_records(parse, source_sha)
    print(f"  notes: {len(records)} records "
          f"{dict(sorted(Counter(r['kind'] for r in records.values()).items()))}")

    stem = f"vn_tariff_{REVISION}"
    n_en = write_csv(parse, args.out_dir / f"{stem}.csv", "en")
    n_vi = write_csv(parse, args.out_dir / f"{stem}.vi.csv", "vi")
    write_chapters(parse, args.chapters_out)
    write_notes(records, args.notes_dir, parse, source_sha)

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

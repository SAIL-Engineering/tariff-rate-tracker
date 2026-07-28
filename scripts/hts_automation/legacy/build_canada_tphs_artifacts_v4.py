# =============================================================================
# VENDORED 2026-07-27 — SUPERSEDED for the retrieval corpus. Read this first.
# =============================================================================
# Previously this lived only at
#   ~/Desktop/SAIL/hts/canada_tphs_v4_pipeline_outputs/
# i.e. outside version control, despite being the only thing that could rebuild
# the Canadian corpus. It is vendored here so it is tracked, alongside its input
# (data/ca_tariff_source/ca_tariff_2026_rev_1.csv) — and note that input is NOT
# re-downloadable: CBSA publishes the tariff as PDF/HTML only, with no
# machine-readable form, so unlike the USITC CSVs this file is irreplaceable and
# is deliberately committed rather than gitignored.
#
# THE PINECONE CORPUS IS NO LONGER BUILT BY THIS SCRIPT. It is built by
#   build_hts_corpus.py --source-format cbsa
# which shares one tree implementation with the US path. Three defects here are
# why; all three also existed in the US builder and were fixed in the same pass.
#
#  1. EMITS ONLY 10-DIGIT CODES.
#     Output is 10,972 records, all 10-digit. The Canadian schedule also has 67
#     codes that are TERMINAL AT 8 DIGITS, plus one at 4. Those are legitimate
#     final classification targets and were absent from the corpus entirely,
#     giving them a structural retrieval recall of zero.
#
#  2. DROPS THE COLON-TERMINATED GROUPING ROWS.
#     "0101.2  Horses:" and 1,923 others never reach a breadcrumb, so
#     0101.21.00.00 reads "Live animals > Live horses... > Pure-bred breeding
#     animals" with the "Horses" level missing. That text is often the only
#     thing distinguishing otherwise-identical siblings.
#
#  3. NO SIBLING CONTEXT FOR BASKET PROVISIONS.
#     2,689 leaves (24%) are literally "Other". Their own text carries no
#     retrievable meaning; what defines them is what they EXCLUDE. The new
#     builder renders them "Other, other than: <siblings>".
#
# A fourth defect was found while porting and is specific to prefix-derived
# hierarchy, so it never existed here in this form: 353 Canadian codes have no
# ancestor present in the file (Chapter 99 provisions such as 9903.00.00 whose
# 4-digit heading row does not exist). Deriving indent from code LENGTH makes
# those adopt whatever unrelated node sits at a shallower level; the new builder
# derives indent from ANCESTOR COUNT instead, so an orphan is a root.
#
# This script still produces artifacts the new builder does not — book.json,
# records.json, table.csv, the section/chapter JSONs — so it is kept, not
# deleted. Use it for those. Do not use it for the retrieval corpus.
# =============================================================================

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Build repeatable Canadian Customs Tariff / TPHS artifacts.

This version makes the sorted TPHS rows the canonical source of truth:
  1. Load and normalize TPHS rows.
  2. Sort rows into tariff-book order.
  3. Build hierarchy, minimal outputs (for RAG Classification [Ragie]), table outputs, JSONL, and compact JSON
     only from that sorted canonical row set.


Examples:
  python3 build_canada_tphs_artifacts_v4.py TPHS.csv canada_tphs_v4 \
    --chapters-json canada_tphs_chapters.json \
    --sections-json canada_tphs_sections.json
    

Primary input:
    TPHS.csv
        Raw Canadian Customs Tariff Schedule file. The file is expected to
        contain tariff classification rows with columns such as:
            - TARIFF
            - EFF_DATE
            - CHANGE
            - SUB_CHAP
            - DESC1
            - DESC2
            - DESC3
            - FOOTNOTE
            - UOM
            - MFN
            - General Tariff
            - preferential tariff treatment columns such as UST, MXT,
              CPTPT, UKT, CEUT, KRT, HNT, COLT, JT, PAT, GPT, LDCT, CCCT,
              and related rate columns.

Optional context inputs:
    canada_tphs_chapters.json
        Chapter metadata keyed by two-digit chapter number. Used to add
        canonical chapter titles such as:
            01 -> Live animals

    canada_tphs_sections.json
        Section metadata keyed by HS section. Used to map chapters to
        their parent sections and add section-level context such as:
            Section I -> LIVE ANIMALS; ANIMAL PRODUCTS

Why this script exists:
    The Canadian TPHS file does not include an explicit "Indent" column like
    the U.S. HTS source file. Instead, hierarchy must be inferred from the
    tariff code structure itself. The raw TPHS file may also not be sorted in
    canonical tariff-book order. For that reason, this script first normalizes
    and sorts the source rows, then builds every downstream artifact from that
    sorted canonical dataset.

Processing flow:
    1. Load the raw TPHS.csv file.
    2. Normalize tariff codes by extracting digit-only identifiers.
    3. Sort all rows into canonical tariff-book order.
    4. Export the sorted original TPHS rows for auditability and reuse.
    5. Build a prefix-based hierarchy from the sorted tariff codes.
    6. Identify final 10-digit Canadian tariff/statistical codes.
    7. Build minimal breadcrumb strings for classification/RAG lookup.
    8. Build compact enriched records for each 10-digit code.
    9. Build a normalized tariff-book JSON that avoids redundant repetition
       of section, chapter, treatment, node, and line metadata.
    10. Write validation output describing record counts, duplicate codes,
        missing chapter context, and hierarchy/path issues.

Important Canadian tariff assumption:
    Canada uses a unified 10-digit classification system. These same 10-digit
    codes are used both for import classification and for export statistical
    reporting. Duty-rate columns are relevant for imports, while TARIFF and
    UOM are especially important for export declarations and statistics.

Main outputs:
    <out_stem>_sorted_original.csv
        The original TPHS rows, preserved with their source columns, but sorted
        into canonical tariff-book order. This is the audit-friendly canonical
        source used by all other generated artifacts.

    <out_stem>_minimal.csv
        One-column CSV with a "content" column. Each row contains a compact
        hierarchy breadcrumb for a 10-digit code, for example:
            0101.21.00.10 = 01 Live animals | 0101 Live horses, asses,
            mules and hinnies | 0101.21.00 Purebred breeding animals |
            0101.21.00.10 Males

    <out_stem>_minimal.jsonl
        JSONL version of the minimal breadcrumb output. Useful for RAG systems
        that ingest one compact classification path per line.

    <out_stem>_table.csv
        Compact tabular output for application/database use. Includes the
        10-digit code, hierarchy fields, description, UOM, tariff rates,
        rate-source metadata, section/chapter context, and minimal content.

    <out_stem>_records.json
        Compact list of line-level 10-digit tariff records. Each record stores
        only the fields specific to that code and references shared hierarchy
        context by code/path rather than repeating large text blocks.

    <out_stem>_book.json
        Normalized tariff-book JSON. Stores shared information once, including:
            - sections
            - chapters
            - tariff treatments
            - hierarchy nodes
            - final 10-digit lines

        This is the preferred structured JSON for applications because it
        avoids unnecessary duplication across thousands of tariff lines.

    <out_stem>_rag.jsonl
        Enriched JSONL records suitable for RAG ingestion when more context
        than the minimal breadcrumb is needed.

    <out_stem>_validation.json
        Validation summary including counts, duplicate tariff codes, missing
        chapter or section context, and hierarchy/path integrity checks.

Example usage:
    python3 build_canada_tphs_artifacts_v4.py TPHS.csv canada_tphs_v4 \
        --chapters-json canada_tphs_chapters.json \
        --sections-json canada_tphs_sections.json

Design principles:
    - The sorted TPHS dataset is the single source of truth.
    - No manual hardcoding of specific tariff codes.
    - Hierarchy is inferred generically from tariff-code prefixes.
    - Minimal outputs are optimized for retrieval and classification context.
    - Structured JSON outputs avoid redundant repeated breadcrumbs and metadata.
    - The pipeline is repeatable for future TPHS revisions.

"""

from __future__ import annotations

import argparse
import csv
import json
import re
from copy import deepcopy
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

DESC_COLUMNS = ["DESC1", "DESC2", "DESC3"]
CORE_COLUMNS = ["TARIFF", "EFF_DATE", "CHANGE", "SUB_CHAP", "FOOTNOTE", "UOM"]

DEFAULT_RATE_COLUMNS = [
    "MFN",
    "AUT",
    "NZT",
    "CCCT",
    "LDCT",
    "GPT",
    "UST",
    "MXT",
    "CIAT",
    "CT",
    "CRT",
    "IT",
    "NT",
    "SLT",
    "PT",
    "COLT",
    "JT",
    "PAT",
    "HNT",
    "KRT",
    "CEUT",
    "CPTPT",
    "UKT",
    "UAT",
    "General Tariff",
]

TREATMENT_LABELS = {
    "MFN": "Most-Favoured-Nation Tariff",
    "AUT": "Australia Tariff",
    "NZT": "New Zealand Tariff",
    "CCCT": "Commonwealth Caribbean Countries Tariff",
    "LDCT": "Least Developed Country Tariff",
    "GPT": "General Preferential Tariff",
    "UST": "United States Tariff",
    "MXT": "Mexico Tariff",
    "CIAT": "Canada-Israel Agreement Tariff",
    "CT": "Chile Tariff",
    "CRT": "Costa Rica Tariff",
    "IT": "Iceland Tariff",
    "NT": "Norway Tariff",
    "SLT": "Switzerland-Liechtenstein Tariff",
    "PT": "Peru Tariff",
    "COLT": "Colombia Tariff",
    "JT": "Jordan Tariff",
    "PAT": "Panama Tariff",
    "HNT": "Honduras Tariff",
    "KRT": "Korea Tariff",
    "CEUT": "Canada-European Union Tariff",
    "CPTPT": "Comprehensive and Progressive Trans-Pacific Partnership Tariff",
    "UKT": "United Kingdom Tariff",
    "UAT": "Ukraine Tariff",
    "General Tariff": "General Tariff",
}

WHITESPACE_RE = re.compile(r"\s+")


def clean_text(value: Any, strip_trailing_colon: bool = False) -> str:
    text = "" if value is None else str(value)
    text = text.replace("\ufeff", "")
    text = WHITESPACE_RE.sub(" ", text).strip()
    if strip_trailing_colon:
        text = text.rstrip(":").strip()
    return text


def digits_only(code: Any) -> str:
    return "".join(ch for ch in clean_text(code) if ch.isdigit())


def row_id_int(row: Dict[str, str]) -> int:
    try:
        return int(clean_text(row.get("row_id", "")))
    except ValueError:
        return 10**12


def tariff_level(digits: str) -> str:
    length = len(digits)
    return {
        2: "chapter",
        4: "heading",
        5: "subheading_group",
        6: "subheading",
        7: "tariff_item_group",
        8: "tariff_item",
        9: "statistical_group",
        10: "statistical_code",
    }.get(length, f"level_{length}_digits")


def code_parts(digits: str) -> Dict[str, str]:
    return {
        "chapter": digits[:2] if len(digits) >= 2 else "",
        "heading": digits[:4] if len(digits) >= 4 else "",
        "subheading": digits[:6] if len(digits) >= 6 else "",
        "tariff_item": digits[:8] if len(digits) >= 8 else "",
        "statistical_suffix": digits[8:10] if len(digits) >= 10 else "",
        "digits": digits,
    }


def display_code_from_digits(digits: str, source_code: Any = "") -> str:
    if len(digits) == 2:
        return digits
    if len(digits) == 4:
        return digits
    if len(digits) == 5:
        return f"{digits[:4]}.{digits[4:5]}"
    if len(digits) == 6:
        return f"{digits[:4]}.{digits[4:6]}"
    if len(digits) == 7:
        return f"{digits[:4]}.{digits[4:6]}.{digits[6:7]}"
    if len(digits) == 8:
        return f"{digits[:4]}.{digits[4:6]}.{digits[6:8]}"
    if len(digits) == 9:
        return f"{digits[:4]}.{digits[4:6]}.{digits[6:8]}.{digits[8:9]}"
    if len(digits) == 10:
        return f"{digits[:4]}.{digits[4:6]}.{digits[6:8]}.{digits[8:10]}"
    return clean_text(source_code) or digits


def combined_description(row: Dict[str, str]) -> str:
    # DESC2 and DESC3 are continuations, not independent hierarchy levels.
    return clean_text(" ".join(clean_text(row.get(c, "")) for c in DESC_COLUMNS), strip_trailing_colon=True)


def clean_minimal_description(value: Any) -> str:
    desc = clean_text(value, strip_trailing_colon=True)
    lower = desc.lower()
    abbreviation_endings = ("n.e.s.", "e.g.", "i.e.", "etc.")
    if desc.endswith(".") and not lower.endswith(abbreviation_endings):
        desc = desc[:-1].strip()
    return desc


def load_rows(path: Path) -> Tuple[List[Dict[str, str]], List[str]]:
    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        if not reader.fieldnames:
            raise ValueError(f"No header row found in {path}")
        fieldnames = [name.strip() for name in reader.fieldnames]
        rows: List[Dict[str, str]] = []
        for raw in reader:
            row = {k.strip(): clean_text(v) for k, v in raw.items() if k is not None}
            for col in fieldnames:
                row.setdefault(col, "")
            digits = digits_only(row.get("TARIFF", ""))
            row["_tariff_digits"] = digits
            row["_tariff_level"] = tariff_level(digits)
            row["_description"] = combined_description(row)
            row["_row_id_int"] = row_id_int(row)
            rows.append(row)
    return rows, fieldnames


def sort_rows_for_book(rows: Iterable[Dict[str, str]]) -> List[Dict[str, str]]:
    """Sort once into canonical tariff-book order; all downstream work uses this."""
    return sorted(
        rows,
        key=lambda r: (
            r.get("_tariff_digits", ""),
            len(r.get("_tariff_digits", "")),
            r.get("_row_id_int", 10**12),
            r.get("TARIFF", ""),
        ),
    )


def write_sorted_original(rows: List[Dict[str, str]], fieldnames: List[str], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({col: row.get(col, "") for col in fieldnames})


def load_json_payload(path: Optional[Path]) -> Any:
    if not path:
        return None
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def normalize_chapter_key(value: Any) -> str:
    digits = digits_only(value)
    return digits.zfill(2)[:2] if digits else ""


def normalize_parts(parts: Any) -> List[Dict[str, str]]:
    if not parts:
        return []
    normalized: List[Dict[str, str]] = []
    for part in parts:
        if isinstance(part, dict):
            label = clean_text(part.get("part") or part.get("label") or part.get("number") or part.get("id") or "")
            desc = clean_text(part.get("description") or part.get("title") or part.get("text") or "")
        else:
            raw = clean_text(part)
            if " - " in raw:
                label, desc = raw.split(" - ", 1)
                label, desc = clean_text(label), clean_text(desc)
            else:
                label, desc = "", raw
        if label or desc:
            normalized.append({"part": label, "description": desc})
    return normalized


def upsert_chapter(
    chapters: Dict[str, Dict[str, Any]],
    chapter: Any,
    description: Any = "",
    section: Any = "",
    section_number: Any = "",
    section_title: Any = "",
    parts: Any = None,
) -> None:
    key = normalize_chapter_key(chapter)
    if not key:
        return
    existing = chapters.setdefault(
        key,
        {
            "chapter": key,
            "title": "",
            "section": "",
            "section_number": "",
            "parts": [],
        },
    )
    desc = clean_text(description)
    if desc:
        existing["title"] = desc
    sec = clean_text(section)
    if sec:
        existing["section"] = sec
    sec_num = clean_text(section_number)
    if sec_num:
        try:
            existing["section_number"] = int(sec_num)
        except ValueError:
            existing["section_number"] = sec_num
    part_list = normalize_parts(parts)
    if part_list:
        existing["parts"] = part_list


def load_context(chapters_json: Optional[Path], sections_json: Optional[Path]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    sections_by_id: Dict[str, Any] = {}
    chapters_by_id: Dict[str, Any] = {}

    sections_payload = load_json_payload(sections_json)
    if sections_payload is not None:
        sections = sections_payload.get("sections", []) if isinstance(sections_payload, dict) else sections_payload
        if not isinstance(sections, list):
            raise ValueError("sections JSON must be a list or an object with a 'sections' list")
        for section_obj in sections:
            if not isinstance(section_obj, dict):
                continue
            sec_id = clean_text(section_obj.get("section", ""))
            sec_num = section_obj.get("section_number", "")
            title = clean_text(section_obj.get("title") or section_obj.get("section_title") or "")
            chapter_refs: List[str] = []
            for ch in section_obj.get("chapters", []) or []:
                if isinstance(ch, dict):
                    ch_id = normalize_chapter_key(ch.get("chapter", ""))
                    if ch_id:
                        chapter_refs.append(ch_id)
                        upsert_chapter(chapters_by_id, ch_id, ch.get("description", ""), sec_id, sec_num, title, ch.get("parts", []))
                else:
                    ch_id = normalize_chapter_key(ch)
                    if ch_id:
                        chapter_refs.append(ch_id)
                        upsert_chapter(chapters_by_id, ch_id, "", sec_id, sec_num, title, [])
            if sec_id:
                sections_by_id[sec_id] = {
                    "section": sec_id,
                    "section_number": int(sec_num) if str(sec_num).isdigit() else sec_num,
                    "title": title,
                    "chapter_start": clean_text(section_obj.get("chapter_start", "")),
                    "chapter_end": clean_text(section_obj.get("chapter_end", "")),
                    "chapters": chapter_refs,
                }

    chapters_payload = load_json_payload(chapters_json)
    if chapters_payload is not None:
        chapter_list = chapters_payload.get("chapters", []) if isinstance(chapters_payload, dict) else chapters_payload
        if not isinstance(chapter_list, list):
            raise ValueError("chapters JSON must be a list or an object with a 'chapters' list")
        for ch in chapter_list:
            if not isinstance(ch, dict):
                continue
            upsert_chapter(
                chapters_by_id,
                ch.get("chapter", ""),
                ch.get("description") or ch.get("title") or "",
                ch.get("section", ""),
                ch.get("section_number", ""),
                ch.get("section_title", ""),
                ch.get("parts", []),
            )

    return sections_by_id, chapters_by_id


def attach_hierarchy_paths(sorted_rows: List[Dict[str, str]]) -> List[Dict[str, Any]]:
    stack: List[Dict[str, Any]] = []
    enriched: List[Dict[str, Any]] = []

    for source_row in sorted_rows:
        row: Dict[str, Any] = deepcopy(source_row)
        digits = row.get("_tariff_digits", "")
        if not digits:
            continue
        while stack and (
            len(stack[-1].get("_tariff_digits", "")) >= len(digits)
            or not digits.startswith(stack[-1].get("_tariff_digits", ""))
        ):
            stack.pop()
        path = stack + [row]
        row["_path"] = path
        row["_parent_digits"] = stack[-1].get("_tariff_digits", "") if stack else ""
        enriched.append(row)
        stack.append(row)
    return enriched


def first_non_empty_from_path(path: List[Dict[str, Any]], column: str) -> Tuple[str, str, str]:
    for node in reversed(path):
        value = clean_text(node.get(column, ""))
        if value:
            return value, clean_text(node.get("TARIFF", "")), clean_text(node.get("_tariff_digits", ""))
    return "", "", ""


def collect_footnotes(path: List[Dict[str, Any]]) -> List[str]:
    seen = set()
    notes: List[str] = []
    for node in path:
        note = clean_text(node.get("FOOTNOTE", ""))
        if note and note not in seen:
            notes.append(note)
            seen.add(note)
    return notes


def build_node_path_with_chapter(path: List[Dict[str, Any]], chapter: str) -> List[str]:
    values = [chapter] if chapter else []
    for node in path:
        digits = clean_text(node.get("_tariff_digits", ""))
        if digits and digits not in values:
            values.append(digits)
    return values


def minimal_content_from_path(
    tariff: str,
    path: List[Dict[str, Any]],
    chapter: str,
    chapter_title: str,
    include_group_levels: bool = False,
) -> str:
    parts: List[Tuple[str, str, str]] = []
    if chapter and chapter_title:
        parts.append((chapter, clean_minimal_description(chapter_title), chapter))

    allowed_lengths = {4, 6, 8, 10}
    if include_group_levels:
        allowed_lengths.update({5, 7, 9})

    seen = {chapter} if chapter else set()
    for node in path:
        digits = clean_text(node.get("_tariff_digits", ""))
        if len(digits) not in allowed_lengths:
            continue
        code = display_code_from_digits(digits, node.get("TARIFF", ""))
        desc = clean_minimal_description(node.get("_description", ""))
        if not code or not desc:
            continue
        key = f"{code}\u241f{desc}"
        if key in seen:
            continue
        parts.append((code, desc, key))
        seen.add(key)

    compact: List[Tuple[str, str, str]] = []
    for idx, part in enumerate(parts):
        code, desc, key = part
        next_part = parts[idx + 1] if idx + 1 < len(parts) else None
        if next_part and desc == next_part[1]:
            this_digits = digits_only(code)
            next_digits = digits_only(next_part[0])
            is_zero_extension = (this_digits + "0" * (len(next_digits) - len(this_digits))) == next_digits
            if is_zero_extension:
                continue
        compact.append(part)

    body = " | ".join(f"{code} {desc}" for code, desc, _ in compact)
    return f"{tariff} = {body}" if tariff and body else body


def build_nodes(enriched_rows: List[Dict[str, Any]], chapters_by_id: Dict[str, Any]) -> Dict[str, Any]:
    nodes: Dict[str, Any] = {}

    # Add chapter nodes from context even though TPHS rows usually start at headings.
    for chapter_id, ch in sorted(chapters_by_id.items()):
        nodes[chapter_id] = {
            "digits": chapter_id,
            "code": chapter_id,
            "level": "chapter",
            "parent": ch.get("section", ""),
            "chapter": chapter_id,
            "description": clean_text(ch.get("title", "")),
            "row_ids": [],
        }

    for row in enriched_rows:
        digits = clean_text(row.get("_tariff_digits", ""))
        if not digits:
            continue
        chapter = digits[:2] if len(digits) >= 2 else ""
        row_id = clean_text(row.get("row_id", ""))
        entry = nodes.setdefault(
            digits,
            {
                "digits": digits,
                "code": display_code_from_digits(digits, row.get("TARIFF", "")),
                "source_code": clean_text(row.get("TARIFF", "")),
                "level": tariff_level(digits),
                "parent": clean_text(row.get("_parent_digits", "")) or chapter,
                "chapter": chapter,
                "description": clean_text(row.get("_description", ""), strip_trailing_colon=True),
                "row_ids": [],
            },
        )
        if row_id and row_id not in entry["row_ids"]:
            entry["row_ids"].append(row_id)
        # Preserve source metadata only when it exists on that node.
        for source_col, out_col in [
            ("EFF_DATE", "effective_date"),
            ("CHANGE", "change"),
            ("SUB_CHAP", "sub_chap"),
            ("FOOTNOTE", "footnote"),
            ("UOM", "uom"),
        ]:
            value = clean_text(row.get(source_col, ""))
            if value and out_col not in entry:
                entry[out_col] = value
    return nodes


def inherited_rates(path: List[Dict[str, Any]], rate_columns: List[str], current_digits: str) -> Tuple[Dict[str, str], Dict[str, str]]:
    rates: Dict[str, str] = {}
    sources: Dict[str, str] = {}
    for col in rate_columns:
        value, _source_code, source_digits = first_non_empty_from_path(path, col)
        if value:
            rates[col] = value
            # To reduce redundancy, only store source when inherited from an ancestor.
            if source_digits and source_digits != current_digits:
                sources[col] = source_digits
    return rates, sources


def make_records(
    enriched_rows: List[Dict[str, Any]],
    rate_columns: List[str],
    chapters_by_id: Dict[str, Any],
    include_group_levels: bool = False,
) -> Tuple[List[Dict[str, Any]], Dict[str, List[str]]]:
    records: List[Dict[str, Any]] = []
    seen_by_digits: Dict[str, Dict[str, Any]] = {}
    duplicates: Dict[str, List[str]] = {}

    for row in enriched_rows:
        digits = clean_text(row.get("_tariff_digits", ""))
        if len(digits) != 10:
            continue
        path: List[Dict[str, Any]] = row.get("_path", [row])
        parts = code_parts(digits)
        chapter = parts["chapter"]
        chapter_ctx = chapters_by_id.get(chapter, {"chapter": chapter, "title": ""})
        chapter_title = clean_text(chapter_ctx.get("title", ""))
        tariff = display_code_from_digits(digits, row.get("TARIFF", ""))
        rates, rate_sources = inherited_rates(path, rate_columns, digits)
        uom, _uom_code, uom_source = first_non_empty_from_path(path, "UOM")
        sub_chap, _sub_code, sub_source = first_non_empty_from_path(path, "SUB_CHAP")
        row_id = clean_text(row.get("row_id", ""))

        record: Dict[str, Any] = {
            "code": tariff,
            "digits": digits,
            "chapter": chapter,
            "heading": parts["heading"],
            "subheading": parts["subheading"],
            "tariff_item": parts["tariff_item"],
            "statistical_suffix": parts["statistical_suffix"],
            "description": clean_text(row.get("_description", ""), strip_trailing_colon=True),
            "path": build_node_path_with_chapter(path, chapter),
            "uom": uom,
            "uom_source": uom_source if uom_source and uom_source != digits else "",
            "effective_date": clean_text(row.get("EFF_DATE", "")),
            "change": clean_text(row.get("CHANGE", "")),
            "sub_chap": sub_chap,
            "sub_chap_source": sub_source if sub_source and sub_source != digits else "",
            "footnotes": collect_footnotes(path),
            "rates": rates,
            "rate_sources": rate_sources,
            "row_ids": [row_id] if row_id else [],
        }
        record["minimal_content"] = minimal_content_from_path(tariff, path, chapter, chapter_title, include_group_levels)

        if digits in seen_by_digits:
            if row_id:
                duplicates.setdefault(digits, []).append(row_id)
            continue
        seen_by_digits[digits] = record
        records.append(record)

    for record in records:
        duplicate_ids = [x for x in duplicates.get(record["digits"], []) if x]
        if duplicate_ids:
            record["duplicate_row_ids"] = duplicate_ids
            record["row_ids"] = record.get("row_ids", []) + duplicate_ids

    return records, duplicates


def rag_content(record: Dict[str, Any], nodes: Dict[str, Any], chapters: Dict[str, Any], sections: Dict[str, Any], treatments: Dict[str, Any]) -> str:
    path_text: List[str] = []
    for node_id in record.get("path", []):
        node = nodes.get(node_id, {})
        code = clean_text(node.get("code", ""))
        desc = clean_text(node.get("description", ""), strip_trailing_colon=True)
        if code and desc:
            path_text.append(f"{code} {desc}")
    pieces = [f"{record['code']} = {' | '.join(path_text)}"]
    if record.get("uom"):
        pieces.append(f"Unit of measure={record['uom']}")
    if record.get("effective_date"):
        pieces.append(f"Effective date={record['effective_date']}")
    if record.get("footnotes"):
        pieces.append("Footnotes=" + "; ".join(record["footnotes"]))
    if record.get("rates"):
        rate_bits = []
        for col, value in record["rates"].items():
            label = treatments.get(col, {}).get("label", col)
            src = record.get("rate_sources", {}).get(col, "")
            src_note = f", inherited_from={display_code_from_digits(src, src)}" if src else ""
            rate_bits.append(f"{label} ({col})={value}{src_note}")
        if rate_bits:
            pieces.append("Tariff treatments: " + "; ".join(rate_bits))
    pieces.append("Usage note=Canada uses this 10-digit code for customs import classification and export statistical reporting.")
    return " | ".join(pieces)


def build_book_json(
    records: List[Dict[str, Any]],
    nodes: Dict[str, Any],
    sections: Dict[str, Any],
    chapters: Dict[str, Any],
    rate_columns: List[str],
    source_file: str,
    sorted_source_file: str,
    duplicates: Dict[str, List[str]],
) -> Dict[str, Any]:
    treatments = {col: {"code": col, "label": TREATMENT_LABELS.get(col, col)} for col in rate_columns}
    return {
        "schema_version": "canada_tphs_book_v1",
        "metadata": {
            "jurisdiction": "Canada",
            "source_system": "Canada Customs Tariff TPHS",
            "source_file": source_file,
            "canonical_sorted_source_file": sorted_source_file,
            "record_level": "10-digit statistical tariff code",
            "record_count": len(records),
            "node_count": len(nodes),
            "section_count": len(sections),
            "chapter_count": len(chapters),
            "duplicate_10_digit_codes": sorted(duplicates.keys()),
            "pipeline_order": [
                "load TPHS",
                "normalize rows and tariff digits",
                "sort rows into canonical tariff-book order",
                "build hierarchy from sorted rows",
                "write sorted original CSV",
                "write minimal, table, JSONL, records JSON, and normalized book JSON",
            ],
        },
        "treatments": treatments,
        "sections": sections,
        "chapters": chapters,
        "nodes": nodes,
        "lines": {record["digits"]: record for record in records},
    }


def build_records_json(records: List[Dict[str, Any]], rate_columns: List[str], source_file: str) -> Dict[str, Any]:
    return {
        "schema_version": "canada_tphs_records_v1",
        "metadata": {
            "jurisdiction": "Canada",
            "source_system": "Canada Customs Tariff TPHS",
            "source_file": source_file,
            "record_level": "10-digit statistical tariff code",
            "record_count": len(records),
            "treatment_columns": rate_columns,
            "design_note": "Compact records reference section/chapter/treatment/node context instead of repeating labels and full breadcrumbs on every record. Use *_book.json for the normalized dictionaries.",
        },
        "records": records,
    }


def write_json(payload: Any, path: Path) -> None:
    with path.open("w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


def write_jsonl(records: List[Dict[str, Any]], path: Path) -> None:
    with path.open("w", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def write_minimal_csv(records: List[Dict[str, Any]], path: Path) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["content"])
        for record in records:
            writer.writerow([record.get("minimal_content", "")])


def write_minimal_jsonl(records: List[Dict[str, Any]], path: Path) -> None:
    with path.open("w", encoding="utf-8") as fh:
        for record in records:
            obj = {
                "code": record.get("code", ""),
                "digits": record.get("digits", ""),
                "chapter": record.get("chapter", ""),
                "heading": record.get("heading", ""),
                "subheading": record.get("subheading", ""),
                "tariff_item": record.get("tariff_item", ""),
                "content": record.get("minimal_content", ""),
            }
            fh.write(json.dumps(obj, ensure_ascii=False) + "\n")


def write_rag_jsonl(records: List[Dict[str, Any]], nodes: Dict[str, Any], chapters: Dict[str, Any], sections: Dict[str, Any], treatments: Dict[str, Any], path: Path) -> None:
    with path.open("w", encoding="utf-8") as fh:
        for record in records:
            obj = {
                "code": record.get("code", ""),
                "digits": record.get("digits", ""),
                "chapter": record.get("chapter", ""),
                "heading": record.get("heading", ""),
                "subheading": record.get("subheading", ""),
                "tariff_item": record.get("tariff_item", ""),
                "uom": record.get("uom", ""),
                "rates": record.get("rates", {}),
                "rate_sources": record.get("rate_sources", {}),
                "content": rag_content(record, nodes, chapters, sections, treatments),
            }
            fh.write(json.dumps(obj, ensure_ascii=False) + "\n")


def write_table_csv(records: List[Dict[str, Any]], rate_columns: List[str], path: Path) -> None:
    fieldnames = [
        "code",
        "digits",
        "chapter",
        "heading",
        "subheading",
        "tariff_item",
        "statistical_suffix",
        "description",
        "path_json",
        "uom",
        "uom_source",
        "effective_date",
        "change",
        "sub_chap",
        "sub_chap_source",
        "footnotes_json",
        "rate_sources_json",
        "row_ids_json",
        "duplicate_row_ids_json",
    ] + rate_columns + ["minimal_content"]

    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for record in records:
            row = {k: record.get(k, "") for k in fieldnames}
            row["path_json"] = json.dumps(record.get("path", []), ensure_ascii=False)
            row["footnotes_json"] = json.dumps(record.get("footnotes", []), ensure_ascii=False)
            row["rate_sources_json"] = json.dumps(record.get("rate_sources", {}), ensure_ascii=False)
            row["row_ids_json"] = json.dumps(record.get("row_ids", []), ensure_ascii=False)
            row["duplicate_row_ids_json"] = json.dumps(record.get("duplicate_row_ids", []), ensure_ascii=False)
            for col in rate_columns:
                row[col] = record.get("rates", {}).get(col, "")
            writer.writerow(row)


def validate(records: List[Dict[str, Any]], chapters: Dict[str, Any], nodes: Dict[str, Any], duplicates: Dict[str, List[str]]) -> Dict[str, Any]:
    chapters_in_records = sorted({r.get("chapter", "") for r in records if r.get("chapter")})
    missing_chapter_context = sorted(ch for ch in chapters_in_records if ch not in chapters)
    missing_chapter_titles = sorted(ch for ch in chapters_in_records if not chapters.get(ch, {}).get("title"))
    path_missing_nodes = sorted({node_id for r in records for node_id in r.get("path", []) if node_id not in nodes})
    return {
        "records": len(records),
        "chapters_in_records": len(chapters_in_records),
        "chapters_context_loaded": len(chapters),
        "chapters_missing_context": missing_chapter_context,
        "chapters_missing_titles": missing_chapter_titles,
        "path_node_references_missing": path_missing_nodes,
        "duplicate_10_digit_code_count": len(duplicates),
        "duplicate_10_digit_codes": sorted(duplicates.keys()),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Canadian TPHS artifacts from a canonically sorted row set.")
    parser.add_argument("input_csv", type=Path, help="Path to TPHS.csv or a previously sorted TPHS CSV")
    parser.add_argument("out_stem", type=Path, help="Output stem, e.g. canada_tphs_v4")
    parser.add_argument("--chapters-json", type=Path, default=None, help="Canadian chapters JSON input")
    parser.add_argument("--sections-json", type=Path, default=None, help="Canadian sections JSON input")
    parser.add_argument("--no-sorted-original", action="store_true", help="Skip writing the canonical sorted original CSV")
    parser.add_argument("--minimal-include-group-levels", action="store_true", help="Include odd-length grouping rows in minimal breadcrumbs")
    args = parser.parse_args()

    rows, fieldnames = load_rows(args.input_csv)
    if "TARIFF" not in fieldnames:
        raise ValueError("Expected a TARIFF column in TPHS.csv")

    # Important: from here forward, only sorted_rows is used for hierarchy and outputs.
    sorted_rows = sort_rows_for_book(rows)
    sections, chapters = load_context(args.chapters_json, args.sections_json)
    enriched_rows = attach_hierarchy_paths(sorted_rows)
    rate_columns = [col for col in DEFAULT_RATE_COLUMNS if col in fieldnames]
    nodes = build_nodes(enriched_rows, chapters)
    records, duplicates = make_records(enriched_rows, rate_columns, chapters, args.minimal_include_group_levels)

    out_stem = args.out_stem
    sorted_original_path = out_stem.with_name(out_stem.name + "_sorted_original.csv")
    table_csv_path = out_stem.with_name(out_stem.name + "_table.csv")
    minimal_csv_path = out_stem.with_name(out_stem.name + "_minimal.csv")
    minimal_jsonl_path = out_stem.with_name(out_stem.name + "_minimal.jsonl")
    rag_jsonl_path = out_stem.with_name(out_stem.name + "_rag.jsonl")
    records_json_path = out_stem.with_name(out_stem.name + "_records.json")
    book_json_path = out_stem.with_name(out_stem.name + "_book.json")
    validation_path = out_stem.with_name(out_stem.name + "_validation.json")

    treatments = {col: {"code": col, "label": TREATMENT_LABELS.get(col, col)} for col in rate_columns}

    if not args.no_sorted_original:
        write_sorted_original(sorted_rows, fieldnames, sorted_original_path)
    write_table_csv(records, rate_columns, table_csv_path)
    write_minimal_csv(records, minimal_csv_path)
    write_minimal_jsonl(records, minimal_jsonl_path)
    write_rag_jsonl(records, nodes, chapters, sections, treatments, rag_jsonl_path)
    write_json(build_records_json(records, rate_columns, args.input_csv.name), records_json_path)
    write_json(
        build_book_json(
            records,
            nodes,
            sections,
            chapters,
            rate_columns,
            args.input_csv.name,
            sorted_original_path.name,
            duplicates,
        ),
        book_json_path,
    )
    write_json(validate(records, chapters, nodes, duplicates), validation_path)

    print(f"Loaded {len(rows):,} TPHS source rows")
    print("Sorted rows into canonical tariff-book order before hierarchy construction")
    if not args.no_sorted_original:
        print(f"Wrote sorted original rows → {sorted_original_path}")
    print(f"Wrote {len(records):,} compact 10-digit records → {records_json_path}")
    print(f"Wrote normalized tariff book JSON → {book_json_path}")
    print(f"Wrote table CSV → {table_csv_path}")
    print(f"Wrote minimal CSV → {minimal_csv_path}")
    print(f"Wrote minimal JSONL → {minimal_jsonl_path}")
    print(f"Wrote RAG JSONL → {rag_jsonl_path}")
    print(f"Wrote validation summary → {validation_path}")
    if duplicates:
        print(f"Detected {len(duplicates):,} duplicated 10-digit code(s): {', '.join(sorted(duplicates.keys())[:10])}")


if __name__ == "__main__":
    main()

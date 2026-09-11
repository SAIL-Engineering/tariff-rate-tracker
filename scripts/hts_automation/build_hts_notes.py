#!/usr/bin/env python3
"""Build a deterministic, citation-addressable US HTS legal-notes corpus.

The source PDFs are the public USITC reststop files. Extraction is deliberately
mechanical: cached PDF -> ``pdftotext -layout`` -> normalized lines -> a small
state machine. No OCR, model call, timestamp, or non-deterministic identifier is
part of the output.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

from usitc_native import REPO_ROOT, UA

RESTSTOP_URL = "https://hts.usitc.gov/reststop/file"
JURISDICTION = "US"
RESERVED_CHAPTERS = frozenset({77})

KIND_ORDER = {
    "gri": 0,
    "add_us_rule": 1,
    "compiler_note": 2,
    "section_note": 3,
    "chapter_note": 4,
    "subheading_note": 5,
    "add_us_note": 6,
    "statistical_note": 7,
}

CHAPTER_SECTIONS: tuple[tuple[int, int, str], ...] = (
    (1, 5, "I"), (6, 14, "II"), (15, 15, "III"), (16, 24, "IV"),
    (25, 27, "V"), (28, 38, "VI"), (39, 40, "VII"),
    (41, 43, "VIII"), (44, 46, "IX"), (47, 49, "X"),
    (50, 63, "XI"), (64, 67, "XII"), (68, 70, "XIII"),
    (71, 71, "XIV"), (72, 83, "XV"), (84, 85, "XVI"),
    (86, 89, "XVII"), (90, 92, "XVIII"), (93, 93, "XIX"),
    (94, 96, "XX"), (97, 97, "XXI"), (98, 99, "XXII"),
)

RUNNING_HEADER_RE = re.compile(
    r"^(?:Harmonized Tariff Schedule of the United States|"
    r"Annotated for Statistical Reporting Purposes)"
)
PAGE_TAG_RE = re.compile(
    r"^(?:GN p\.\d+|(?:[IVXLCDM]+|\d{1,2})(?:-[IVXLCDM]+)?-\d+|"
    r"[IVXLCDM]+\s+\d{1,2}(?:-[IVXLCDM]+)?-\d+|[IVXLCDM]+)$",
    re.IGNORECASE,
)
SECTION_RE = re.compile(r"^SECTION\s+([IVXLCDM]+)$", re.IGNORECASE)
CHAPTER_RE = re.compile(r"^CHAPTER\s+(\d{1,2})$", re.IGNORECASE)
SUBCHAPTER_RE = re.compile(r"^SUBCHAPTER\s+([IVXLCDM]+)$", re.IGNORECASE)
NOTE_START_RE = re.compile(r"^(\d+)\.\s+(.*)$")
SUBPARA_RE = re.compile(r"^\(([a-z]{1,4})\)\s*(.*)$")
TABLE_START_RE = re.compile(r"^Heading/\s*Stat\.", re.IGNORECASE)

BLOCK_KINDS = {
    "note": "notes",
    "notes": "notes",
    "subheading note": "subheading_note",
    "subheading notes": "subheading_note",
    "additional u.s. note": "add_us_note",
    "additional u.s. notes": "add_us_note",
    "u.s. note": "add_us_note",
    "u.s. notes": "add_us_note",
    "statistical note": "statistical_note",
    "statistical notes": "statistical_note",
}


@dataclass(frozen=True)
class SourceLine:
    text: str
    indent: int
    page: int


@dataclass
class PendingNote:
    kind: str
    section: str | None
    chapter: str | None
    scope: str
    note_number: str
    lines: list[SourceLine]
    source_page: int


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def chapter_section(chapter: int) -> str:
    for first, last, section in CHAPTER_SECTIONS:
        if first <= chapter <= last:
            return section
    raise ValueError(f"Chapter {chapter} is outside the HTS range")


def source_url(release: str, filename: str) -> str:
    query = urllib.parse.urlencode({"release": release, "filename": filename})
    return f"{RESTSTOP_URL}?{query}"


def release_for_revision(revision: str) -> str:
    match = re.fullmatch(r"(\d{4})_(basic|rev_(\d+))", revision)
    if not match:
        raise ValueError(
            f"Unsupported revision {revision!r}; expected YYYY_basic or YYYY_rev_N"
        )
    year, variant, number = match.groups()
    return f"{year}HTSBasic" if variant == "basic" else f"{year}HTSRev{number}"


def normalized_lines(text: str) -> list[SourceLine]:
    """Drop PDF furniture while preserving indentation used for note nesting."""
    normalized = unicodedata.normalize("NFKC", text.replace("\r\n", "\n"))
    lines: list[SourceLine] = []
    for page, page_text in enumerate(normalized.split("\f"), start=1):
        for raw in page_text.splitlines():
            raw = raw.replace("\u00a0", " ").rstrip()
            stripped = " ".join(raw.split())
            if not stripped:
                continue
            if RUNNING_HEADER_RE.match(stripped) or PAGE_TAG_RE.fullmatch(stripped):
                continue
            indent = len(raw) - len(raw.lstrip(" "))
            lines.append(SourceLine(stripped, indent, page))
    return lines


def join_fragments(parts: Iterable[str]) -> str:
    out = ""
    for raw in parts:
        part = " ".join(raw.split())
        if not part:
            continue
        if out.endswith("-") and part[0].islower():
            out = out[:-1] + part
        else:
            out = f"{out} {part}".strip()
    return re.sub(r"\s+", " ", out).strip()


def extract_references(text: str) -> dict[str, list[str]]:
    """Extract explicit section/chapter/heading/subheading cross-references."""
    def after(label: str, item: str) -> set[str]:
        results: set[str] = set()
        token = rf"(?:{item})(?![A-Za-z0-9])"
        expression = re.compile(
            rf"\b(?:{label})s?\s+({token}(?:\s*(?:,|and|or|to|through|-)"
            rf"\s*{token})*)",
            re.IGNORECASE,
        )
        item_re = re.compile(item, re.IGNORECASE)
        for match in expression.finditer(text):
            results.update(item_re.findall(match.group(1)))
        return results

    sections = {item.upper() for item in after("section", r"[IVXLCDM]+")}
    chapters = after("chapter", r"\d{1,2}")
    headings = after("heading", r"\d{4}")
    subheadings = after("subheading", r"\d{4}\.\d{2,6}(?:\.\d{1,4})?")
    return {
        "refs_sections": sorted(sections),
        "refs_chapters": sorted(chapters, key=int),
        "refs_headings": sorted(headings),
        "refs_subheadings": sorted(subheadings),
    }


def _citation(kind: str, scope: str, note: str, paragraph: str | None) -> str:
    para = f"({paragraph})" if paragraph else ""
    if kind == "gri":
        return f"GRI-{note}{para}"
    if kind == "add_us_rule":
        return f"AUSR-{note}{para}"
    if kind == "compiler_note":
        return "COMPILER-NOTE"
    prefix = {
        "section_note": "SN",
        "chapter_note": "N",
        "subheading_note": "SHN",
        "add_us_note": "AUSN",
        "statistical_note": "STN",
    }[kind]
    return f"{prefix}-{scope}-{note}{para}"


def _display_label(kind: str, scope: str, note: str, paragraph: str | None) -> str:
    suffix = f"({paragraph})" if paragraph else ""
    labels = {
        "gri": f"General Rule of Interpretation {note}{suffix}",
        "add_us_rule": f"Additional U.S. Rule of Interpretation {note}{suffix}",
        "compiler_note": "Compiler's note",
        "section_note": f"Section {scope}, Note {note}{suffix}",
        "chapter_note": f"Chapter {scope}, Note {note}{suffix}",
        "subheading_note": f"Chapter {scope}, Subheading Note {note}{suffix}",
        "add_us_note": (
            f"{'Section' if scope.isalpha() else 'Chapter'} {scope}, "
            f"Additional U.S. Note {note}{suffix}"
        ),
        "statistical_note": (
            f"{'Section' if scope.isalpha() else 'Chapter'} {scope}, "
            f"Statistical Note {note}{suffix}"
        ),
    }
    return labels[kind]


def make_record(
    *,
    revision: str,
    kind: str,
    scope: str,
    note_number: str,
    paragraph: str | None,
    chunk_text: str,
    section: str | None,
    chapter: str | None,
    url: str,
    pdf_sha256: str,
    page: int,
) -> dict[str, Any]:
    cite_id = _citation(kind, scope, note_number, paragraph)
    para_id = f"|{paragraph}" if paragraph else ""
    record_id = (
        f"{JURISDICTION}|{revision}|{kind}|{scope}|{note_number}{para_id}"
    )
    references = extract_references(chunk_text)
    return {
        "_id": record_id,
        "kind": kind,
        "section": section,
        "chapter": chapter,
        "note_number": note_number,
        "paragraph": f"({paragraph})" if paragraph else None,
        "cite_id": cite_id,
        "chunk_text": chunk_text,
        "display_text": (
            f"[{cite_id}] {_display_label(kind, scope, note_number, paragraph)}: "
            f"{chunk_text}"
        ),
        **references,
        "revision": revision,
        "jurisdiction": JURISDICTION,
        "source_url": url,
        "source_sha256": pdf_sha256,
        "content_sha256": sha256_bytes(chunk_text.encode("utf-8")),
        "page": page,
    }


def _direct_paragraphs(lines: Sequence[SourceLine]) -> list[tuple[int, str]]:
    candidates: list[tuple[int, int, str]] = []
    for index, line in enumerate(lines):
        match = SUBPARA_RE.match(line.text)
        if match:
            candidates.append((index, line.indent, match.group(1).lower()))
    if not candidates:
        return []
    direct_indent = min(indent for _, indent, _ in candidates)
    direct = [
        (index, label)
        for index, indent, label in candidates
        if indent <= direct_indent + 2
    ]
    # A few legal notes contain multiple separately introduced lists that reuse
    # (a), (b), etc. Those subdivisions have no unambiguous cite ID, so retain
    # the complete numbered-note record instead of inventing a legal citation.
    labels = [label for _, label in direct]
    return [] if len(labels) != len(set(labels)) else direct


def records_for_note(
    note: PendingNote,
    *,
    revision: str,
    url: str,
    pdf_sha256: str,
    force_paragraphs: bool = False,
) -> list[dict[str, Any]]:
    full_text = join_fragments(line.text for line in note.lines)
    if not full_text:
        return []
    records = [make_record(
        revision=revision,
        kind=note.kind,
        scope=note.scope,
        note_number=note.note_number,
        paragraph=None,
        chunk_text=full_text,
        section=note.section,
        chapter=note.chapter,
        url=url,
        pdf_sha256=pdf_sha256,
        page=note.source_page,
    )]

    paragraph_starts = _direct_paragraphs(note.lines)
    is_long_list = len(paragraph_starts) >= 3 or len(full_text) >= 600
    if not paragraph_starts or not (force_paragraphs or is_long_list):
        return records

    lead_in = join_fragments(
        line.text for line in note.lines[:paragraph_starts[0][0]]
    )
    for position, (start, label) in enumerate(paragraph_starts):
        end = (
            paragraph_starts[position + 1][0]
            if position + 1 < len(paragraph_starts)
            else len(note.lines)
        )
        first_match = SUBPARA_RE.match(note.lines[start].text)
        assert first_match is not None
        paragraph_body = join_fragments(
            [first_match.group(2), *(line.text for line in note.lines[start + 1:end])]
        )
        chunk = f"({label}) {paragraph_body}".strip()
        if lead_in:
            chunk = f"{lead_in} {chunk}"
        records.append(make_record(
            revision=revision,
            kind=note.kind,
            scope=note.scope,
            note_number=note.note_number,
            paragraph=label,
            chunk_text=chunk,
            section=note.section,
            chapter=note.chapter,
            url=url,
            pdf_sha256=pdf_sha256,
            page=note.lines[start].page,
        ))
    return records


def _numbered_notes(
    lines: Sequence[SourceLine],
    *,
    kind: str,
    scope: str,
    section: str | None,
    chapter: str | None,
) -> list[PendingNote]:
    notes: list[PendingNote] = []
    current: PendingNote | None = None
    for line in lines:
        match = NOTE_START_RE.match(line.text)
        if match:
            if current:
                notes.append(current)
            first = SourceLine(match.group(2), line.indent + 5, line.page)
            current = PendingNote(
                kind, section, chapter, scope, match.group(1), [first], line.page
            )
        elif current:
            current.lines.append(line)
    if current:
        notes.append(current)
    return notes


def parse_gri_text(
    text: str,
    *,
    revision: str,
    url: str,
    pdf_sha256: str,
) -> list[dict[str, Any]]:
    lines = normalized_lines(text)
    general_index = next(
        (i for i, line in enumerate(lines) if line.text == "GENERAL RULES OF INTERPRETATION"),
        None,
    )
    additional_index = next(
        (i for i, line in enumerate(lines)
         if line.text == "ADDITIONAL U.S. RULES OF INTERPRETATION"),
        None,
    )
    if general_index is None or additional_index is None:
        raise ValueError("GRI PDF is missing an expected rules heading")

    compiler_index = next(
        (i for i, line in enumerate(lines)
         if line.text.upper().startswith("[COMPILER'S NOTE:")),
        len(lines),
    )
    records: list[dict[str, Any]] = []
    for note in _numbered_notes(
        lines[general_index + 1:additional_index],
        kind="gri", scope="GRI", section=None, chapter=None,
    ):
        records.extend(records_for_note(
            note, revision=revision, url=url, pdf_sha256=pdf_sha256,
            force_paragraphs=True,
        ))
    for note in _numbered_notes(
        lines[additional_index + 1:compiler_index],
        kind="add_us_rule", scope="GRI", section=None, chapter=None,
    ):
        records.extend(records_for_note(
            note, revision=revision, url=url, pdf_sha256=pdf_sha256,
            force_paragraphs=True,
        ))

    if compiler_index < len(lines):
        compiler_lines = lines[compiler_index:]
        compiler_text = join_fragments(line.text for line in compiler_lines)
        compiler_text = re.sub(
            r"^\[COMPILER'S NOTE:\s*", "", compiler_text, flags=re.IGNORECASE
        ).rstrip("]").strip()
        records.append(make_record(
            revision=revision,
            kind="compiler_note",
            scope="GRI",
            note_number="compiler",
            paragraph=None,
            chunk_text=compiler_text,
            section=None,
            chapter=None,
            url=url,
            pdf_sha256=pdf_sha256,
            page=compiler_lines[0].page,
        ))
    return records


def _block_heading(text: str) -> tuple[str | None, bool]:
    lowered = text.lower().strip().rstrip(":").strip()
    continuation = lowered.endswith("(con.)")
    if continuation:
        lowered = lowered[:-6].strip()
    return BLOCK_KINDS.get(lowered), continuation


def parse_chapter_text(
    text: str,
    *,
    expected_chapter: int,
    revision: str,
    url: str,
    pdf_sha256: str,
) -> list[dict[str, Any]]:
    lines = normalized_lines(text)
    expected_section = chapter_section(expected_chapter)
    current_section = expected_section
    current_chapter: str | None = None
    current_subchapter: str | None = None
    current_kind: str | None = None
    current_note: PendingNote | None = None
    records: list[dict[str, Any]] = []

    def flush() -> None:
        nonlocal current_note
        if current_note:
            records.extend(records_for_note(
                current_note,
                revision=revision,
                url=url,
                pdf_sha256=pdf_sha256,
            ))
            current_note = None

    for line in lines:
        section_match = SECTION_RE.fullmatch(line.text)
        chapter_match = CHAPTER_RE.fullmatch(line.text)
        subchapter_match = SUBCHAPTER_RE.fullmatch(line.text)

        if section_match:
            flush()
            current_section = section_match.group(1).upper()
            current_kind = None
            continue
        if chapter_match:
            flush()
            found_chapter = int(chapter_match.group(1))
            if found_chapter != expected_chapter:
                raise ValueError(
                    f"Expected Chapter {expected_chapter}, found Chapter {found_chapter}"
                )
            current_chapter = str(found_chapter)
            current_subchapter = None
            current_kind = None
            continue
        if subchapter_match and expected_chapter == 98:
            flush()
            current_subchapter = subchapter_match.group(1).upper()
            current_kind = None
            continue
        if TABLE_START_RE.match(line.text):
            flush()
            current_kind = None
            if expected_chapter != 98:
                break
            continue

        block_kind, continuation = _block_heading(line.text)
        if block_kind:
            flush()
            if continuation and current_kind:
                continue
            if block_kind == "notes":
                current_kind = (
                    "section_note" if current_chapter is None else "chapter_note"
                )
            else:
                current_kind = block_kind
            continue
        if current_kind is None:
            continue

        match = NOTE_START_RE.match(line.text) if line.indent <= 7 else None
        if match:
            flush()
            if current_chapter is None:
                scope = current_section
            elif expected_chapter == 98 and current_subchapter:
                scope = f"98.{current_subchapter}"
            else:
                scope = str(expected_chapter)
            first = SourceLine(match.group(2), line.indent + 5, line.page)
            current_note = PendingNote(
                kind=current_kind,
                section=current_section,
                chapter=str(expected_chapter),
                scope=scope,
                note_number=match.group(1),
                lines=[first],
                source_page=line.page,
            )
        elif current_note:
            current_note.lines.append(line)

    flush()
    if current_chapter != str(expected_chapter):
        raise ValueError(f"Chapter {expected_chapter} heading was not found")
    return records


def ensure_pdftotext() -> tuple[str, str]:
    executable = shutil.which("pdftotext")
    if not executable:
        raise RuntimeError(
            "pdftotext is required to build HTS notes. Install poppler-utils "
            "and ensure pdftotext is on PATH."
        )
    version_run = subprocess.run(
        [executable, "-v"], capture_output=True, text=True, check=False
    )
    version = (version_run.stderr or version_run.stdout).splitlines()
    return executable, (version[0].strip() if version else "pdftotext (unknown version)")


def extract_pdf_text(executable: str, pdf_path: Path, text_path: Path) -> str:
    result = subprocess.run(
        [executable, "-layout", str(pdf_path), str(text_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"pdftotext failed for {pdf_path}: "
            f"{(result.stderr or result.stdout).strip()}"
        )
    return text_path.read_text(encoding="utf-8")


def download_pdf(url: str, destination: Path, attempts: int = 4) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    temporary.unlink(missing_ok=True)
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            request = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read()
            if not data.startswith(b"%PDF"):
                raise ValueError("response is not a PDF")
            temporary.write_bytes(data)
            temporary.replace(destination)
            return
        except Exception as exc:  # noqa: BLE001 - retries report final cause
            last_error = exc
            temporary.unlink(missing_ok=True)
            if attempt < attempts:
                time.sleep(2 ** (attempt - 1))
    raise RuntimeError(f"Failed to download {url} after {attempts} attempts: {last_error}")


def _read_json(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8", newline="\n")
    temporary.replace(path)


def _record_sort_key(record: dict[str, Any]) -> tuple[Any, ...]:
    scope = str(record["_id"]).split("|")[3]
    return (
        KIND_ORDER[record["kind"]],
        scope,
        int(record["note_number"]) if str(record["note_number"]).isdigit() else 9999,
        record["paragraph"] or "",
        record["_id"],
    )


def build_corpus(revision: str, release: str, out_dir: Path) -> dict[str, Any]:
    out_dir.mkdir(parents=True, exist_ok=True)
    prefix = f"us_{revision}.notes"
    manifest_path = out_dir / f"{prefix}.manifest.json"
    previous_manifest = _read_json(manifest_path)
    previous_shas = (
        previous_manifest.get("pdf_sha256", {})
        if previous_manifest.get("release") == release
        else {}
    )
    pdftotext, poppler_version = ensure_pdftotext()

    sources: list[tuple[str, str, int | None]] = [
        ("gri", "General Rules of Interpretation", None),
        *[(f"chapter_{number:02d}", f"Chapter {number}", number)
          for number in range(1, 99)],
    ]
    records: list[dict[str, Any]] = []
    pdf_shas: dict[str, str] = {}
    source_urls: dict[str, str] = {}
    parsed_chapters: list[int] = []

    for position, (key, filename, chapter) in enumerate(sources, start=1):
        url = source_url(release, filename)
        source_urls[key] = url
        if chapter in RESERVED_CHAPTERS:
            print(f"[{position:02d}/{len(sources)}] reserved {filename} (no source PDF)")
            parsed_chapters.append(chapter)
            continue
        pdf_path = out_dir / f"{key}.pdf"
        text_path = out_dir / f"{key}.txt"
        checksum_path = out_dir / f"{key}.pdf.sha256"
        cached_sha = sha256_file(pdf_path) if pdf_path.is_file() else None
        checksum_sha = (
            checksum_path.read_text(encoding="ascii").strip()
            if checksum_path.is_file()
            else None
        )
        expected_sha = previous_shas.get(key) or checksum_sha
        is_valid_unindexed_cache = bool(
            cached_sha
            and not expected_sha
            and pdf_path.read_bytes()[:4] == b"%PDF"
        )
        if not cached_sha or not (
            cached_sha == expected_sha or is_valid_unindexed_cache
        ):
            print(f"[{position:02d}/{len(sources)}] downloading {filename}")
            download_pdf(url, pdf_path)
            cached_sha = sha256_file(pdf_path)
        else:
            print(f"[{position:02d}/{len(sources)}] cached {filename}")

        assert cached_sha is not None
        _write_text(checksum_path, f"{cached_sha}\n")
        pdf_shas[key] = cached_sha
        extracted = extract_pdf_text(pdftotext, pdf_path, text_path)
        if chapter is None:
            parsed = parse_gri_text(
                extracted,
                revision=revision,
                url=url,
                pdf_sha256=cached_sha,
            )
        else:
            parsed = parse_chapter_text(
                extracted,
                expected_chapter=chapter,
                revision=revision,
                url=url,
                pdf_sha256=cached_sha,
            )
            parsed_chapters.append(chapter)
        records.extend(parsed)

    records.sort(key=_record_sort_key)
    ids = [record["_id"] for record in records]
    citations = [record["cite_id"] for record in records]
    if len(ids) != len(set(ids)):
        duplicates = sorted(key for key, count in Counter(ids).items() if count > 1)
        raise ValueError(f"Duplicate note record IDs: {duplicates[:10]}")
    if len(citations) != len(set(citations)):
        duplicates = sorted(
            key for key, count in Counter(citations).items() if count > 1
        )
        raise ValueError(f"Duplicate cite IDs: {duplicates[:10]}")

    families = {
        "gri": {"gri", "add_us_rule", "compiler_note"},
        "section": {"section_note"},
        "chapter": {
            "chapter_note", "subheading_note", "add_us_note", "statistical_note"
        },
    }
    artifact_shas: dict[str, str] = {}
    for family, kinds in families.items():
        path = out_dir / f"{prefix}.{family}.jsonl"
        # Pinecone metadata takes a string, number, boolean or list of strings —
        # an explicit null is rejected outright ("Invalid type for field
        # 'paragraph' … got 'null'"), so absent scope fields are omitted rather
        # than written as None. The sidecar below keeps the full shape.
        payload = "".join(
            json.dumps(
                {k: v for k, v in record.items() if v is not None},
                ensure_ascii=False, sort_keys=True, separators=(",", ":"),
            )
            + "\n"
            for record in records
            if record["kind"] in kinds
        )
        _write_text(path, payload)
        artifact_shas[path.name] = sha256_file(path)

    sidecar_path = out_dir / f"{prefix}.json"
    sidecar = {record["cite_id"]: record for record in records}
    _write_text(
        sidecar_path,
        json.dumps(sidecar, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
    )
    artifact_shas[sidecar_path.name] = sha256_file(sidecar_path)

    counts_by_kind = Counter(record["kind"] for record in records)
    counts_by_section = Counter(
        record["section"] for record in records if record["section"]
    )
    counts_by_chapter = Counter(
        record["chapter"] for record in records if record["chapter"]
    )
    manifest = {
        "schema_version": 1,
        "jurisdiction": JURISDICTION,
        "revision": revision,
        "release": release,
        "poppler_version": poppler_version,
        "parsed_gri": any(record["kind"] == "gri" for record in records),
        "parsed_chapters": parsed_chapters,
        "reserved_chapters": sorted(RESERVED_CHAPTERS),
        "counts": {
            "total": len(records),
            "by_kind": dict(sorted(counts_by_kind.items())),
            "by_section": dict(sorted(counts_by_section.items())),
            "by_chapter": dict(
                sorted(counts_by_chapter.items(), key=lambda item: int(item[0]))
            ),
        },
        "pdf_sha256": dict(sorted(pdf_shas.items())),
        "source_urls": dict(sorted(source_urls.items())),
        "artifact_sha256": dict(sorted(artifact_shas.items())),
    }
    _write_text(
        manifest_path,
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
    )
    print(
        f"Built {len(records)} records from GRI + {len(parsed_chapters)} chapters "
        f"in {out_dir}"
    )
    return manifest


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True, help="e.g. 2026_rev_18")
    parser.add_argument(
        "--release",
        help="USITC release name; derived from --revision when omitted",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        help="default: data/hts_notes/<revision>",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        release = args.release or release_for_revision(args.revision)
        out_dir = args.out_dir or REPO_ROOT / "data" / "hts_notes" / args.revision
        build_corpus(args.revision, release, out_dir.resolve())
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

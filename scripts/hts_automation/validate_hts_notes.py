#!/usr/bin/env python3
"""Validate a built US HTS legal-notes corpus before publication.

The checks are deliberately independent of Pinecone. They prove extraction
coverage, stable legal anchors, family partitioning, source/content checksums
and bounded revision drift before any external write is allowed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any, Iterable, Sequence

ROMAN_SECTIONS = (
    "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI",
    "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX",
    "XXI", "XXII",
)
DEFAULT_NO_NOTES_CHAPTERS = frozenset({77})
FAMILY_KINDS = {
    "gri": frozenset({"gri", "add_us_rule", "compiler_note"}),
    "section": frozenset({"section_note"}),
    "chapter": frozenset({
        "chapter_note", "subheading_note", "add_us_note", "statistical_note",
    }),
}
REQUIRED_GRI_CITES = frozenset({
    "GRI-1", "GRI-2", "GRI-2(a)", "GRI-2(b)", "GRI-3", "GRI-3(a)",
    "GRI-3(b)", "GRI-3(c)", "GRI-4", "GRI-5", "GRI-5(a)", "GRI-5(b)",
    "GRI-6", "AUSR-1(a)", "AUSR-1(b)", "AUSR-1(c)", "AUSR-1(d)",
})
REQUIRED_NOTE_CITES = frozenset({
    "SN-XI-1", "AUSN-61-1", "N-84-1", "N-95-1",
})


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot read {label} {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"{label} {path} must contain a JSON object")
    return value


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    try:
        with path.open(encoding="utf-8") as handle:
            for number, line in enumerate(handle, start=1):
                if not line.strip():
                    continue
                value = json.loads(line)
                if not isinstance(value, dict):
                    raise ValueError(f"line {number} is not an object")
                records.append(value)
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        raise ValueError(f"cannot read JSONL {path}: {exc}") from exc
    return records


def parse_revision(value: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d{4})_(?:basic|rev_(\d+))", value)
    if not match:
        raise ValueError(f"invalid revision {value!r}")
    return int(match.group(1)), int(match.group(2) or 0)


def find_previous_manifest(current: Path, revision: str) -> Path | None:
    """Return the newest committed/cache manifest older than ``revision``."""
    current_key = parse_revision(revision)
    candidates: list[tuple[tuple[int, int], Path]] = []
    for path in current.parent.parent.glob("*/us_*.notes.manifest.json"):
        if path == current:
            continue
        try:
            manifest = load_json_object(path, "manifest")
            key = parse_revision(str(manifest.get("revision", "")))
        except ValueError:
            continue
        if key < current_key:
            candidates.append((key, path))
    return max(candidates, default=(None, None), key=lambda item: item[0])[1]


def _pct(count: int, base: int) -> float:
    return 0.0 if base == 0 else count * 100.0 / base


def _delta_errors(
    current_ids: set[str],
    previous_ids: set[str],
    max_removed_pct: float,
    max_added_pct: float,
) -> tuple[list[str], str]:
    removed = previous_ids - current_ids
    added = current_ids - previous_ids
    removed_pct = _pct(len(removed), len(previous_ids))
    added_pct = _pct(len(added), len(previous_ids))
    errors = []
    if removed_pct > max_removed_pct:
        errors.append(
            f"removed {len(removed)}/{len(previous_ids)} cite IDs "
            f"({removed_pct:.2f}%) > {max_removed_pct:.2f}%"
        )
    if added_pct > max_added_pct:
        errors.append(
            f"added {len(added)}/{len(previous_ids)} cite IDs "
            f"({added_pct:.2f}%) > {max_added_pct:.2f}%"
        )
    summary = (
        f"exact delta: +{len(added)} ({added_pct:.2f}%), "
        f"-{len(removed)} ({removed_pct:.2f}%)"
    )
    return errors, summary


def _count_delta_errors(
    current_total: int,
    previous_total: int,
    max_removed_pct: float,
    max_added_pct: float,
) -> tuple[list[str], str]:
    removed = max(0, previous_total - current_total)
    added = max(0, current_total - previous_total)
    removed_pct = _pct(removed, previous_total)
    added_pct = _pct(added, previous_total)
    errors = []
    if removed_pct > max_removed_pct:
        errors.append(
            f"net record removal {removed}/{previous_total} ({removed_pct:.2f}%) "
            f"> {max_removed_pct:.2f}%"
        )
    if added_pct > max_added_pct:
        errors.append(
            f"net record addition {added}/{previous_total} ({added_pct:.2f}%) "
            f"> {max_added_pct:.2f}%"
        )
    summary = (
        f"count delta: {previous_total} -> {current_total} "
        f"(+{added}, -{removed}); exact prior sidecar unavailable"
    )
    return errors, summary


def validate_notes(
    manifest_path: Path,
    sidecar_path: Path,
    *,
    previous_sidecar: Path | None = None,
    previous_manifest: Path | None = None,
    max_removed_pct: float = 5.0,
    max_added_pct: float = 10.0,
    no_notes_chapters: Iterable[int] = DEFAULT_NO_NOTES_CHAPTERS,
) -> tuple[list[str], list[str]]:
    """Return ``(errors, informational summaries)`` without exiting."""
    errors: list[str] = []
    info: list[str] = []
    try:
        manifest = load_json_object(manifest_path, "manifest")
        sidecar = load_json_object(sidecar_path, "sidecar")
    except ValueError as exc:
        return [str(exc)], info

    revision = str(manifest.get("revision", ""))
    if manifest.get("schema_version") != 1:
        errors.append(f"unsupported schema_version {manifest.get('schema_version')!r}")
    if manifest.get("jurisdiction") != "US":
        errors.append(f"manifest jurisdiction must be US, got {manifest.get('jurisdiction')!r}")
    try:
        parse_revision(revision)
    except ValueError as exc:
        errors.append(str(exc))

    records = list(sidecar.values())
    cite_ids = set(sidecar)
    if not records:
        errors.append("sidecar contains no records")
    for cite_id, record in sidecar.items():
        if not isinstance(record, dict):
            errors.append(f"{cite_id}: sidecar value is not an object")
            continue
        if record.get("cite_id") != cite_id:
            errors.append(f"{cite_id}: record cite_id is {record.get('cite_id')!r}")
        if record.get("jurisdiction") != "US" or record.get("revision") != revision:
            errors.append(f"{cite_id}: jurisdiction/revision does not match manifest")
        chunk = record.get("chunk_text")
        if not isinstance(chunk, str) or not chunk.strip():
            errors.append(f"{cite_id}: chunk_text is empty")
        elif hashlib.sha256(chunk.encode("utf-8")).hexdigest() != record.get("content_sha256"):
            errors.append(f"{cite_id}: content_sha256 does not match chunk_text")
        if "heading/ stat." in str(chunk).lower():
            errors.append(f"{cite_id}: tariff-table text leaked into note content")
        source_sha = str(record.get("source_sha256", ""))
        if not re.fullmatch(r"[0-9a-f]{64}", source_sha):
            errors.append(f"{cite_id}: source_sha256 is not a lowercase SHA-256")

    manifest_total = int((manifest.get("counts") or {}).get("total") or 0)
    if manifest_total != len(records):
        errors.append(f"manifest total {manifest_total} != sidecar records {len(records)}")

    expected_counts = {
        "by_kind": Counter(str(r.get("kind")) for r in records if isinstance(r, dict)),
        "by_section": Counter(str(r.get("section")) for r in records
                              if isinstance(r, dict) and r.get("section")),
        "by_chapter": Counter(str(r.get("chapter")) for r in records
                              if isinstance(r, dict) and r.get("chapter")),
    }
    manifest_counts = manifest.get("counts") or {}
    for key, actual in expected_counts.items():
        declared = {str(k): int(v) for k, v in (manifest_counts.get(key) or {}).items()}
        if declared != dict(actual):
            errors.append(f"manifest {key} does not match sidecar")

    pdf_shas = set((manifest.get("pdf_sha256") or {}).values())
    if pdf_shas:
        malformed_pdf_shas = [value for value in pdf_shas
                              if not re.fullmatch(r"[0-9a-f]{64}", str(value))]
        if malformed_pdf_shas:
            errors.append("manifest pdf_sha256 contains malformed values")
        unknown_sources = [str(record.get("cite_id")) for record in records
                           if record.get("source_sha256") not in pdf_shas]
        if unknown_sources:
            errors.append(
                f"{len(unknown_sources)} records reference a source SHA absent from manifest"
            )

    artifact_shas = manifest.get("artifact_sha256") or {}
    family_ids: set[str] = set()
    for family, kinds in FAMILY_KINDS.items():
        path = sidecar_path.with_name(sidecar_path.name.replace(".json", f".{family}.jsonl"))
        if not path.is_file():
            errors.append(f"missing {family} family JSONL: {path}")
            continue
        expected_sha = artifact_shas.get(path.name)
        if expected_sha != sha256_file(path):
            errors.append(f"{path.name}: artifact SHA-256 does not match manifest")
        try:
            family_records = load_jsonl(path)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        ids = [str(record.get("cite_id", "")) for record in family_records]
        if len(ids) != len(set(ids)):
            errors.append(f"{path.name}: duplicate cite IDs")
        wrong = [record.get("cite_id") for record in family_records
                 if record.get("kind") not in kinds]
        if wrong:
            errors.append(f"{path.name}: {len(wrong)} records belong to another family")
        family_ids.update(ids)
    if family_ids != cite_ids:
        errors.append(
            f"family JSONL union differs from sidecar "
            f"(missing={len(cite_ids - family_ids)}, extra={len(family_ids - cite_ids)})"
        )

    expected_sidecar_sha = artifact_shas.get(sidecar_path.name)
    if expected_sidecar_sha != sha256_file(sidecar_path):
        errors.append(f"{sidecar_path.name}: artifact SHA-256 does not match manifest")

    missing_gri = sorted(REQUIRED_GRI_CITES - cite_ids)
    if missing_gri:
        errors.append(f"missing required GRI/AUSR cites: {missing_gri}")
    missing_notes = sorted(REQUIRED_NOTE_CITES - cite_ids)
    if missing_notes:
        errors.append(f"missing legal-note goldens: {missing_notes}")

    ch39 = sidecar.get("N-39-2")
    if not isinstance(ch39, dict) or "does not cover" not in str(ch39.get("chunk_text", "")).lower():
        errors.append("N-39-2 must contain the Chapter 39 'does not cover' exclusion")
    ch39_paragraphs = sum(cite.startswith("N-39-2(") for cite in cite_ids)
    if ch39_paragraphs < 20:
        errors.append(f"N-39-2 has {ch39_paragraphs} paragraphs; expected at least 20")

    parsed_chapters = {int(value) for value in manifest.get("parsed_chapters") or []}
    missing_parsed = set(range(1, 98)) - parsed_chapters
    if missing_parsed:
        errors.append(f"chapters not parsed in 1-97: {sorted(missing_parsed)}")
    permitted_empty = set(no_notes_chapters)
    chapter_counts = expected_counts["by_chapter"]
    empty = [chapter for chapter in range(1, 98)
             if chapter not in permitted_empty and chapter_counts[str(chapter)] == 0]
    if empty:
        errors.append(f"chapters with no records and not allowlisted: {empty}")
    declared_reserved = {int(value) for value in manifest.get("reserved_chapters") or []}
    if not declared_reserved <= permitted_empty:
        errors.append(
            f"manifest reserved chapters are not in the explicit no-notes allowlist: "
            f"{sorted(declared_reserved - permitted_empty)}"
        )

    # Not every HTS section defines section-level notes. A section is present
    # when its own notes or any of its chapter-scoped notes carry the section
    # anchor; requiring a fabricated section_note for all 22 would reject the
    # real schedule (while SN-XI-1 above still proves section-note parsing).
    missing_sections = [section for section in ROMAN_SECTIONS
                        if expected_counts["by_section"][section] == 0]
    if missing_sections:
        errors.append(f"sections with no records: {missing_sections}")

    if previous_sidecar:
        try:
            previous = load_json_object(previous_sidecar, "previous sidecar")
            delta_errors, summary = _delta_errors(
                cite_ids, set(previous), max_removed_pct, max_added_pct,
            )
            errors.extend(delta_errors)
            info.append(summary)
        except ValueError as exc:
            errors.append(str(exc))
    elif previous_manifest:
        try:
            old = load_json_object(previous_manifest, "previous manifest")
            previous_total = int((old.get("counts") or {}).get("total") or 0)
            delta_errors, summary = _count_delta_errors(
                len(records), previous_total, max_removed_pct, max_added_pct,
            )
            errors.extend(delta_errors)
            info.append(summary)
        except (TypeError, ValueError) as exc:
            errors.append(f"cannot compare previous manifest: {exc}")
    else:
        info.append("revision delta: no previous notes corpus; recording initial baseline")

    return errors, info


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--sidecar", required=True, type=Path)
    parser.add_argument("--previous-manifest", type=Path,
                        help="previous revision manifest (auto-discovered when omitted)")
    parser.add_argument("--previous-sidecar", type=Path,
                        help="previous revision sidecar for exact cite-ID deltas")
    parser.add_argument("--max-removed-pct", type=float, default=5.0)
    parser.add_argument("--max-added-pct", type=float, default=10.0)
    parser.add_argument("--no-notes-chapter", type=int, action="append", default=None,
                        help="explicit chapter with no source/notes; repeat as needed (default: 77)")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.max_removed_pct < 0 or args.max_added_pct < 0:
        print("ERROR: delta thresholds cannot be negative", file=sys.stderr)
        return 1

    try:
        manifest = load_json_object(args.manifest, "manifest")
        revision = str(manifest.get("revision", ""))
        previous_manifest = args.previous_manifest or find_previous_manifest(
            args.manifest, revision,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    previous_sidecar = args.previous_sidecar
    if previous_sidecar is None and previous_manifest:
        candidate = previous_manifest.with_name(
            previous_manifest.name.replace(".manifest.json", ".json")
        )
        if candidate.is_file():
            previous_sidecar = candidate

    errors, info = validate_notes(
        args.manifest,
        args.sidecar,
        previous_sidecar=previous_sidecar,
        previous_manifest=None if previous_sidecar else previous_manifest,
        max_removed_pct=args.max_removed_pct,
        max_added_pct=args.max_added_pct,
        no_notes_chapters=(
            args.no_notes_chapter
            if args.no_notes_chapter is not None
            else DEFAULT_NO_NOTES_CHAPTERS
        ),
    )
    for message in info:
        print(f"[delta] {message}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        print(f"Validation failed with {len(errors)} error(s).", file=sys.stderr)
        return 1
    print(f"Validation passed: {len(load_json_object(args.sidecar, 'sidecar')):,} records")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

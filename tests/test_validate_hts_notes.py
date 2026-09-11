from __future__ import annotations

import hashlib
import json
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "hts_automation"))

from validate_hts_notes import (  # noqa: E402
    FAMILY_KINDS,
    REQUIRED_GRI_CITES,
    ROMAN_SECTIONS,
    validate_notes,
)

SHA = "f" * 64


def _record(
    cite_id: str,
    kind: str,
    revision: str,
    *,
    section: str | None = None,
    chapter: str | None = None,
    text: str = "Legal note text.",
) -> dict:
    return {
        "_id": f"US|{revision}|{kind}|{cite_id}",
        "kind": kind,
        "section": section,
        "chapter": chapter,
        "note_number": "1",
        "paragraph": None,
        "cite_id": cite_id,
        "chunk_text": text,
        "display_text": f"[{cite_id}] {text}",
        "refs_sections": [],
        "refs_chapters": [],
        "refs_headings": [],
        "refs_subheadings": [],
        "revision": revision,
        "jurisdiction": "US",
        "source_url": "https://hts.usitc.gov/reststop/file?fixture=1",
        "source_sha256": SHA,
        "content_sha256": hashlib.sha256(text.encode()).hexdigest(),
        "page": 1,
    }


def _complete_records(revision: str) -> dict[str, dict]:
    records: dict[str, dict] = {}
    for cite in REQUIRED_GRI_CITES:
        kind = "add_us_rule" if cite.startswith("AUSR") else "gri"
        records[cite] = _record(cite, kind, revision)

    for chapter in range(1, 98):
        if chapter == 77:
            continue
        cite = f"N-{chapter}-999"
        records[cite] = _record(cite, "chapter_note", revision, chapter=str(chapter))

    records["N-39-2"] = _record(
        "N-39-2", "chapter_note", revision, chapter="39",
        text="This chapter does not cover the following articles.",
    )
    for index in range(20):
        label = chr(ord("a") + index)
        cite = f"N-39-2({label})"
        records[cite] = _record(cite, "chapter_note", revision, chapter="39")
    records["AUSN-61-1"] = _record(
        "AUSN-61-1", "add_us_note", revision, chapter="61",
    )
    records["N-84-1"] = _record("N-84-1", "chapter_note", revision, chapter="84")
    records["N-95-1"] = _record("N-95-1", "chapter_note", revision, chapter="95")

    for section in ROMAN_SECTIONS:
        cite = "SN-XI-1" if section == "XI" else f"SN-{section}-999"
        records[cite] = _record(cite, "section_note", revision, section=section)
    return records


def _write_corpus(root: Path, revision: str, records: dict[str, dict]):
    root.mkdir(parents=True)
    prefix = f"us_{revision}.notes"
    sidecar_path = root / f"{prefix}.json"
    sidecar_path.write_text(
        json.dumps(records, sort_keys=True, indent=2) + "\n", encoding="utf-8",
    )

    artifact_sha = {}
    for family, kinds in FAMILY_KINDS.items():
        path = root / f"{prefix}.{family}.jsonl"
        payload = "".join(
            json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n"
            for record in records.values()
            if record["kind"] in kinds
        )
        path.write_text(payload, encoding="utf-8")
        artifact_sha[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    artifact_sha[sidecar_path.name] = hashlib.sha256(sidecar_path.read_bytes()).hexdigest()

    values = list(records.values())
    counts = {
        "total": len(values),
        "by_kind": dict(Counter(record["kind"] for record in values)),
        "by_section": dict(Counter(record["section"] for record in values if record["section"])),
        "by_chapter": dict(Counter(record["chapter"] for record in values if record["chapter"])),
    }
    manifest = {
        "schema_version": 1,
        "jurisdiction": "US",
        "revision": revision,
        "parsed_chapters": list(range(1, 98)),
        "reserved_chapters": [77],
        "counts": counts,
        "artifact_sha256": artifact_sha,
    }
    manifest_path = root / f"{prefix}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    return manifest_path, sidecar_path


def test_validator_accepts_complete_structural_and_legal_goldens(tmp_path):
    manifest, sidecar = _write_corpus(
        tmp_path / "2026_rev_18", "2026_rev_18", _complete_records("2026_rev_18"),
    )

    errors, _info = validate_notes(manifest, sidecar)

    assert errors == []


def test_section_coverage_does_not_require_nonexistent_section_notes(tmp_path):
    records = _complete_records("2026_rev_18")
    del records["SN-III-999"]
    records["N-3-999"]["section"] = "III"
    manifest, sidecar = _write_corpus(
        tmp_path / "2026_rev_18", "2026_rev_18", records,
    )

    errors, _info = validate_notes(manifest, sidecar)

    assert errors == []


def test_validator_rejects_table_bleed_and_missing_required_cite(tmp_path):
    records = _complete_records("2026_rev_18")
    del records["N-95-1"]
    records["N-84-1"] = _record(
        "N-84-1", "chapter_note", "2026_rev_18", chapter="84",
        text="Heading/ Stat. Unit Rates of Duty",
    )
    manifest, sidecar = _write_corpus(tmp_path / "2026_rev_18", "2026_rev_18", records)

    errors, _info = validate_notes(manifest, sidecar)

    assert any("tariff-table text leaked" in error for error in errors)
    assert any("N-95-1" in error for error in errors)


def test_validator_blocks_exact_cite_id_drift_over_threshold(tmp_path):
    previous_records = _complete_records("2026_rev_17")
    previous_manifest, previous_sidecar = _write_corpus(
        tmp_path / "2026_rev_17", "2026_rev_17", previous_records,
    )
    assert previous_manifest.is_file()

    current_records = _complete_records("2026_rev_18")
    current_records["N-98-999"] = _record(
        "N-98-999", "chapter_note", "2026_rev_18", chapter="98",
    )
    manifest, sidecar = _write_corpus(
        tmp_path / "2026_rev_18", "2026_rev_18", current_records,
    )

    errors, info = validate_notes(
        manifest,
        sidecar,
        previous_sidecar=previous_sidecar,
        max_added_pct=0,
        max_removed_pct=0,
    )

    assert any("added 1/" in error for error in errors)
    assert any("exact delta" in message for message in info)

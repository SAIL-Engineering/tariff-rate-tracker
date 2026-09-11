from __future__ import annotations

import hashlib
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "hts_automation"))

from build_hts_notes import (  # noqa: E402
    RESERVED_CHAPTERS,
    extract_references,
    parse_chapter_text,
    parse_gri_text,
    release_for_revision,
)

FIXTURES = Path(__file__).parent / "fixtures" / "hts_notes"
REVISION = "2026_rev_18"
SHA = "f" * 64
URL = "https://hts.usitc.gov/reststop/file?fixture=1"


def fixture(name: str) -> str:
    return (FIXTURES / f"{name}.txt").read_text(encoding="utf-8")


def parse_chapter(chapter: int):
    return parse_chapter_text(
        fixture(f"ch{chapter}"),
        expected_chapter=chapter,
        revision=REVISION,
        url=URL,
        pdf_sha256=SHA,
    )


def by_cite(records):
    return {record["cite_id"]: record for record in records}


def test_revision_release_name_is_deterministic():
    assert release_for_revision("2026_rev_18") == "2026HTSRev18"
    assert release_for_revision("2026_basic") == "2026HTSBasic"
    with pytest.raises(ValueError, match="expected YYYY_basic or YYYY_rev_N"):
        release_for_revision("rev18")
    assert RESERVED_CHAPTERS == {77}


def test_gri_ids_subparts_and_compiler_note_tagging():
    records = parse_gri_text(
        fixture("gri"), revision=REVISION, url=URL, pdf_sha256=SHA
    )
    citations = by_cite(records)

    for cite in ("GRI-1", "GRI-2(a)", "GRI-3(b)", "GRI-6"):
        assert cite in citations
    for cite in ("AUSR-1(a)", "AUSR-1(b)", "AUSR-1(c)", "AUSR-1(d)"):
        assert cite in citations
    compiler = citations["COMPILER-NOTE"]
    assert compiler["kind"] == "compiler_note"
    assert "Multiple sets of changes" in compiler["chunk_text"]
    assert compiler["_id"] == "US|2026_rev_18|compiler_note|GRI|compiler"


def test_chapter_39_long_exclusion_list_has_stable_ids_and_lead_ins():
    records = parse_chapter(39)
    citations = by_cite(records)
    paragraphs = [
        record for record in records
        if record["cite_id"].startswith("N-39-2(")
    ]

    assert "SN-VII-2" in citations
    assert "N-39-2(h)" in citations
    assert len(paragraphs) >= 20
    assert citations["N-39-2(h)"]["_id"] == (
        "US|2026_rev_18|chapter_note|39|2|h"
    )
    assert citations["N-39-2(h)"]["chunk_text"].startswith(
        "This chapter does not cover: (h) Prepared additives"
    )
    assert citations["N-39-2(h)"]["refs_headings"] == ["3811"]
    assert citations["SN-VII-2"]["refs_chapters"] == ["49"]
    assert citations["SN-VII-2"]["refs_headings"] == ["3918", "3919"]


@pytest.mark.parametrize("chapter", [39, 61, 84, 98])
def test_tariff_table_is_a_hard_stop(chapter):
    records = parse_chapter(chapter)
    assert records
    assert all("Heading/ Stat." not in record["chunk_text"] for record in records)
    assert all("Rates of Duty" not in record["chunk_text"] for record in records)


def test_note_kinds_counts_and_reference_extraction():
    ch61 = by_cite(parse_chapter(61))
    ch84 = parse_chapter(84)

    assert ch61["AUSN-61-1"]["kind"] == "add_us_note"
    assert sum(record["kind"] == "chapter_note" for record in ch84) >= 5
    assert sum(record["kind"] == "statistical_note" for record in ch61.values()) >= 1

    refs = extract_references(
        "See section XI, chapters 39 and 49, headings 3901 to 3914, "
        "and subheadings 3920.43 and 3921.90.11."
    )
    assert refs == {
        "refs_sections": ["XI"],
        "refs_chapters": ["39", "49"],
        "refs_headings": ["3901", "3914"],
        "refs_subheadings": ["3920.43", "3921.90.11"],
    }


def test_chapter_98_us_notes_are_scoped_to_each_subchapter():
    citations = by_cite(parse_chapter(98))

    assert "AUSN-98.I-1" in citations
    assert "AUSN-98.II-1" in citations
    assert citations["AUSN-98.II-1"]["_id"].startswith(
        "US|2026_rev_18|add_us_note|98.II|1"
    )
    assert citations["AUSN-98.II-1"]["chapter"] == "98"
    assert citations["AUSN-98.II-1"]["section"] == "XXII"


def test_every_note_family_printed_before_a_chapter_attaches_to_the_section():
    records = parse_chapter_text(
        """SECTION IV
Note
1. Section-wide legal note.
Additional U.S. Notes
1. Section-wide domestic note.
CHAPTER 16
Notes
1. Chapter legal note.
Heading/ Stat. Unit Rates of Duty
""",
        expected_chapter=16,
        revision=REVISION,
        url=URL,
        pdf_sha256=SHA,
    )
    citations = by_cite(records)

    assert set(citations) == {"SN-IV-1", "AUSN-IV-1", "N-16-1"}
    assert citations["AUSN-IV-1"]["display_text"].startswith(
        "[AUSN-IV-1] Section IV"
    )


def test_same_fixture_bytes_produce_identical_records():
    text = fixture("ch39")
    first = parse_chapter_text(
        text, expected_chapter=39, revision=REVISION, url=URL, pdf_sha256=SHA
    )
    second = parse_chapter_text(
        text, expected_chapter=39, revision=REVISION, url=URL, pdf_sha256=SHA
    )

    assert first == second
    digest = hashlib.sha256(repr(first).encode()).hexdigest()
    assert digest == hashlib.sha256(repr(second).encode()).hexdigest()

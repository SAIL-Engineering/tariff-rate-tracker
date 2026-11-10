"""Vietnam Import-Export Tariff loader: stated indents, grouping rows, chapter 98.

Fixtures are cut from the real parsed CSVs, in BOTH languages where the language
is what is being tested.

`vn_0101_slice.csv` is heading 01.01 entire: a grouping row ("- Horses:") that
qualifies the two codes beneath it, a 6-digit level (0101.30) that is itself a
parent, and a basket at each of two depths — 0101.29.00 "Other" means "other
horses" while 0101.90.00 "Other" means "other than horses or asses". Its `.vi`
twin is the same codes and indents with the Vietnamese text, which is what the
`--lang vi` build consumes.

`vn_0103_slice.csv` is heading 01.03, five rows that are the whole reason this
loader needs grouping rows at all: 0103.10.00 sits at indent 1 and 0103.91.00 at
indent 2, with "- Other:" between them. Drop that one uncoded row and 0103.91.00
parents to 0103.10.00 — "Live swine > Pure-bred breeding animals > Weighing less
than 50 kg", the exact opposite of what the schedule says — and a reportable line
becomes an internal node. 504 codes were wrong this way.

`vn_9804_slice.csv` is chapter 98 from 98.04 to 98.08, which is where Vietnam's
national chapter differs from the AHTN schedule: no unit of quantity anywhere,
CORRESPONDING_CODES instead naming the chapter 1-97 lines each entry maps to,
depth from the printed dash prefix, and at sheet row 19086 a grouping row whose
code cell repeats 9808 one dash deeper. Its English descriptions are EMPTY,
which is a property of the source, not of the parse.
"""
import csv as _csv

import pytest

import build_hts_corpus as bhc
from conftest import build, FIXTURES, AUTOMATION

VN_CHAPTERS = AUTOMATION / "chapters_vn.json"


def _build(fixture, lang="en"):
    """conftest.build() takes no language, and basket resolution reads the
    module global, so set it here the way main() and the explorer builder do."""
    previous = bhc.CORPUS_LANG
    bhc.CORPUS_LANG = lang
    try:
        return build(FIXTURES / fixture, VN_CHAPTERS,
                     source_format="vn", jurisdiction="VN", revision="2026_0405")
    finally:
        bhc.CORPUS_LANG = previous


def _raw(fixture):
    return list(_csv.DictReader((FIXTURES / fixture).open(encoding="utf-8")))


def test_display_dotting_matches_the_printed_schedule():
    assert bhc._vn_display("0101") == "01.01"
    assert bhc._vn_display("010130") == "0101.30"
    assert bhc._vn_display("01012100") == "0101.21.00"
    # chapter 98 is printed the same way
    assert bhc._vn_display("98041711") == "9804.17.11"


def test_only_four_six_and_eight_digit_codes_load():
    rows, _ = bhc.load_rows_vn(FIXTURES / "vn_0101_slice.csv")
    assert {len(r["_digits"]) for r in rows if r["_digits"]} <= {4, 6, 8}


def test_grouping_rows_are_carried_through_uncoded():
    rows, stats = bhc.load_rows_vn(FIXTURES / "vn_0101_slice.csv")
    conditions = [r for r in rows if not r["_code"]]
    assert stats.condition_row_count == len(conditions) > 0
    assert any("Horses" in r["Description"] for r in conditions)


def test_the_grouping_row_is_what_keeps_0103_91_off_its_own_sibling():
    # Without "- Other:" between them, 0103.91.00 at indent 2 parents to
    # 0103.10.00 at indent 1 and inherits "Pure-bred breeding animals".
    b = _build("vn_0103_slice.csv")
    record = b.by_code["0103.91.00"]
    assert "Other" in record["chunk_text"]
    assert "Pure-bred" not in record["chunk_text"]
    # and the pure-bred line stays a leaf of its own
    assert "0103.10.00" in b.by_code
    assert b.nodes["01031000"] is False


def test_condition_text_reaches_the_breadcrumb():
    b = _build("vn_0101_slice.csv")
    assert "Horses" in b.by_code["0101.21.00"]["chunk_text"]
    # and a closed group must not leak onto what follows it: asses are not horses
    assert "Horses" not in b.by_code["0101.30.10"]["chunk_text"]


def test_dash_prefixes_are_stripped_from_the_embedded_text():
    # The CSV keeps the dash prefix the schedule prints; the corpus must not.
    raw = {r["GOODS_CODE"]: r for r in _raw("vn_0101_slice.csv") if r["GOODS_CODE"]}
    assert raw["01012100"]["DESCRIPTION"].startswith("- - ")
    rows, _ = bhc.load_rows_vn(FIXTURES / "vn_0101_slice.csv")
    by = {r["_digits"]: r for r in rows if r["_digits"]}
    assert by["01012100"]["Description"] == "Pure-bred breeding animals"
    assert not any(r["Description"].startswith("-") for r in rows)


def test_basket_provision_resolves_against_its_own_group():
    # 0101.29.00 is "Other" under "- Horses:", so it means other HORSES and must
    # exclude only the sibling inside that group.
    b = _build("vn_0101_slice.csv")
    basket = b.by_code["0101.29.00"]
    assert basket["is_basket"]
    assert "other than" in basket["chunk_text"]
    assert "Pure-bred breeding animals" in basket["chunk_text"]


def test_vietnamese_basket_and_exclusion_template():
    # Loại khác is the residual on 4,147 lines of the schedule; with no "vi"
    # entry in _BASKET_RES not one of them is recognised.
    assert bhc._BASKET_RES["vi"].match("Loại khác")
    assert bhc._BASKET_RES["vi"].match("Khác")
    assert not bhc._BASKET_RES["vi"].match("Loại khác, sống")
    b = _build("vn_0101_slice.vi.csv", lang="vi")
    basket = b.by_code["0101.29.00"]
    assert basket["is_basket"]
    assert "trừ:" in basket["chunk_text"]
    assert "Loại thuần chủng để nhân giống" in basket["chunk_text"]


def test_both_languages_carry_the_same_codes_and_indents():
    en = [(r["GOODS_CODE"], r["INDENT"]) for r in _raw("vn_0101_slice.csv")]
    vi = [(r["GOODS_CODE"], r["INDENT"]) for r in _raw("vn_0101_slice.vi.csv")]
    assert en == vi


# ── chapter 98 ───────────────────────────────────────────────────────────

def test_chapter_98_leaves_come_from_is_leaf_not_from_a_unit():
    # The unit column is empty for the whole chapter, so reading it as the leaf
    # marker would declare Vietnam's national chapter leafless.
    rows, stats = bhc.load_rows_vn(FIXTURES / "vn_9804_slice.csv")
    coded = [r for r in rows if r["_digits"]]
    assert coded and not any(r["Unit of Quantity"] for r in coded)
    assert "98041711" in stats.official_leaf_digits
    # a 6-digit intermediate level is coded and is not a leaf
    assert "980417" in stats.coded_digits
    assert "980417" not in stats.official_leaf_digits


def test_chapter_98_leaf_flags_agree_with_the_rebuilt_tree():
    # This is the exit-7 cross-check of build_hts_corpus.main(), held over the
    # fixture: the indent tree and the source's own flags must name one set.
    b = _build("vn_9804_slice.csv")
    ours = {d for d, has_children in b.nodes.items() if not has_children}
    assert ours == b.stats.official_leaf_digits


def test_corresponding_codes_are_the_chapter_1_to_97_mapping():
    raw = {r["GOODS_CODE"]: r for r in _raw("vn_9804_slice.csv") if r["GOODS_CODE"]}
    assert raw["98041500"]["CORRESPONDING_CODES"] == "03061500"
    # one chapter-98 line can map to many, which is why the sheet repeats the
    # code once per pairing and the parser joins them with ";"
    assert raw["98050000"]["CORRESPONDING_CODES"].split(";") == [
        "12073000", "12074090", "12075000", "12076000", "12077000",
        "12079100", "12079940", "12079950", "12079990"]


def test_a_repeated_chapter_98_code_one_dash_deeper_is_a_grouping_row():
    # Sheet row 19086 prints 9808 again as the header of a nested group. Kept as
    # a code it is a duplicate; dropped it orphans 9808.00.10/90 onto 98.08.
    rows = _raw("vn_9804_slice.csv")
    repeat = [r for r in rows if r["SHEET_ROW"] == "19086"]
    assert len(repeat) == 1
    assert repeat[0]["GOODS_CODE"] == "" and repeat[0]["INDENT"] == "1"
    vi = [r for r in _raw("vn_9804_slice.vi.csv") if r["SHEET_ROW"] == "19086"]
    assert vi[0]["DESCRIPTION"] == "- Loại khác:"
    b = _build("vn_9804_slice.csv")
    assert b.nodes["9808"] is True
    assert b.nodes["98080010"] is False


def test_chapter_98_has_no_english_in_the_source():
    # A recorded property of the workbook, not a parse failure: all 666 coded
    # rows with no English description are in chapter 98. The test exists so
    # that filling the gap (from the ITPC chapter PDFs, or by falling back to
    # Vietnamese) shows up as a deliberate change here.
    en = _raw("vn_9804_slice.csv")
    assert all(not r["DESCRIPTION"] for r in en)
    vi = _raw("vn_9804_slice.vi.csv")
    assert all(r["DESCRIPTION"] for r in vi)


# ── failure modes ────────────────────────────────────────────────────────

HEADER = ("GOODS_CODE,DISPLAY,DESCRIPTION,INDENT,UNIT,CORRESPONDING_CODES,"
          "MFN_RATE,ORDINARY_RATE,VAT,IS_LEAF,SECTION,CHAPTER,SHEET_ROW\n")


def test_duplicate_code_fails_loudly(tmp_path):
    bad = tmp_path / "dupe.csv"
    bad.write_text(
        HEADER
        + "01012100,0101.21.00,- - Pure-bred,2,kg/unit,,0,5,8/10,1,I,1,22\n"
        + "01012100,0101.21.00,- - Pure-bred,2,kg/unit,,0,5,8/10,1,I,1,23\n",
        encoding="utf-8")
    with pytest.raises(SystemExit, match="duplicate"):
        bhc.load_rows_vn(bad)


def test_malformed_code_fails_loudly(tmp_path):
    # The source has four of these ('9849170\xa0' and friends); the parser
    # records them as anomalies and keeps them out of the CSV, so one reaching
    # the loader means that changed.
    bad = tmp_path / "bad.csv"
    bad.write_text(
        HEADER + "9849170,9849.17.0,- - Nonsense,2,,,0,5,,1,,98,19499\n",
        encoding="utf-8")
    with pytest.raises(SystemExit, match="bad GOODS_CODE"):
        bhc.load_rows_vn(bad)


def test_indent_agrees_with_code_prefix_parentage_in_chapters_1_to_97():
    # The same invariant parse_vn_tariff asserts over the AHTN schedule. It does
    # NOT hold in chapter 98, where the code is a serial number over a dash tree
    # (9849.35xx hangs under the 9849.34 grouping), so that chapter is excluded.
    for fixture in ("vn_0101_slice.csv", "vn_0103_slice.csv"):
        rows, _ = bhc.load_rows_vn(FIXTURES / fixture)
        stack = []
        for row in rows:
            while stack and stack[-1]["_indent"] >= row["_indent"]:
                stack.pop()
            if row["_digits"]:
                coded = [a for a in stack if a["_digits"]]
                if coded:
                    assert row["_digits"].startswith(coded[-1]["_digits"]), (
                        f'{fixture}: {row["_code"]} at indent {row["_indent"]} '
                        f'under {coded[-1]["_code"]}')
            stack.append(row)

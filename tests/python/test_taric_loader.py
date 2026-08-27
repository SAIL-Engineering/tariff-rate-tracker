"""EU TARIC loader: producline mapping, trimmed display, official leaf flags."""
import build_hts_corpus as bhc
from conftest import build, FIXTURES, AUTOMATION

EU_CHAPTERS = AUTOMATION / "chapters_eu.json"


def _build_eu():
    return build(FIXTURES / "eu_0101_slice.csv", EU_CHAPTERS,
                 source_format="taric", jurisdiction="EU", revision="2026_rev_8")


def test_suffix_80_is_line_others_are_conditions():
    b = _build_eu()
    # grouping rows (suffix 10) never become nodes
    assert all(len(d) == 10 for d in b.nodes)
    # the "Horses" grouping folded into the condition chain
    r = b.by_code.get("0101.21.00.00")
    assert r and "Horses" in r["chunk_text"]


def test_display_trims_internals_keeps_leaves_full():
    b = _build_eu()
    r = b.by_code["0101.29.10.00"]
    # internal heading level shows the book form, not 0101.00.00.00
    assert "| 0101 Live horses" in r["display_text"]
    assert "0101.00.00.00" not in r["display_text"]
    # the leaf itself is the full declarable 10-digit form
    assert r["display_text"].startswith("0101.29.10.00 = ")


def test_codes_json_keys_are_full_ten_digits():
    b = _build_eu()
    assert all(len(d) == 10 and d.isdigit() for d in b.nodes)
    # the internal CN line is present and marked internal — the validator's
    # 'incomplete' verdict depends on exactly this
    assert b.nodes.get("0101290000") is True
    assert b.nodes.get("0101291000") is False


def test_official_leaf_digits_collected():
    rows, stats = bhc.load_rows_taric(FIXTURES / "eu_0101_slice.csv")
    assert stats.official_leaf_digits
    assert "0101210000" in stats.official_leaf_digits
    # chapter rows are dropped, not coded
    assert "0100000000" not in stats.coded_digits


def test_chapter_prefix_from_chapters_file():
    b = _build_eu()
    r = b.by_code["0101.21.00.00"]
    assert r["chunk_text"].startswith("Live animals > ")
    assert r["depth"] == 10 and r["heading"] == "0101" and r["subheading"] == "010121"

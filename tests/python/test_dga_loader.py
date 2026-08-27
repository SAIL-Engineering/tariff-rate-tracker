"""DR (DGA) loader: dash hierarchy, Spanish baskets, dup-as-group, orphans."""
import build_hts_corpus as bhc
from conftest import build, FIXTURES, AUTOMATION

DO_CHAPTERS = AUTOMATION / "chapters_do.json"


def _b(name):
    # Spanish basket handling is a build-time mode, set here the way main() does
    old = bhc.CORPUS_LANG
    bhc.CORPUS_LANG = "es"
    try:
        return build(FIXTURES / name, DO_CHAPTERS,
                     source_format="dga", jurisdiction="DO", revision="2022_rev_7")
    finally:
        bhc.CORPUS_LANG = old


def test_dash_hierarchy_and_condition_rows():
    b = _b("do_0101_slice.csv")
    r = b.by_code["0101.21.00"]
    # the uncoded "- Caballos:" grouping row became a condition breadcrumb
    assert "Caballos" in r["chunk_text"]
    assert r["depth"] == 8


def test_spanish_basket_expansion():
    b = _b("do_0101_slice.csv")
    r = b.by_code["0101.29.00"]     # " - - Los demás"
    assert r["is_basket"] is True
    assert "excepto:" in r["chunk_text"]
    assert "other than" not in r["chunk_text"]


def test_repeated_code_becomes_group_row():
    b = _b("do_8517_dup_slice.csv")
    # 8517.62 appears twice; the second ("- - - Los demás:") must not collide
    assert b.stats.dropped_duplicates == 1
    assert b.stats.coded_digits == set(b.nodes)   # L1 still holds


def test_orphan_heading_as_leaf():
    b = _b("do_0205_orphan_slice.csv")
    # 0205.00.00 has no 02.05 heading row — single-line heading, root + leaf
    assert [r["code"] for r in b.records] == ["0205.00.00"]
    assert b.records[0]["chunk_text"].count(">") <= 1

"""Malaysia PDK loader: 4/6/8/10-digit codes, condition rows, TRQ basis.

Fixtures are cut from the real parsed CSV. `my_0103_slice.csv` is heading 01.03,
which carries the two tariff-rate-quota lines — the ones the ezHS portal shows
with a blank import rate and the gazette states as "TRQ as specified in
Appendix B". `my_2903_slice.csv` is the HFC run in chapter 29, where
"2903.43.00" is an eight-digit internal node over three ten-digit children; a
first pass padded those to 2903430000 and made the parent a sibling of its own
children.
"""
import build_hts_corpus as bhc
from conftest import build, FIXTURES, AUTOMATION

MY_CHAPTERS = AUTOMATION / "chapters_my.json"


def _build(fixture):
    return build(FIXTURES / fixture, MY_CHAPTERS,
                 source_format="my", jurisdiction="MY", revision="2025_rev_1101")


def test_display_dotting_matches_the_gazette():
    assert bhc._my_display("0101") == "01.01"
    assert bhc._my_display("010130") == "0101.30"
    assert bhc._my_display("29034300") == "2903.43.00"
    assert bhc._my_display("0101210000") == "0101.21.00 00"


def test_all_four_code_lengths_load():
    rows, stats = bhc.load_rows_my(FIXTURES / "my_2903_slice.csv")
    lengths = {len(r["_digits"]) for r in rows if r["_digits"]}
    assert lengths <= {4, 6, 8, 10}
    assert 8 in lengths, "the eight-digit internal nodes must survive"
    assert 10 in lengths


def test_eight_digit_node_is_the_parent_of_its_ten_digit_children():
    rows, _ = bhc.load_rows_my(FIXTURES / "my_2903_slice.csv")
    by = {r["_digits"]: r for r in rows if r["_digits"]}
    assert "29034300" in by
    children = [d for d in by if len(d) == 10 and d.startswith("29034300")]
    assert len(children) == 3, children
    # and the parent must be shallower than every child
    for child in children:
        assert by[child]["_indent"] > by["29034300"]["_indent"]
    # the padded code must not exist
    assert "2903430000" not in by


def test_eight_digit_node_is_not_an_official_leaf():
    _, stats = bhc.load_rows_my(FIXTURES / "my_2903_slice.csv")
    assert "29034300" in stats.coded_digits
    assert "29034300" not in stats.official_leaf_digits
    assert "2903430010" in stats.official_leaf_digits


def test_condition_rows_are_carried_through_uncoded():
    rows, stats = bhc.load_rows_my(FIXTURES / "my_0103_slice.csv")
    conditions = [r for r in rows if not r["_code"]]
    assert stats.condition_row_count == len(conditions) > 0
    assert any("Other" in r["Description"] for r in conditions)


def test_condition_text_reaches_the_breadcrumb():
    b = _build("my_0103_slice.csv")
    # 0103.91 is "- - Weighing less than 50 kg" under the "- Other:" group, not
    # under "- Pure-bred breeding animals".
    record = b.by_code["0103.91.00 00"]
    assert "Other" in record["chunk_text"]
    assert "Pure-bred" not in record["chunk_text"]


def test_quota_lines_carry_a_basis_instead_of_a_blank_rate():
    # A blank import rate on a quota line must never read as zero: the gazette
    # states it by reference to Appendix B, and the rates live there.
    import csv as _csv
    rows = list(_csv.DictReader(
        (FIXTURES / "my_0103_slice.csv").open(encoding="utf-8")))
    quota = [r for r in rows if r["IMPORT_RATE_BASIS"] == "trq_appendix_b"]
    assert len(quota) == 2, [r["DISPLAY"] for r in quota]
    for row in quota:
        assert row["IMPORT_RATE"] == ""
        assert row["TRQ_IN_QUOTA"] and row["TRQ_OUT_QUOTA"]
        assert row["TRQ_AGENCY"]
    # every other coded line states a schedule rate
    for row in rows:
        if row["GOODS_CODE"] and len(row["GOODS_CODE"]) == 10 \
                and row["IMPORT_RATE_BASIS"] == "schedule":
            assert row["IMPORT_RATE"]


def test_indent_agrees_with_code_prefix_parentage():
    for fixture in ("my_0103_slice.csv", "my_2903_slice.csv"):
        rows, _ = bhc.load_rows_my(FIXTURES / fixture)
        stack = []
        for row in rows:
            while stack and stack[-1]["_indent"] >= row["_indent"]:
                stack.pop()
            if row["_digits"] and len(row["_digits"]) > 4:
                coded = [a for a in stack if a["_digits"]]
                if coded:
                    assert row["_digits"].startswith(coded[-1]["_digits"]), (
                        f'{fixture}: {row["_code"]} under {coded[-1]["_code"]}')
            stack.append(row)


def test_malformed_or_duplicate_codes_fail_loudly(tmp_path):
    header = ("GOODS_CODE,DISPLAY,HEADING,DESCRIPTION,INDENT,UNIT,IMPORT_RATE,"
              "IMPORT_RATE_BASIS\n")
    dupe = tmp_path / "dupe.csv"
    dupe.write_text(header
                    + "0101210000,0101.21.00 00,01.01,Pure-bred,2,u,0%,schedule\n"
                    + "0101210000,0101.21.00 00,01.01,Pure-bred,2,u,0%,schedule\n",
                    encoding="utf-8")
    try:
        bhc.load_rows_my(dupe)
    except SystemExit as exc:
        assert "duplicate" in str(exc)
    else:
        raise AssertionError("a duplicate code must fail the load")

    bad = tmp_path / "bad.csv"
    bad.write_text(header + "010121000,0101.21.0 0,01.01,Nonsense,2,u,0%,schedule\n",
                   encoding="utf-8")
    try:
        bhc.load_rows_my(bad)
    except SystemExit as exc:
        assert "bad GOODS_CODE" in str(exc)
    else:
        raise AssertionError("a 9-digit code must fail the load")

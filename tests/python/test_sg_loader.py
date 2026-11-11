"""Singapore STCCED loader: printed dash depth, condition rows, 8-digit leaves.

The fixtures are cut from the real parsed CSV. `sg_0301_slice.csv` is heading
03.01 entire, chosen because it carries every structural case the PDF parse has
to get right in one place: a 6-digit intermediate level that is also a parent,
uncoded condition rows, a basket provision with four named siblings, and the two
rows whose code and description are typeset on different baselines
(0301.11.10 and 0301.19.90 — see STITCH_MAX_GAP in parse_sg_stcced.py).
`sg_2203_slice.csv` is heading 22.03, the beer lines, which are the only rows in
the schedule with all three duty columns populated.
"""
import build_hts_corpus as bhc
from conftest import build, FIXTURES, AUTOMATION

SG_CHAPTERS = AUTOMATION / "chapters_sg.json"


def _build_sg(fixture="sg_0301_slice.csv"):
    return build(FIXTURES / fixture, SG_CHAPTERS,
                 source_format="sg", jurisdiction="SG", revision="2022_rev_101")


def test_display_dotting_matches_the_printed_book():
    assert bhc._sg_display("0101") == "01.01"
    assert bhc._sg_display("010130") == "0101.30"
    assert bhc._sg_display("01012100") == "0101.21.00"


def test_leaves_are_eight_digits_and_carry_a_unit():
    b = _build_sg()
    assert b.records, "no records built"
    assert all(len(r["code"].replace(".", "")) == 8 for r in b.records)
    rows_by_digits = {r["_digits"]: r for r in b.rows if r["_digits"]}
    for rec in b.records:
        digits = rec["code"].replace(".", "")
        assert rows_by_digits[digits]["Unit of Quantity"], \
            f"{rec['code']} is a leaf with no unit of quantity"


def test_official_leaf_digits_come_from_the_unit_column():
    rows, stats = bhc.load_rows_sg(FIXTURES / "sg_0301_slice.csv")
    assert stats.official_leaf_digits
    assert "03011191" in stats.official_leaf_digits
    # a 6-digit intermediate level is coded but is not a reportable line
    assert "030111" in stats.coded_digits
    assert "030111" not in stats.official_leaf_digits


def test_condition_rows_are_carried_through_uncoded():
    rows, stats = bhc.load_rows_sg(FIXTURES / "sg_0301_slice.csv")
    conditions = [r for r in rows if not r["_code"]]
    assert stats.condition_row_count == len(conditions) > 0
    assert any("Ornamental fish" in r["Description"] for r in conditions)


def test_condition_text_reaches_the_breadcrumb():
    # "Ornamental fish :" has no code of its own, and without it 0301.11.91 is
    # described only as "Freshwater > Koi carp".
    b = _build_sg()
    assert "Ornamental fish" in b.by_code["0301.11.91"]["chunk_text"]


def test_rows_split_across_baselines_keep_code_and_description_together():
    # Both of these are typeset with the code on one line and the description
    # on another; a parse that does not rejoin them puts 0301.11.10 at indent 0
    # where it adopts five unrelated children, and loses 0301.19.90's text.
    rows, _ = bhc.load_rows_sg(FIXTURES / "sg_0301_slice.csv")
    by_digits = {r["_digits"]: r for r in rows if r["_digits"]}
    assert by_digits["03011110"]["Description"] == "Fry"
    assert by_digits["03011990"]["Description"] == "Other"
    # Both must sit two levels under their 6-digit parent, not at the top.
    assert by_digits["03011110"]["_indent"] == 3
    assert by_digits["03011990"]["_indent"] == 3

    b = _build_sg()
    fry = b.by_code["0301.11.10"]
    assert fry["chunk_text"].endswith("Freshwater > Fry")
    # 0301.19.90 must hang off 0301.19, not off the ornamental-fish branch
    assert "0301.19 " in b.by_code["0301.19.90"]["display_text"]


def test_basket_provision_resolves_against_its_named_siblings():
    b = _build_sg()
    basket = b.by_code["0301.11.99"]["chunk_text"]
    assert "other than" in basket
    for sibling in ("Koi carp", "Goldfish", "Siamese fighting fish", "Arowanas"):
        assert sibling in basket


def test_indent_agrees_with_code_prefix_parentage():
    # The indent is the dash depth the book prints. This is the same invariant
    # parse_sg_stcced.validate() asserts over all 14,460 codes, held here over
    # the fixture so a loader change cannot quietly break it.
    rows, _ = bhc.load_rows_sg(FIXTURES / "sg_0301_slice.csv")
    stack = []
    for row in rows:
        while stack and stack[-1]["_indent"] >= row["_indent"]:
            stack.pop()
        if row["_digits"]:
            ancestors = [a for a in stack if a["_digits"]]
            if ancestors:
                assert row["_digits"].startswith(ancestors[-1]["_digits"]), \
                    f'{row["_code"]} at indent {row["_indent"]} under {ancestors[-1]["_code"]}'
        stack.append(row)


def test_duty_columns_survive_their_three_line_wrap():
    # "$16.00 / per litre / of alcohol" is one cell over three printed lines,
    # and "of" lands four tenths of a point inside the unit column.
    rows, _ = bhc.load_rows_sg(FIXTURES / "sg_2203_slice.csv")
    import csv as _csv
    raw = {r["GOODS_CODE"]: r for r
           in _csv.DictReader((FIXTURES / "sg_2203_slice.csv").open(encoding="utf-8"))
           if r["GOODS_CODE"]}
    beer = raw["22030011"]
    assert beer["DUTY_FULL"] == "$16.00 per litre of alcohol"
    assert beer["DUTY_PREF"] == "Free"
    assert beer["EXCISE"] == "$60.00 per litre of alcohol"
    assert beer["UNIT"] == "LTR"


def test_duplicate_or_malformed_codes_fail_loudly(tmp_path):
    bad = tmp_path / "dupe.csv"
    bad.write_text(
        "GOODS_CODE,DISPLAY,DESCRIPTION,INDENT,UNIT\n"
        "01012100,0101.21.00,Pure-bred breeding animals,2,NMB\n"
        "01012100,0101.21.00,Pure-bred breeding animals,2,NMB\n",
        encoding="utf-8")
    try:
        bhc.load_rows_sg(bad)
    except SystemExit as exc:
        assert "duplicate" in str(exc)
    else:
        raise AssertionError("a duplicate code must fail the load")

    malformed = tmp_path / "bad.csv"
    malformed.write_text(
        "GOODS_CODE,DISPLAY,DESCRIPTION,INDENT,UNIT\n"
        "0101210,0101.21.0,Nonsense,2,NMB\n", encoding="utf-8")
    try:
        bhc.load_rows_sg(malformed)
    except SystemExit as exc:
        assert "bad GOODS_CODE" in str(exc)
    else:
        raise AssertionError("a 7-digit code must fail the load")

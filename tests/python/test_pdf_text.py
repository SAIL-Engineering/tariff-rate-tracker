"""pdf_text: the text repairs shared by the Singapore and Malaysia PDF parsers.

Every case here is one the 2026-11-11 audit found in the real books.
"""
import pytest

import pdf_text as pt


def norm(s: str) -> str:
    return " ".join((s or "").split())


@pytest.fixture(autouse=True)
def vocabulary():
    """A small book: the words it prints within a line."""
    pt.set_vocabulary(pt.Vocabulary(
        "micro-organisms pre-cooked chemical wheelbarrows cigarette cigarettes "
        "stick of each the (c) igarette".split()))
    yield
    pt.set_vocabulary(pt.Vocabulary())


# ── line-break hyphens ───────────────────────────────────────────────────────

@pytest.mark.parametrize("head, tail, joined", [
    # locants and single-letter prefixes always keep the hyphen
    ("Ethylene dichloride (ISO) (1,2-", "dichloroethane)", "Ethylene dichloride (ISO) (1,2-dichloroethane)"),
    ("o-dichlorobenzene and p-", "dichlorobenzene", "o-dichlorobenzene and p-dichlorobenzene"),
    # the book prints the hyphenated form within a line
    ("other single-cell micro-", "organisms, dead:", "other single-cell micro-organisms, dead:"),
    # the book prints only the joined form: a real word break
    ("chemi-", "cal products", "chemical products"),
    # no evidence either way: keep, a visible hyphen misleads less than a fused name
    ("leaded anti-", "knock compound sludges", "leaded anti-knock compound sludges"),
    # a non-lowercase continuation is never a broken word, and never gets a space
    ("curium-", "242, curium-243", "curium-242, curium-243"),
    # a free-standing dash is text
    ("Of a kind -", "other", "Of a kind - other"),
])
def test_line_break_hyphens(head, tail, joined):
    assert pt.join_wrapped(head, tail, norm) == joined


def test_word_split_without_a_hyphen():
    # Singapore's cigarette excise: "each stick of c" / "igarette"
    assert pt.join_wrapped("each stick of c", "igarette", norm) == "each stick of cigarette"


def test_ordinary_words_are_not_glued():
    assert pt.join_wrapped("each stick", "of cigarette", norm) == "each stick of cigarette"


# ── in-line hyphens ──────────────────────────────────────────────────────────

@pytest.mark.parametrize("raw, tidy", [
    ("beet- pulp, bagasse", "beet-pulp, bagasse"),
    ("octadecan- 1-ol (stearyl alcohol)", "octadecan-1-ol (stearyl alcohol)"),
    ("1-Chloro-2,3- epoxypropane", "1-Chloro-2,3-epoxypropane"),
    ("Mono- , di- or trichloroacetic acids", "Mono-, di- or trichloroacetic acids"),
    # suspended hyphens before a conjunction are HS text and stay
    ("Of mono- or disodium", "Of mono- or disodium"),
    ("Diazo-, azo- or azoxy-compounds", "Diazo-, azo- or azoxy-compounds"),
    ("- - Other", "- - Other"),
])
def test_tidy_hyphens(raw, tidy):
    assert pt.tidy_hyphens(raw) == tidy


# ── sub- and superscripts ────────────────────────────────────────────────────

def w(x0, y0, x1, y1, text):
    return (x0, y0, x1, y1, text)


def texts(words):
    return [t for *_, t in words]


def test_subscripts_join_their_formula():
    # H3BO3, Malaysia page 235: base 14.06pt, subscripts 9.42pt, touching
    page = [w(259.01, 341.95, 269.75, 356.01, "of"), w(272.44, 341.95, 281.10, 356.01, "H"),
            w(281.09, 346.19, 285.85, 355.61, "3"), w(285.89, 341.95, 302.03, 356.01, "BO"),
            w(301.97, 346.19, 306.73, 355.61, "3"), w(309.41, 341.95, 365.88, 356.01, "calculated")]
    assert texts(pt.merge_scripts(page)) == ["of", "H3BO3", "calculated"]


def test_superscript_with_attached_punctuation():
    # "150g/m" + "2:", Malaysia 4802.57
    page = [w(317.21, 385.15, 358.86, 399.21, "150g/m"), w(358.85, 385.91, 365.41, 395.33, "2:")]
    assert texts(pt.merge_scripts(page)) == ["150g/m2:"]


def test_negative_exponent():
    page = [w(376.58, 74.25, 385.54, 82.35, "10"), w(385.55, 73.30, 390.48, 78.70, "-6"),
            w(392.76, 74.25, 404.28, 82.35, "per")]
    assert texts(pt.merge_scripts(page)) == ["10-6", "per"]


def test_degree_sign_touching_and_with_a_gap():
    # Whether or not the raised "o" touches the number, the result is the same
    # "23 °C": one word for the unit, as the books set it with a space.
    touching = [w(302.66, 346.53, 311.59, 354.63, "23"), w(311.64, 345.58, 314.64, 350.98, "o"),
                w(316.92, 346.53, 322.92, 354.63, "C")]
    assert texts(pt.merge_scripts(touching)) == ["23", "°C"]
    gap = [w(344.43, 164.66, 357.67, 178.72, "23"), w(360.29, 165.42, 364.56, 174.84, "o"),
           w(364.61, 164.66, 371.37, 178.72, "C")]
    assert texts(pt.merge_scripts(gap)) == ["23", "°C"]


def test_body_height_digits_are_not_scripts():
    page = [w(100, 10, 120, 24, "Chapter"), w(120.2, 10, 130, 24, "87")]
    assert texts(pt.merge_scripts(page)) == ["Chapter", "87"]


# ── sub-chapter headings ─────────────────────────────────────────────────────

def test_subchapter_heading_and_title():
    assert pt.RE_SUBCHAPTER.match("SUB-CHAPTER II")
    assert pt.RE_SUBCHAPTER.match("SUB-CHAPTER VII")
    assert not pt.RE_SUBCHAPTER.match("Sub-chapter notes apply")
    assert pt.is_caps_title("INORGANIC ACIDS AND INORGANIC OXYGEN COMPOUNDS OF")
    assert not pt.is_caps_title("Containing by weight 0.6% or more of carbon")
    assert not pt.is_caps_title("(HFC-143a)")

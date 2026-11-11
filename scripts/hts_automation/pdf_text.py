"""Text repair shared by the two PDF-sourced parsers, parse_sg_stcced.py and
parse_my_pdk.py.

Both rebuild every table cell from `pdftotext -bbox-layout` words, and an audit
against independent sources (2026-11-11: the other two ASEAN books, Malaysia's
ezHS portal, and each PDF page itself) found both getting the same three things
wrong. The fixes live here once so the two parsers cannot drift apart.

1. LINE-BREAK HYPHENS. A cell that wrapped after a hyphen was joined by dropping
   the hyphen whenever the next line began in lowercase ("1,2-" / "dichloro-
   ethane" -> "1,2dichloroethane", "micro-" / "organisms" -> "microorganisms"),
   and with a space otherwise ("curium-" / "242" -> "curium- 242"). About 145
   Singapore and 230 Malaysian rows were affected. Harmonized System text is full
   of real hyphens and seldom hyphenates an ordinary word, so neither blanket
   rule is right. The book itself decides: `Vocabulary` counts every word printed
   WITHIN a line, where no line-break hyphen can occur, and `join_wrapped()`
   keeps the hyphen when the hyphenated form appears there, drops it when only
   the joined form does, and otherwise keeps it, because a visible hyphen
   misleads less than a fused chemical name.

2. SUPERSCRIPTS AND SUBSCRIPTS. A raised or lowered character ("m²", "H₃BO₃",
   "10⁻⁶", "23 °C") is its own word in a smaller face. Each parser clusters words
   into lines by position, so it landed on a line of its own and was appended
   after the text: "H BO 3 3", "150g/m 2", "23 o C". Measured in both books,
   such a word is two-thirds of body height (5.40 of 8.10pt in Singapore, 9.42
   of 14.06pt in Malaysia) and touches the word it belongs to, with gaps within
   +/-0.05pt. `merge_scripts()` glues it to that word before any line is built.

3. SUB-CHAPTER HEADINGS. Chapters 28, 29 and 69 are divided into sub-chapters,
   printed between tariff lines as "SUB-CHAPTER II" plus one or two capitalised
   title lines. Neither parser knew the form, so the heading was read as
   continuation text of the line above it: 2905.19.00 "Other SUB-CHAPTER II
   ALCOHOLS AND THEIR HALOGENATED, ..." (26 Singapore rows, 19 Malaysian).
   `RE_SUBCHAPTER` recognises the first line and `is_caps_title()` its title.
"""
from __future__ import annotations

import re
from collections import Counter

# Punctuation that can wrap a word without being part of it.
EDGE = "\"'()[]{}.,;:!?"

STATS: Counter = Counter()


def _core(token: str) -> str:
    return token.strip(EDGE).lower()


class Vocabulary:
    """Every word a book prints within a line, counted case-insensitively.

    A token ending in "-" is a line-end fragment, never a whole word, so it is
    skipped: counting it would let the very breaks being judged vote on
    themselves.
    """

    def __init__(self, tokens=()) -> None:
        self.counts: Counter = Counter()
        self.add(tokens)

    def add(self, tokens) -> None:
        for token in tokens:
            if not token or token.endswith("-"):
                continue
            core = _core(token)
            if core:
                self.counts[core] += 1

    def __contains__(self, word: str) -> bool:
        return self.counts.get(word.lower(), 0) > 0


_VOCAB = Vocabulary()


def set_vocabulary(vocab: Vocabulary) -> None:
    """Install the book's vocabulary. Each parser calls this once per run, after
    loading its pages and before reading any cell."""
    global _VOCAB
    _VOCAB = vocab


def keep_hyphen(head: str, tail: str) -> bool:
    """Whether the hyphen ending `head` is part of the word that `tail` completes."""
    left = head.split()[-1][:-1].lstrip(EDGE)          # "1,2", "micro", "N,N-dimethyl"
    right = tail.split()[0].rstrip(EDGE) if tail.split() else ""
    if not left or not right:
        return True
    # Only a lowercase continuation can be a broken ordinary word. "curium-242",
    # "N-Methyl" and "1,1,1-Trichloro" keep theirs.
    if not right[0].islower():
        return True
    last = re.split(r"[-,]", left)[-1]
    # Locants and single-letter prefixes are always hyphenated: "1,2-dichloro",
    # "p-dichlorobenzene", "o-xylene", "N-methyl".
    if not last.isalpha() or len(last) == 1:
        return True
    if f"{left}-{right}" in _VOCAB or f"{last}-{right}" in _VOCAB:
        return True
    if f"{left}{right}" in _VOCAB or f"{last}{right}" in _VOCAB:
        return False
    return True


def join_wrapped(head: str, tail: str, norm) -> str:
    """Append a wrapped fragment `tail` to `head`, normalised by `norm`.

    A hyphen attached to the last word of `head` is a line-break hyphen; whether
    it survives is keep_hyphen()'s call, and no space is ever inserted after it.
    A free-standing dash (" -") is ordinary text and joins with a space.
    """
    head = (head or "").rstrip()
    tail = norm(tail)
    if not head:
        return tail
    if not tail:
        return head
    if head.endswith("-") and len(head) >= 2 and not head[-2].isspace():
        keep = keep_hyphen(head, tail)
        STATS["hyphen_kept" if keep else "hyphen_dropped"] += 1
        return norm((head if keep else head[:-1]) + tail)
    if split_without_hyphen(head, tail):
        STATS["split_word_joined"] += 1
        return norm(head + tail)
    return norm(head + " " + tail)


def split_without_hyphen(head: str, tail: str) -> bool:
    """A word broken across lines with NO hyphen at all.

    Singapore's cigarette excise prints "each stick of c" / "igarette": a
    typesetting slip, not a hyphenation. The test is narrow: the next line opens
    with a fragment the book prints nowhere else, and gluing it to the last word
    of the line above gives a word the book does print.
    """
    if not head.split() or not tail.split():
        return False
    last, first = head.split()[-1], tail.split()[0]
    if not last.isalpha() or not first.rstrip(EDGE).isalpha() or not first[:1].islower():
        return False
    fragment = _core(first)
    return _VOCAB.counts.get(fragment, 0) <= 1 and _VOCAB.counts.get(last.lower() + fragment, 0) >= 1


# A sub- or superscript as these books print one: a one- or two-digit number,
# optionally signed ("2", "3", "-6", "-1"), or the raised "o" of a degree sign.
# pdftotext can attach the punctuation that follows it ("150g/m" + "2:"); the
# height test, not this pattern, is what makes it a script.
RE_SCRIPT = re.compile(r"^(?:[-−]?\d{1,2}|o|°)[:;,.)]?$")
SCRIPT_MAX_RATIO = 0.8      # measured 0.67 in both books; body text is 1.0
TOUCH_MIN, TOUCH_MAX = -0.3, 0.6   # measured -0.05..+0.05; a word space is ~2pt
DEGREE_GAP = 3.0            # "23 °C": the "C" sits 2.3pt after the raised "o"


def merge_scripts(words: list) -> list:
    """Glue every sub/superscript into the word it belongs to.

    `words` is one page's words in pdftotext's stream order, as
    (xMin, yMin, xMax, yMax, text) tuples. A script follows its base word in that
    order. The merged word keeps the base word's vertical extent, so line
    clustering sees one body-height word where there were two.

    After a script, a word that touches it continues the same token: the "BO" in
    H₃BO₃ and the ".cm" in "(min⁻¹.cm⁻²)". A raised "o" becomes "°" and takes a
    following "C" or "F" with it.
    """
    out: list = []
    after_script = False
    words = _merge_degree_signs(words)
    for x0, y0, x1, y1, text in words:
        if out:
            px0, py0, px1, py1, ptext = out[-1]
            gap = x0 - px1
            touching = TOUCH_MIN <= gap <= TOUCH_MAX
            overlaps = y0 < py1 and y1 > py0
            height, base_height = y1 - y0, py1 - py0
            if (RE_SCRIPT.match(text) and touching and overlaps
                    and base_height > 0 and height < SCRIPT_MAX_RATIO * base_height):
                glyph = "°" if text == "o" else text.replace("−", "-")
                out[-1] = (px0, py0, x1, py1, ptext + glyph)
                STATS["script_merged"] += 1
                after_script = True
                continue
            if after_script and overlaps and (
                    touching or (ptext.endswith("°") and 0 <= gap <= DEGREE_GAP
                                 and re.match(r"^[CF]\b", text))):
                out[-1] = (px0, py0, x1, py1, ptext + text)
                STATS["script_tail_merged"] += 1
                continue
        after_script = False
        out.append((x0, y0, x1, y1, text))
    return out


# A hyphen followed by a space INSIDE a line: "beet- pulp", "amino- compounds",
# "octadecan- 1-ol", "2,3- epoxypropane". pdftotext reports these as two words
# where the book sets one hyphenated term. The one real construction of that
# shape is the suspended hyphen of HS text -- "mono- or disodium", "di- or
# trimethylamine", "Diazo-, azo- or azoxy-compounds" -- whose next word is a
# conjunction, so that is left alone.
RE_INLINE_HYPHEN_SPACE = re.compile(r"(?<=\w)- (?!(?:or|and|nor|to)\b)(?=\w)")


def tidy_hyphens(text: str) -> str:
    """Close a hyphen-then-space inside a line, and "Mono- ," to "Mono-,"."""
    return RE_INLINE_HYPHEN_SPACE.sub("-", text).replace("- ,", "-,")


def _merge_degree_signs(words: list) -> list:
    """A raised "o" that does NOT touch its number but sits just before "C" or
    "F": "23 o C" in Singapore's 3903.90.91 and Malaysia's 2710.12.92, where the
    book leaves a space after the number. It becomes one word, "°C"."""
    out, i = [], 0
    while i < len(words):
        x0, y0, x1, y1, text = words[i]
        if text == "o" and i + 1 < len(words):
            nx0, ny0, nx1, ny1, ntext = words[i + 1]
            if (re.match(r"^[CF]\b", ntext) and TOUCH_MIN <= nx0 - x1 <= DEGREE_GAP
                    and y0 < ny1 and y1 > ny0 and ny1 > ny0
                    and (y1 - y0) < SCRIPT_MAX_RATIO * (ny1 - ny0)):
                out.append((x0, ny0, nx1, ny1, "\u00b0" + ntext))
                STATS["degree_sign_merged"] += 1
                i += 2
                continue
        out.append(words[i])
        i += 1
    return out


RE_SUBCHAPTER = re.compile(r"^SUB-?\s?CHAPTER\s+[IVXLC]+\b")


def is_caps_title(text: str) -> bool:
    """A line set entirely in capitals, as a sub-chapter's title is."""
    letters = [c for c in text if c.isalpha()]
    return bool(letters) and not any(c.islower() for c in letters)

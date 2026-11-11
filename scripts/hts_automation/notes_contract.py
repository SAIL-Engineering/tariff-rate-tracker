"""The legal-notes record contract the US corpus set, for every other jurisdiction.

build_hts_notes.py defines what a notes record in the notes index looks like
for the US, and sail-gtx reads that shape (server/src/services/htsNotes.ts
toNoteRecord, NOTES_RETURN_FIELDS). The Singapore, Malaysia and Vietnam parsers
build their own whole-note records from very different sources (two PDFs and a
workbook); this module turns them into the US shape so the index holds one
kind of record whatever the jurisdiction:

  * the same fields, and no others, with no nulls (Pinecone rejects an
    explicit null; source-specific extras such as the Vietnamese text or the
    sheet row stay in the parser's sidecar);
  * a section note carries the chapter it is printed with, the first chapter
    of its section, as the US records do;
  * cross-references (refs_*) on every record, computed when the parser did
    not supply them;
  * a lettered note is stored twice over, whole and once per direct lettered
    paragraph -- `N-1-1` and `N-1-1(a)`, `(b)` ... -- under the US rule: always
    for the General Interpretative Rules, otherwise when the note has three or
    more direct paragraphs or runs to 600 characters, and never when its
    letters restart (two lists in one note have no unambiguous cite id).

The US finds direct paragraphs from the indentation of the printed lines. The
other sources keep only the note text, so here a direct paragraph is a
lower-case letter in parentheses that opens the text or follows ':', ';' or
'.' (optionally then 'and'/'or'), and the letters must run a, b, c ... in
order; anything else -- (i), (1), (A), or a letter out of sequence -- belongs to
the paragraph it sits in.
"""
from __future__ import annotations

import hashlib
import re
from typing import Callable

# Exactly the fields a US notes record carries (build_hts_notes.make_record).
PINECONE_FIELDS = (
    "_id", "kind", "section", "chapter", "note_number", "paragraph", "cite_id",
    "chunk_text", "display_text", "refs_chapters", "refs_headings",
    "refs_sections", "refs_subheadings", "revision", "jurisdiction",
    "source_url", "source_sha256", "content_sha256", "page",
)

# The Harmonized System's sections and the chapter each opens with.
SECTION_FIRST_CHAPTER = {
    "I": "1", "II": "6", "III": "15", "IV": "16", "V": "25", "VI": "28",
    "VII": "39", "VIII": "41", "IX": "44", "X": "47", "XI": "50", "XII": "64",
    "XIII": "68", "XIV": "71", "XV": "72", "XVI": "84", "XVII": "86",
    "XVIII": "90", "XIX": "93", "XX": "94", "XXI": "97",
}

# Cross-references as the HS prints them (heading 03.01, subheading 0306.11 or
# 8471.30.00) and as the US prints them (heading 0301), normalised to the US
# corpus's digits-only form.
_RE_H4 = re.compile(r"\bheadings?\s+((?:\d{2}\.?\d{2}(?:\s*(?:,|and|or|to)\s*)?)+)",
                    re.IGNORECASE)
_RE_S = re.compile(r"\bsub-?headings?\s+((?:\d{4}\.?\d{2}(?:\.\d{2,4})?"
                   r"(?:\s*(?:,|and|or|to)\s*)?)+)", re.IGNORECASE)
_RE_CH = re.compile(r"\bChapters?\s+(\d{1,2})(?:\s*(?:,|and|or|to)\s*(\d{1,2}))*",
                    re.IGNORECASE)
_RE_SEC = re.compile(r"\bSections?\s+((?:[IVX]+(?:\s*(?:,|and|or|to)\s*)?)+)")


def extract_refs(text: str) -> dict[str, list[str]]:
    headings = {re.sub(r"\D", "", h) for m in _RE_H4.finditer(text)
                for h in re.findall(r"\d{2}\.?\d{2}", m.group(1))}
    subheadings = set()
    for m in _RE_S.finditer(text):
        for s in re.findall(r"\d{4}\.?\d{2}(?:\.\d{2,4})?", m.group(1)):
            digits = re.sub(r"\D", "", s)
            subheadings.add(digits[:6] if len(digits) > 6 else digits)
    chapters = set()
    for m in _RE_CH.finditer(text):
        chapters.update(str(int(c)) for c in re.findall(r"\d{1,2}", m.group(0)))
    sections = {s for m in _RE_SEC.finditer(text)
                for s in re.findall(r"[IVX]+", m.group(1))}
    return {
        "refs_sections": sorted(sections),
        "refs_chapters": sorted(chapters, key=int),
        "refs_headings": sorted(headings),
        "refs_subheadings": sorted(subheadings),
    }


_RE_LABEL = re.compile(r"\(([a-z]|ij)\)\s")
# A clear paragraph boundary: the start, or ':', ';' or '.' (perhaps closing a
# parenthesis, perhaps then 'and'/'or').
_RE_STRONG = re.compile(r"(?:^|[:;.]\)?(?:\s*(?:and|or))?)$")
# Words that make a following "(b)" a reference, not a paragraph: "Rule 2 (b)",
# "Note 1 (c)", "paragraph (a)", "of (b) above".
_RE_REFERENCE = re.compile(
    r"\b(?:rules?|notes?|paragraphs?|sub-?paragraphs?|items?|headings?|"
    r"sub-?headings?|chapters?|sections?|of|in|under|to|see|by)"
    r"(?:\s+[\dA-Za-z.]+)?$", re.IGNORECASE)


def _next_letters(letter: str) -> set[str]:
    # The HS letters run (h), (ij), (k): "ij" stands in for "i" so it is not
    # read as a roman numeral. A source that prints a plain (i) there goes on
    # to (k) or to (j).
    if letter == "h":
        return {"ij", "i"}
    if letter == "ij":
        return {"k"}
    if letter == "i":
        return {"j", "k"}
    return {chr(ord(letter) + 1)}


def split_paragraphs(text: str) -> tuple[str, list[tuple[str, str]]] | None:
    """Text -> (lead-in, [(letter, paragraph text)]) for its direct lettered
    paragraphs, or None when it has none or its letters restart.

    A letter counts when it is the next one in sequence and either follows a
    clear boundary or follows ordinary text that is not a reference ("(a)
    Refined copper (b) Copper alloys", or a table row "... Si (b) Copper
    alloys"). A restart at (a) after a clear boundary means two lists."""
    starts: list[tuple[int, int, str]] = []
    expected = {"a"}
    for m in _RE_LABEL.finditer(text):
        letter = m.group(1)
        before = text[:m.start()].rstrip()
        strong = bool(_RE_STRONG.search(before))
        if letter in expected and (strong or not _RE_REFERENCE.search(before)):
            starts.append((m.start(), m.end(), letter))
            expected = _next_letters(letter)
        elif letter == "a" and starts and strong:
            return None                          # a second list: no cite id
    if not starts:
        return None
    lead = text[:starts[0][0]].strip()
    paras = []
    for i, (_, body_start, letter) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
        paras.append((letter, text[body_start:end].strip()))
    return lead, paras


def _label_of(record: dict) -> str:
    """'Chapter 1, Note 1' from '[N-1-1] Chapter 1, Note 1: <chunk_text>'."""
    head = f"[{record['cite_id']}] "
    tail = f": {record['chunk_text']}"
    display = record["display_text"]
    if not (display.startswith(head) and display.endswith(tail)):
        raise ValueError(f"{record['cite_id']}: display_text is not "
                         f"'[cite] label: chunk_text'")
    return display[len(head):len(display) - len(tail)]


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def finalize(records: dict[str, dict],
             refs: Callable[[str], dict] = extract_refs) -> dict[str, dict]:
    """Whole-note records (cite_id -> record) -> the US-shaped record set:
    section chapters filled, refs present, paragraph records added. The
    paragraph records sit right after their note."""
    out: dict[str, dict] = {}
    for cite, whole in records.items():
        whole = dict(whole)
        if whole["kind"] == "section_note" and not whole.get("chapter"):
            whole["chapter"] = SECTION_FIRST_CHAPTER.get(whole.get("section") or "")
        if "refs_headings" not in whole:
            whole.update(refs(whole["chunk_text"]))
        whole["paragraph"] = None
        out[cite] = whole
        split = split_paragraphs(whole["chunk_text"])
        if not split:
            continue
        lead, paras = split
        if not (whole["kind"] == "gri" or len(paras) >= 3
                or len(whole["chunk_text"]) >= 600):
            continue
        label = _label_of(whole)
        for letter, body in paras:
            chunk = f"{lead} ({letter}) {body}".strip()
            pcite = f"{cite}({letter})"
            if pcite in records or pcite in out:
                raise ValueError(f"paragraph cite id {pcite} already exists")
            out[pcite] = {
                **whole,
                "_id": f"{whole['_id']}|{letter}",
                "paragraph": f"({letter})",
                "cite_id": pcite,
                "chunk_text": chunk,
                "display_text": f"[{pcite}] {label}({letter}): {chunk}",
                "content_sha256": _sha(chunk),
                **refs(chunk),
            }
    return out


def pinecone_record(record: dict) -> dict:
    """A record as it goes to the notes index: the US fields, no nulls."""
    return {k: record[k] for k in PINECONE_FIELDS if record.get(k) is not None}

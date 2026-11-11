"""notes_contract: SG/MY/VN legal notes in the record shape the US corpus set."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"))

import notes_contract as nc                                  # noqa: E402

N_1_1 = ("This Chapter covers all live animals except: (a) Fish and crustaceans, "
         "of heading 03.01, 03.06, 03.07 or 03.08; (b) Cultures of micro-organisms "
         "and other products of heading 30.02; and (c) Animals of heading 95.08.")


def letters(text):
    split = nc.split_paragraphs(text)
    return [l for l, _ in split[1]] if split else None


def test_direct_paragraphs_and_lead_in():
    lead, paras = nc.split_paragraphs(N_1_1)
    assert lead == "This Chapter covers all live animals except:"
    assert [l for l, _ in paras] == ["a", "b", "c"]
    assert paras[2][1] == "Animals of heading 95.08."


def test_hs_ij_and_a_plain_i_both_lead_to_k():
    hs = " ".join(f"({l}) item {l};" for l in "abcdefgh") + " (ij) item ij; (k) item k."
    assert letters("Not covered: " + hs)[-3:] == ["h", "ij", "k"]
    plain = " ".join(f"({l}) item {l};" for l in "abcdefghi") + " (k) item k."
    assert letters("Not covered: " + plain)[-3:] == ["h", "i", "k"]


def test_definition_lists_without_punctuation():
    # Chapter 74 Note 1 / a table row ending "... Si (b) Copper alloys"
    assert letters("the following meanings: (a) Refined copper Metal containing 99.85% "
                   "Ag Silver 0.25 Si (b) Copper alloys Metallic substances") == ["a", "b"]


def test_references_are_not_paragraphs():
    text = ("When by application of Rule 2 (b) or for any other reason goods are "
            "classifiable: (a) the most specific; (b) mixtures by essential character; "
            "(c) the last in numerical order, as in paragraph (a) above.")
    assert letters(text) == ["a", "b", "c"]


def test_a_second_list_has_no_cite_ids():
    assert nc.split_paragraphs("Note: (a) one; (b) two. Also: (a) three; (b) four.") is None


def _whole(cite="N-1-1", kind="chapter_note", text=N_1_1, **extra):
    return {"_id": f"VN|r|{kind}|1|1", "kind": kind, "section": "I", "chapter": "1",
            "note_number": "1", "paragraph": None, "cite_id": cite, "chunk_text": text,
            "display_text": f"[{cite}] Chapter 1, Note 1: {text}", "revision": "r",
            "jurisdiction": "VN", "source_url": "u", "source_sha256": "s",
            "content_sha256": "c", "sheet_row": 16, "chunk_text_vi": "vi", **extra}


def test_finalize_adds_us_shaped_paragraph_records():
    out = nc.finalize({"N-1-1": _whole()})
    assert list(out) == ["N-1-1", "N-1-1(a)", "N-1-1(b)", "N-1-1(c)"]
    a = out["N-1-1(a)"]
    assert a["_id"] == "VN|r|chapter_note|1|1|a" and a["paragraph"] == "(a)"
    assert a["chunk_text"].startswith("This Chapter covers all live animals except: (a) Fish")
    assert a["display_text"].startswith("[N-1-1(a)] Chapter 1, Note 1(a): This Chapter")
    assert a["refs_headings"] == ["0301", "0306", "0307", "0308"]
    assert "9508" in out["N-1-1"]["refs_headings"]


def test_thresholds_follow_the_us():
    short = "Not covered: (a) one; (b) two."
    assert list(nc.finalize({"N-1-1": _whole(text=short)})) == ["N-1-1"]
    gri = _whole("GRI-2", "gri", short)
    assert "GRI-2(b)" in nc.finalize({"GRI-2": gri})               # always for GRIs
    long = "Not covered: (a) " + "x " * 320 + "; (b) two."
    assert "N-1-1(b)" in nc.finalize({"N-1-1": _whole(text=long)})


def test_section_note_carries_its_first_chapter():
    sn = _whole("SN-XV-9", "section_note", "For Chapters 74 to 76: (a) Bars", section="XV")
    sn["chapter"] = None
    assert nc.finalize({"SN-XV-9": sn})["SN-XV-9"]["chapter"] == "72"


def test_pinecone_record_is_the_us_field_set_without_nulls():
    rec = nc.pinecone_record(nc.finalize({"N-1-1": _whole()})["N-1-1"])
    assert set(rec) <= set(nc.PINECONE_FIELDS)
    assert "paragraph" not in rec and "sheet_row" not in rec and "chunk_text_vi" not in rec
    assert None not in rec.values()


def test_extract_refs_reads_hs_and_us_forms():
    r = nc.extract_refs("of heading 03.01, 03.06 or 0308; subheading 0306.11 and "
                        "8471.30.00; Chapters 74 to 76; Section XV")
    assert r["refs_headings"] == ["0301", "0306", "0308"]
    assert r["refs_subheadings"] == ["030611", "847130"]
    assert r["refs_chapters"] == ["74", "76"] and r["refs_sections"] == ["XV"]

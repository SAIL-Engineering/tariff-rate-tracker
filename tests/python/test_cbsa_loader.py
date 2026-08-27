"""CBSA (Canada) loader: ancestor-count indent, orphans, duplicates, order."""
import csv

import pytest

import build_hts_corpus as bhc
from conftest import build


def test_orphan_code_becomes_root(fixtures, ca_chapters):
    """9903.00.00 has no 4-digit heading row in the file. Ancestor-count indent
    makes it a root by construction (353 such codes in CA rev 1); a fixed
    length->indent map made a dozen Ch.99 provisions inherit an arbitrary
    sibling's 52k-char description."""
    b = build(fixtures / "ca_ch99_orphan_slice.csv", ca_chapters,
              source_format="cbsa", jurisdiction="CA")
    assert len(b.roots) == 1
    rec = b.records[0]
    assert rec["code"] == "9903.00.00"
    assert rec["depth"] == 8
    # breadcrumb must not contain any adopted foreign parent text
    assert rec["chunk_text"].count(">") <= 1


def test_duplicate_code_dropped_once_and_counted(fixtures, ca_chapters):
    """5206.41.00.00 appears twice in CA rev 1 — first wins, counted in stats."""
    b = build(fixtures / "ca_dupe_slice.csv", ca_chapters,
              source_format="cbsa", jurisdiction="CA")
    assert b.stats.dropped_duplicates == 1
    assert b.stats.coded_row_count == len(b.stats.coded_digits) == 4
    assert sum(1 for r in b.records if r["code"] == "5206.41.00.00") == 1


def test_ancestor_indent_min_len_semantics():
    codes = {"0101", "01012", "01012100", "0101210000"}
    assert bhc._cbsa_indent("0101", codes) == 0
    assert bhc._cbsa_indent("01012", codes) == 1
    assert bhc._cbsa_indent("01012100", codes) == 2
    assert bhc._cbsa_indent("0101210000", codes) == 3
    # orphan: nothing above it present
    assert bhc._cbsa_indent("9903000000", codes) == 0


def test_out_of_document_order_raises(tmp_path, ca_chapters, fixtures):
    """A child preceding its ancestor must fail loudly, not silently reparent."""
    rows = list(csv.reader(open(fixtures / "ca_dupe_slice.csv", encoding="utf-8-sig")))
    hdr, data = rows[0], rows[1:]
    # move the 10-digit row before its 4-digit ancestor
    data = [data[3]] + data[:3] + data[4:]
    bad = tmp_path / "bad_order.csv"
    with bad.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(hdr)
        w.writerows(data)
    with pytest.raises(SystemExit, match="document order"):
        bhc.load_rows_cbsa(bad)

"""Taiwan adapter: note_8 parsing (continuation lines, dash levels,
sections), bilingual canonical emission, reconciliation, the logout-stub
tripwire and the three-outcome gate."""
import argparse
import csv
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parents[2] / "scripts" / "hts_automation"))

from acquire import tw_customs as tw  # noqa: E402


NOTE8_EN = """HS_NO     NOTE\r
01       Chapter 1 live animals\r
0101     Live horses, asses, mules and hinnies\r
01012    -Horses :\r
010121   Pure-bred breeding animals\r
01012100 Live horses, pure-bred breeding animals\r
29       Chapter 29 organic chemicals\r
2931     Other organo-inorganic compounds\r
293153   O-(3-chloropropyl) O-[4-nitro]\r
methylphosphonothionate\r
29315300 Same wrapped leaf\r
S01      SECTION I LIVE ANIMALS; ANIMAL PRODUCTS\r
S06      SECTION VI PRODUCTS OF THE CHEMICAL OR ALLIED INDUSTRIES\r
"""

NOTE8_ZH = """HS_NO     NOTE\r
01       第１章　活動物\r
0101     馬、驢、騾及駃騠\r
01012    ─馬︰\r
010121   純種繁殖用\r
01012100 馬，純種繁殖用\r
29       第２９章　有機化學品\r
2931     其他有機無機化合物\r
293153   某化學品\r
29315300 某化學品葉\r
S01      第１類　活動物；動物產品\r
S06      第６類　化學品\r
"""


def _write(tmp_path, name, text):
    p = tmp_path / name
    p.write_text(text, encoding="utf-8", newline="")
    return p


def test_parse_note8_continuations_and_sections(tmp_path):
    nodes, sections = tw.parse_note8(_write(tmp_path, "note_8_E.txt", NOTE8_EN))
    by = {n["code"]: n["desc"] for n in nodes}
    # wrapped description joined
    assert by["293153"] == "O-(3-chloropropyl) O-[4-nitro] methylphosphonothionate"
    # dash marker stripped
    assert by["01012"] == "Horses :"
    assert sections["S01"].startswith("SECTION I LIVE ANIMALS")
    assert len(sections) == 2


def test_parse_note8_layout_tripwire(tmp_path):
    bad = "HS_NO     NOTE\r\nnonsense first line\r\n"
    with pytest.raises(SystemExit):
        tw.parse_note8(_write(tmp_path, "bad.txt", bad))


def _leaves():
    return [
        {"code": "01012100003", "zh": "馬，純種繁殖用", "en": "Live horses, pure-bred",
         "col1": "2.5%", "col2": "0% (PA,GT,NI,SV,HN,NZ,SG)", "col3": "2.5%",
         "unit_qty": "HED", "unit_wt": "KGM", "levy": "", "import_reg": "",
         "export_reg": ""},
        {"code": "29315300001", "zh": "某化學品葉", "en": "Wrapped leaf",
         "col1": "免稅" if False else "0%", "col2": "", "col3": "0%",
         "unit_qty": "", "unit_wt": "KGM", "levy": "R", "import_reg": "",
         "export_reg": ""},
    ]


def test_convert_bilingual_with_longest_prefix_parents(tmp_path, monkeypatch):
    note8_en = _write(tmp_path, "note_8_E.txt", NOTE8_EN)
    note8_zh = _write(tmp_path, "note_8_C.txt", NOTE8_ZH)
    monkeypatch.setattr(tw, "parse_main_xls", lambda p: _leaves())
    out = tmp_path / "tw_tariff_2026_rev_729.csv"
    stats = tw.convert(tmp_path / "fake.xls", note8_en, note8_zh, out)
    assert stats["leaves"] == 2

    rows = list(csv.DictReader(out.open(encoding="utf-8")))
    by = {r["GOODS_CODE"]: r for r in rows}
    # 11-digit leaf parented under the 8-digit line, one level deeper
    assert by["01012100003"]["IS_LEAF"] == "1"
    assert int(by["01012100003"]["INDENT"]) == int(by["01012100"]["INDENT"]) + 1
    # 5-digit dash level is a REAL level between 4 and 6
    assert int(by["010121"]["INDENT"]) == int(by["01012"]["INDENT"]) + 1
    assert by["01012100003"]["UNIT"] == "HED"

    zh_rows = list(csv.DictReader((tmp_path / "tw_tariff_2026_rev_729.zh.csv")
                                  .open(encoding="utf-8")))
    zh_by = {r["GOODS_CODE"]: r for r in zh_rows}
    assert zh_by["01012100003"]["DESCRIPTION"] == "馬，純種繁殖用"
    assert [r["GOODS_CODE"] for r in rows] == [r["GOODS_CODE"] for r in zh_rows]


def test_chapters_shared_format(tmp_path):
    note8_en = _write(tmp_path, "note_8_E.txt", NOTE8_EN)
    note8_zh = _write(tmp_path, "note_8_C.txt", NOTE8_ZH)
    out_en, out_zh = tmp_path / "ch.json", tmp_path / "ch.zh.json"
    tw.make_tw_chapters(note8_en, note8_zh, out_en, out_zh)
    import json
    en = json.loads(out_en.read_text(encoding="utf-8"))
    zh = json.loads(out_zh.read_text(encoding="utf-8"))
    assert en[0] == {"chapter": "01", "description": "Live animals",
                     "section": "I",
                     "sectionTitle": "Live animals; animal products"}
    assert zh[0]["description"] == "活動物"
    assert zh[0]["sectionTitle"] == "活動物；動物產品"


class _FakeResp:
    def __init__(self, content=b"", ctype="application/octet-stream"):
        self.content = content
        self.headers = {"Content-Type": ctype}
    def raise_for_status(self):
        pass


def test_logout_stub_retries_once_then_blocks(tmp_path, monkeypatch):
    calls = {"page": 0, "dl": 0}
    stub = _FakeResp(b"<head>Logout</head>", "text/html; charset=UTF-8")

    class S:
        headers = {}
        def get(self, url, **kw):
            if "Download" in url:
                calls["dl"] += 1
                return stub
            calls["page"] += 1
            return _FakeResp(b"x" * 2000, "text/html")

    monkeypatch.setattr(tw, "fetch_page", lambda s: calls.__setitem__("page", calls["page"] + 1))
    with pytest.raises(tw.PortalBlocked):
        tw.download(S(), "note_8_E.txt", tmp_path / "x.txt")
    assert calls["dl"] == 2          # original + one post-re-session retry
    assert calls["page"] == 1        # exactly one re-session


def test_gate_modes(tmp_path, monkeypatch):
    monkeypatch.setattr(tw, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(tw, "_session", lambda: None)

    # Portal unreachable -> clean in_progress skip
    def boom(session):
        raise tw.PortalBlocked("connect timeout")
    monkeypatch.setattr(tw, "fetch_page", boom)
    chk = tw.check_latest({"code": "TW"}, argparse.Namespace())
    assert chk.status == "in_progress"
    assert "unreachable" in chk.detail

    # Unchanged -> current revision reported (gate resolves to skip)
    tw.save_state({"corpus_revision": "2026_rev_729",
                   "last_modify_date": "2026-07-29",
                   "effective_date": "2026-07-29"})
    monkeypatch.setattr(tw, "fetch_page", lambda s: "CCC CODE last modify date&nbsp;2026-07-29 ")
    chk = tw.check_latest({"code": "TW"}, argparse.Namespace())
    assert chk.status == "available" and chk.rev_id == "2026_rev_729"

    # New modify date -> new revision available
    monkeypatch.setattr(tw, "fetch_page", lambda s: "CCC CODE last modify date 2026-11-15")
    chk = tw.check_latest({"code": "TW"}, argparse.Namespace())
    assert chk.rev_id == "2026_rev_1115" and chk.extras["mode"] == "full"


def test_rev_mapping():
    assert tw._rev_from_modify_date("2026-07-29") == ("2026_rev_729", 2026, 729)
    assert tw._rev_from_modify_date("2027-01-05") == ("2027_rev_105", 2027, 105)

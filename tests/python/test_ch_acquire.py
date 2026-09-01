"""ch_tares adapter: tree conversion, tier/indent mapping, gate outcomes."""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parents[2] / "scripts" / "hts_automation"
sys.path.insert(0, str(HERE))

from acquire import ch_tares as ch                      # noqa: E402
import refresh                                          # noqa: E402
from check_upstream import UpstreamCheck                # noqa: E402


def _tree_xml(tmp_path, rows):
    def tariff(sorter, num, typ, pad=0, vkr="", en="x", de="dx",
               vto="2999-12-31"):
        return f"""<Tariff><sorter>{sorter}</sorter><objNumber>{num}</objNumber>
<objType>{typ}</objType><tn8Vkr>{vkr}</tn8Vkr><gtAns>1.0</gtAns>
<padDash></padDash><padNum>{pad}</padNum>
<text><de>{de}</de><fr>f</fr><it>i</it><en>{en}</en></text>
<gtBem><de>Fr. je Stück</de><en>Fr. per piece(s)</en></gtBem>
<validFrom>2012-01-01</validFrom><validTo>{vto}</validTo></Tariff>"""
    body = "".join(tariff(*r[:-1], **r[-1]) if isinstance(r[-1], dict)
                   else tariff(*r) for r in rows)
    tmp_path.mkdir(parents=True, exist_ok=True)
    p = tmp_path / "TariffsTree_v1.xml"
    p.write_text(f'<TariffsTree created="2026-09-01T18:00:00">{body}'
                 f'</TariffsTree>', encoding="utf-8")
    return p


BASE = [
    (1, "01", "TAB", 0, "", "LIVE ANIMALS"),
    (2, "01", "TN2", 0, "", "Live animals"),
    (3, "0101", "TN4", 0, "", "Live horses:"),
    (4, "1", "VT6", 1, "", "horses:"),
    (5, "0101.21", "TN6", 2, "", "pure-bred:"),
    (6, "0101.2110", "TN8", 3, "I", "within the tariff quota"),
    (7, "911", "STI", 1, "", "foals"),
    (8, "0101.2190", "TN8", 3, "I+E", "other"),
]


def test_convert_tiers_langs_and_leaves(tmp_path):
    xml = _tree_xml(tmp_path, BASE)
    out = tmp_path / "canonical.csv"
    stats = ch.convert(xml, out)
    rows = list(csv.DictReader(out.open(encoding="utf-8-sig")))
    assert [(r["GOODS_CODE"], r["SUFFIX"], r["INDENT"], r["IS_LEAF"])
            for r in rows] == [
        ("01", "80", "0", "0"),
        ("0101", "80", "1", "0"),
        ("", "10", "2", ""),          # VT6 -> condition
        ("010121", "80", "3", "0"),
        ("01012110", "80", "4", "1"),
        ("01012190", "80", "4", "1"),
    ]
    assert stats["leaves"] == 2 and stats["dropped_stat_keys"] == 1
    assert stats["dropped_structure"] == 1   # TAB
    assert rows[4]["UNIT"] == "Fr. per piece(s)"
    assert rows[4]["GT_RATE"] == "1.0"
    # language siblings from the same parse
    de = list(csv.DictReader(out.with_suffix(".de.csv")
                             .open(encoding="utf-8-sig")))
    assert de[4]["DESCRIPTION"] == "dx"
    assert out.with_suffix(".fr.csv").is_file()
    assert out.with_suffix(".it.csv").is_file()


def test_convert_rejects_export_only_tn8(tmp_path):
    rows = BASE[:5] + [(6, "0101.2110", "TN8", 3, "E", "export only")]
    with pytest.raises(SystemExit):
        ch.convert(_tree_xml(tmp_path, rows), tmp_path / "o.csv")


def test_convert_drops_expired_rows(tmp_path):
    rows = BASE + [(9, "0101.2199", "TN8", 3, "I", "gone",
                    {"vto": "2020-01-01"})]
    stats = ch.convert(_tree_xml(tmp_path, rows), tmp_path / "o.csv")
    assert stats["end_dated_dropped"] == 1


def test_classification_hash_tracks_en_and_structure(tmp_path):
    a = ch.classification_hash(_tree_xml(tmp_path / "a", BASE))
    changed = [list(r) for r in BASE]
    changed[5][5] = "renamed line"
    b = ch.classification_hash(_tree_xml(tmp_path / "b",
                                         [tuple(r) for r in changed]))
    assert a != b
    # a German-only change must NOT trigger a corpus republish
    de_only = [list(r) for r in BASE]
    c = ch.classification_hash(_tree_xml(tmp_path / "c",
                                         [tuple(r) for r in de_only]))
    assert a == c


def test_chapters_from_swiss_tab_sections(tmp_path):
    xml = _tree_xml(tmp_path, BASE)
    out = tmp_path / "chapters_ch.json"
    ch.make_ch_chapters(xml, out)
    import json
    data = json.loads(out.read_text())
    assert data == [{"chapter": "01", "description": "Live animals",
                     "section": "I", "sectionTitle": "Live animals"}]


def test_rev_from_created():
    assert ch.rev_from_created("2026-09-01T18:25:14") == (2026, 901,
                                                          "2026-09-01")
    assert ch.rev_from_created("2026-12-31T00:00:00")[1] == 1231


def test_gate_rates_only_flows_through(tmp_path, monkeypatch):
    class _Adapter:
        def check_latest(self, spec, args):
            return UpstreamCheck(
                status="available", rev_id="2026_rev_901", year=2026,
                rev_num=901, effective_date="2026-09-01",
                detail="master data regenerated; tree unchanged",
                extras={"mode": "rates_only"})
    args = argparse.Namespace(if_new=True, plan_only=False, revision=None)
    spec = {"code": "CH", "registry": str(tmp_path / "r.csv"),
            "acquire": {"adapter": "ch_tares", "options": {}}}
    refresh.gate_if_new(spec, _Adapter(), args)
    assert args.rates_only is True

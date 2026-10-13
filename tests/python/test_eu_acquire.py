"""acquire/eu_taric.fetch(): the manifest-parsing path, against fixtures in
the vendored downloader's REAL schema (latest.json is a POINTER; the file
list lives in metadata.json). The first version of fetch() read a schema
that did not exist and KeyError'd — this test pins the contract."""
import json
from pathlib import Path

import pytest

from acquire import eu_taric


class _Args:
    source = None
    revision = None
    effective_date = None


def test_fetch_parses_pointer_and_manifest(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    out_dir = tmp_path / "data/eu_tariff_source/.circabc_download"
    release_dir = out_dir / "2026" / "2026-08"
    release_dir.mkdir(parents=True)

    files = []
    for logical in ("nomenclature_en", "nomenclature_fr", "declarable_codes",
                    "duties_import", "geo_composition", "measure_exclusions",
                    "measure_conditions", "addcodes_descriptions"):
        f = release_dir / f"{logical}.xlsx"
        f.write_bytes(b"PK\x03\x04fixture")
        files.append({"logical_name": logical, "local_file": str(f)})

    manifest_path = release_dir / "metadata.json"
    manifest_path.write_text(json.dumps({"files": files}))
    (out_dir / "latest.json").write_text(json.dumps({
        "dataset": "EU TARIC monthly database extraction",
        "release_month": "2026-08",
        "snapshot_date": None,
        "release_folder_id": "x",
        "release_folder_url": "https://circabc.europa.eu/ui/group/g/library/x",
        "metadata_file": str(manifest_path),
        "updated_at_utc": "2026-08-27T00:00:00Z",
    }))

    monkeypatch.setattr(eu_taric, "convert",
                        lambda nom, dec, dest, check_lang=None, as_of=None:
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        or dest.write_text("GOODS_CODE\n"))
    import acquire.vendor.eu_taric_downloader as vendor
    monkeypatch.setattr(vendor, "main", lambda argv: 0)

    spec = {"acquire": {"options": {}}, "registry": None}
    res = eu_taric.fetch(spec, _Args())
    assert res.rev_id == "2026_rev_8" and res.year == 2026 and res.rev_num == 8
    assert res.effective_date == "2026-08-01"
    assert res.source_url.startswith("https://circabc")
    assert set(res.extras) == {"eu_duties_xlsx", "eu_geo_xlsx",
                               "eu_exclusions_xlsx", "eu_conditions_xlsx",
                               "eu_addcodes_xlsx"}


def test_fetch_fails_without_exclusions(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    out_dir = tmp_path / "data/eu_tariff_source/.circabc_download"
    release_dir = out_dir / "2026" / "2026-08"
    release_dir.mkdir(parents=True)
    files = []
    for logical in ("nomenclature_en", "declarable_codes", "duties_import",
                    "geo_composition"):
        f = release_dir / f"{logical}.xlsx"
        f.write_bytes(b"PK\x03\x04")
        files.append({"logical_name": logical, "local_file": str(f)})
    mp = release_dir / "metadata.json"
    mp.write_text(json.dumps({"files": files}))
    (out_dir / "latest.json").write_text(json.dumps(
        {"release_month": "2026-08", "metadata_file": str(mp)}))
    import acquire.vendor.eu_taric_downloader as vendor
    monkeypatch.setattr(vendor, "main", lambda argv: 0)
    with pytest.raises(SystemExit, match="Measure exclusions"):
        eu_taric.fetch({"acquire": {"options": {}}}, _Args())


# ─── end dates: future vs past ───────────────────────────────────────

import csv as _csv                                           # noqa: E402
import datetime as _dt                                       # noqa: E402


def _write(path, rows):
    with path.open("w", newline="", encoding="utf-8") as fh:
        _csv.writer(fh).writerows(rows)
    return path


def _sources(tmp_path, nom_end, dec_end):
    """One chapter + one heading + one 10-digit line, with the end dates under
    test on the 10-digit line (Nomenclature uses DD-MM-YYYY, Declarable DDMMYYYY)."""
    nom = _write(tmp_path / "nom.csv", [
        ["Goods code", "Start date", "End date", "Language", "Hier. Pos.",
         "Indent", "Description", "Descr. start date"],
        ["0100000000 80", "01-01-1972", "", "EN", "", "", "LIVE ANIMALS", ""],
        ["0201000000 80", "01-01-1972", "", "EN", "", "-", "Meat of bovine animals", ""],
        ["0201300031 80", "01-01-2022", nom_end, "EN", "", "--", "Thick flank", ""],
    ])
    dec = _write(tmp_path / "dec.csv", [
        ["Goods code", "Start date", "Decl. start date", "IS_LEAF", "End date"],
        # Every nomenclature line has a declarable row (the real files are
        # row-for-row); only leaves carry IS_LEAF=1.
        ["0100000000 80", "01-01-1972", "01-01-1972", "0", ""],
        ["0201000000 80", "01-01-1972", "01-01-1972", "0", ""],
        ["0201300031 80", "01-01-2022", "01-01-2022", "1", dec_end],
    ])
    return nom, dec


def _rows(path):
    with path.open(newline="", encoding="utf-8") as fh:
        return list(_csv.DictReader(fh))


def test_future_end_date_keeps_the_code_and_its_leaf_flag(tmp_path):
    """TARIC's 2026-10 release end-dated 80 nomenclature lines and 83
    declarable rows at 31-12-2026. They are declarable until then: dropping
    them lost 71 live codes and broke the join for 3 (EU/XI failed from
    2026-10-02)."""
    nom, dec = _sources(tmp_path, "31-12-2026", "31122026")
    out = tmp_path / "out.csv"
    stats = eu_taric.convert(nom, dec, out, as_of=_dt.date(2026, 10, 1))
    assert stats["end_dated_dropped"] == 0 and stats["unjoined"] == 0
    rows = _rows(out)
    assert [r["GOODS_CODE"] for r in rows] == ["0100000000", "0201000000", "0201300031"]
    assert rows[-1]["IS_LEAF"] == "1"


def test_past_end_date_drops_the_code(tmp_path):
    nom, dec = _sources(tmp_path, "31-12-2026", "31122026")
    out = tmp_path / "out.csv"
    stats = eu_taric.convert(nom, dec, out, as_of=_dt.date(2027, 1, 1))
    assert stats["end_dated_dropped"] == 1
    assert [r["GOODS_CODE"] for r in _rows(out)] == ["0100000000", "0201000000"]


def test_missing_declarable_entry_still_fails_loudly(tmp_path):
    nom, dec = _sources(tmp_path, "", "")
    _write(dec, [  # the 10-digit line's row is gone
        ["Goods code", "Start date", "Decl. start date", "IS_LEAF", "End date"],
        ["0100000000 80", "01-01-1972", "01-01-1972", "0", ""],
        ["0201000000 80", "01-01-1972", "01-01-1972", "0", ""],
    ])
    with pytest.raises(SystemExit, match="no entry in"):
        eu_taric.convert(nom, dec, tmp_path / "out.csv", as_of=_dt.date(2026, 10, 1))


def test_unparseable_date_fails_loudly(tmp_path):
    nom, dec = _sources(tmp_path, "2026/12/31", "31122026")
    with pytest.raises(SystemExit, match="unparseable TARIC date"):
        eu_taric.convert(nom, dec, tmp_path / "out.csv", as_of=_dt.date(2026, 10, 1))


@pytest.mark.parametrize("raw,expected", [
    ("31-12-2026", _dt.date(2026, 12, 31)),
    ("31122026", _dt.date(2026, 12, 31)),
    ("", None),
    (None, None),
])
def test_parse_eu_date(raw, expected):
    assert eu_taric._parse_eu_date(raw) == expected

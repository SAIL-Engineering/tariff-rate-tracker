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
                        lambda nom, dec, dest, check_lang=None:
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

"""sync_usitc_archive: archive-listing parser and registry merge (network-free).
The fixture mirrors the live markup of
https://www.usitc.gov/harmonized_tariff_information/hts/archive/list (2026-09-15)."""
from __future__ import annotations

import csv
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO / "scripts" / "hts_automation"))

import sync_usitc_archive as s                            # noqa: E402
import usitc_native as u                                  # noqa: E402

FIXTURE = """
<div class="views-field views-field-field-hts-arch-published-date views-accordion-header"><span class="field-content">2026 HTS Revision 19 (September 15, 2026)</span></div><div class="views-field views-field-nothing"><span class="field-content"><strong class="text-bold text-primary">Revision Link/File Downloads:</strong> <a href="https://hts.usitc.gov/download?release=2026HTSRev19&amp;releaseDate=09%2F09%2F2026"><i class="fa fa-file-code"></i> HTML</a> | <a href="/sites/default/files/tata/hts/hts_2026_revision_19_csv.csv"><i class="fa fa-file-csv"></i> CSV</a> | <a href="/sites/default/files/tata/hts/hts_2026_revision_19_json.json"><i class="fa fa-file"></i> JSON</a></span></div><div class="views-field views-field-field-hts-arch-mods-source"><span class="field-content">
  <div class="field field--name-field-hts-arch-mods-source">
    <div class="title">Modification Source(s):</div>
        <div class="field__items">
                    <div class="field__item">
<div class="margin-y-1">
    <svg class="usa-icon" aria-hidden="true" focusable="false" role="img">
        <use href="/themes/usitc_uswds_v2/assets/img/sprite.svg#navigate_next"></use>
      </svg> Further Ensuring Affordable Beef for the American Consumer (<a href="https://www.federalregister.gov/documents/2026/08/31/2026-17842/further-ensuring-affordable-beef-for-the-american-consumer" target="_blank">91 Fed. Reg . 55989</a>)
</div>
</div>
              <div class="field__item">
<div class="margin-y-1">
    <svg class="usa-icon" aria-hidden="true" focusable="false" role="img">
        <use href="/themes/usitc_uswds_v2/assets/img/sprite.svg#navigate_next"></use>
      </svg> Notice of Action: Brazil’s Acts (<a href="https://www.federalregister.gov/documents/2026/07/20/2026-14542/notice" target="_blank">91 Fed. Reg. 45516</a>)
</div>
</div>
                </div>
      </div>
</span></div>
  </div>
      <div>
    <div class="views-field views-field-field-hts-arch-published-date views-accordion-header"><span class="field-content">2021 HTSA Basic Revision 3 (April 27, 2021)</span></div><div class="views-field views-field-nothing"><span class="field-content"><strong class="text-bold text-primary">Revision Link/File Downloads:</strong> <a href="/sites/default/files/tata/hts/hts_2021_revision_basic_3_csv.csv"><i class="fa fa-file-csv"></i> CSV</a></span></div>
"""


@pytest.mark.parametrize("title,ids", [
    ("2026 HTS Revision 19 (September 15, 2026)", ["2026_rev_19"]),
    ("2021 HTSA Basic Revision 3 (April 27, 2021)", ["2021_rev_3"]),
    ("2022 HTSA Basic and Revision 1 (February 15, 2022)", ["2022_basic", "2022_rev_1"]),
    ("2019 HTSA Basic Edition (February 15, 2019)", ["2019_basic"]),
    ("2026 HTS Basic Edition (December 31, 2025)", ["2026_basic"]),
    ("2022 HTSA Preliminary Edition (January 5, 2022)", []),
    ("2012 HTSA Supplement 1 (Rev. 1) Edition (October 23, 2012)", []),
])
def test_revision_ids(title, ids):
    assert s.revision_ids(title) == ids


def test_parse_page_files_and_sources():
    newest, older = s.parse_page(FIXTURE)
    assert newest["ids"] == ["2026_rev_19"]
    assert newest["files"]["csv"] == ("https://www.usitc.gov/sites/default/files/"
                                      "tata/hts/hts_2026_revision_19_csv.csv")
    assert newest["files"]["html"].startswith(
        "https://hts.usitc.gov/download?release=2026HTSRev19&releaseDate=")
    assert newest["sources"][0] == {
        "title": "Further Ensuring Affordable Beef for the American Consumer",
        "citation": "91 Fed. Reg. 55989",                  # archive typo normalised
        "url": "https://www.federalregister.gov/documents/2026/08/31/2026-17842/"
               "further-ensuring-affordable-beef-for-the-american-consumer",
    }
    assert newest["sources"][1]["title"] == "Notice of Action: Brazil's Acts"
    assert older["ids"] == ["2021_rev_3"]
    assert older["sources"] == [] and set(older["files"]) == {"csv"}


@pytest.mark.parametrize("raw,norm", [
    ("91 Fed. Reg. 58331", "fr 91 58331"),
    ("91 Fed. Reg . 55989", "fr 91 55989"),
    ("90. Fed. Reg. 43737", "fr 90 43737"),
    ("(90 Fed. Reg. 14705", "fr 90 14705"),
    ("90 FR 14705", "fr 90 14705"),
    ("484(f)", "484(f)"),
])
def test_norm_citation(raw, norm):
    assert s._norm_citation(raw) == norm


def test_upgrade_search_links_swaps_only_matching_citations():
    search = "https://www.federalregister.gov/documents/search?conditions%5Bterm%5D=x"
    row = {"modification_source_citations": "90 Fed. Reg. 43737 | 86 Fed. Reg. 73593",
           "federal_register_or_source_links": f"{search} | {search}"}
    entry = {"sources": [
        {"title": "T", "citation": "90. Fed. Reg. 43737",
         "url": "https://www.federalregister.gov/documents/2025/09/10/2025-17349/t"},
        {"title": "U", "citation": "87 Fed. Reg. 7357",
         "url": "https://www.federalregister.gov/documents/2022/02/10/2022-02834/u"},
    ]}
    assert s.upgrade_search_links(row, entry) == 1
    links = row["federal_register_or_source_links"].split(" | ")
    assert links[0] == "https://www.federalregister.gov/documents/2025/09/10/2025-17349/t"
    assert links[1] == search                              # no matching citation
    assert s.upgrade_search_links(row, None) == 0


def test_upgrade_search_links_skips_site_root_urls():
    search = "https://www.federalregister.gov/documents/search?conditions%5Bterm%5D=memo"
    row = {"modification_source_citations": "White House memo",
           "federal_register_or_source_links": search}
    entry = {"sources": [{"title": "M", "citation": "White House memo",
                          "url": "https://www.whitehouse.gov/"}]}
    assert s.upgrade_search_links(row, entry) == 0
    assert row["federal_register_or_source_links"] == search


def test_parse_page_makes_relative_source_links_absolute():
    page = ('<div class="views-field views-field-field-hts-arch-published-date">'
            '<span class="field-content">2024 HTS Basic Edition (January 1, 2024)</span></div>'
            '<div>Modification Source(s):<div class="margin-y-1"> Changes approved by '
            'the Committee (<a href="/harmonized_tariff_information/484_f_committee">'
            '484(f)</a>)</div></div>')
    (entry,) = s.parse_page(page)
    assert entry["ids"] == ["2024_basic"]
    assert entry["sources"] == [{
        "title": "Changes approved by the Committee", "citation": "484(f)",
        "url": "https://www.usitc.gov/harmonized_tariff_information/484_f_committee"}]


def test_upgrade_search_links_leaves_direct_links_untouched():
    row = {"modification_source_citations": "91 Fed. Reg. 1",
           "federal_register_or_source_links": "https://www.federalregister.gov/documents/2026/1/a"}
    before = dict(row)
    entry = {"sources": [{"title": "A", "citation": "91 Fed. Reg. 1",
                          "url": "https://www.federalregister.gov/documents/2026/1/b"}]}
    assert s.upgrade_search_links(row, entry) == 0 and row == before


def _write(path: Path, fields: list[str], rows: list[dict]) -> None:
    with path.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, lineterminator="\n")
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k, "NA") for k in fields})


def test_cmd_sources_fills_blank_rows_keeps_curated_and_appends_map(tmp_path, monkeypatch):
    rev_dates = tmp_path / "revision_dates.csv"
    _write(rev_dates, u.FIELDS, [
        {"revision": "2026_rev_10", "effective_date": "2026-06-08",
         "policy_family": "section_232_metals",
         "modification_source_titles": "Curated title",
         "federal_register_or_source_links": "https://example.gov/curated"},
        {"revision": "2026_rev_19", "effective_date": "2026-09-15",
         "policy_family": "section_338_canada"},
    ])
    source_map = tmp_path / "source_map.csv"
    map_fields = ["revision", "effective_date", "policy_effective_date", "tpc_date",
                  "policy_event", "tpc_policy_revision", "needs_review",
                  "usitc_archive_page_url", "modification_source_titles",
                  "modification_source_citations",
                  "federal_register_or_source_links", "source_commentary"]
    _write(source_map, map_fields, [
        {"revision": "2026_rev_10", "effective_date": "2026-06-08",
         "tpc_policy_revision": "section_232_metals",
         "modification_source_titles": "Curated title"},
    ])
    monkeypatch.setattr(s, "REV_DATES", rev_dates)
    monkeypatch.setattr(s, "SOURCE_MAP", source_map)
    archive = {
        "2026_rev_10": {"page_url": s.ARCHIVE_URL, "sources": [
            {"title": "Archive title", "citation": "91 Fed. Reg. 1", "url": "https://fr/1"}]},
        "2026_rev_19": {"page_url": s.ARCHIVE_URL, "sources": [
            {"title": "A", "citation": "91 Fed. Reg. 58331", "url": "https://fr/a"},
            {"title": "B", "citation": "91 Fed. Reg. 58339", "url": "https://fr/b"}]},
    }

    s.cmd_sources(archive, dry_run=False)

    rows = {r["revision"]: r for r in u._read_rows(rev_dates)}
    assert rows["2026_rev_10"]["modification_source_titles"] == "Curated title"
    assert rows["2026_rev_19"]["modification_source_titles"] == "A | B"
    assert rows["2026_rev_19"]["modification_source_citations"] == (
        "91 Fed. Reg. 58331 | 91 Fed. Reg. 58339")
    assert rows["2026_rev_19"]["federal_register_or_source_links"] == (
        "https://fr/a | https://fr/b")
    assert rows["2026_rev_19"]["source_commentary"] == s.COMMENTARY
    with source_map.open(newline="", encoding="utf-8") as fh:
        mapped = list(csv.DictReader(fh))
    assert [r["revision"] for r in mapped] == ["2026_rev_10", "2026_rev_19"]
    assert mapped[0]["modification_source_titles"] == "Curated title"
    assert mapped[1]["tpc_policy_revision"] == "section_338_canada"
    assert mapped[1]["needs_review"] == "NA"


def test_cmd_sources_dry_run_writes_nothing(tmp_path, monkeypatch):
    rev_dates = tmp_path / "revision_dates.csv"
    _write(rev_dates, u.FIELDS, [{"revision": "2026_rev_19",
                                  "effective_date": "2026-09-15"}])
    source_map = tmp_path / "source_map.csv"
    _write(source_map, ["revision", "tpc_policy_revision", "needs_review",
                        "modification_source_titles"], [])
    before = (rev_dates.read_bytes(), source_map.read_bytes())
    monkeypatch.setattr(s, "REV_DATES", rev_dates)
    monkeypatch.setattr(s, "SOURCE_MAP", source_map)
    s.cmd_sources({"2026_rev_19": {"page_url": s.ARCHIVE_URL, "sources": [
        {"title": "A", "citation": "", "url": "https://fr/a"}]}}, dry_run=True)
    assert (rev_dates.read_bytes(), source_map.read_bytes()) == before

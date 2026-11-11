# Tariff schedule sources

Where every jurisdiction's tariff schedule comes from: who issues it, every URL
we were given or use, and how the pipeline gets it. **Update this page whenever
a source changes or a new one is supplied.**

Two records, two jobs:

| Record | Answers | Where |
|---|---|---|
| This page | Where does the schedule come from, and how do we get it? | `SOURCES.md` |
| Revision registries | Exactly what was downloaded for each revision: URL, sha256, date, notes | `config/jurisdictions/<cc>_revisions.csv` (US: `config/revision_dates.csv`) |

Per-jurisdiction detail (file formats, corrections, parser quirks) lives in
`data/<cc>_tariff_source/README.md` where one exists. Automation options for the
hand-acquired schedules are in
[docs/jurisdiction-source-acquisition.md](docs/jurisdiction-source-acquisition.md).

**Before publishing a new SG, MY or VN edition**, check the conversion against
its sources:

```bash
python3 -I scripts/hts_automation/audit_conversion.py        # exits 1 on any failed gate
```

The script deliberately reuses none of the parsers' code. It reads each PDF with
`pdftotext -layout`, Vietnam's workbook through `zipfile`, Malaysia's rates
against its ezHS portal, and the shared ASEAN lines against the other two books.
It needs the downloaded sources in each `.xx_download/` folder; a check whose
source is absent is reported as skipped, not passed.

## At a glance

| Code | Jurisdiction | Issuing authority | Edition in use | How we get it | Refresh |
|---|---|---|---|---|---|
| US | United States | USITC | HTSUS, 2019 – 2026 revisions | `acquire/usitc.py` | Nightly |
| CA | Canada | Canada Border Services Agency (CBSA) | Customs Tariff T2026 | `acquire/cbsa.py` | Nightly |
| EU | European Union | European Commission (TARIC) | Monthly TARIC release | `acquire/eu_taric.py` | Nightly |
| XI | Northern Ireland | EU TARIC under the Windsor Framework | Same monthly TARIC release as EU | `acquire/eu_taric.py` (reused) | Nightly |
| GB | United Kingdom | Department for Business and Trade (DBT) | UK Integrated Online Tariff | `acquire/uk_tariff.py` | Nightly |
| CH | Switzerland (+ Liechtenstein) | Federal Office for Customs and Border Security (BAZG) | Tares | `acquire/ch_tares.py` | Nightly |
| KR | South Korea | Korea Customs Service (KCS) | HSK 2026 | `acquire/kr_kcs.py` | Nightly |
| TW | Taiwan | Customs Administration, Ministry of Finance | Customs Import Tariff (CCC) | `acquire/tw_customs.py` | Nightly, but the portal is unreachable from CI; frozen at `2026_rev_922` |
| DO | Dominican Republic | Dirección General de Aduanas (DGA) | Arancel de Aduanas, 7ma Enmienda (2022) | Manual: user transcription | By hand |
| SG | Singapore | Singapore Customs | STCCED 2022 | Manual: `parse_sg_stcced.py` | By hand |
| MY | Malaysia | Royal Malaysian Customs Department | Customs Duties Order 2025, P.U. (A) 384 | Manual: `parse_my_pdk.py` | By hand |
| VN | Vietnam | Ministry of Finance / Government Decree | Import-Export Tariff workbook as at 5 April 2026 | Manual: `parse_vn_tariff.py` | By hand |
| TH | Thailand | Thai Customs Department | Not built (deferred) | None | — |

Scripts are under `scripts/hts_automation/`.

---

## United States (US)

- Release list (what the nightly checks): `https://hts.usitc.gov/reststop/releaseList`
- Export list: `https://hts.usitc.gov/reststop/exportList`
- Archive index: <https://www.usitc.gov/harmonized_tariff_information/hts/archive/list>
- Per-revision files: `https://www.usitc.gov/sites/default/files/tata/hts/hts_<year>_revision_<n>_csv.csv`
  (and `_json.json`); basic editions are `hts_<year>_basic_csv.csv`. Archive
  filenames for 2019–2022 are irregular; `scripts/sync_usitc_archive.py` resolves them.
- Chapter 99 PDF: `https://hts.usitc.gov/reststop/file?release=currentRelease&filename=Chapter+99`
- Registry: `config/revision_dates.csv`

## Canada (CA)

- CBSA tariff menu (provided 2026-08-27): <https://www.cbsa-asfc.gc.ca/trade-commerce/tariff-tarif/menu-eng.html>
- Current year (provided 2026-08-27): <https://www.cbsa-asfc.gc.ca/trade-commerce/tariff-tarif/2026/menu-eng.html>
- What we download: the Access database zip, e.g.
  <https://www.cbsa-asfc.gc.ca/trade-commerce/tariff-tarif/2026/01-99/01-99-2026-2-eng.zip>,
  exported with mdbtools; `TPHS` becomes the canonical CSV.
- Numbering: CBSA's base edition T2026 is our `2026_rev_1`; T2026-1 is `2026_rev_2`.
- Registry: `config/jurisdictions/ca_revisions.csv`; detail: `data/ca_tariff_source/README.md`

## European Union (EU) and Northern Ireland (XI)

- CIRCABC TARIC library: <https://circabc.europa.eu/ui/group/0e5f18c2-4b2f-42e9-aed4-dfe50ae1263b/library/42ac4443-5aa0-44ed-9122-4430b38fd18b>
- Release month N of year Y becomes our `Y_rev_N`. The release month is a
  snapshot date, not a legal effective date: TARIC measures carry their own dates.
- XI uses the same release: the Northern Ireland Online Tariff applies the EU
  TARIC baseline under the Windsor Framework.
- Registries: `config/jurisdictions/eu_revisions.csv`, `xi_revisions.csv`

## United Kingdom (GB)

- DBT Data API dataset (provided 2026-09-01): `https://data.api.trade.gov.uk/v1/datasets/uk-tariff-2021-01-01/versions/<VERSION>/…`
  — tables `commodities-report`, `measures-as-defined`, `measures-on-declarable-commodities`
- Dataset metadata (provided): <https://data.api.trade.gov.uk/v1/datasets/uk-tariff-2021-01-01/versions/latest/metadata?format=html>
- data.gov.uk listing (provided): <https://www.data.gov.uk/dataset/2af878bc-f302-49fd-98ef-9d1f4a63a318/tariffs-to-trade-with-the-uk-from-1-january-2021>
- Geographical areas: UK Trade Tariff service API, `https://www.trade-tariff.service.gov.uk/api/v2`
- Legal instrument (provided): <https://www.legislation.gov.uk/uksi/2020/1430>
- Registry: `config/jurisdictions/gb_revisions.csv`

## Switzerland (CH)

- BAZG data hub: `https://datahub.bazg.admin.ch/public-resources/TariffMasterData_v6.zip`
  — the filename never changes; the HTTP ETag / Last-Modified is the version signal.
- Four languages from one release: English is the corpus source, and
  German/French/Italian feed the Tariff Schedule page's language switch.
- Registry: `config/jurisdictions/ch_revisions.csv`

## South Korea (KR)

Three official KCS datasets on data.go.kr (provided 2026-09-02):

| Dataset | What it is | Page |
|---|---|---|
| 15130660 | HS code item names, Korean + English (the tariff tree) | <https://www.data.go.kr/data/15130660/fileData.do> |
| 15049722 | 10-digit HSK master | <https://www.data.go.kr/en/data/15049722/fileData.do> |
| 15051179 | Tariff schedule by item number (duty rates) | <https://www.data.go.kr/en/data/15051179/fileData.do> |

- UNI-PASS lookups, for spot checks (provided):
  <https://unipass.customs.go.kr/clip/hsinfosrch/openULS0201002Q.do>,
  <https://unipass.customs.go.kr/clip/hsinfosrch/openULS0201007Q.do>,
  <https://unipass.customs.go.kr/clip/hsinfosrch/openULS0201009Q.do>
- **Gap:** `kr_revisions.csv` leaves `source_url` empty because the adapter does
  not write it. The datasets above are what it downloads.

## Taiwan (TW)

- Customs portal, Tariff Database download page (provided 2026-09-03): <https://portal.sw.nat.gov.tw/APGQ/GC453>
  (English; GC413 is the full Chinese page)
- Main file `海關進口稅則資料{YYYY}.xls` (bilingual, one row per 11-digit CCC
  code) plus `note_8_E.txt` / `note_8_C.txt` for the hierarchy.
- The portal gates downloads behind a session. It has been unreachable from both
  CI and the laptop since `2026_rev_922`.
- Registry: `config/jurisdictions/tw_revisions.csv`

## Dominican Republic (DO)

- Official book: DGA *Arancel de Aduanas, 7ma Enmienda* (2022), PDF only. The
  committed CSV is a user transcription plus 14 corrections, each checked against
  `672577902-Arancel-de-Aduanas-7ma-Enmienda-2022.pdf`; see `data/do_tariff_source/README.md`.
- **Gap:** no URL was ever recorded for that PDF, and `do_revisions.csv` leaves
  `source_url` empty. Add it here when known.
- Registry: `config/jurisdictions/do_revisions.csv`

## Singapore (SG)

- STCCED 2022 PDF (provided 2026-11-09): <https://file.go.gov.sg/stcced2022.pdf>
  — 655 pages; the 2022 edition is current.
- Singapore Customs, HS classification guidance (provided 2026-11-10):
  <https://www.customs.gov.sg/doing-business/business-resources/hs-classification-of-goods/understanding-hs-classification/>
- Parsed from `pdftotext -bbox-layout` coordinates by `parse_sg_stcced.py`. The
  PDF is not committed (gitignored `.sg_download/`); its sha256 is in the registry.
- The PDF states no commencement date; the effective date used is the HS 2022 edition date.
- Registry: `config/jurisdictions/sg_revisions.csv`; detail: `data/sg_tariff_source/README.md`

## Malaysia (MY)

Two sources, used for different things:

- **Gazette — structure, import/export duty, notes** (provided 2026-11-10):
  <https://www.customs.gov.my/images/06-prosedur/perintah-kastam/perintah/PUA_384.pdf>
  — Customs Duties Order 2025, P.U. (A) 384, 1,466 pages, gazetted 31 Oct 2025,
  in force 1 Nov 2025.
- **ezHS portal — SST, excise, cess, joined by code only** (provided 2026-11-09):
  <https://ezhs.customs.gov.my/public-tariff?tariff=UERLVkZTSHNlMzU1QW1lMjAyNjA1MTAxMQ==&km=11f7da5fa7e4e1267654f4d882564e42>
  — the `tariff` token encodes a date that rotates; `km` is per scheme and stable.
  The portal lists codes **sorted, not in book order**, so it must never be used
  for structure.
- Not yet acquired: Malaysia's 19 preferential schedules (ATIGA, ACFTA, RCEP,
  CPTPP, …), on the same ezHS URL with a different `km`.
- Registry: `config/jurisdictions/my_revisions.csv`; detail: `data/my_tariff_source/README.md`

## Vietnam (VN)

The authoritative instrument is the Government / Ministry of Finance decree
enacting the schedule. The file we parse is a **compiled** workbook, not the
decree itself: compiled by the Quang Ninh Customs Sub-Department and
redistributed via thuvienphapluat.vn.

- Workbook as Google Sheet (provided 2026-11-10; what we download, as `export?format=xlsx`):
  <https://docs.google.com/spreadsheets/d/1Tv3kzX5M-HOA0GoFjaGydTrHWD8piDh5/edit?gid=264651960>
- Same workbook, short link (provided 2026-11-10): <https://tinyurl.com/btxnk260405>
- Article announcing the 5 April 2026 update (provided 2026-11-10):
  <https://thuvienphapluat.vn/chinh-sach-phap-luat-moi/vn/ho-tro-phap-luat/chinh-sach-moi/109354/cap-nhat-link-tai-file-bieu-thue-xuat-nhap-khau-05-4-2026-moi-nhat>
- HCMC Investment and Trade Promotion Centre, English tariff page (provided 2026-11-10):
  <https://itpc.hochiminhcity.gov.vn/web/en/-/vietnam-s-customs-tariff-schedule>
- Bilingual: Vietnamese and English per row. The English is missing on part of
  the national Chapter 98.
- **The official instruments.** The workbook attributes each MFN rate to a decree.
  These, not the workbook, are what the rates must be checked against:

  | Decree | Effective | Lines citing it |
  |---|---|---|
  | 26/2023/NĐ-CP (base export/import tariff) | 15 Jul 2023 | 11,157 |
  | 73/2025/NĐ-CP | 31 Mar 2025 | 617 |
  | 144/2024/NĐ-CP | 1 Nov 2024 | 63 |
  | 199/2025/NĐ-CP | 8 Jul 2025 | 34 |

  The newest is from July 2025, so the workbook shows nothing issued after that.
  Some rates also carry a temporary 0% window "theo NĐ72" (9 Mar – 30 Apr), which
  has already expired.
- Registry: `config/jurisdictions/vn_revisions.csv`; detail: `data/vn_tariff_source/README.md`

## Thailand (TH) — deferred

- Thai Customs reference files (provided 2026-11-09):
  <https://www.customs.go.th/list_strc_download_with_document.php?order_by=co_last_update_datetime&sort_type=0&ini_content=reference_files&show_search=1&lang=en&left_menu=nmenu_esevice_006>
- Not a tariff master: 781 incremental fixed-width TIS-620 patches, each
  amending a few codes, with no base schedule and no English. A usable source
  must come from elsewhere.

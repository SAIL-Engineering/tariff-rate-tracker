# Vietnam tariff source

| What | Where |
|---|---|
| Workbook (xlsx) | `https://docs.google.com/spreadsheets/d/1Tv3kzX5M-HOA0GoFjaGydTrHWD8piDh5/export?format=xlsx` — 39 sheets, 32.3 MB, `sha256 2b55f20e…d0418f` |
| The same file as a Sheet | <https://docs.google.com/spreadsheets/d/1Tv3kzX5M-HOA0GoFjaGydTrHWD8piDh5/edit> |
| Link publisher | <https://thuvienphapluat.vn/chinh-sach-phap-luat-moi/vn/ho-tro-phap-luat/chinh-sach-moi/109354/> — publishes the current short link |
| English per-chapter PDFs | <https://itpc.hochiminhcity.gov.vn/web/en/-/vietnam-s-customs-tariff-schedule> |

The `tinyurl.com/btxnk260405` short link in circulation resolves to the SAME
Google Sheet; the "Excel file" and the "Google Sheet" are one artifact, not two.
The slug encodes the compilation date (26-04-05), so a later revision is
expected to appear under a NEW short link rather than at this URL.

## Provenance, and what it is not

The workbook is compiled by the **Quang Ninh Customs Sub-Department** and
redistributed by a third-party law library. It is convenient and current, and it
is **not** the issuing instrument: Vietnam enacts its schedule by Government /
Ministry of Finance Decree, and that Decree is the citable authority. Anything
built from this file should say so, and a production deployment should either
reconcile against the Decree or label the source honestly.

It is also not a durable archive — it is a retained upload on someone's Drive,
and it stops being fetchable the day its owner unshares it. Mirror the bytes we
used; the sha256 above is the identity to mirror against.

## What it contains

`BT2026` is the MFN spine: 19,901 rows x 109 columns, of which 15,119 carry a
code in `Mã hàng` (1,081 four-digit, 2,034 six-digit, 12,000 eight-digit, and
4 malformed seven-digit cells — see defects). Descriptions come in BOTH
languages, `Mô tả hàng hoá - Tiếng Việt` and `- Tiếng Anh`, with English on
14,453 of the coded rows (95.6%), and the section and chapter notes are
bilingual too. So Vietnam needs no separate English source: the ITPC per-chapter
PDFs are a cross-check and a gap-filler for the 666 rows with no English, not
the English source.

The other 38 sheets carry the preferential schedules (ATIGA, ACFTA, CPTPP,
RCEP A-F, EV, UKV, EAV, AANZ, AI, AJ, VJ, AK, VK, VC, AKH and more), export
duties, environmental protection tax and VAT reduction — so the per-origin work
deferred for Malaysia is already in this one file.

## Verified before any parser was written

Vietnam contains **every one** of the 11,413 eight-digit codes that Singapore's
STCCED and Malaysia's Customs Duties Order independently agree on — zero
missing. The 458 codes it has beyond that core sit in Chapter 98 (239 under
heading 9849 alone), spread over 42 headings: the signature of national
provisions, not parse noise. It also carries 9024.90, which Singapore has and
Malaysia's gazette omits — the third independent confirmation of that gazette
defect.

## Recorded source defects

| Defect | Count | Detail |
|---|---|---|
| Coded rows with no English description | 666 | fill from the ITPC per-chapter PDFs where they exist; otherwise keep Vietnamese and flag |
| Malformed codes | 4 | `'9849170 '` x3 and `'9849190 '` — seven digits plus a trailing non-breaking space, no English. All Chapter 98. |
| Uncoded grouping rows marked as coded rows | 2,455 | A row like `- Horses:` or `- Loại khác:` carries an empty code cell with a *coded* type marker (18+depth), so only the empty code distinguishes it from a tariff line. 182 are in Chapter 98, which marks nothing, and take their depth from the dash prefix. They are not optional — see "Why the grouping rows matter". |
| Note bullets marked as coded rows | 72 | Bullet lines *inside* note blocks carry a coded type marker instead of a note-paragraph one: Chapter 28's note 1 (`- individual nuclides, excluding, however, ...`) and Chapter 61's subheading note 3(a) defining a suit. What tells them apart from a grouping row is that a note block is still open. They stay out of the tree; they are **also not recovered into the note body**, so that operative text is still missing from the notes corpus. |
| Chapter 98 code repeated one dash deeper | 2 | `9808` (sheet row 19086) and `9849.43` (19889) are printed again as the header of a nested group. Kept as codes they are duplicates; dropped they orphan the lines beneath them onto their own siblings. Emitted as grouping rows, the way the Dominican Arancel's three repeated 6-digit codes are. |
| Chapter 98 heading has no type marker | 1 | `Chương 98` and its title carry none, so no chapter header is parsed for it and `chapters_vn.json` would omit chapter 98 entirely. The entry is stated in `parse_vn_tariff.CH98_ENTRY`. |
| Unit column residue in Chapter 98 | 10 | The chapter overloads the unit cell with the corresponding Chapter 1-97 code. Eight rows (9819, 9820, 9822.x) hold the classification instruction the schedule prints there instead, and `9811.00.10`/`.90` hold `7224`/`7229` — four-digit *headings*, too short for the parser's 6-to-10-digit corresponding-code rule, so they stay in `UNIT`. `load_rows_vn()` drops the unit column for the whole chapter rather than publish an HS heading as a unit of quantity. Routing those two into `CORRESPONDING_CODES` is a parser change still to make. |
| Grouping row that qualifies nothing | 1 | `- - Loại khác:` at sheet row 19500 heads the four malformed `9849.17`/`9849.19` codes, which are excluded, so its children are gone with them. Pinned in `EXPECTED` so a second one fails the build. |

Gate these counts rather than repairing them silently, so a later edition that
differs fails the build instead of absorbing the change. Every count above is
either in `EXPECTED` in `scripts/hts_automation/parse_vn_tariff.py` or in the
notes manifest's `source_anomalies`.

## Why the grouping rows matter

Vietnam states its hierarchy outright — on the `BT2026` sheet the row's type
cell encodes its depth — so unlike Singapore and Malaysia nothing has to be
inferred from printed dashes. That makes it tempting to keep only the coded
rows. It is wrong, and quietly:

```
0103.10.00   indent 1   Pure-bred breeding animals
             indent 1   Other:                        <- uncoded
0103.91.00   indent 2   Weighing less than 50 kg
```

Drop the middle row and `0103.91.00` parents to `0103.10.00`, so a line that is
explicitly *not* a pure-bred breeding animal is described as one, and a
reportable line becomes an internal node. Across the schedule that mis-parented
**2,734 lines and turned 504 unit-bearing codes into internal nodes** — exactly
what `build_hts_corpus.py`'s official-leaf cross-check (exit 7) exists to catch.
With the grouping rows present, the tree rebuilt from the source's own indents
and the source's own leaf markers agree at **11,873 leaves, exactly**.

## Build

Fetch the workbook by hand into `.vn_download/` (gitignored — 32 MB) and run:

```bash
python3 scripts/hts_automation/parse_vn_tariff.py            # ~3 min, needs openpyxl
python3 scripts/hts_automation/parse_vn_tariff.py --no-validate
```

The gates must pass before it writes anything. That produces:

| Path | Tracked | What it is |
|---|---|---|
| `vn_tariff_2026_rev_405.csv` | yes | canonical rows for `build_hts_corpus.load_rows_vn()`, English descriptions |
| `vn_tariff_2026_rev_405.csv.meta.json` | yes | effective date and source, read by `acquire/manual.py` |
| `vn_tariff_2026_rev_405.vi.csv` | yes | the same codes and indents in the same order, Vietnamese descriptions |
| `../hts_notes/vn_2026_rev_405/vn_2026_rev_405.notes.json` | no (gitignored) | cite_id → note record sidecar |
| `../hts_notes/vn_2026_rev_405/vn_2026_rev_405.notes.{section,chapter}.jsonl` | no | Pinecone note families |
| `../hts_notes/vn_2026_rev_405/vn_2026_rev_405.notes.manifest.json` | yes | counts, hashes, source anomalies |
| `scripts/hts_automation/chapters_vn.json` | yes | chapter/section index, 98 entries, from the workbook |

Then the Explorer dataset and the retrieval corpus, from that CSV. The output
directory is not created for you:

```bash
mkdir -p output/vn_2026_rev_405

python3 scripts/hts_automation/build_explorer_dataset.py \
    data/vn_tariff_source/vn_tariff_2026_rev_405.csv \
    --source-format vn --jurisdiction VN \
    --out output/vn_2026_rev_405/vn_2026_revision_405.json

python3 scripts/hts_automation/build_hts_corpus.py \
    data/vn_tariff_source/vn_tariff_2026_rev_405.csv \
    scripts/hts_automation/chapters_vn.json \
    output/vn_2026_rev_405/vn_2026_rev_405 \
    --jurisdiction VN --revision 2026_rev_405 --source-format vn --max-depth 8
```

`--max-depth 8` because Vietnamese codes are 4, 6 and 8 digits — it is **not**
10 like Malaysia. The Vietnamese corpus is the same command against the `.vi`
CSV with `--lang vi`, which selects the `Loại khác` basket pattern and the
`trừ:` exclusion template:

```bash
python3 scripts/hts_automation/build_hts_corpus.py \
    data/vn_tariff_source/vn_tariff_2026_rev_405.vi.csv \
    scripts/hts_automation/chapters_vn.json \
    output/vn_2026_rev_405/vn_2026_rev_405.vi \
    --jurisdiction VN --revision 2026_rev_405 --source-format vn \
    --max-depth 8 --lang vi
```

## What the 2026_rev_405 edition contains

17,441 CSV rows: **14,984 coded** (1,080 headings, 2,033 six-digit, 11,871
eight-digit) and **2,457 grouping rows**. 11,873 leaves — 11,414 in chapters
1-97, every one of them carrying a unit of quantity and no non-leaf carrying
one, and 459 in chapter 98. 97 chapters plus Vietnam's own chapter 98 (531
codes, 447 of them naming the Chapter 1-97 codes they map to). The English
corpus resolves 3,017 basket provisions, the Vietnamese one 3,050.

Duty is real and comes in **two columns that must never be swapped**: the MFN
(preferential) rate, and the ordinary rate that applies absent MFN or FTA
eligibility, higher by construction (27% vs 40.5% on frozen shrimp). Both carry
their enacting Decree and effective date. 49 of the distinct rate values state a
qualifier in words rather than a number — `40 (NHN: 80)` is 40% within quota and
80% outside, `150% thuế MFN` is 150% *of* the MFN duty — so a rate cell is only
suffixed `%` when it is purely numeric. The VAT band (`8/10`, `*/5/8/10`, where
`*` means not subject) is a tax, not a tariff, so it is named in the Explorer's
`special` column rather than put in a duty column.

Legal notes: **487 records** — 365 chapter notes, 78 subheading notes and 44
section notes, and **no General Interpretative Rules**: Vietnam enacts those in
the Decree, not in this compilation, so `REQUIRED_NOTE_KINDS` asserts only the
two families the source actually has.

## Known gap: Chapter 98 has no English

The workbook prints no English for any of chapter 98's 531 lines, and that
propagates:

- the **English corpus** emits all 459 chapter-98 leaf records with the chapter
  title as their only prose, so none of them is retrievable on description;
- the **Explorer** shows those rows with a blank description — their codes,
  rates and `Applies to goods of ...` mapping are all present.

The Vietnamese build has the full text, so `--lang vi` is the usable corpus for
that chapter today. Closing the gap properly means either the ITPC per-chapter
PDFs or a declared Vietnamese fallback in `parse_vn_tariff.write_csv()` — a data
policy decision rather than a parse fix, and deliberately not taken here.

## Not yet automated

There is no acquire adapter: the source is a retained upload on a third party's
Drive behind a rotating short link, so there is nothing to poll. See
`docs/jurisdiction-source-acquisition.md` for what automating it would take.
`config/jurisdictions/vn.json` therefore runs `build`, `publish`, `register`
only — no `acquire`, and no `verify` because there is no predecessor revision to
diff against yet.

# Malaysia tariff source

**Two sources, and both are needed.** The Customs Duties Order 2025 is
P.U. (A) 384, gazetted 31 October 2025 and in force 1 November 2025.

| | |
|---|---|
| Gazette PDF | <https://www.customs.gov.my/images/06-prosedur/perintah-kastam/perintah/PUA_384.pdf> — 1,466 pages, 25 MB, `sha256 e51c740c…beea99` |
| ezHS portal | <https://ezhs.customs.gov.my/> → "PDK 2025". Serves the whole schedule as one server-rendered page (5.7 MB, 13,502 rows), no API and no session. `sha256 d80ce47f…d73aa` |

Both are fetched by hand into `.my_download/` (gitignored — 31 MB together) and
converted by `scripts/hts_automation/parse_my_pdk.py`. The portal token embeds a
date that rotates, so `--fetch` resolves the current link off the portal's home
page rather than using a stored URL.

```bash
python3 scripts/hts_automation/parse_my_pdk.py            # both from .my_download/
python3 scripts/hts_automation/parse_my_pdk.py --fetch     # re-download the portal page
```

## Why both

**The gazette carries the structure.** The portal's table is *sorted*, not in
document order: of 1,231 headings exactly one has a condition row after a coded
row, and within a heading every blank-code row precedes every coded one — under
0105 the indent runs 0,1,1,3,3 then 2,2,2…, which no printed page ever did. The
hierarchy is the dash depth printed beside each line, and dash depth means
nothing once the lines are reordered. The dash-depth gate caught this at 6,852
violations.

**The portal carries four columns the gazette does not print**: SST, excise and
cess 1–3. It is joined by 10-digit code, which is safe — it has no duplicate
codes, and after parsing both sources name the same 11,452 codes with exactly
one divergence each way (`7208271900` gazette-only, `9024900000` portal-only).

**Appendix B of the gazette carries the quota rates.** 38 coded rows in the
portal have a blank import rate and its own TRQ column flags only 27 of them.
In the gazette every quota line reads "TRQ as specified in Appendix B", and
Appendix B (printed pages 1371–1376) gives the in-quota rate, the out-of-quota
rate and the agency that sets the quota. Taking the portal's blank at face value
would publish quota-controlled pork and poultry as duty-free, so a blank import
rate on a coded row is never emitted as a rate: it carries
`IMPORT_RATE_BASIS=trq_appendix_b`.

## Outputs

| Path | Tracked | What |
|---|---|---|
| `my_tariff_pdk2025.csv` | yes | canonical rows for `build_hts_corpus.load_rows_my()` |
| `../hts_notes/my_pdk2025/my_pdk2025.notes.json` | no (gitignored) | cite_id → note record sidecar |
| `../hts_notes/my_pdk2025/my_pdk2025.notes.{section,chapter}.jsonl` | no | Pinecone note families |
| `../hts_notes/my_pdk2025/my_pdk2025.notes.manifest.json` | yes | counts, hashes, source anomalies |
| `scripts/hts_automation/chapters_my.json` | yes | chapter/section index, from the gazette |

## What the 2025 order contains

16,765 rows: 11,441 ten-digit lines (every one a leaf, and every one carrying a
unit of quantity — the reconstructed leaf set and Malaysia's own unit column
agree exactly), 2,013 six-digit, 11 eight-digit internal nodes, 1,228 headings,
and 2,275 condition rows. 97 chapters.

Duty is real here, unlike Singapore: **11,414 lines carry an import duty**, all
11,441 an export duty, 11,437 a sales-tax rate, 416 an excise duty, 175 a cess,
and 27 are quota-controlled.

Legal notes: 469 records — 347 chapter notes, 78 subheading notes and **44
National Notes**, Malaysia's own category defining terms the schedule relies on
("airtight container", "Fish ball"). Until that header was matched, a National
Note's "1." was read as a second note 1 of the block above it and 30 blocks were
dropped.

## Recorded source defects

`source_anomalies` in the notes manifest lists each one with its page:

- Heading **38.04** is not printed at all — page 402 runs `38.03 / 3803.00.00 00`
  then straight to `3804.00.10 00`. Heading **38.27** is split across a page
  break, its text absorbed into the foot of page 418 and its code printed on 419
  below the 3827.11 that belongs under it. Both headings are synthesised from
  the portal, which carries their descriptions.
- `3827.63.90 30` (page 421) is printed with **no dash prefix at all** while all
  five siblings carry `- - - -`, so it read as a root and swallowed them.
- `1515.60.00 00` (page 149) is set at `- -` inside 1515.50's one-dash group,
  though 151550 is not a prefix of 151560.
- Two note blocks share a number (`NN-27-1`, `N-85-1`); both are kept, the
  second under a suffixed cite, so no operative text is lost.

## Not in scope

The portal also serves **19 preferential schedules** at the same URL shape with
a per-scheme key: ATIGA, ACFTA, AHKFTA, MPCEPA, AKFTA, AJCEP, AANZFTA, AINDFTA,
MNZFTA, MICECA, D8PTA, MCFTA, MAFTA, MTFTA, RCEP, CPTPP, TPS-OIC, MY-UAE-CEPA.
A preferential rate is per-origin and belongs in the duty-rates surface, not in
the Explorer's three rate columns, so they are left for a second pass.

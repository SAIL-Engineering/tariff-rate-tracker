# Dominican Republic (DO) — Arancel de Aduanas source

`do_tariff_2022_rev_7.csv` is the user-transcribed CSV of the DGA *Arancel de
Aduanas, 7ma Enmienda* (2022) — the current edition. There is no public
machine-readable source; the DGA publishes PDF only, so this file is
irreplaceable and committed. The `.meta.json` sidecar carries the effective
date for the `manual` acquisition adapter.

Columns: `Código` (2/4/6/8-digit, dotted; leaves are 8-digit — DR never uses
10), `Designación de la mercancía` (Spanish; leading dashes encode hierarchy
depth; trailing `:` marks a grouping), `Grav.` (MFN ad valorem %),
`Selectivo Ad Valorem` / `Selectivo Específico` (ISC excise), `ITBIS*` (VAT).
Preferential (DR-CAFTA/EPA) rates are NOT in this book.

Refresh: drop a new `do_tariff_<year>_rev_<n>.csv` (+ sidecar) here and run
`python3 scripts/hts_automation/refresh.py -j DO`.

## Corrections applied to the transcription (2026-08-27)

The committed CSV is the user transcription **plus 14 corrections**, each
verified against the official book (the datalab OCR of
`672577902-Arancel-de-Aduanas-7ma-Enmienda-2022.pdf`). The build previously
produced 7,696 leaves with 5 phantom non-8-digit leaves and 6 impossible
8-digit internal nodes; after these it produces exactly the official **7,697**
operative subheadings, all at 8 digits:

| line | code | fix |
|---|---|---|
| 2145 | `25.27` | suppressed HS heading printed bare -> bracketed `[25.27]` like the other 36 |
| 7601 | `79.01` | row was a corrupted duplicate of `7806.00.20` (with an Excel formula fragment `+H7815:L7815`) that displaced the real zinc heading -> restored `79.01,Cinc en bruto.` |
| 335 | `0304.51.00` | 1 dash -> 2 (siblings at 2; book p.1283) |
| 2639-40 | `2853.90.10/.20` | 1 dash -> 2 |
| 3119-20 | `2925.29.10/.90` | 2 dashes -> 3 (book prints these at the parent group's depth — structural depth used) |
| 4258 | `3920.79.20` | 2 dashes -> 3 |
| 6457-59 | `6505.00.20/.30/.90` | 2 dashes -> 1 (book prints all 6505.00.x at 1) |
| 7091 | `7217.90.91` | 2 dashes -> 3 |
| 8264 | `8429.30.00` | 2 dashes -> 1 |
| 10756-57 | `9405.19.10/.20` | 2 dashes -> 3 |

Also handled by the loader (`build_hts_corpus.py --source-format dga`), not
edited: 36 bracketed suppressed headings dropped; the stray bare `77` chapter
row dropped; three 6-digit codes that appear twice (`7113.19`, `8517.62`,
`9019.10` — the second time as a nested "Los demás:" group header) have the
second occurrence treated as a grouping row.

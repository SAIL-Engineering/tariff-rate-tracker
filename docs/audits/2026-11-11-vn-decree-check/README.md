# Vietnam MFN rates checked against the issuing instruments (2026-11-11)

The VN schedule is parsed from a compiled workbook (Quang Ninh Customs
Sub-Department, as at 5 April 2026), not from the law itself. This check compares
the parsed rates with the signed Decrees and Resolutions on the Government
portal, and looks for anything enacted after the workbook's date.

## Result

978 comparisons ([`comparisons.csv`](comparisons.csv)): 953 match, 25 do not.
The 25 come down to three findings, all now fixed:

| Finding | Lines | Fix |
|---|---|---|
| The 0% on fuels under Decree 72/2026/NĐ-CP did not end on 30 April 2026, as the workbook prints. Resolutions 25, 34 and 43/2026/NQ-CP extended it to **31 December 2026**. | 15 | `config/duty_overlays/vn.json`, applied by `build_duty_rates.py` |
| Resolution 25/2026/NQ-CP Art. 2 set 0% on three more lines from 1 May 2026, after the workbook's date. The same Resolutions extend it to 31 December 2026. | 3 (2710.19.20, 2710.19.89, 2711.19.00) | same overlay |
| Four Chapter 98 codes are malformed in the workbook (`9849170` x3, `9849190`), so the lines were dropped. Decree 26/2023 Annex II, printed pp. 846-847, gives 9849.17.10, .20, .90 and 9849.19.10, each at 0%. | 4 | `parse_vn_tariff.CODE_REPAIRS` |

Also found, among the matching rows: the workbook gives Decree 144/2024/NĐ-CP's
signing date (01/11/2024) as the effective date of its 63 lines. Its Art. 2(1)
makes it effective 16/12/2024. Fixed by `parse_vn_tariff.DATE_REPAIRS`.

`comparisons.csv` describes the CSV **as it was before these fixes**.

## What was compared

| Group | Rows | Source |
|---|---|---|
| Decree 73/2025/NĐ-CP, every line citing it | 617 | 73-cp.signed.pdf |
| Decree 26/2023/NĐ-CP, random sample (seed 20261111) | 160 | 26-nd.signed.pdf, 26-nd-2.pdf |
| Decree 144/2024/NĐ-CP, every line | 63 | 144-cp.signed.pdf |
| Lines Decree 72/2026 restates unchanged (extra corroboration) | 52 | 72-ndcp.signed.pdf |
| Decree 199/2025/NĐ-CP, every line | 34 | 199-ndcp.signed.pdf |
| Tariff-quota lines, all | 31 | 26-nd.signed.pdf, 26-nd-2.pdf |
| Decree 72/2026 temporary 0%, all | 15 | 72-ndcp + Resolutions 25, 34, 43 |
| Chapter 98 malformed codes | 4 | 26-nd-2.pdf |
| Resolution 25/2026 Art. 2 lines not in another group | 2 | 25-nqcp.signed.pdf |

How later instruments were found is in [`amendments.json`](amendments.json)
(`search_method`, `coverage_limits`): the Government portal's complete document
listings, paged in full, and the Government Office's monthly bulletins for July
to September 2026. Instruments read and set aside (export duties, FTA schedules,
a special consumption tax) are listed under `reviewed_not_mfn`. A Ministry of
Finance draft amending Decree 26/2023 was seen only in search results and is
**not in force**; it is recorded under `pending_not_in_force`.

Every PDF read is listed with its URL and sha256 in
[`source-manifest.json`](source-manifest.json). They are scans with no text
layer, so the cited articles and annex rows were read from page images. Decree
72/2026 (Art. 2 and the annex), Resolutions 25/2026 (Arts. 2-3), 34/2026 (Arts.
1 and 3) and 43/2026 (Arts. 1 and 3), Decree 144/2024 (Art. 2(1)) and Decree
26/2023 Annex II pp. 846-847 were each read twice: once by the check, and again
before the fixes were written.

## Limits

- Checked through 2026-11-11. Anything enacted later is not reflected.
- Some Decree numbers are missing from the portal listing; see
  `coverage_limits` in `amendments.json`. The monthly bulletins cover July to
  September 2026 completely and show no other MFN change.
- The 0% windows end on 31 December 2026 unless extended again (Resolution
  43/2026 Art. 3(3)). The duty rates are built for the build date, so **rebuild
  and ship VN after 31 December 2026**, or update the overlay first if a further
  extension is enacted.
- The ordinary rate (thuế thông thường) is left as the workbook prints it; the
  temporary MFN reductions are not applied to it.

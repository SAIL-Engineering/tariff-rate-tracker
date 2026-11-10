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

Gate these counts rather than repairing them silently, so a later edition that
differs fails the build instead of absorbing the change.

## Not yet built

No parser, loader, explorer dataset, corpus or notes exist for Vietnam. See
`docs/jurisdiction-source-acquisition.md` for what automating the acquisition
would take.

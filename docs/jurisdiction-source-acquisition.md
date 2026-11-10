# Acquiring SG, MY and VN revisions — what automation would take

Singapore, Malaysia and Vietnam were all acquired by hand. None has a GitHub
Action, and the reason is the same in all three cases and worth writing down:
**none of them publishes a stable URL for "the current edition."** Every one
encodes an edition identifier in the filename or link, so a new revision appears
at a *new* address. An Action cannot just re-fetch a known URL and diff; it has
to discover the address first.

`config/jurisdictions/<cc>_revisions.csv` is the provenance of record for each —
`source_url`, `source_sha256`, `acquired_at` and the notes. A detector's job is
to find a candidate, hash it, and compare against the newest row there.

## Singapore — the cleanest to automate

| | |
|---|---|
| Source | `https://file.go.gov.sg/stcced2022.pdf` (11.4 MB, 655 pages) |
| Landing page | <https://www.customs.gov.sg/doing-business/business-resources/hs-classification-of-goods/understanding-hs-classification/> |
| URL stability | **None.** The year is in the filename. HS 2028 will be a different file. |
| Auth / session | None. Plain static file, no token, no cookie. |
| Cadence | Tied to WCO HS editions (2022 → 2028), plus any Singapore reissue in between. Years apart, not weekly. |
| Detector | Fetch the landing page, take the first href matching `stcced(\d{4})\.pdf`, hash it, compare to `sg_revisions.csv`. |
| Blocker | None technical. This one could ship as an Action as-is. |

The parser takes the PDF as its only argument and writes everything else, so the
Action is: discover → download → `parse_sg_stcced.py <pdf>` → the gates decide.
Its `EXPECTED` counts are measured against the 2022 book, so a genuinely new
edition SHOULD fail them — that is the point. A new edition is a review, not an
auto-merge.

## Malaysia — automatable, with a rotating token already handled

| | |
|---|---|
| Gazette | `https://www.customs.gov.my/images/06-prosedur/perintah-kastam/perintah/PUA_384.pdf` (25 MB, 1,466 pages) |
| Portal | <https://ezhs.customs.gov.my/> → "PDK 2025" (5.7 MB, one server-rendered page, 13,502 rows) |
| URL stability | **Gazette: none** — `PUA_384` is the gazette number P.U. (A) 384; a new order gets a new number. **Portal: self-resolving** (below). |
| Auth / session | No login. The portal URL carries a base64 `tariff` parameter whose embedded date rotates, plus a per-scheme `km` key that is stable. |
| Cadence | A new Customs Duties Order is years apart; amendment orders are more frequent and arrive as separate P.U. (A) instruments. |
| Detector | List `…/06-prosedur/perintah-kastam/perintah/`, pick new `PUA_*.pdf`, hash, compare. The portal needs nothing: `resolve_portal_url()` already reads the current token off the portal home page, which is why `--fetch` works unattended. |
| Fetch quirks | Requires `--http1.1`; the server rejects the HTTP/2 header set. Use an honest client UA — do not spoof a browser. |
| Blocker | CI egress. The portal and `customs.gov.my` are reachable from a laptop; neither has been exercised from the Action runner, and a comparable portal (TW) is unreachable from CI. Prove reachability before relying on it. |

Amendment orders are the real gap: the parser reads one consolidated order and
has no notion of applying a P.U. (A) amendment to a base order. Until that
exists, "a new revision" means a new consolidated order.

## Vietnam — the least automatable, and not for technical reasons

| | |
|---|---|
| Source | Google Sheets export of file id `1Tv3kzX5M-HOA0GoFjaGydTrHWD8piDh5` (32.3 MB xlsx) |
| Link publisher | <https://thuvienphapluat.vn/chinh-sach-phap-luat-moi/vn/ho-tro-phap-luat/chinh-sach-moi/109354/> |
| URL stability | **None, and worse.** The circulating short link `tinyurl.com/btxnk260405` encodes the compilation date; a later revision is expected under a new link, plausibly a new file id. |
| Auth / session | None while the file stays shared — and that is the exposure: it is a retained upload on a Drive we do not control. |
| Cadence | Irregular. The compiler updates it as instruments land, which is often. |
| Detector | Fetch the publisher page, extract the current short link, resolve it to a Drive file id, export `?format=xlsx`, hash, compare to `vn_revisions.csv`. |
| Blocker | **Provenance, not plumbing.** The file is compiled by the Quang Ninh Customs Sub-Department and redistributed by a third-party law library. It is not the issuing instrument — Vietnam enacts by Government / MOF Decree — so an Action built on it automates a convenience copy, not the law. |

Two consequences worth deciding before writing that Action: mirror the bytes we
used (the file can be unshared at any time), and resolve whether the Decree
becomes the citable source with this workbook as the machine-readable
convenience, or the workbook is cited honestly as a compilation.

## Shared shape, if and when these become Actions

1. **Discover** the candidate address — the only genuinely per-jurisdiction step.
2. **Hash and compare** against the newest `<cc>_revisions.csv` row; stop if unchanged.
3. **Mirror** the bytes somewhere durable before parsing. All three sources can
   move or vanish; two are not operated by the issuing authority.
4. **Parse** and let the gates fail. Every one of these parsers pins counts
   measured against a specific edition, and each carries recorded source defects
   with per-defect counts. A new edition is expected to trip them — that is the
   gate doing its job, and the output is a review, never an auto-merge.
5. **Append** the revision row with the new `source_url`, `source_sha256` and
   `acquired_at`, so the provenance stays complete.

Nothing here needs a scheduler that runs more often than monthly. These
schedules move on the order of years, and all three detectors are cheap page
fetches.

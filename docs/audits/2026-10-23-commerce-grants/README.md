# Commerce grants, claim interactions and quota-source follow-up

Base: `c0bd77818806e8000e55345c347f2cb9b71af3d8`, original tracker branch
`wjr_dev`. Only the tracker is changed. Trade-intelligence CATAIR evidence was
reused read-only at the commit recorded in the policy source manifest. No push,
deployment, workflow dispatch, production MotherDuck write, release activation or
timeseries/revision rebuild was performed.

## Implemented

* A reviewed individual-grant snapshot now enters the normal R legacy-metal
  compiler through `SECTION232_GRANT_SNAPSHOT`. It produces the existing
  declarative R/TypeScript rules, carrying original decisions, field citations,
  importer/product/action scope, activation/expiry, quantity, correction and
  revocation cutoffs. An ID or an HTS association cannot establish a grant.
* Grant relief validates actual quantity before suppressing duty. Partial lines
  require splitting. The normal action graph reevaluates after relief: the June
  metal/emergency ordering and USMCA interaction continue to work. An ordinary
  aluminum grant cannot remove the separate Russian action. An STX extension
  cannot broaden the source-defined EU origin group or survive March 12.
* A blanket unchanged-base assertion was too broad. CBP states that a valid
  Section 232 exclusion can restore GSP/AGOA eligibility. Only explicitly
  identified ordinary column-1/column-2 rules now inherit that assertion.
  Preference-sensitive and unreviewed base rules stay unpriced for the claim.
* The snapshot is a hashed fragment artifact, composition retains its pin, and
  release loading rejects unpinned rules, mismatched grant identities and mixed
  snapshots across revisions. This uses the existing versioned MotherDuck
  serving path; it does not activate a release or establish authority coverage.

The [grant contract](../../section232-grant-evidence.md) documents the complete
input requirements, provenance limits and manual commands. The public bundle remains v1,
release v6. Use a new dataset version and newly composed bundles.

## Primary evidence and acquisition limit

[BIS's Section 232 page](https://www.bis.gov/about-bis/bis-leadership-and-offices/SIES/section-232-investigations/section-232-steel-aluminum)
distinguishes surviving activated individual grants from terminated GAEs and EU
STX extensions. Its application cutoff is extracted from the retained text.
[85 FR 81060](https://www.govinfo.gov/content/pkg/FR-2020-12-14/html/2020-27110.htm)
supplies the party/product, activation and grant-specific validity requirements;
no one-year or five-calendar-day default is inferred.
[CBP CSMS 64384423](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3d66da7)
and [64384496](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3d66df0)
confirm continuation of ACE-active importer exclusions after March 12 until
expiry or volume exhaustion. The
[CBP FAQ](https://www.cbp.gov/trade/programs-administration/entry-summary/232-tariffs-aluminum-and-steel-faqs)
supplies the GSP/AGOA interaction. Source hashes are in
`resources/legal_evidence/section232/grants/sources.json`.

The officially linked public extract returned HTTP 403 with “web app is stopped.”
The portal landing page did not expose usable grant decisions. **No real
individual grant inventory was acquired or legally qualified.** The six grant
records in tests are explicitly synthetic. Their 23 scenarios test the compiler
against real archived metal rules, not the accuracy of a production grant corpus.
The unavailable extract is not treated as an empty inventory or zero liability.

## Quota references investigated

The original [EU proclamation 10328 annex](https://www.govinfo.gov/content/pkg/FR-2022-01-03/pdf/2021-28516.pdf)
also prints `9213.91.45` under 9903.81.07. The prior audit retained the original
Japan annex with the same reference under 9903.81.66. The problem is present in
the primary publications, not only in USITC JSON/PDF extraction. No verified
correcting authority was found in this pass; the exact-reference Federal
Register search returned zero but does not establish absence, because annex
images may not be indexed. The original EU PDF and extracted text are retained.
The compiler continues to price the ordinary over-quota alternative while
leaving the affected claimed in-quota category unresolved.

The castings/forgings references are different: 7616.99.5160 and 7616.99.5170
both exist in the 2025 basic schedule. 7616.99.5175 is “Articles of wire” under a
separate “Other” branch; it is not a verified replacement for 5170. No statistical
successor mapping was introduced. The existing six conditional primary
candidates per EU/UK group are not six proven quota defects. Material/product
scope still matters. UK clad-sheet/thickness discrepancies and the aluminum
quota-accounting wording disagreement still need authoritative reconciliation.

## Verification and MotherDuck distinction

`verification.json` records commands, outcomes and retained-file hashes.

* Python: 322 passed; final native Node/API/DuckDB suite: 243 passed.
* R grant conformance: 23 scenarios; pre-March: 35; legacy tests and action
  composition pass. These remain partial-authority tests with explicit
  incomplete totals.
* Full R gate: 38 suites, 36 OK, one ERROR from 312 existing missing/stale
  normalized partitions, and one missing-TPC-data SKIP. The reported 402 counted
  assertions pass, but the full gate is **not green**. Final affected R suites
  were rerun after the EU-origin restriction and evidence normalization.
* Typecheck/build pass; the existing bundle-size warning remains. This pass has
  no SAIL UI changes or production browser qualification.
* A bounded six-product/seven-origin pipeline test with the configured synthetic
  snapshot passes through normal normalized emission. It verifies the emitted
  grant hash/rules and reads the fragment back with every source-artifact hash
  checked. It writes temporary fixture output, not a revision rebuild.
* Source-only audit covers the five pre-March source revisions, all 240 origins,
  835 candidate products per revision and 36,360 decision branches. It still
  records 16 **candidate** product/quota-group gaps per revision, not 16 proven
  statutory holes. No timeseries was calculated.

The source audit was compared with the **previous retained read-only MotherDuck
snapshot**, not a new live read. The same 429,420 positive modeled metal rows
outside both source scopes remain in that snapshot. They are not unique
shipments, whole-duty-stack results or financial exposure. Grant shipment facts
are not established by those aggregate rows. The exact prior raw export remains
at `docs/audits/2026-10-23-pre-march-metals/motherduck.json.gz`; the new source
inventory/comparison is retained here. Nothing has been corrected in live
MotherDuck by this local pass.

## Remaining work and rollback

This is not complete legal coverage. Acquisition and qualification of real
individual decisions, automated extraction from their actual formats,
post-April-2026 grant treatment, remaining reciprocal IEEPA/122/338/301 and
preference/Chapter 98 interactions, AD/CVD, financial consumers and exhaustive
rebuilt HTS/origin/interval reconciliation remain open. A grant cannot fill a
gap in another authority. No new blanket coverage attestation was added.

Unclaimed aggregate calculations and model shares are unchanged by this pass;
the manual rebuild and its aggregate comparisons remain WJR's work. Commands
are in `docs/shipment-duty-manual-rebuild.md`. Keep the grant evidence snapshot
consistent for the entire build. Do not use synthetic fixtures for that build.

No active release changed. Local rollback is a revert of this change, followed
by regeneration/recomposition from the recorded base. If a later release is
approved, retain the prior active release ID and its complete versioned tables
for rollback. Do not combine old wide partitions with new rule evidence.

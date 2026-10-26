# Shipment artifact and serving-path reconciliation

Tracker base `291d49aae93455ebfe3ba66885b446a27fd40485`, original branch `wjr_dev`.
This checkpoint repairs normal-build and release-contract defects. It does not
complete the legal-action inventory, qualify a deployment or change MotherDuck.

## Corrected defects

| Finding | Correction and verification |
| --- | --- |
| Point calculator returned NA daily bounds although its bundles had identified dates | Return the same explicit daily interval used by normalized emission. The old retained fixture failed the new verifier; the corrected actual-source fixture passed. |
| Full native inventories include Chapter98, but ordinary-product adapters rejected it | Preserve a separate primary-source special-classification inventory. Exclude it from ordinary sector membership compilers, retain it in the grid, and emit the precise unimplemented entitlement/valuation/program question. Printed `Free` is not unconditional zero duty. |
| Native presentation markup prevented complete rate parsing | Normalize only recognized presentation tags/entities, including USITC's `<il></il>`, while retaining raw text and normalization steps. Specific/compound rates still preserve units and valuation. Conditions, unknown tags/attributes and unknown entities remain unresolved. No HTS examples enter production logic. |
| The real Parquet combiner stores revision in Hive paths rather than physical columns | Manifest explicitly declares storage identity. Preflight verifies the exact `revision=<id>` parent, rejects a conflicting physical column, and proves the row identities through the rule/class links. |
| v7 release preparation expected a single bundle and old aggregate/statutory arithmetic | Add v8 indexed preparation. Stream byte-pinned exact-time bundles, preserve their raw bytes, and stage bundle-index, rule, source, coverage, claim, required normalized and decision tables in one immutable schema. Hash large Parquet files as streams. Keep v7 compatibility separate. |
| No exhaustive reconciliation of new emitted shipment decisions | New R verifier recomputes every emitted cell, membership and class; directly evaluates every distinct decision class; checks sources, references, full grids, versions and exact/daily interval tiling. Production additionally requires the complete primary product/origin inventory. |

The verifier reports `consistent_with_declared_rules`, with legal coverage,
production qualification and aggregate reproduction explicitly **not attested**.
Source duplication/order and fact-branch coverage require their independent suites.
Normalized economic/source annotations remain distinct from executable tables;
schema/hash validation is not a claim that all those annotations are independently
reconciled to complete law.

## Primary-source reconciliation

The all-55 source-calendar comparison separates complete rate expressions,
column-specific annotations and classification ancestry. After preserving legal
text but normalizing presentation, it found **no general-duty-expression
differences** between the overlapping comparison snapshots. Raw markup accounted
for the previously observed general-expression differences. This is not proof
that every base expression is parsed or every source selection is legally valid.

Remaining records include Column2 expressions, product presence, classification
context and changing annotations. Counts are repeated comparison observations,
not independent proven rate errors. A snapshot's raw or policy-selection date
does not supply an item's legal effective date. Removed Chapter99 endnotes do
not repeal an independently sourced action.

The 15 Column2-expression observations reduce to two malformed expression
groups. Independent same-revision chapter PDFs were downloaded through gstack,
byte-pinned and visually inspected at printed pages20-6 and29-30. They contain
the same `drained weght` and `37% /` strings as the JSON. This establishes that
the defect is in the primary publication, rather than a JSON extraction loss.
See [source evidence](sources/manifest.json). No spelling correction, substring
rate or guessed footnote was inserted into the calculator. These expressions
remain explicit source questions pending statutory/erratum reconciliation.

Eleven missing 2026 change-record PDFs were acquired through gstack from the
official USITC revision endpoint. Their headers, complete hashes, source URLs
and acquisition method are retained in
[`acquisition_2026-10-26.json`](../../../data/hts_change_record/acquisition_2026-10-26.json).
All55 records now participate in the classification chronology audit. Its
establishment, deletion and simultaneous-event questions are research evidence;
they do not silently renumber products or decide liability. Native statistical
identifiers can be reused for different goods. Original scope, context and
instructions must establish which goods an identifier represents historically.

The new audit also handles a short code vertically centered beside its own
two-line nature/date cell; it preserves both source lines and refuses to borrow
a preceding code's date. Legal eight-digit changes remain for independent
instrument/annex reconciliation. This tool intentionally does not parse the
whole Chapter99 change record as an executable tariff rule.

The final mechanical chronology pass retains929 ten-digit event observations,
941 other/uninterpreted rows and45 simultaneous-event groups. The latter can
represent reused statistical identifiers for different goods, rather than
contradictory legal instructions. It flags129 repeated native/event comparison
observations across seven distinct identifiers. These are reconciliation
candidates, not129 adjudicated mistakes. Recognizing explicit ten-digit
`Deleted` rows and vertically centered cells resolved several earlier apparent
discrepancies, including the July2026 Chapter38 successor catalog. Six remaining
pharmaceutical identifiers and one pre-July tobacco identifier require scope/
date reconciliation; their values were not altered from this diagnostic alone.

## Fresh read-only MotherDuck findings

Retained audit uses `READ_ONLY` and a read-only transaction against the configured
catalog. It returned 220 grouped rows, 1,100 selected historical rows across55
revisions and12 Hong Kong examples. The sampled rows have no new shipment
dataset/status fields. Existing Mexico `8703230190` observations still include
23.7625% statutory §232 in September2026 and concurrent auto/drug-emergency
components in May2025. They are stored old outputs, not accepted test oracles.
The local source-backed component tests establish the auto decision with
declared vehicle/use/content/claim facts; other unresolved components still
prevent a complete total.

Grouped concurrency/suppression counts are **screening metrics**, not counts of
independently adjudicated legal errors. Old rows do not contain enough facts to
price every shipment; compare applicability, assumptions and component sources.

## Verification and remaining gates

See `verification.json`, byte-pinned evidence artifacts and
[manual diagnostic commands](DIAGNOSTICS.md). Actual bounded normal fixtures
cover2025/2026, ten emitted grid cells, three exact-time bundles,16 memberships/
classes and20 fact-specific R/TypeScript/JSON/Arrow/batch cases. A single v8 local
release successfully stages both actual-source revisions with one dataset pin.
It is diagnostic and cannot activate. Unit negatives cover artifact changes,
missing indexes, unsupported types/catalogs, duplicate product states, forged
memberships, incomplete production evidence and diagnostic activation. Failed
preparation preserves a preexisting active registry fixture.

Final Python and Node gates passed427 and660 tests respectively. Typecheck and
the prototype build passed. The full R run completed65 suites:62 OK, two errors
and one skip. One error was an invalid result caused by editing the Chapter98
test while its file was being read; the frozen standalone rerun then passed both
the mixed and special-only grids. The remaining normalized gate stopped before
parity with685 missing/stale artifact errors; the TPC input was absent. The full
R command was not rerun after the standalone recovery, and is not reported green.
The gstack check exercised the static shell only; no API was connected.

The final full timeseries rebuild remains premature. In particular, the
reciprocal compiler still ends at the August7,2025 policy horizon; later country
replacements/retroactivity are not automatically implemented by a product
exemption list. Remaining §232 sectors/claims, §122/§338/§301 interactions,
FTZ, Chapter98 entitlement and AD/CVD coverage need their original-source
decisions. The v8 local staging path does not complete cloud synchronization,
legacy aggregate readers/cache transitions or remaining SAIL financial consumers.
No production publication, workflow edit, activation, push or deployment occurred.

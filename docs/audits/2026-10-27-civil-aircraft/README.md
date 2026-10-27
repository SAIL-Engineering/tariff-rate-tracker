# Independent Section 232 civil-aircraft agreements

Built from local `wjr_dev` checkpoint
`35fc42cc67766b22786ce976696d73e9a7b3752b`. This closes a specific executable
gap identified in the reciprocal chronology audit. It does not certify complete
Section 232, Section 301 or all-authority coverage.

The UK, EU, Japan and Korea metal concessions were attached to the reciprocal
compiler. That compiler's collection ending could therefore remove a separate
Section 232 concession. The ordinary Parquet build now emits an independent
`section232_civil_aircraft_rules.json` fragment and composes its decisions with
the other actions. Both the original reporting lists and the April replacement
lists are data extracted from the instruments.

## Primary-source reconciliation

- The original UK definition is extracted once and shared with reciprocal
  interpretation: [2025-12060, part C](https://www.govinfo.gov/content/pkg/FR-2025-06-30/html/2025-12060.htm).
  Moving that extraction into a shared function preserves the entire original
  reciprocal history object, verified against the preceding implementation.
- The original [EU](https://www.govinfo.gov/content/pkg/FR-2025-09-25/html/2025-18660.htm),
  [Japan](https://www.govinfo.gov/content/pkg/FR-2025-09-16/html/2025-17908.htm)
  and [Korea](https://www.govinfo.gov/content/pkg/FR-2025-12-04/html/2025-21940.htm)
  conditions and product lists reuse the source extractor added in `35fc42cc`.
- [Proclamation 11021, clause 10](https://www.govinfo.gov/content/pkg/FR-2026-04-09/html/2026-06960.htm)
  expressly preserves prior civil-aircraft agreements. Its original Annex IV
  A(3) replaces the metal heading references in note 2(v)(xxii) and (xxiv)(b);
  A(6) replaces the UK/Japan metal references in note 35. The original PDF
  pages 60, 61 and 64 (FR 18260–18261, 18264) were rendered and visually checked.
  The transcription pins the original PDF. It does not use later snapshots to
  decide an earlier entry's heading.

The original metal lists were valid historical references; their replacement
is an operative amendment, not a reason to invent a reporting number. Exact
deletion operands are reconciled against each original action. All applicable
replacement operations must produce the same result. Conflicting operations
stop compilation. The April instant comes from the original operative clause.

The Swiss/Liechtenstein aircraft clauses remove reciprocal duties only. Sharing
an aircraft condition with another agreement does not establish a Section 232
metal concession. The extractor records that distinction and creates no metal
waiver from those clauses. This finding concerns these clauses, not an exhaustive
review of every possible Swiss/Liechtenstein entitlement.

## Executable behavior and boundaries

Each concession keeps its own origin, exact HTS8/HTS10 precision, qualification
predicate and legal windows. June 30, September 1, September 16 and November 14
entry instants come from their instruments. April 6, 2026 at 00:01 Eastern
changes the target metal headings. Reciprocal collection ending on February 24
does not terminate this independent relief.

The zero-duty reporting decision belongs to `section_232`, even where its
Chapter 99 number also has a reciprocal reporting role. Consumers must use the
resolved action/authority, not infer liability from the number's prefix. A new
compiler-only `target_authority` restriction prevents an exemption from
suppressing another authority sharing a reporting identifier. Runtime formulas
use the existing R/TypeScript primitives; no React legal constants or new HTTP
contract version is needed. The build's content identity changes normally.

Qualification is a shipment fact and applies regardless of whether `Free (C)`
appears in the Special column. Missing qualification cannot become a waiver
or a priced metal charge. The ordinary-entry path is executable; FTZ admission,
status and classification history remain explicitly unpriced. Chapter 98 rows
requiring underlying-classification reconciliation are not silently treated as
ordinary products.

## Verification

Exact commands, hashes, counts and limits are in `verification.json`; compressed
evidence is indexed by `evidence-inventory.json`. The final checkpoint passed
455 Python tests, 774 individual Node tests, 151 R rate tests and 32 new R
civil-aircraft cases. The tracker prototype build also passed; the retained log
includes its Browserslist and chunk-size warnings.

- The source census covers all 55 configured revisions, their complete native
  ordinary product inventories, four agreements and the original-to-April
  reporting transition. Native carrier definitions have no conflicts. It
  calculates no revision or timeseries rates and is not a full duty-grid oracle.
- R/TypeScript fixtures cover exact start/replacement seconds, four origins,
  Swiss nonextension, an uncovered product, missing qualification, FTZ paths
  and preservation of a controlled Section 301 charge. Controlled actions are
  identified as synthetic and never attest production coverage.
- The normal point calculator for real `7304.31.30.00`, Germany, September 15,
  2026 verifies a USD50 metal component on USD100 under `9903.82.02`, or its
  sourced zero-duty aircraft concession under `9903.02.76`. Both results have
  NULL complete totals. This is a component regression, not a complete-total
  legal oracle. Modeling shares and assembly credits cannot change the result.
- One-cell Parquet/normalized verification and local DuckDB → JSON/Arrow/batch
  delivery preserve those resolved components, source references and dataset
  version; stale versions and tampered bundles are rejected.

To repeat only the source census, without calculating rates:

```bash
python3 scripts/audit_civil_aircraft_policy.py --out /tmp/civil-aircraft-source-recheck
```

The output directory must not already exist. No WJR revision rebuild is invoked.

## Read-only MotherDuck observations and the next source gap

A fresh `READ_ONLY` audit reads 275 existing rows: this steel product, five
origins and all 55 revisions. The retained schema still lacks shipment fields.
For September 15 the legacy German row carries 50% Section 232 and a 60%
statutory total. Its extra ten points are the separate Section 301 forced-labor
column; they are not expired Section 122 or reciprocal duty.

The original [USTR final action, 2026-15181](https://www.govinfo.gov/content/pkg/FR-2026-07-28/html/2026-15181.htm)
was read through gstack. Note 52(f) excludes the specified Section 232 metal
articles; note 52(d) has a separate aircraft condition. These cannot be priced
by adding the legacy statutory forced-labor parameter to an already stacked
metal duty. Its complete source-backed executable reconstruction, including
tiers, country/product annexes, transit, preferences and Chapter 98, remains a
priority. The ordinary shipment projection already leaves unpriced statutory
fields NULL and the result incomplete; it does not copy that legacy parameter
into a certified total.

The observed old table cannot price the supplied qualification facts. Raw
legacy rows, the primary-source research captures and the new point results
are retained separately; no complete-total parity is asserted.

## Release limits and rollback

The complete R gate remains unqualified because normalized artifacts are
missing/stale and TPC input is absent. Remaining authority inventories,
FTZ/Chapter 98 paths, AD/CVD, Section 301 forced-labor/Brazil actions and remaining
consumers still require work. These checks do not qualify treaty-territory
coverage or the full all-origin duty stack. Aggregate differences are not
qualified because no series was rebuilt.

Changes are local commits on `wjr_dev`. No MotherDuck write, active-release
switch, publication, deployment, workflow dispatch or timeseries/revision build
was performed. WJR retains the manual rebuild and production approval steps.
Before publication, rollback is a local revert of this checkpoint. A later
approved release must be prepared/validated as one dataset, retain the preceding
active release and switch identifiers only after deployment smoke testing.

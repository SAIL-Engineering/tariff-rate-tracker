# Original forced-labor actions and Section 232 interaction

Local `wjr_dev` work from `51e3763bc140951439e044a52cbe7c971ebcde12`.
This checkpoint resolves the named Section 232 exemption and inventories the
remaining forced-labor decisions. It does not complete Section 301 or the
all-authority shipment stack.

## Legal finding

The [original USTR final action](https://www.govinfo.gov/content/pkg/FR-2026-07-28/html/2026-15181.htm),
Annex I A(2), U.S. note 52(f), exempts the specified Section 232 articles.
This depends on legal applicability under the named headings, including
zero-payable decisions. A positive aggregate Section 232 rate is insufficient.

Its seven original items address metals, passenger vehicles, passenger-vehicle
parts, wood, medium/heavy vehicles, their parts and semiconductors. Annex I B
adds patented pharmaceuticals at July 31, 2026, 00:01 Eastern. The original
action starts July 24 at 00:01 Eastern. The transit deadline is separately
July 28 at 00:01. Publication dates do not replace these operative instants.

The original [USTR machine-readable final PDF](https://ustr.gov/sites/default/files/files/Press/Releases/2026/FLIP%20301%20Investigation%20Final%20Action%20FRN%207-23-26%20FINAL.pdf)
is retained with its compressed layout extraction and hashes. The entire
published textual note 52(f), not only its reporting numbers, independently
reconciles with it. Every one of the 101 inserted heading descriptions and
printed percentages corroborates with the first native HTS snapshot. The
complete original table blocks and native duty expressions are retained.
Percentage agreement is an inventory check, not executable reconstruction of
the remaining charge expressions. The image tables in the published PDF have
not been independently reconciled cell by cell.

## Executable correction

`section301_labor.py` separates 60 investigation actions, 65 charge headings,
the Section 232 exemption carrier and 35 other reporting provisions requiring
further executable reconciliation. The latter retain identified descriptions
and unresolved questions. No additional amount is inferred from a residual,
the highest candidate rate or an aggregate forced-labor parameter.

The exemption binds source-named headings to composed Section 232 decisions.
Metal headings `9903.82.01` and `9903.82.03` cannot borrow the exemption for
the listed metal headings. Shared vehicle/parts headings preserve the source's
article qualifications. The automobile compiler supplies authoritative derived
facts; contradictory caller aliases cannot grant relief. Properly evaluated
vehicle-content and preference decisions remain subject to this interaction
even when their payable Section 232 amount becomes zero. An independent China
Section 301 component is retained.

The July 31 pharmaceutical insertion is a separate exact-time window. Its
heading-description insertion operands come from the original amendment and
also reconcile with subsequent native snapshots. It is not applied early or
held until the next HTS revision.

An FTZ withdrawal requires admission/status and reporting history before a
current Section 232 candidate can price this exemption. The original action's
domestic/privileged-status paragraph is retained. Unknown FTZ history requests
the relevant fact; a confirmed FTZ path remains explicitly unpriced pending
that reconciliation. This is unfinished implementation, not a conclusion that
the history is legally impossible to resolve.

## Ordinary build and serving path

The normal emitter writes `section301_forced_labor_rules.json`. Ordinary bundle
composition and the existing Parquet, local DuckDB and API path consume it;
there is no second React calculation or a hand-selected production fixture.
The ordinary revision builder also loads the original action history when
splitting legal states, including the transit and July 31 boundaries.

Unfinished charge/annex/claim/valuation paths emit an identified unpriced action
with NULL amount and no chosen reporting heading. They do not synthesize zero.
Their potential charge headings remain source metadata. The fragment makes no
full Section 301 coverage attestation, and no completed total is claimed.

## Verification and read-only comparison

Exact counts, commands, source pins and limitations are in `verification.json`;
compressed artifacts are indexed by `evidence-inventory.json`.

- The source-only census checks all 55 configured native snapshots. It retains
  original and amended descriptions, exact windows and the ordinary Census/EU
  mapping for all 60 investigations (86 Census origins). It calculates no
  revision or timeseries rates.
- Fifty controlled R cases test named/unnamed headings, zero versus positive
  payable amounts, absent candidates, qualified vehicle/parts branches,
  unresolved facts, FTZ histories, an independent Section 301 component and the
  exact July 31 second. Eight additional cases compose the actual original
  automobile and forced-labor fragments. All 58 have TypeScript conformance
  fixtures and modeling-input invariance checks. Controlled components do not
  attest real scope or full legal coverage.
- A one-cell ordinary Parquet build for `7304.31.30.00`, Germany, September 15,
  2026 resolves USD50 Section 232 on USD100 and a zero forced-labor component
  under `9903.05.90`. Its full total stays NULL. With the separate aircraft
  agreement qualified, Section 232 becomes zero and the still-uncompiled
  forced-labor aircraft path remains explicitly unresolved.
- The existing read-only MotherDuck observation for this ordinary metal case
  has a 10% forced-labor statutory parameter and 60% statutory total. The new
  result establishes the named component exemption; the old table cannot
  evaluate all shipment facts. This is not full-total parity. The 275-row,
  55-revision MotherDuck cohort is pinned in the preceding civil-aircraft audit
  and referenced here by hash. No live data was modified.
- Local DuckDB JSON/Arrow/batch checks retain the actual resolved components,
  dataset version and incompleteness; stale versions and tampering are tested.

Repeat only the source census:

```bash
python3 scripts/audit_section301_labor_policy.py --out /tmp/s301-labor-source-recheck
```

The output directory must not already exist. This is not WJR's revision rebuild.

## Remaining work and release limits

The remaining forced-labor work is explicit: original product and country
annex membership; description-limited articles; GN6 aircraft and pharmaceutical
use; transit and baggage/donation/information treatment; claimed USMCA and
CAFTA-DR treatment; actual Column 1 caps including specific/compound duties and
Korea's Special treatment; Chapter 98 valuations; subsequent TRQ implementation;
and FTZ admission/withdrawal history. The available text must be compiled and
verified, rather than leaving these paths permanently unresolved. The Brazil
action, remaining authority/claim interactions, AD/CVD and consumers also need
work.

The complete R gate remains unqualified because normalized artifacts are
missing/stale and TPC input is absent. Retained point logs also expose existing
aggregate parsing, Section 201 schedule and denormalization warnings. Those are
not passing full-coverage results. Aggregate differences are unqualified because
no series was rebuilt.

No timeseries/revision build, push, deployment, live MotherDuck write, release
activation, workflow dispatch or publication occurred. WJR retains the rebuild
and production approval steps. Before publication, rollback is a local revert
of this checkpoint; a later approved release must retain and atomically switch
the previous complete release identifier.

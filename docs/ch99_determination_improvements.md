# Chapter 99 Determination Correctness — June 11, 2026 Session

Improvements across **tariff-rate-tracker** (pipeline, branch `wjr_dev`) and
**sail-gtx-prerelease** (frontend, branch `illegal-transshipment`). Trigger
case: HTS 8536.90.8585 × Poland × Feb 24 – Apr 5, 2026 showed Section 232 as
"Statutory 50% → Effective 1.81%" under Ch. 99 heading 9903.85.04 — wrong
code, and an ad-valorem-equivalent presented as if it were a legal rate.

## The two core principles now enforced

1. **Determination vs. calculation are separate layers.** Determination
   surfaces (Tariff Explorer cards, Reconciliation, Duty Stack) show only the
   published statutory rate, the legal duty basis, the operative Ch. 99
   code(s), the required entry facts, and a calculation status. Dollar
   estimates exist only in the calculation layer, only after the importer
   supplies the legally relevant basis, and are always labeled
   "Estimated duty amount" — never "rate".
2. **No hardcoded Ch. 99 decisions.** Code/heading assignments, duty-basis
   semantics, and heading discovery derive from parsed sources (HTS JSON,
   US Notes PDF subdivisions, reviewed resource CSVs) with config demoted to
   QC expected-sets.

## Pipeline (tariff-rate-tracker)

### Per-product Section 232 derivative Ch. 99 codes
- **Bug fixed:** `resolve_ch99_codes()` assigned `sort(active codes)[1]` —
  9903.85.04 — to *every* aluminum derivative (steel analog identical). The
  per-product subdivision membership in `resources/s232_derivative_products.csv`
  (US Note 19: (i)→.04, (j)→.07, (k)→.08; Note 16(t)→9903.81.91) was parsed
  correctly but discarded.
- `apply_232_derivatives()` now carries each product's `deriv_ch99_code`
  (longest-prefix match, conflict guardrail preferring the more specific
  subdivision); `resolve_ch99_codes()` uses it when active in the revision,
  with a broadest-active-heading fallback (never alphabetical) and
  rate-matched base-heading picks.
- `scrape_us_notes.R` discovers derivative headings from the note text itself
  (new Inclusions-Process subdivisions self-register); the CSV diff remains
  the human review gate. `policy_params.yaml` heading lists are now QC
  expected-sets only.
- **Steel derivative coverage added** (the fork previously had none): 357
  Note 16(t) products ported from upstream.

### Duty-basis semantics (`duty_basis_232`)
- New column: `'metal_content_value'` (duty on the DECLARED value of the
  metal content — US Notes 16(a)/19(a), pre-Apr-6-2026 derivatives outside
  primary chapters) vs `'full_value'` (primary chapters, heading programs,
  and the entire annex era per Proclamation 11021). Derived from parsed
  structure — no dates hardcoded anywhere.
- `duty_provenance_json` §232 slot now carries `basis`, `basis_metal`, and
  the posted `statutory` rate.

### Chapter 99 rule sweep foundations
- `ch99_rules_json`: per-line rule objects — four statuses
  (`applied | exempt_or_replaced | not_applicable |
  potentially_applicable_requires_more_facts`), multiple simultaneous codes
  per line, exemption headings as citable codes, citation reason codes,
  required user inputs, and upstream-AuthoritySpec-aligned vocabulary
  (`stacking_class`, `rate_type`) so a later convergence stays possible.
- 9902 (MTB suspensions) and 9904 (agricultural safeguards) are parsed and
  surfaced as `requires_more_facts` candidates (no rate math yet).
- §301 exclusion headings emit determination-grade candidate rules
  (description-scoped; claiming one is a fact question) — `rate_301` is
  never modified.
- **Completeness QC:** any active 9903 heading with a parsed rate that is
  neither handled, not-duty-relevant, nor allowlisted fails 2025+ builds
  (`config/ch99_unresolved_allowlist.csv` is the reviewed escape hatch; it
  caught and documented 14 legacy 1980s-safeguard/washers headings on first
  run).
- `config/ch99_source_registry.yaml`: the program-family → FR/CSMS/quota
  source registry, committed as reviewed config.

### Legal-prose registries (single source of truth)
- `config/duty_citations.yaml` → `dutyCitations.json` (both frontends):
  derivative narratives rewritten to statutory/declared-basis phrasing; new
  sourced notes: `s232_basis_metal_content` (CBP two-line reporting),
  `s232_basis_value_unknown_mode` (CSMS #65236645: unknown content value ⇒
  report on entire entered value), `s122_non232_portion_only`
  (Proclamation 11012 — §122 applies only to the non-232 portion),
  `ieepa_terminated_eo14389`, `s232_full_value_proc11021`.
- New emits: `program_registry.json` (data-driven frontend program list),
  `s232_derivative_map.json` (reviewed subdivision map — lets the frontend
  correct stale pooled codes until the data rebuild lands),
  `revision_sources.json` (per-revision USITC archive Modification Sources,
  from `resources/tpc_policy_revision_map_usitc_archive_enriched.csv`, also
  merged into `config/revision_dates.csv`).

### Upstream correctness ports (Budget-Lab-Yale @2a1763cf — selective, no merge)
All five completed and validated against upstream's published magnitudes
(see `docs/upstream_port_notes.md`): revision re-dating from change-record
PDFs (44 PDFs ingested; 2026_rev_8 excluded as editorial-only), USMCA
eligibility inheritance + HS8 share fallback, IEEPA Annex II date-windowing
(final exempt list byte-identical to upstream's), 8-digit leaf HTS retention
(+473 products), §301 exclusion registry. Plus: MHD blanket-chapter strip,
Russia Proclamation 10522 narrowed to aluminum-only.

### Tests
`tests/test_ch99_rules.R` (21 checks) + extended `test_rate_calculation.R`
(57) — all green. Integration verified on real 2026_rev_4 data
(`scripts/verify_revision_subset.R`): 8536908585 → 9903.85.08 /
metal_content_value / statutory 50%, steel derivative → 9903.81.91, rules
JSON valid on every row, completeness QC passing.

## Frontend (sail-gtx-prerelease, `src/modules/tariff-rates`)

- **Determination model** (`utils/programDeterminations.ts`): consumes
  `ch99_rules_json` with a null-tolerant fallback (scalar columns + the
  reviewed subdivision map) for pre-rebuild data; `codeSource` labels
  map-corrected codes with an explicit pending-rebuild note that disappears
  automatically once rebuilt rows arrive.
- **Rate card:** statutory-rate headlines; Declared {Metal} Content section
  (required value $ + kg; CBP entry-reporting facts — smelt/cast with a
  Russia/Proc 10522 warning — explicitly *not* calculation inputs); split
  formula `s122% × (entered − declared) + 232% × declared` that resolves to
  per-term dollars, an effective % and the progress bar once values are
  present; Mode-B blocked state with the CBP unknown-value caveat inline;
  no metal-% slider, no "detected estimate" presented as a product fact
  (BEA shares are sector statistics, labeled as such); interactive
  worksheet-style formulas with editable value chips; kg × $/kg derivation
  aid (the legal basis remains the declared $ value).
- **Calculator:** full per-shipment Declared Content sections writing
  per-row composition; per-shipment worksheets reusing engine math; the
  assumed-share scenario tool is opt-in, starts empty, and badges every
  figure. **Engine fix:** a declared value is charged at the statutory rate
  (was double-scaled against the AVE), and the override is gated on the
  legal basis so annex-era rows aren't collapsed.
- **Reasoning & sources:** §232 headlines the statutory rate "of declared
  {metal}-content value" with column fallbacks; references effective after
  the row's period (e.g. Proclamation 11021 for Feb–Apr 2026) move to a
  "Subsequent legal change" section; per-revision USITC modification
  sources with FR links; citation hyperlinks wherever doc numbers exist.
- **Bulk tabs:** composition upload fields (value/kg/smelt/cast — no
  percent), editable RevoGrid composition band + `Est. §232 duty (declared
  basis)` + calc-status columns, Reconciliation drawer composition card,
  "Cannot reconcile — missing declared metal content value" variance
  semantics (excluded from aggregates), statutory × declared display on
  §232 stack rows.
- **Layout:** the Current Rate card animates to double width when the
  selected period carries composition logic (both date-entry and
  history-bar selection paths).

## Operational status / next steps

- All code committed locally: tariff-rate-tracker `wjr_dev` (14 commits),
  sail-gtx `illegal-transshipment` (10 commits). **Both branches are
  unpushed** (no git credentials in the working environment).
- **Data rebuild pending** (the one step that retires the pending-rebuild
  hedges):
  1. `Rscript src/00_build_timeseries.R --only-revisions 2025,2026`
     (add `--build-only` to skip daily/ETR/quality refresh; omit it once so
     downstream artifacts pick up the revision re-dating).
  2. MotherDuck: full push (`node frontend/scripts/push-to-motherduck.mjs
     --confirm-drop`) recreates the table with the new columns — no manual
     ALTER. Incremental (`--only-revisions 2025,2026`) requires
     `ALTER TABLE rates ADD COLUMN duty_basis_232 VARCHAR; ALTER TABLE rates
     ADD COLUMN ch99_rules_json VARCHAR;` first.
  3. Restart the API server (column detection runs at startup).
- Roadmap (documented, out of scope this round): 9902 MTB rate integration,
  9904/TRQ quota-fill logic, AD/CVD layer, ACE filing-sequence validation,
  full upstream AuthoritySpec convergence.

# Pre-March Section 232 source, logic and MotherDuck audit

Work starts from `661b570fd14616a367be79385b55a95b7a71230d`, on the original
tracker branch `wjr_dev`. No other repository was edited in this pass. No push,
deployment, workflow dispatch, MotherDuck write, release activation or timeseries
rebuild was performed. Only a bounded six-product/seven-origin pipeline fixture
was calculated, with temporary normalized and ledger output.

## Findings and corrections

1. **Scope broadening:** the read-only MotherDuck snapshot contains **429,420
   positive modeled metal rows**, in **2,105 HTS/revision groups**, outside both
   extracted pre-March scopes. For example, China `7202.11.50.00` and
   `7317.00.55.90` carry 25% steel despite not belonging to the old primary or
   derivative lists. The source-defined matching now reaches the R calculation,
   normalized decisions and executable fragment. Examples occur only in tests
   and audit queries, not production scope logic.
2. **Wrong metal for country relief:** configuration applied steel-only country
   relief to aluminum from Japan, South Korea, Brazil and Ukraine. The correction
   narrows the authority in declarative configuration; an independent extraction
   of heading/superior-text country exceptions rejects unsupported zero model
   overrides. Twenty saved `7604.10.10.00` country/revision rows demonstrate the
   previous zero. The ordinary additional aluminum duty is 10% under note 19,
   subject to individual grant/Russian-material facts. This is not a complete
   shipment-total finding.
3. **Quotas and reporting:** all 196 source categories retain exact codes,
   statistical exclusions, superior text and conditions. TRQ exhaustion selects
   the ordinary duty heading; absolute quota denial has no over-quota duty
   alternative. Actual CBP allocation is a shipment input. Partial allocations
   require split entry lines. No national utilization share substitutes for it.
4. **Claims:** 76 steel and five aluminum General Approved Exclusions are
   extracted and reconciled across six CBP bulletins. Their reporting differs by
   origin/regime, including cases requiring no Section 232 heading. They leave
   base/Section 301/emergency liabilities intact and cannot remove the Russian
   aluminum action. USMCA reevaluates the emergency/metal action ordering. An
   irrelevant individual-grant claim does not block independent country relief.
5. **Dates and identities:** Mexico melt/smelt predicates, Ukrainian certificates,
   EU/UK/Japan quota conditions and Russian treatment precede heading selection.
   Retired Canadian aluminum heading 9903.85.21 is not activated by its presence.
   The termination instant is extracted from Proclamation 10896. Old treatment
   runs through March 12, 2025 at 00:00:59 Eastern; new treatment starts at 00:01,
   within revision 4. Rates come from the source expressions, not rate maxima.

## Reporting identities investigated but still unresolved

The archived quota descriptions for **9903.81.07 and 9903.81.66** refer to
`9213.91.45`, which has no current product. The original Japan proclamation,
[Proclamation 10356, 87 FR 19351, annex](https://www.govinfo.gov/content/pkg/FR-2022-04-01/pdf/2022-07136.pdf),
prints the same reference under 9903.81.66. Both PDF and extracted text are retained
here. A guessed digit substitution to `7213.91.45` is not a verified amendment.
The audit records these references and the resulting missing quota category.
Over-quota liability can still be priced without inventing an in-quota heading.

The source inventory also records primary candidates without EU/UK quota
categories: narrower castings/forgings statistical references and two UK clad
sheet references. These are candidate discrepancies, not automatic scope
expansions. Description-limited primary and quota rules still require their
conditions. The audit records **16 product/quota-group gaps per revision**;
material facts may eliminate some candidates. These need legal/statistical
chronology reconciliation before declaring complete quota coverage.

Individual Commerce grants require a verified grant inventory establishing the
party, product description, operative dates, quantity remaining and reporting
instructions. An exclusion ID alone cannot establish them. The sources also
differ on whether some aluminum exclusions count against quota; this change does
not compute quota inventory or assume availability from either statement.

## Evidence and coverage limits

`summary.json` covers five relevant source revisions, all 240 configured origins,
835 candidate products per revision, 4,210 scope memberships in total, and 36,360
compiled decision branches (revision 4 includes the later regime). This is a
source/rule inventory, **not an exhaustive shipment-fact evaluation**.

`motherduck.json.gz` retains the exact read-only export, including SQL, database,
transaction mode and timestamps. Its uncompressed SHA256 is
`13fec9cf9803c04525c06cadc5d2c3b257a8c341bc9e778c41b026085def77ad`.
There are 6,245 primary-scope groups, 3,719 component groups and 8,400 selected
HTS/origin/revision rows. The comparisons concern metal components, not unique
shipments, whole-stack accuracy or financial exposure.

Primary guidance is retained with hashes in
`resources/legal_evidence/section232/pre-march`: CBP bulletins
[25-601](https://www.cbp.gov/trade/quota/bulletins/qb-25-601-2025),
[25-611](https://www.cbp.gov/trade/quota/bulletins/qb-25-611-2025),
[25-621](https://www.cbp.gov/trade/quota/bulletins/qb-25-621-2025),
[25-701](https://www.cbp.gov/trade/quota/bulletins/qb-25-701-2025),
[25-711](https://www.cbp.gov/trade/quota/bulletins/qb-25-711-2025) and
[25-721](https://www.cbp.gov/trade/quota/bulletins/qb-25-721-2025).
The matching full archived Chapter 99 notes and JSON hashes are recorded in each
source snapshot. Proclamations 10895/10896 and CBP's EO 14289 implementation are
additional retained sources. Browsing used gstack only.

The release remains `sail.tariff-release/v6`; result/rule bundles remain v1.
Rebuild with a new dataset version and recompose the bundles before preparing the
complete local release. The emitter persists the source, rules and applicability
through the existing versioned MotherDuck delivery path. It does not activate
anything. Publication needs WJR's later approval and a deployment smoke test.

## Remaining work and rollback

Broader all-authority coverage is not complete. Remaining work includes verified
individual Section 232 grants, the quota discrepancies above, further authority
and Chapter 98 claim interactions, AD/CVD scope/party instructions, financial
consumers, and the full rebuilt all-HTS/origin/interval reconciliation. Existing
IEEPA/122/338/301 suites are regression checks, not a new complete legal audit.

Aggregate weighting and utilization methodology is retained; emitted scope and
country parameters change. A full aggregate before/after comparison awaits WJR's
manual rebuild. Commands are in `docs/shipment-duty-manual-rebuild.md`.

No active release changed, so production rollback is unnecessary. Locally,
revert this change's commit if required and rebuild from the recorded base;
do not mix earlier rates with new fragments. Retain the prior active release
identifier when an eventual approved MotherDuck release is prepared.

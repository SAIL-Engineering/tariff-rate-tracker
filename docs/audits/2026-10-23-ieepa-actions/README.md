# Ordinary IEEPA action extraction and remaining chronology

The source-only audit retains the country-action decisions from all 55 configured
2025–2026 HTS archives. It does not rebuild rate partitions or write MotherDuck.
Its hashes identify the source/selector versions at the time of the audit.
`source-audit/` retains the initial run; `source-audit-v2/` is the subsequent
55-revision run with explicit country-exclusion decisions. Active reciprocal
periods now retain all 240 configured origins, including the six excluded origins,
instead of relying on missing rows to imply zero.

The calculation now keeps reciprocal and independent country-EO actions separate.
An Annex II reciprocal exclusion does not erase a separate country action. The
ordinary reciprocal baseline survives when only the independent EO is present.
Overlapping live country alternatives fail reconciliation instead of selecting
the greatest rate. Retired headings do not win because their rate is larger.

Verified source corrections include:

* April 9 country rates are not capped at the later suspended baseline. The
  April 10 suspension is a separate legal interval. [EO 14266, sections 2–3](https://www.govinfo.gov/content/pkg/FR-2025-04-15/html/2025-06462.htm).
* Japan's replacement floor takes effect August 7, although published in
  September. [Annex I(a), 90 FR notice 2025-17908](https://www.govinfo.gov/content/pkg/FR-2025-09-16/html/2025-17908.htm).
* Korea's replacement floor takes effect November 14. [Annex B, notice 2025-21940](https://www.govinfo.gov/content/pkg/FR-2025-12-04/html/2025-21940.htm).
* Swiss/Liechtenstein replacement floors also take effect November 14. The
  March review date is not an automatic tariff expiration. [Annex II and review provision, notice 2025-23316](https://www.govinfo.gov/content/pkg/FR-2025-12-18/html/2025-23316.htm).
* The build's collection gate uses the February 24, 2026 00:00 Eastern CBP
  cessation, separately from the earlier decision date and the 00:01 Section
  122 commencement. [CBP CSMS 67834313](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/40b11c9).

The source and normalized output retain every selected action code, parameter,
amendment hash, source description and effective timestamp. Both wide and
normalized model projections use independent reciprocal and EO arithmetic.
No highest-rate reporting-code fallback is used for ambiguous actions.

The reciprocal country exclusions use the revision's published .01.26/.27/.29
headings and its GN 3(b) membership. Their zero additional reciprocal parameter
does not remove a separate emergency action. Missing exclusion evidence, a missing
baseline needed for an origin, or a missing live action parameter fails selection.
Missing values propagate as unknown in the wide helper; the normalized aggregate
adapter rejects absent country parameters or unpriced floors. An affirmative
exemption can still remove its own action without requiring irrelevant base-duty
inputs. The source's blank duty cell for the GN 3(b) exclusion remains blank in
evidence; it is not fabricated into a quoted rate expression.

**Remaining:** November 14 falls inside the snapshot interval beginning November
13. Correcting the snapshot-date extraction alone does not split that entire
historical interval. The exact amendment timestamp is preserved, but complete
legal-event splitting/evaluation is still required before claiming all entry
dates are corrected. Fentanyl note 2(s)/(u) chronology, all product exceptions,
transit/warehouse conditions and the complete executable IEEPA bundle also remain
unfinished. A missing heading is not a finding that the law cannot resolve it.

Reproduce the source audit without a rate build:

```sh
Rscript scripts/audit_ieepa_actions.R output/new-ieepa-source-audit
```

Full rebuild commands are in the [manual runbook](../../shipment-duty-manual-rebuild.md).
No aggregate before/after totals or production qualification are claimed yet.

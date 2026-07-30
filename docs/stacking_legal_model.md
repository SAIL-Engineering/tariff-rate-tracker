# Duty stacking, override and replacement — the legal model

> **Status:** Phase 0 of the stacking rework. This document is the *reviewed legal
> reading*; `config/stacking_rules.yaml` is its machine-readable form and the
> engine's single source of truth. Change the law's reading here first, then the
> YAML, then the code — never the other way round.

## Why this exists

The engine previously encoded stacking as one hardcoded `case_when` in
`apply_stacking_rules()` whose only exclusion mechanism was multiplicative
metal-content scaling (`nonmetal_share`). The law does not work that way. It
specifies **categorical exclusion** between named actions, it **changes over
time**, and several duties **replace** the base rate rather than adding to it.

Three distinct relationships have to be modelled, and the old code could only
express the first:

| Relationship | Meaning | Example |
|---|---|---|
| **stacks** | both duties owed, additively | §301 + §232 |
| **excludes** | higher-precedence action applies; the other is *not owed at all* | §232 autos excludes §232 steel |
| **replaces** | the duty substitutes for the base rate | Column 2 replaces Column 1 |

---

## 1. EO 14289 — the non-stacking order

**Executive Order 14289, "Addressing Certain Tariffs on Imported Articles"**
— [90 FR 18907](https://www.federalregister.gov/documents/2025/05/02/2025-07835/addressing-certain-tariffs-on-imported-articles),
signed 2025-04-29, published 2025-05-02.
Implementation: [90 FR 21487](https://www.federalregister.gov/documents/2025/05/20/2025-09066/notice-of-implementation-of-addressing-certain-tariffs-on-imported-articles-pursuant-to-the).
CBP operational guidance: **[CSMS #65054270](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3e0a63e)**
(2025-05-15), applying to entries **on or after 2025-03-04** —
*"retroactively to entries of merchandise subject to the five applicable tariff
measures and entered for consumption or withdrawn from warehouse for consumption
on or after March 4, 2025."*

### §2 — the order applies to exactly five actions

| Ref | Action | Our authority key |
|---|---|---|
| 2(a) | Proclamation 10908 — Autos and Auto Parts | `s232_auto` |
| 2(b) | EO 14193 (am. 14197, 14226, 14231) — IEEPA **Canada** | `ieepa_canada` |
| 2(c) | EO 14194 (am. 14198, 14227, 14232) — IEEPA **Mexico** | `ieepa_mexico` |
| 2(d) | Proclamation 9704 (am. 9980, 10895) — **Aluminum** | `s232_aluminum` |
| 2(e) | Proclamation 9705 (am. 9980, 10896) — **Steel** | `s232_steel` |

Anything not on this list is outside the non-stacking order entirely.

### §3(a) — the precedence rules, verbatim

> **(i)** An article subject to tariffs pursuant to the action listed in section
> (2)(a) … **shall not be subject to** additional tariffs … pursuant to the
> actions listed in sections 2(b) through 2(e).
>
> **(ii)** An article subject to tariffs pursuant to the actions listed in section
> 2(b) or 2(c) … **shall not be subject to** additional tariffs … pursuant to the
> actions listed in section 2(d) or 2(e).
>
> **(iii)** An article subject to tariffs pursuant to the actions listed in section
> 2(d) … **shall be subject to** additional tariffs … pursuant to the actions
> listed in section 2(e) …; likewise, an article subject to … 2(e) shall be
> subject to … 2(d), provided the article otherwise satisfies all conditions
> necessary for application of those additional tariffs.

So:

```
Step 1   s232_auto        → excludes ieepa_canada, ieepa_mexico, s232_aluminum, s232_steel
Step 2   ieepa_canada
         ieepa_mexico     → excludes s232_aluminum, s232_steel
Step 3   s232_aluminum  ⇄  s232_steel   — these two STACK with each other
```

**§3(a)(iii) is the rule the old engine could not express at all**, because it
collapsed every §232 action into a single `rate_232` scalar. A derivative
containing both steel and aluminum owes duty on **both** contents.

### The definition that makes it work

CSMS #65054270, verbatim:

> **"'Subject to' means that duty more than 0% is owed under the tariff action."**

This single definition also produces the USMCA behaviour, so it needs no special
case: a USMCA-qualifying part of a passenger vehicle or light truck owes 0% under
Proc 10908, is therefore **not "subject to"** 2(a), and falls through Steps 1 and
2 to Step 3 — where it may still owe §232 aluminum and/or steel. Model the
definition, and the exception falls out.

CBP states the same outcome as a direct carve-out:

> "Parts of passenger vehicles and light trucks that qualify for preferential
> treatment under United States-Mexico-Canada Agreement (USMCA), **ARE NOT
> subject to** the 232 Auto/Auto Parts tariff or the IEEPA Canada or IEEPA Mexico
> tariff."

The two readings agree on the result. We encode only the >0% threshold and do
**not** add a separate USMCA branch — one rule, not two that can drift apart.

### §3(b), §3(c), §4 — what stays cumulative

> **§3(b)** Each action … remains independently valid and enforceable, except that
> the duty **rates** … shall not be cumulative when the conditions … are met.

i.e. exclusion suppresses the *rate*, not the classification. A suppressed action
should still be visible in provenance with a rate of 0 and a reason.

> **§3(c)** If an imported article is subject to both a tariff imposed pursuant to
> subsection (a) … and one or more tariffs imposed pursuant to an action **not
> listed in section 2** …, then the tariff … **shall be cumulative**.

> **§4(b)** … an article … may still be subject to other applicable duties, taxes,
> fees, exactions, and charges, such as, but not limited to, those set forth in
> **column 1** of the HTSUS; duties imposed pursuant to **section 301** of the
> Trade Act of 1974; duties imposed pursuant to **Executive Order 14195**
> (synthetic opioid supply chain, PRC); and **antidumping and countervailing
> duties**.

Explicitly cumulative, never suppressed by the order:
`column1_hts`, `s301`, `ieepa_fentanyl` (EO 14195), `adcvd`.

**IEEPA reciprocal (EO 14257) is absent from §2**, so it is likewise outside the
order and cumulative. This is a deliberate reading: the order enumerates its scope
exhaustively and reciprocal is not in it.

---

## 2. Duties that REPLACE rather than add

### Column 2 (non-NTR)
HTSUS **General Note 3(b)**. Products of countries not entitled to normal trade
relations are dutiable at the Column 2 rate, which **replaces** Column 1 General
— it is not additional. Column 2 rates are frequently an order of magnitude
higher (e.g. `2921.46.00`: Free on Column 1, `15.4¢/kg + 149.5%` on Column 2).

Current non-NTR origins, maintained per revision in
`resources/gn3_column2_countries.csv`: **Cuba, North Korea, Russia, Belarus**.
Russia and Belarus lost PNTR in April 2022.

Column 2 replaces the base rate; the Chapter 99 additional duties then stack on
top of it as normal.

### Chapter 99 subchapter II (MTB, 9902)
Temporary duty suspensions/reductions. The heading text is explicit — the article
"is subject to duty at the rate set forth herein **in lieu of** the rate provided
therefor in chapters 1 to 97." A *replacement* of the base rate, downward.

### Floor / cap semantics
Not replacement, but base-rate-dependent, so they belong with it:
- **Floor** (IEEPA reciprocal floor, §232 annex III): additional =
  `max(0, floor − base)`, so `base + additional = floor`.
- **Total-duty cap** (§301 forced-labor net-MFN tiers): additional =
  `max(0, cap − base)`.

Both mean the base rate feeds back into an authority rate, so the order of
operations against preference reductions matters — see `docs/assumptions.md` §14.

---

## 3. Era boundaries

The rules change repeatedly; a single static matrix is wrong. Eras are keyed by
revision effective date in `config/stacking_rules.yaml`.

| From | Era | What changes |
|---|---|---|
| — | `legacy` | §232 steel/alu + §301 + §201; no non-stacking order |
| 2025-03-04 | `eo14289` | EO 14289 non-stacking order applies to entries on/after this date |
| 2026-02-20 | `post_ieepa` | IEEPA invalidated — reciprocal and fentanyl cease |
| 2026-02-24 | `s122` | §122 surcharge window opens (closes 2026-07-23) |
| 2026-04-06 | `s232_annex` | §232 annex regime — duty on full customs value, metal-content scaling retired |
| 2026-07-22 | `s301_2026` | §301 Brazil (note 50); then forced labor 60 economies (note 52) from 07-24 |
| 2026-08-19 | `s338` | §338 Canada |

Note the `eo14289` era begins at the **entry** date CBP applies it from
(2025-03-04), which precedes both the EO's signature and its HTS implementation —
the guidance is explicitly retroactive.

---

## 4. What this model deliberately does not assert

- **Scope determinations.** Whether a given article falls within an AD/CVD order's
  narrative scope, or within a §232 derivative list, is a factual determination we
  cannot make from the HTS alone. Those are emitted as candidates requiring more
  facts, not as asserted duty.
- **Exporter identity.** AD/CVD rates are firm-specific; we carry the all-others
  rate and expose the range.
- **Chapter 98, drawback, FTZ.** Out of scope for this pass; noted in
  `config/ch99_source_registry.yaml` as open.

---

## Sources

- EO 14289 — [90 FR 18907](https://www.federalregister.gov/documents/2025/05/02/2025-07835/addressing-certain-tariffs-on-imported-articles) (full text retrieved and quoted above)
- Implementation notice — [90 FR 21487](https://www.federalregister.gov/documents/2025/05/20/2025-09066/notice-of-implementation-of-addressing-certain-tariffs-on-imported-articles-pursuant-to-the)
- CBP **CSMS #65054270** — [primary bulletin](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3e0a63e) (retrieved 2026-07-30; all quotes above taken from it directly). Corroborating summaries: [International Trade Insights](https://www.internationaltradeinsights.com/2025/05/cbp-issues-guidance-on-prioritization-of-articles-subject-to-more-than-one-tariff-under-eo-14289/), [C.H. Robinson](https://www.chrobinson.com/en-us/resources/insights-and-advisories/client-advisories/2025q2/05-21-2025-client-advisory-cbp-issues-guidance-on-tariff-prioritization-under-executive-order-14289/)
- [Global Trade Alert — US Tariff Stacking, Explained](https://globaltradealert.org/blog/US-Tariff-Stacking-Explained)
- HTSUS General Note 3(b); `resources/gn3_column2_countries.csv` (parsed from GN 3 per revision)

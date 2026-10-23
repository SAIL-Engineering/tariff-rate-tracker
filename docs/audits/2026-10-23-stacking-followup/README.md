# IEEPA and Section 232 stacking follow-up, 2026-10-23

Status: confirmed defects fixed locally; shipment release remains unqualified.
No timeseries build, MotherDuck write, publication or deployment was performed.

## Read-only evidence

`motherduck.json` records a single READ_ONLY transaction against `duty_calculator`,
with exact SQL and timestamps. It contains 220 revision/origin groups across all
55 configured revisions for Canada, Mexico, China and Hong Kong; 1,100 targeted
HTS/origin/revision rows; and 12 Hong Kong examples. `sources.json` records primary
source URLs, locators and hashes. `manifest.json` hashes the saved artifacts.
The HTS excerpt includes the source archive hash, the 1.5% ferroalloy base rate,
and heading 9903.01.24 explicitly naming China **and Hong Kong**.

## Confirmed findings and changes

1. **June 4 priority reversal was missing.** Proclamation 10947 clause (5)
   reverses EO 14289 section 3(a)(ii) at 00:01 Eastern. Steel/aluminum take
   priority over Canada/Mexico IEEPA; autos retain priority. Canadian
   `7202115000` in live `2025_rev_14` still suppresses steel and reports 11.5%.
   The reviewed unclaimed base/steel/IEEPA subtotal is **51.5%** (1.5 + 50 + 0),
   rather than 11.5%. This is not an AD/CVD/scope-qualified complete total.
   The broad query flags **57,628** post-amendment rows with the same suppression
   pattern. Those are review candidates, not 57,628 independently proven errors.
2. **Later eras discarded inherited rules.** The resolver returned the child
   YAML object without resolving `inherits`; the production calculation then
   treated absence of `non_stacking` as no precedence. It now resolves ancestry,
   rejects cycles/missing parents/ambiguous boundaries, and executes ordered
   action/exclusion edges from data. Unsuppressed action inputs are preserved for
   the statutory branch instead of reusing the aggregate's suppressed actions.
3. **Auto/copper exclusion was missing.** Proclamation 10962 clause (5) creates
   a dated exclusion from August 1 at 00:01 Eastern. The original EO's treatment
   of unlisted actions cannot be applied forever. Tests retain copper when the
   auto action is not owed and retain other unrelated actions.
4. **Hong Kong fentanyl was incorrectly discounted.** EO 14195 remains cumulative
   under EO 14289 section 4(b). The shared fentanyl column was treated differently
   solely because the code's full-value branch selected mainland China.
   `hong-kong-replay.json` holds all other model inputs fixed. For the aluminum
   beer example, the legacy modeled total changes from 31.04407585% to
   32.08815170%; several full-value Section 232 rows recover a missing 20-point
   component. These are model replays, not shipment total oracles. The query finds
   **77,541** Hong Kong rows with concurrent positive fentanyl and Section 232
   rates across revisions; it does not certify each one's scope or valuation.
5. **Semiconductor shares were presented as statutory rates.** CBP CSMS 67400472
   requires technical eligibility and end-use facts. New columns retain the
   published conditional rate, qualifying share, end-use share and calibration
   basis. `shipment_232_scope_status=needs_inputs` and required-fact/source fields
   accompany a null statutory rate and total. Aggregate rates remain unchanged.
   This also covers zero-model-duty rows added during grid expansion. Configured
   missing share files and invalid/duplicate shares now fail extraction. A missing
   calibration row retains the old upper-bound model only with an explicit label.
6. **Unknown statutory values became zero in totals.** Any supplied unknown
   statutory component now invalidates the numerical statutory total and
   alternative totals, including unknown IEEPA/122/232/301/338 components.

## Dates and remaining legal work

The era metadata distinguishes CBP's IEEPA collection end at **2026-02-24 00:00
Eastern** from Section 122's start at **00:01**, and preserves Section 122's
exclusive end at July 24 00:01 and the postponed August 22 Section 338 start.
A date-only revision is the model regime at the end of that day. Exact entry
queries need offset-bearing timestamps; revision lookup alone is insufficient.
The February 20 legal-invalidity/ruling date, later collection cessation and
refund treatment are distinct; this change does not collapse them or alter the
existing aggregate policy-date sensitivity option.

Unfinished: executable all-authority rule compilation; exact content valuation;
non-metal CA/MX interactions and other heading-program exclusions; semiconductor
technical/end-use evaluation and interactions; remaining action attribution;
normalized aggregate reconstruction; complete SAIL consumer migration; and
production release qualification. The new model/required-fact fields are retained
in generated wide output, but legacy API projections are not the complete
shipment contract. Publication must wait for the serving-path gates.

## Reproduction and manual rebuild

```sh
node frontend/scripts/audit-stacking-motherduck.mjs .env output/stacking-audit-NEW.json
Rscript tests/test_stacking_temporal.R
Rscript tests/test_s232_model_separation.R
Rscript tests/test_statutory_totals.R
```

The audit refuses to overwrite an existing output. Its connection and transaction
are read-only. It runs fixed bounded queries, not arbitrary SQL supplied by users.
Run it from the tracker root. Existing production data remains unchanged.

The [manual rebuild runbook](../../shipment-duty-manual-rebuild.md) contains the
55-revision command and downstream gates. WJR runs those commands. Version 2 of
`config/stacking_rules.yaml` is emitted as `stacking_model_version`, with
`stacking_era_id`, so corrected historical aggregate changes can be identified.
A full before/after trade-weighted difference report requires that manual rebuild.
Local replay evidence does not substitute for it.

Verification logs and their hashes are recorded separately. Full-data parity
cannot pass until the missing normalized artifacts are rebuilt manually.

## Verification

The complete R run passed 21 of 23 suites (401 counted assertions plus uncounted
suites). Normalized parity still fails for 2,008 cases with missing rebuilt
normalized artifacts; TPC is skipped for missing inputs. After final input and
schema guards, the affected suites passed again: temporal 13, rate calculation
151, statutory totals 15, and the semiconductor/model-invariance suite. All 54
Node/API tests passed, including Arrow null preservation. This is not a green
full-data qualification. `verification.json` records the order and actual logs.

This pass changes only the tracker repository. The existing Trade Intelligence
and SAIL integration commits remain unchanged; serving-path completion remains
part of the broader plan.

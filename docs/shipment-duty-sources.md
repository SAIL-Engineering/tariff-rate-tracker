# Shipment-duty sources and the meaning of unresolved results

The tariff stack is not stored solely as generic prose. The tracker consumes
USITC's structured HTS records, complete duty expressions, original legal
instruments and annex tables, CBP implementation instructions, and the existing
Trade Intelligence evidence corpus. A database row, a legal action and a complete
shipment calculation are different objects.

This is a navigation map to the principal sources and retained manifests, not a
claim that the complete legal-action inventory has already been qualified.

| Decision | Primary source entry points | Retained evidence / executable implementation |
|---|---|---|
| Classification, General/Special/Column2 expressions, programme identities | [USITC HTS](https://hts.usitc.gov/), revision exports, Chapter99, General Note3 and the applicable programme's General Note | `data/hts_archives/hts_*.json`, `data/us_notes/chapter99_*.pdf`, native GN3 snapshots; `src/shipment_base_sources.py`, `src/shipment_build.R` |
| Original reciprocal IEEPA action | [EO14257 and original annexes](https://www.govinfo.gov/content/pkg/FR-2025-04-07/pdf/2025-06063.pdf), subsequent country agreements, suspensions and product amendments | `resources/legal_evidence/2025-06063/`, `resources/legal_evidence/reciprocal-later/source-catalog.json`; `src/ieepa_reciprocal_history.py`, `src/ieepa_reciprocal_rules.py` |
| Drug-emergency IEEPA actions | Original presidential orders and CBP heading insertions/amendments; [retained source and chronology implementation](../src/ieepa_fentanyl_sources.py) identifies each source; collection termination is independently reconciled with CBP | `resources/legal_evidence/2025-02293/`, `2025-03664/`, `2025-03665/`, `2025-03900/`, `2025-03901/`, later amendments and termination; `src/ieepa_emergency_rules.py` |
| Historical steel/aluminum, quotas and exclusions | Original proclamations, historical notes16/19 and CBP quota bulletins; individual grant authority and grant-specific records | `resources/legal_evidence/section232/pre-march/sources.json`, `section232/grants/sources.json`; `src/section232_legacy_rules.py`, `src/section232_pre_march.py`, `src/section232_grants.py` |
| April/June2026 metal regimes | [Proclamation11021 and annexes](https://www.govinfo.gov/content/pkg/FR-2026-04-09/pdf/2026-06960.pdf), [April technical correction](https://www.govinfo.gov/content/pkg/FR-2026-04-29/html/2026-08297.htm), [June amendment](https://www.govinfo.gov/content/pkg/FR-2026-06-04/pdf/2026-11314.pdf) | `resources/legal_evidence/section232/note16-reviewed-semantics.json`, `note16-us-metal-reconciliation.json`, `intraday-transitions.json`; `src/section232_revision.R`, `src/section232_note16_rules.py` |
| Copper before April2026 | [Proclamation10962 clauses1,4–6 and annex](https://www.govinfo.gov/content/pkg/FR-2025-08-05/html/2025-14893.htm), [CBP-CSMS65794272](https://content.govdelivery.com/bulletins/gd/USDHSCBP-3ebf0e0), and the original April replacement annex | `resources/legal_evidence/2025-14893/`, `CSMS-65794272/`, `section232/copper/`; `src/section232_copper.py` |
| Automobiles/parts and country amendments | Original Proclamation10908 annex and subsequent original country instruments, independently corroborated against native note33 | `resources/legal_evidence/section232/autos/review.json` lists exact URLs, hashes and corpus versions; `src/section232_autos.py` |
| Listed MHD parts, certified auto/MHD parts and offset procedures | [Proclamation10984 original annex](https://www.govinfo.gov/content/pkg/FR-2025-10-22/pdf/2025-19639.pdf), native notes33/38, original country/metal amendments and CBP certification FAQs | `resources/legal_evidence/section232/vehicle-parts/`; `src/section232_mhd_parts.py`, `src/section232_vehicle_certified.py`; [verification checkpoint](audits/2026-10-30-vehicle-parts/README.md) |
| Civil-aircraft concessions | Original country instruments plus the explicit April preservation and reporting replacements | `resources/legal_evidence/section232/civil-aircraft/sources.json`; `src/section232_civil_aircraft.py` |
| Semiconductors | [Proclamation11002 and original annex](https://www.govinfo.gov/content/pkg/FR-2026-01-20/pdf/2026-01052.pdf), original amendments and CBP implementation instructions | `resources/legal_evidence/2026-01052/`, `section232/semiconductors/`; `src/section232_semiconductors.py` |
| Section122 | [Original proclamation, especially paragraph4 and annexes](https://www.govinfo.gov/content/pkg/FR-2026-02-25/pdf/2026-03824.pdf), subsequent original amendments, native note2(aa) | `resources/legal_evidence/section122/interactions/review.json` identifies the exact operands and original sources; `src/section122_sources.py`, `src/section122_rules.py` |
| Section338 | Original alcohol, dairy and vehicle proclamations, suspension and subsequent scope amendments | `resources/legal_evidence/section338/manifest.json` lists each original PDF, URL, hash and extraction; `src/section338_sources.py`, `src/section338_rules.py` |
| Traditional Section301 charges/exclusions and Chapter98 interactions | Original USTR actions, note20/31, exclusion extensions and retroactive/conforming amendments; [2024 modification example](https://www.govinfo.gov/content/pkg/FR-2024-09-18/pdf/2024-21217.pdf) | `resources/legal_evidence/section301_chapter98/review.json`, revision-specific note/exclusion extraction; `src/section301_sources.py`, `src/section301_revision.R` |
| Forced-labor Section301 actions | [Original USTR final action and annexes](https://ustr.gov/sites/default/files/files/Press/Releases/2026/FLIP%20301%20Investigation%20Final%20Action%20FRN%207-23-26%20FINAL.pdf), [published Federal Register document](https://www.govinfo.gov/content/pkg/FR-2026-07-28/pdf/2026-15181.pdf) | `resources/legal_evidence/section301/forced-labor/sources.json`, `reviewed-annexes.json`, `annex-reconciliation.json`; `src/section301_labor.py`, `src/section301_labor_pricing.py` |
| FTZ classification, status, rate clock and valuation | [19CFR146.65](https://www.govinfo.gov/content/pkg/CFR-2025-title19-vol2/xml/CFR-2025-title19-vol2-sec146-65.xml),146.41/.42/.43, each action's own FTZ provisions, applicable CBP instructions and fact-specific CROSS rulings | `resources/legal_evidence/ftz/sources.json` includes dated XML snapshots and CROSS corpus versions; `src/ftz_valuation.R` |
| AD/CVD deposits | Commerce order/scope evidence, company-specific CBP cash-deposit instructions, corrections, effective entry windows and relevant suspension/revocation instructions | Existing `sail-trade-intel-data` MotherDuck corpus and pinned evidence exports. An HTS association alone does not establish scope or the applicable company rate. |

Generated components retain source IDs/citations and reporting codes. Source
manifests retain byte hashes and URLs. Original legal instants remain distinct
from the date USITC published a revised snapshot. CROSS rulings interpret their
own facts and operative historical law; they do not turn a historical code into
a currently valid classification.

## What unresolved means

| Cause | Example | Required resolution |
|---|---|---|
| Missing actual shipment facts | Copper-content value, quantities, end use, producer/exporter, FTZ status/application date or a properly asserted claim | Obtain the relevant evidence. Ask for facts only on matched conditional paths. Missing information cannot become zero. |
| Extraction or implementation unfinished | Privileged-foreign historical classification/rate selection; an action-specific override not yet compiled; remaining claim/valuation intersections | Improve the extraction, rule catalog and evaluator. This is engineering work, not evidence that the law is unknowable. Do not move it onto the importer as a generic yes/no fact. |
| Source history has not been reconciled | A correction is retroactive, a reporting provision changes between snapshots, or one source lists a different scope | Identify the operative instrument and its exact reach, retain the predecessor/correction and test the temporal boundaries. A later snapshot alone cannot settle an earlier entry. |
| Actual published defect or conflict | A malformed native Special reference also appears in the printed book; the April/June US-metal formulations disagree for some inputs | Preserve the exact discrepancy and pursue corroborating original instruments/instructions. Resolve independently supported portions; do not repair digits, punctuation or rates by guessing. |
| Corpus coverage incomplete | The read-only CSMS corpus search returned no copper notices although a directly verified public CBP copper notice exists | Expand evidence acquisition or retrieve the primary record directly. Zero search results are not proof that no instruction exists. A local export does not replace the production evidence database. |

The current result status `unresolved_source` covers several of these legal/data
causes. Its detailed questions must be read before deciding whether the next
step is research, an engineering correction or a request for shipment evidence.
It must not be advertised as a complete duty total.

## Other structured content and calculation tools

USITC's [export facility](https://hts.usitc.gov/) supplies machine-readable HTS
records. CBP's [ACE CATAIR Entry Summary Create/Update](https://www.cbp.gov/sites/default/files/2026-09/26_0924_ace_catair_entry_summary_create_update.pdf) defines
structured filing interfaces; a filing format is not a complete legal evaluator.

Commercial services also maintain tariff content and calculation products:
[Descartes duty/tariff data](https://www.descartes.com/solutions/global-trade-intelligence/duty-and-tariff-data)
and [Avalara cross-border calculations](https://www.avalara.com/us/en/products/industry-solutions/cross-border-solutions.html)
are concrete examples checked against their official product pages. Those pages
do not qualify the complete historical/action/FTZ/company coverage needed here.
Any independent comparison must record product/data version, entry-date support,
shipment assumptions, covered authorities, citations and unresolved components;
agreement between two engines is not itself proof of legal correctness.

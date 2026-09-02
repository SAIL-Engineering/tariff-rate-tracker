# HTS revision rollout — multi-jurisdiction

Detects new tariff revisions, builds the retrieval corpus that SAIL GTX
classification searches, publishes it to Pinecone, and points the app at it —
with completeness gates, a smoke test, and rollback.

ONE spec-driven orchestrator serves every jurisdiction:

```bash
python3 scripts/hts_automation/refresh.py --jurisdiction US   # or CA / EU / DO
```

`run_locally.sh` (US) and `refresh_ca.sh` (CA) survive as thin wrappers with
their historical flags. The GitHub workflow (`hts-revision-update.yml`) calls
the same orchestrator — there is no separate inline copy to drift.

| | US | Canada | EU | Dominican Republic |
|---|---|---|---|---|
| Spec | `config/jurisdictions/us.json` | `ca.json` | `eu.json` | `do.json` |
| Discovery | USITC scrape (daily cron) | CBSA menu page scrape (`.accdb` download + mdbtools TPHS export) | CIRCABC REST (monthly release folders) | manual — user drops the book in `data/do_tariff_source/` |
| Source format | `usitc` (Indent column) | `cbsa` (ancestor-count indent) | `taric` (producline suffix + dash indent + official IS_LEAF) | `dga` (dash-prefix hierarchy, Spanish) |
| Leaf depth | 8/10-digit | 10-digit (67 at 8, 1 at 4) | 10-digit TARIC (16,708 official leaves) | 8-digit (7,697) |
| Steps | acquire build publish register ship envvars smoke | acquire build verify publish register ship | same as CA | same as CA |
| Duty rates | US rate pipeline (MotherDuck) | `build_duty_rates.py` (25 TPHS treatments, inherited) | measures 103/142 + origin groups | Grav./ITBIS/Selectivo |

Key commands:

```bash
refresh.py -j CA --plan-only                # show the plan, run nothing
refresh.py -j CA --dry-run                  # build + verify, no external writes
refresh.py -j US --from-step publish        # resume a broken run (names or 1-based index)
refresh.py -j DO --acquire-adapter manual --source path.csv --effective-date 2022-01-01
```

Completeness guarantees (the reason this pipeline exists):

* **Source-row conservation** (exit 5/6): every coded source row must appear in
  the built tree and the tree may invent nothing.
* **Official leaf cross-check** (EU, exit 7): our leaf set must equal the EU's
  own `Declarable codes.xlsx` IS_LEAF flags exactly.
* **Cross-revision diff** (`diff_revisions.py`, the `verify` step): added /
  removed / leaf→internal / redescribed vs the previous revision, gated by
  per-jurisdiction percentages — a bad parse never reaches Pinecone.
* **Golden queries** per jurisdiction (`config/jurisdictions/*_golden_queries.json`)
  at publish and smoke time.
* **Byte-identical regression**: `tests/python/` (pytest, offline) locks the
  four documented `build_tree()` fixes, the loaders, and the record schema.

Retention: `publish.keep = 3` — the latest revision plus the previous two per
jurisdiction, pruned only at swap time (operator decision 2026-08-27).

Artifacts shipped to sail-gtx-prerelease per revision (one commit):
`server/data/hts/<jur>_<year>_rev_<n>.codes.json` (hallucination-guard index),
`server/data/hts/<jur>_<year>_revision_<n>.json` (HTS Explorer dataset;
US keeps the legacy `hts_<year>_revision_<n>.json` name), and
`server/data/duty-rates/…` (per-chapter derived duty rates + treatments).

---

## Nightly automation — US, CA, EU, GB

`.github/workflows/hts-revision-update.yml`, cron `0 6,7 * * *` (2 AM
US-Eastern in both DST regimes), one serial matrix leg per jurisdiction.
Each leg runs `refresh.py --jurisdiction <JUR> --if-new`: the gate asks the
upstream source for its latest revision (USITC scrape / CBSA menu page /
CIRCABC folder listing — no corpus download) and compares against the latest
revision registered in Supabase, exiting 0 in seconds when nothing is new.
EU months whose CIRCABC folder is still uploading report `in_progress` and
skip cleanly. On a new revision the leg runs the full rollout and commits the
registry CSV (+ CA/EU source CSVs) back to this repo. `run_locally.sh`
mirrors the US leg step for step; `refresh.py -j CA` / `-j EU` mirror theirs.
Manual check: `python3 scripts/hts_automation/check_upstream.py -j CA`.
GB (United Kingdom) versions bump near-daily; its two-stage gate republishes
the Pinecone corpus only when the nomenclature hash changes and otherwise
ships a rates-only refresh of the duty artifacts (state in
data/gb_tariff_source/state.json).
Secrets/vars are pushed with `set_repo_secrets.py` (run it yourself; it
reads `.env.hts_automation`).

The US leg is pure Python since 2026-08: `usitc_native.py` ports the three
R scripts (releaseList scrape/merge, latest-revision resolve, archive
download) byte-compatibly — verified against live R runs — so no leg needs
an R toolchain. The R originals remain for the tariff pipeline, which also
owns the un-ported Chapter 99 PDF probe.

The US leg in step terms:

```
1 scrape USITC          01_scrape_revision_dates.R --auto-clear-review
2 resolve revision      latest_revision.R
3 download JSON + CSV   02_download_hts.R
4 build corpus          build_hts_corpus.py
5 publish               pinecone_sync.py swap   ← upload, verify, THEN prune
6 point Supabase        supabase_insert_revision.py
7 commit dataset        sail_gtx_commit.py --prune-keep 3
8 env vars              update_env_vars.py set --snapshot-out
9 smoke test            smoke_test.py           ← rolls back env vars on failure
```

Step 5 was commented out for the whole time Ragie was retired, so every run
shipped a new dataset and advanced the revision *label* while retrieval kept
answering from a frozen corpus. `smoke_test.py` now asserts the namespace
pointer exists **and** queries the corpus, which is the check that would have
caught it.

Required secrets: `PINECONE_API_KEY`, `SUPABASE_URL`,
`SUPABASE_SERVICE_ROLE_KEY`, `SAIL_GTX_REPO_PAT` + the
`SAIL_GTX_PRODUCTION_BRANCH` variable for every leg; the US leg additionally
`RAILWAY_*`, `VERCEL_*`, and the `SAIL_GTX_HEALTHCHECK_URL` /
`SAIL_GTX_API_BASE` variables. (`RAGIE_API_KEY` is no longer referenced and
can be deleted.)

## Canada — one command

```bash
# 1. drop the CBSA export in data/ca_tariff_source/ as ca_tariff_<year>_rev_<n>.csv
# 2.
scripts/hts_automation/refresh_ca.sh --effective-date 2026-08-01
```

Picks up the newest matching file, derives the revision from its name, builds,
uploads to a **new** namespace beside the live one, verifies with golden
queries, and only then points Supabase. If anything fails, Supabase is never
touched and the previous corpus keeps serving. `--dry-run` builds and reports
without writing.

---

## The corpus builder

`build_hts_corpus.py` emits one record per **leaf**, with the embedded text and
the displayed text separated:

```jsonc
{ "_id": "US|2026_rev_12|0101290090",
  // embedded: prose only, no codes, basket resolved against its siblings
  "chunk_text": "Live animals > Live horses… > Horses > Other, other than: Purebred breeding animals > Other, other than: Imported for immediate slaughter",
  // not embedded: what reaches the classification prompt
  "display_text": "0101.29.00.90 = 01 Live animals | 0101 Live horses… | 0101.29.00 Other | 0101.29.00.90 Other",
  "code": "0101.29.00.90", "chapter": "01", "heading": "0101",
  "subheading": "010129", "depth": 10, "is_basket": true, … }
```

Alongside it, `<stem>.codes.json` — every code mapped to whether it has children.
The server's code validator needs that and cannot derive it from the corpus,
because the corpus holds leaves only: telling *"you stopped one level short"*
from *"that code does not exist"* requires seeing internal nodes.

### Why not `build_hts_minimal.py`

That script (still present, still producing the legacy CSV) had three defects in
its tree reconstruction, all fixed here. Measured on US rev 12, **9,477 of
19,949 breadcrumbs — 47% — were factually wrong**:

1. **Condition rows did not own their indent level**, so the next deeper row
   parented to the previous *coded* row. `0103.91.00` ("Weighing less than 50 kg
   each") attached under `0103.10.00.00` ("Purebred breeding animals") — stating
   a code *is* what it explicitly is not — and made `0103.10.00.00` a non-leaf.
   **1,842 leaf codes were lost this way.**
2. **Stale conditions leaked past the end of their group.** `0101.30.00.00`
   ("Asses") and `0101.90` ("Other") both inherited `"Horses:"`.
3. **Only the shallowest condition in a nested chain was kept.**
   `3004.90.92.06` retained `"Other:"` while `"Anti-infective medicaments:"` and
   `"Antivirals:"` were dropped — collapsing 20 distinct medicament baskets into
   one indistinguishable record.

It also emitted only 10-digit codes, dropping **3,453 US codes that are terminal
at 8 digits**. Those are legitimate final classification targets, so their
retrieval recall was structurally zero.

### CBSA differences

`--source-format cbsa` normalises the Canadian export into the same row shape,
so both jurisdictions run through **one** tree implementation — three
independent copies is how the defects above survived.

| CBSA | Handling |
|---|---|
| No `Indent` column | Derived from **ancestor count** |
| `DESC2`/`DESC3` | Continuations of `DESC1`, not hierarchy (2 rows use them) |
| Grouping rows carry codes (`0101.2 Horses:`) | Ordinary breadcrumb levels; 1,924 of them |
| One exact duplicate | First occurrence wins |

**Ancestor count, not code length**, is the load-bearing choice. 353 Canadian
codes have no ancestor in the file — Ch.99 provisions like `9903.00.00` whose
4-digit heading row does not exist. A fixed length→indent map puts those at
indent 4 with nothing above, so the tree walk adopts whatever unrelated node last
occupied a shallower level. That produced a dozen Ch.99 provisions all
inheriting one arbitrary sibling's 52,000-character description.

---

## Files

| | |
|---|---|
| `build_hts_corpus.py` | Corpus + node index. `--source-format usitc\|cbsa` |
| `pinecone_sync.py` | `list` · `upsert` · `verify` · `delete` · `swap` |
| `refresh_ca.sh` | Canada, end to end |
| `run_locally.sh` | US, end to end (mirrors the workflow) |
| `supabase_insert_revision.py` | `hts_revisions` row + `--promote-country-pointer` |
| `update_env_vars.py` | `VITE_HTS_REVISION_*` on Railway + Vercel, with `revert` |
| `sail_gtx_commit.py` | Cross-repo dataset commit, `--prune-keep` |
| `smoke_test.py` | health · canary classify · Supabase row · **corpus queries** |
| `build_hts_minimal.py` | Legacy CSV. Tree fixes applied; superseded for retrieval |
| `legacy/build_canada_tphs_artifacts_v4.py` | Vendored. Still builds book/records/table artifacts |

## Operational limits

- **Embedding: 250k tokens/min.** The US corpus is ~2.3M tokens, so a cold load
  is inherently a ~10-minute job. `pinecone_sync.py` paces itself; unpaced it
  dies around record 3,800.
- **Rerank requests are metered per month.** Relevant to the eval harness in the
  app repo, not to these scripts.
- Namespaces are `{jurisdiction}__{revision}`. `swap` keeps the previous one by
  default so rollback has a target.

## Rollback

```sql
UPDATE hts_revisions SET pinecone_namespace = NULL
 WHERE country_code = 'US' AND revision_year = 2026 AND revision_number = 13;
```

Resolution falls back to `supported_countries.pinecone_namespace` (last known
good). No deploy, no re-upload. Env vars roll back separately from the snapshot
`update_env_vars.py` writes.


## United Kingdom & Northern Ireland

**United Kingdom (GB)** — landed 2026-09-01 (tracker 672227a9, sail-gtx d27f1ed).

- **Corpus**: the DBT Data API commodities report converts into the existing
  TARIC canonical format (the UK tariff is TARIC-descended), so the whole
  corpus/Explorer/chapters machinery is reused — 25,846 nodes, 16,726 leaves
  matching the declarable universe exactly, hierarchy built from parent__sid
  chains (never code length), verified by reconcile_sources with zero
  discrepancies.
- **The daily-version problem**: UK versions bump near-daily (v4.0.1590 →
  1591 in one day) but mostly change measures. The nightly gate is
  two-stage — it hashes the classification-relevant fields and only
  republishes Pinecone when the nomenclature changed; otherwise it runs a
  rates-only refresh that reships just the duty artifacts under the standing
  revision. Duty data stays day-fresh without namespace churn, and the
  treatments coverage as-of line carries the exact dataset version.
- **Duty engine**: 86,454 records from measures-as-defined + ancestor-walk,
  geographic membership from the official trade-tariff service API, all 72
  measure types inventoried (unknown ones surface as informational, never
  dropped), VAT 20% as the flat-tax overlay line. Both hard gates pass live:
  97.8% UKGT leaf coverage (the rest is genuinely TCD-free in the dataset)
  and a 25,919-pair reconciliation against the UK's own 1.1M-row leaf
  expansion with 0.00% misses.

**Northern Ireland (XI)** — its own schedule, exactly as HMG hosts it. The
NI Online Tariff applies the EU's TARIC baseline under the Windsor
Framework, so XI reuses the eu_taric adapter wholesale (same CIRCABC
release; identity/paths via spec options). Its coverage block explains the
two lanes: 'at risk' goods pay these EU-aligned rates; 'not at risk' UKIMS
goods pay the GB rate.

**The customs territory**: GB coverage declares applies_in = [GG, IM, JE,
XI] — England/Scotland/Wales plus the Crown Dependencies customs union,
with NI legally inside but dual-system for inbound goods. The consumer app
shows the UK as an umbrella (home nations as ISO 3166-2 rows GB-ENG/GB-SCT/
GB-WLS normalizing to GB on selection; IM/GG/JE remapped to GB) beside a
separate Northern Ireland row. GB prompts speak pure UK-tariff vocabulary
(Commodity Code, TCTA 2018, ATaR/HMRC); XI keeps TARIC vocabulary framed
for NI.


## South Korea (KR)

KCS datasets on data.go.kr: hierarchy 15130660 (5 level-sheets, KO+EN at
every level, real 5/7/9-digit intermediates — parents are the longest
existing shorter prefix, never digit arithmetic) + HS master 15049722
(active-validity filter, units) for classification; rates 15051179 for
duties. The portal's JS download flow (page → uddi →
selectFileDataDownload.do → fileDownload.do, captcha-gated check-limit
first) is implemented in acquire/kr_kcs.py; revision discovery polls the
/catalog/{id}/fileData.json metadata (dated alternateName + dateModified)
with the three-outcome gate: classification files changed → full rollout
(rev = {year}_rev_{MMDD}); rates only → rates_only refresh; else skip. The
Korean corpus publishes to kr__{rev}_ko beside the English default, and
the Explorer ships an EN/KO switcher with bilingual chapters (Korean HS
section titles curated in hs_sections.ko.json).

Duty engine: every rate row is declared at 10-digit HSK (inherit "exact");
config/kr_rate_classes.json maps the 224 observed rate classes onto the
official UNI-PASS 세율적용 우선순위 (captured 2026-09-02): the served
erga_omnes is the computed applied rate (B beats A; C-family applies when
lower), FTA schedules are conditional preferences per class, tier-1
specials (anti-dumping etc.) are informational with their additive nature
flagged, quotas conditional, unknown classes trip a loud informational
fallback. Specific components (₩ unit tax, base price) stay verbatim.

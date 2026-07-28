# HTS revision rollout

Detects new tariff revisions, builds the retrieval corpus that SAIL GTX
classification searches, publishes it to Pinecone, and points the app at it —
with a smoke test and rollback at the end.

Two jurisdictions, two triggers:

| | US | Canada |
|---|---|---|
| Discovery | automatic — `hts-revision-update.yml`, daily | manual — CBSA has no feed |
| Source | USITC CSV, re-downloaded each run | committed CBSA export |
| Rollout | 9-step workflow | `refresh_ca.sh`, one command |

---

## US — automatic

`.github/workflows/hts-revision-update.yml`, cron `0 6,7 * * *` (2 AM local in
both DST regimes; the gate exits clean when nothing changed, so the redundant
run costs seconds). `run_locally.sh` mirrors it step for step.

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
`SUPABASE_SERVICE_ROLE_KEY`, `RAILWAY_*`, `VERCEL_*`, `SAIL_GTX_REPO_PAT`.
(`RAGIE_API_KEY` is no longer referenced and can be deleted.)

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

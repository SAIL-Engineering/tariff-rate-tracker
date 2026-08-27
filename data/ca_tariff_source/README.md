# Canadian Customs Tariff — source

`ca_tariff_2026_rev_1.csv` is the CBSA tariff export — specifically an
`mdb-export` of the `TPHS` table from CBSA's Microsoft Access distribution of
the Customs Tariff (the "Microsoft Access format" zip linked from
https://www.cbsa-asfc.gc.ca/trade-commerce/tariff-tarif/menu-eng.html).
**It is committed, unlike the USITC CSVs in `data/hts_archives_csv/` which are
gitignored.** Committing it keeps the corpus rebuildable offline and pins the
exact bytes a revision was built from, but the file IS re-derivable: CBSA
publishes a machine-readable `.accdb` per revision (an earlier version of this
README claimed PDF/HTML only — that was wrong), and the `cbsa` acquisition
adapter downloads and re-exports it automatically.

## Refreshing Canada — two steps

1. Drop the new CBSA export here, named `ca_tariff_<year>_rev_<n>.csv`.
2. Run:

```bash
scripts/hts_automation/refresh_ca.sh --effective-date 2026-08-01
```

That is all. The script picks up the newest `ca_tariff_*.csv`, derives the
revision from its filename, builds the corpus, uploads it to a NEW namespace
beside the live one, verifies it with golden queries, and only then points
Supabase at it. If the upload or verification fails, Supabase is never touched
and the previous corpus keeps serving.

Useful flags: `--dry-run` (build and report, write nothing), `--csv <path>`,
`--revision 2026_rev_2`, `--keep N` (how many CA namespaces to retain, default 2
so a rollback has a target).

Rollback is one statement — the revision row falls back to the last-known-good
pointer on `supported_countries`:

```sql
UPDATE hts_revisions SET pinecone_namespace = NULL
 WHERE country_code = 'CA' AND revision_year = 2026 AND revision_number = 2;
```

<details><summary>Equivalent manual steps</summary>

```bash
python3 scripts/hts_automation/build_hts_corpus.py \
    data/ca_tariff_source/ca_tariff_2026_rev_1.csv \
    scripts/hts_automation/chapters_ca.json ca_2026_rev_1 \
    --jurisdiction CA --revision 2026_rev_1 --max-depth 10 --source-format cbsa
python3 scripts/hts_automation/pinecone_sync.py swap \
    --jsonl ca_2026_rev_1.jsonl --namespace ca__2026_rev_1
```
</details>

Current build: **11,040 leaf records** (1 at 4 digits, 67 at 8, 10,972 at 10),
2,689 basket provisions, 3 chunk_text and 9 display_text values truncated.

## Why `--source-format cbsa` rather than the v4 script

`scripts/hts_automation/legacy/build_canada_tphs_artifacts_v4.py` (vendored, was
previously outside version control) still builds the book/records/table
artifacts, but it is no longer used for the retrieval corpus. Its minimal output
was 10,972 records — 10-digit only — and it dropped the colon-terminated
grouping rows. See the header of that file for the full list of defects.

The CBSA format differs from USITC in four ways, all handled inside
`load_rows_cbsa()`:

| CBSA | Handling |
|---|---|
| No `Indent` column | Indent derived from **ancestor count**, not code length |
| `DESC2`/`DESC3` | Continuations of `DESC1`, not hierarchy levels (only 2 rows use them) |
| Grouping rows carry codes (`0101.2 Horses:`) | Become ordinary breadcrumb levels; 1,924 of them |
| One exact duplicate (`5206.41.00.00`) | First occurrence wins |

**Ancestor count, not code length**, is the load-bearing choice. 353 Canadian
codes have no ancestor present in the file — Chapter 99 provisions like
`9903.00.00` whose 4-digit heading row does not exist. A fixed length→indent map
puts those at indent 4 with nothing above them, so the tree walk adopts whatever
unrelated node last occupied a shallower level. That produced a dozen Chapter 99
provisions all inheriting one arbitrary sibling's 50,000-character description.
Counting ancestors makes an orphan a root, which is correct by construction.

## Revisions

`refresh_ca.sh` handles the bump; see above. New editions are discovered by
the `cbsa` acquisition adapter, which parses the CBSA tariff page headings
(`T2026`, `T2026-1`, ...) on both the English and French pages, downloads the
Access distribution, and exports `TPHS` to this directory. If the scrape ever
breaks, dropping the export here by hand (the old manual flow) still works —
that is the `manual` acquisition adapter.

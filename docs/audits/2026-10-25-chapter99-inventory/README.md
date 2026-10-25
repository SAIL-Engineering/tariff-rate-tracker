# Chapter 99 source census and executable-rule reconciliation

Tracker base `c0320c90`, original `wjr_dev` checkout. No timeseries/revision build,
production write, push, release activation or workflow change is part of this work.

The new census indexes every numbered Chapter 99 provision in the PDF/JSON pair,
including structural parents and provisions without a numeric General rate. It
also retains note-only references and original-source rule headings absent from
the snapshot. Conflicting duplicates, missing PDF corroboration, revision mismatch,
changed evidence and unsupported identities fail. Authority is never inferred from
the reporting-code range, a maximum rate or an absent source row.

Each provision preserves its raw description/record, inherited duty expression
and supplying parent, exact note locators/hashes, snapshot-status evidence, linked
action/rule definitions and legal intervals, and precise unresolved questions.
Full note text and its references are normalized once. References are explicitly
discovery aids: a product mentioned somewhere in a long note is not thereby in
every heading's scope. Exact HTS10 references are not truncated to HTS8.

The source-only census covers the **55 configured revisions**, with **182,851
native revision/provision records** and **183,933 records including references**.
These are snapshot observations, not unique legal actions or certified duty
calculations. The source-only pass supplies no executable fragments and therefore
grants no legal coverage. Its hashes/counts are retained in `source-summary.json`;
full reproducible exports remain under `output/chapter99-census-20261025-release`.

The normal emitter links only fragments written during that invocation. It does
not scan an old output directory and silently incorporate stale rule files. Links
preserve predicates, formulas, exact scope, sources and declared uncompiled paths.
An explicit FTZ or other `unresolved_source` expression retains its rule ID and
specific question. A linked rule remains partial coverage; an expired provision
in a snapshot does not acquire an inferred historical legal window.

New normal-build outputs:

- `chapter99_provisions.parquet`: typed provision identities, raw expressions,
  source hashes, statuses, conditions/rule links and unresolved questions.
- `chapter99_notes.parquet`: revision-bound full note text, locators, hashes and
  exact discovery references, joined through provision note IDs.
- `chapter99_inventory_sources.json`: compiler/input hashes, fragment fingerprints,
  source versions/counts and deliberately empty coverage declarations.

These outputs accompany the existing normalized tables. MotherDuck migrations,
automatic production-bundle assembly and serving integration remain Task 4. This
change does not assert that the existing wide rates originate in the shipment
evaluator. Aggregate calculations are unchanged.

Verification includes absent/unknown provisions, parent expressions, expiry versus
cross-reference, exact HTS10, conditional rule links, duplicate/order invariance,
unverified evidence, relative evidence paths, missing artifacts/source mutation,
explicit executable gaps, actual revision 21 inventory, and typed Parquet output
linked to the original reciprocal rules. The bounded normal-calculator regression
also verifies the inventory is emitted with the existing corrected rates. It is
a small temporary fixture, not a full revision build.

Reproduce independently of WJR's later timeseries build:

```sh
python3 scripts/audit_chapter99_inventory.py output/NEW_CHAPTER99_CENSUS
python3 -m pytest -q tests/python/test_chapter99_inventory.py
Rscript tests/test_chapter99_inventory.R
Rscript tests/test_reciprocal_pipeline.R
```

Pass `--normalized-dir NORMALIZED_DIRECTORY` to the source audit to reconcile an
identified existing set of emitted fragments. Partial output directories remain
partial evidence and cannot attest a complete release.

The census does not finish the legal interpretation of every provision. It makes
those obligations and existing compiler gaps inspectable. The next work uses it
to reconcile Section 232 sector rules and later reciprocal amendments, including
changed note 39 cross-program references and source-defined entry windows. Existing
missing normalized artifacts/TPC input remain release gates; tests cannot waive
them or use aggregate values as a legal oracle.

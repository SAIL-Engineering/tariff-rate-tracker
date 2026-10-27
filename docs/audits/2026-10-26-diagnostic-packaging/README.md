# Diagnostic snapshot packaging repair

Base `af861f1a`, original tracker `wjr_dev`. No push, production write or revision
rebuild was performed. This repairs the launcher supplied to WJR, not tariff law.

The first manual run failed inside `section232_autos.load_history()` because the
frozen copy lacked the original automobile proclamation PDF. The launcher's Git
archive selected `src` and `resources` but excluded `docs/audits`. Several runtime
legal compilers read pinned original documents and source metadata there. The
existing shipment dataset context does not inventory that directory, so its
successful dataset check did not prove the snapshot was complete. Copying just
the named PDF would also leave other required source artifacts missing.

The launcher now archives the committed audit directory and independently checks
every selected file against the Git tree. Its source manifest retains the full
file inventory, content SHA256s and aggregate archive identity. It verifies the
inventory before R starts, on snapshot reuse and after the build. Missing or
changed evidence fails before calculation. Credentials are excluded. Preparation
renames the snapshot directory only after all checks and its manifest succeed.

The source-package contract is v2. The default directory has a `-v2` suffix, so
the corrected command preserves the original incomplete snapshot and failed run
logs. Explicit attempts to reuse an old-format snapshot are rejected. Output
directories remain fresh per invocation. The command in
[DIAGNOSTICS.md](../2026-10-26-indexed-release/DIAGNOSTICS.md) is unchanged.

## Verification

Three reproductions failed on the original launcher: the committed evidence was
absent; missing evidence was accepted until the R build started; changed audit
evidence reused the old dataset pin. The corrected seven launcher regressions
pass, including legacy-package rejection and failed-preparation cleanup. The
complete Python suite passes436tests. Logs are retained alongside this report.

A real replacement for commit `a653c4aa7b9b4cbab9854dc00351b6a3ab4746ba` was
prepared at `/tmp/wjr-shipment-source-a653c4aa7b9b-v2`. Its1877 committed files
include1032 audit files. Its dataset identity remains the original
`shipment-b4ae89c48dee580516de9dadb3268f4f043a9638975d0419413895babee55a32`;
the separate source-archive identity covers the formerly omitted evidence.
The snapshot's original code and legal rates were not patched.

From that copy, the actual automobile source compiler passes for both diagnostic
revisions, using each revision's ten valid cohort products and eight origins.
Each emits886 rules and verifies16 source artifacts. These are source-compilation
checks, not rates/revision builds or legal coverage attestations. The full Git
inventory and dataset-context reuse check also pass after compilation. WJR still
runs the manual cohort calculation, artifact manifest and local DuckDB stages.

The source package is an independent reproducibility check; this repair does not
expand the ordinary production dataset-context directory inventory or certify
the broader legal-action coverage. No missing source is replaced by an aggregate
rate, a guessed heading or a zero. The original fail-closed compiler remains.

# Two-revision diagnostic delivery repair

WJR's build at `/tmp/wjr-shipment-diagnostic-20261027T200526498973Z`
finished both revisions (88 cells each) at source `2738d79f`. Preparation then
rejected their schemas before any release activation. All required fields and
shared-name types match. The full-schema equality check rejected 38 additional
2026 fields; the positional UNION would also have been unsafe for reordered
columns. The recorded inventory includes every table and exact type difference.

The loader now checks each physical file's required fields before unioning,
rejects conflicting shared types, and loads optional columns by name with NULL
for absence. It retains exact source bytes. The report records optional schema
differences and legacy aliases. It does not silently repair old product metadata.

The 2026 empty-grid seed had source-tier placeholders before Step 9b's product
join, causing `.x`/`.y` aliases and default canonical tier values. Step 9b now
replaces only source-owned fields before that join. The actual six-cell R
regression verifies source-tier equality, sourced USMCA eligibility, no aliases,
and declared-rule partition parity. These corrections apply to future builds;
no old Parquet is rewritten or relabeled with the corrected source version.

The launcher streams elapsed subprocess activity and ten-second quiet-period
heartbeats. Finite stage/schema/reconciliation/table counts render progress bars.
R revision completion markers support future builds. Machine JSON reports are
separate from human logs. `--resume` verifies the old completed inventory and
original byte pins before creating fresh recovery files. Build and delivery
commits/archives are independently frozen and reported. Resume never invokes the
R revision builder. See [the single-command instructions](../2026-10-26-indexed-release/DIAGNOSTICS.md).

## Verification before the source checkpoint

- 441 Python tests pass, including live output/heartbeats before child exit,
  structured progress rendering, immutable resume metadata and version guards.
- 687 Node tests pass, including optional and reordered partition columns,
  rejection of missing required physical fields, shared type conflicts, bad
  memberships, changed hashes, wrong catalogs and diagnostic activation guards.
- 151 R rate tests pass. The actual-source six-cell point-calculator/partition
  regression passes after first failing on the product metadata aliases.
- Red/green evidence and schema inventory are retained alongside this file.
- A read-only preflight of WJR's actual two-revision artifacts is in progress at
  this checkpoint. Final recovery evidence will be recorded separately after
  preparing a fresh local DuckDB with committed delivery tooling.

This is an artifact-delivery repair, not complete legal coverage. The §201
staged-schedule warning, parsing warnings and inactive IEEPA denormalized-slot
warning remain visible. This run does not qualify aggregate methodology or the
complete R gate, and does not resolve the broader unfinished legal inventory.
No MotherDuck writes, publication, workflow changes, activation or revision
rebuilds were performed by Codex.

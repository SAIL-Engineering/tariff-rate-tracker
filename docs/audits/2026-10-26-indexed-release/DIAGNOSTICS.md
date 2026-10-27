# WJR-run diagnostic builds and local DuckDB checks

## Start here: one command

From any directory, run:

```bash
python3 /home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_tariff-rate-tracker/tariff-rate-tracker/scripts/run_shipment_diagnostic.py --ref a653c4aa
```

This builds only the small cohort for **2025 revision11 and2026 revision19**,
then creates and validates a local DuckDB diagnostic. The launcher freezes
committed code and independently copies its primary inputs, so ongoing edits in
the main checkout cannot affect the run. It prints the result path when finished
and preserves full logs. It neither publishes nor connects to MotherDuck.
Installed Node/R dependencies are reused; no credentials are copied.

The corrected launcher uses `/tmp/wjr-shipment-source-a653c4aa7b9b-v2`. It includes
the committed audit evidence used by the legal compilers and checks every
archived file against the selected Git commit before starting R and after the
build. The original unversioned copy omitted that evidence; its dataset-only
check did not detect the omission. It and the failed run logs are preserved.
Rerun the same command above; no cleanup or extra commands are needed.

This still pins the original a653c4aa diagnostic baseline, independently of later
legal-rule commits. Codex prepares and checks the sources; WJR executes the
revision build. The commands below are for expanded investigations after this
first run; they are not required to start.

## Expanded investigation

Use **2025 and 2026**, beginning with a small cohort rather than rebuilding both
complete years. The first pass below selects eight revisions and eight origins.
These are diagnostic cases; they do not enter production scope/rate definitions.

Run from the tracker repository on its committed `wjr_dev` checkpoint. Keep the
code/source inputs fixed while it runs. The driver checks the content-addressed
input version after each revision and rejects a mixed build. These commands have
not been executed as revision builds by Codex; only their plan/guards and bounded
normal-calculator fixtures were exercised.

```bash
export PATH=/home/wijreid/.nvm/versions/node/v22.22.3/bin:$PATH
DIAG=/tmp/wjr-shipment-diagnostic-20261026

# Read-only plan: creates no output directory.
Rscript scripts/build_shipment_diagnostics.R \
  --revisions=2025_rev_11,2025_rev_17,2025_rev_26,2026_rev_4,2026_rev_5,2026_rev_19,2026_rev_20,2026_rev_21 \
  --countries=2010,1220,5700,4120,4280,5880,5800,5830 \
  --cohort --output="$DIAG" --plan

# WJR runs this manually; the destination must not already exist.
Rscript scripts/build_shipment_diagnostics.R \
  --revisions=2025_rev_11,2025_rev_17,2025_rev_26,2026_rev_4,2026_rev_5,2026_rev_19,2026_rev_20,2026_rev_21 \
  --countries=2010,1220,5700,4120,4280,5880,5800,5830 \
  --cohort --output="$DIAG"

node frontend/scripts/create-shipment-release-manifest.mjs \
  --normalized "$DIAG/normalized" --rates "$DIAG/rates" \
  --revisions 2025_rev_11,2025_rev_17,2025_rev_26,2026_rev_4,2026_rev_5,2026_rev_19,2026_rev_20,2026_rev_21 \
  --mode diagnostic --output "$DIAG/release.json"

node frontend/scripts/prepare-shipment-release.mjs \
  --manifest "$DIAG/release.json" --database "$DIAG/diagnostic.duckdb" \
  > "$DIAG/prepare.json"

# Recheck the same artifacts and catalog without preparing anything again.
node frontend/scripts/prepare-shipment-release.mjs \
  --manifest "$DIAG/release.json" --database "$DIAG/diagnostic.duckdb" --preflight \
  > "$DIAG/preflight.json"
```

The eight origins are Mexico, Canada, China, UK, Germany, Japan, Korea and Taiwan.
The selection exercises May 2025 parts activation, August country changes,
November treatment, §122, April metals, September amendments and revisions 20/21.
The driver uses the ordinary `calculate_revision_legal_states()` path, retains
normal aggregate inputs, and caps the diagnostic horizon at October 22, 2026.
It never combines canonical snapshots, publishes files, connects to MotherDuck,
or switches an active release. Codes absent from a selected native inventory are
listed in `diagnostic-build.json`; absence is not a zero-duty observation.

For a quicker first smoke run, select only `2025_rev_11,2026_rev_19` consistently
in both commands. After the cohort passes, use a **new output directory** and
omit `--cohort` to test complete native product inventories. Omitting
`--countries` includes the complete configured Census roster. Earlier boundary
coverage should additionally include `2025_basic`, `2025_rev_4`–`2025_rev_10`,
`2026_rev_1`, `2026_rev_2`, `2026_rev_9`, `2026_rev_13` and `2026_rev_17`.
These checks complement, rather than qualify, the final full rebuild.

## Query a staged diagnostic without activation

```bash
cat > "$DIAG/request.json" <<'JSON'
{
  "hts10": "8703230190",
  "country": "2010",
  "entry_at": "2025-05-03T12:00:00-04:00",
  "facts": {
    "customs_value": 100,
    "ieepa_ftz_entry": false,
    "s232_auto_passenger_vehicle": true,
    "s232_auto_manufacture_year": 2020,
    "s232_auto_usmca_eligible": false
  }
}
JSON

node frontend/scripts/resolve-prepared-shipment.mjs \
  --database "$DIAG/diagnostic.duckdb" \
  --release "$(jq -r .release_id "$DIAG/prepare.json")" \
  --request "$DIAG/request.json" > "$DIAG/result.json"
```

Inspect action amounts/reporting codes, suppressed rules, sources, missing inputs
and source errors. A complete total is currently expected to remain unavailable
where another authority is not reconciled. For this declared auto use, the
additional auto component on USD100 is USD25, not an assembly-credit-adjusted
percentage. This is a targeted component assertion, not an accepted complete
stack. Add only facts relevant to returned matched rules; do not fill all
booleans with false to force a total.

The preparation report must say `consistent_with_declared_rules` for each
partition. It checks every emitted row/class/membership, exact-time tiling and
the direct R reference. That establishes artifact consistency, not complete law,
all possible fact combinations or aggregate reproduction. Retain the report,
input version, missing-code list and any failure, including source questions.

## Release and rollback boundaries

Diagnostic releases are `prepared_diagnostic`; neither the activation function
nor the active reader accepts them, even if a registry status is manually changed.
They can be removed by deleting the isolated local diagnostic directory after
closing readers. No existing release needs rollback.

Production preparation requires all configured 2025/2026 revisions, full native
product/origin inventories and an independently validated Trade Intelligence
snapshot pin. It stages a new immutable schema as `prepared`, never `validated`
or active. The new migration changes no active pointer. Existing releases remain
available; a later approved activation uses an expected-current identifier and
retains `previous_release_id` for rollback. Cloud loading, activation, application
deployment and the legacy aggregate reader transition still need their separate
approved qualification. Do not use the old wide-table push script as the v8
shipment release publisher.

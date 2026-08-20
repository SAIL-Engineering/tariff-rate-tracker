#!/usr/bin/env bash
# =============================================================================
# run_locally.sh — end-to-end HTS revision rollout from your laptop.
#
# Mirrors the GitHub Actions workflow (.github/workflows/hts-revision-update.yml)
# but runs every step locally so you can:
#   * dogfood the pipeline before wiring up the Actions secrets
#   * keep a manual fallback when the workflow is paused or you need to
#     re-run a specific revision out of band
#
# Setup (one-time):
#   1. cp scripts/hts_automation/.env.hts_automation.example \
#         scripts/hts_automation/.env.hts_automation
#   2. Fill in real values (the .env.hts_automation file is gitignored).
#   3. Make sure `Rscript` and `python3` are on $PATH; install Python deps:
#         pip install -r scripts/hts_automation/requirements.txt
#
# Usage:
#   scripts/hts_automation/run_locally.sh                        # latest revision
#   scripts/hts_automation/run_locally.sh --revision 2026_rev_8  # specific revision
#   scripts/hts_automation/run_locally.sh --dry-run              # no external writes
#   scripts/hts_automation/run_locally.sh --skip-classify        # skip canary classify
#   scripts/hts_automation/run_locally.sh --skip-scrape          # skip 01_scrape (use existing CSV)
#   scripts/hts_automation/run_locally.sh --from-step 8          # resume a broken run at step 8
#
# --from-step N skips the mutating steps below N so a run that died mid-way can
# be resumed without redoing completed work (e.g. the Pinecone upsert, which
# refuses to run twice into the same namespace anyway). Step 2 (resolve) always
# runs — it is read-only and every later step needs the revision it resolves.
# Artifacts that skipped steps would have produced (downloads, corpus files)
# must still exist from the earlier run; the script verifies this up front.
#
# Exit codes:
#   0  success (or no-op — no new revision detected)
#   1  config / argument error
#   >1 a pipeline step failed; the env-var snapshot at
#      /tmp/hts-env-snapshot.json (if it exists) can be replayed with
#      `update_env_vars.py revert --snapshot /tmp/hts-env-snapshot.json`.
# =============================================================================

set -euo pipefail

# ─── Path bootstrapping ──────────────────────────────────────────────
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="$HERE/.env.hts_automation"
SNAPSHOT_FILE="${HTS_ENV_SNAPSHOT_PATH:-/tmp/hts-env-snapshot.json}"

# ─── Args ────────────────────────────────────────────────────────────
REVISION_OVERRIDE=""
DRY_RUN="false"
SKIP_CLASSIFY="true"   # default true: most users won't have SAIL_GTX_API_AUTH_TOKEN
SKIP_SCRAPE="false"
FROM_STEP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --revision)        REVISION_OVERRIDE="$2"; shift 2 ;;
    --dry-run)         DRY_RUN="true"; shift ;;
    --skip-classify)   SKIP_CLASSIFY="true"; shift ;;
    --run-classify)    SKIP_CLASSIFY="false"; shift ;;
    --skip-scrape)     SKIP_SCRAPE="true"; shift ;;
    --from-step)       FROM_STEP="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,48p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if ! [[ "$FROM_STEP" =~ ^[1-9]$ ]]; then
  echo "ERROR: --from-step must be an integer 1-9, got '$FROM_STEP'" >&2
  exit 1
fi

# step_active N — true when step N should run under --from-step.
step_active() { (( $1 >= FROM_STEP )); }
skiplog()     { log "Step $1/9: $2 (skipped — resuming from step $FROM_STEP)"; }

# ─── Load env file ───────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  cat >&2 <<EOF
ERROR: $ENV_FILE not found.

Copy the template and fill in real values:
  cp scripts/hts_automation/.env.hts_automation.example \\
     scripts/hts_automation/.env.hts_automation
EOF
  exit 1
fi

# Export every KEY=VALUE line, skipping comments + blanks. Quoted values
# are preserved. This is the same shell pattern setup-deploy uses.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

require_env() {
  local name="$1"
  if [[ -z "${!name-}" ]]; then
    echo "ERROR: required env var $name is not set in $ENV_FILE" >&2
    exit 1
  fi
}

require_env PINECONE_API_KEY
require_env SUPABASE_URL
require_env SUPABASE_SERVICE_ROLE_KEY
require_env RAILWAY_TOKEN
require_env RAILWAY_PROJECT_ID
require_env RAILWAY_SERVICE_ID
require_env RAILWAY_ENVIRONMENT_ID
require_env VERCEL_TOKEN
require_env VERCEL_PROJECT_ID
require_env SAIL_GTX_REPO_PAT
require_env SAIL_GTX_PRODUCTION_BRANCH
require_env SAIL_GTX_HEALTHCHECK_URL
require_env SAIL_GTX_API_BASE

# ─── Helpers ─────────────────────────────────────────────────────────
log()    { printf '\n\033[1;36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
sublog() { printf '  %s\n' "$*"; }

PY="python3 $HERE"
RUN_PY()   { eval "python3 $HERE/$1.py ${@:2}"; }

# ─── Step 1: scrape USITC ────────────────────────────────────────────
if ! step_active 1; then
  skiplog 1 "scrape"
elif [[ "$SKIP_SCRAPE" == "true" ]]; then
  log "Step 1/9: scrape (skipped via --skip-scrape)"
else
  log "Step 1/9: scrape USITC + auto-clear needs_review"
  Rscript src/01_scrape_revision_dates.R --auto-clear-review
fi

# ─── Step 2: resolve target revision ─────────────────────────────────
log "Step 2/9: resolve target revision"
RESOLVE_ARGS=()
if [[ -n "$REVISION_OVERRIDE" ]]; then
  RESOLVE_ARGS=(--revision "$REVISION_OVERRIDE")
fi
RESOLVED="$(Rscript scripts/hts_automation/latest_revision.R "${RESOLVE_ARGS[@]}")"
echo "$RESOLVED"

# Pull each KEY=VALUE line into shell vars (REV_ID, YEAR, REV_NUM, EFFECTIVE_DATE, etc.)
while IFS='=' read -r key value; do
  case "$key" in
    REV_ID|YEAR|REV_NUM|EFFECTIVE_DATE|EFFECTIVE_DATE_LABEL|JSON_PATH|CSV_PATH)
      printf -v "$key" '%s' "$value"
      ;;
  esac
done <<< "$RESOLVED"

sublog "Resolved REV_ID=$REV_ID  EFFECTIVE_DATE=$EFFECTIVE_DATE  LABEL='$EFFECTIVE_DATE_LABEL'"

# Derived names later steps read. Computed unconditionally so a resumed run
# (--from-step) has them even when the producing step is skipped.
STEM="us_${YEAR}_rev_${REV_NUM}"
CORPUS_JSONL="${STEM}.jsonl"
# Node index for the server-side code validator. It ships in the SAME commit as
# the dataset (step 7) so the two can never describe different revisions.
CORPUS_CODES="${STEM}.codes.json"

# When resuming past a step, the files it would have produced must still exist
# from the earlier run — but only if a step we ARE going to run consumes them.
require_file() {
  test -f "$1" || {
    echo "ERROR: --from-step $FROM_STEP skips the step that produces $1," >&2
    echo "       which $2. Re-run without --from-step (or with a lower one)." >&2
    exit 1
  }
}
if (( FROM_STEP > 3 )); then
  (( FROM_STEP <= 4 )) && require_file "$CSV_PATH" "step 4 builds the corpus from"
  (( FROM_STEP <= 7 )) && require_file "$JSON_PATH" "step 7 commits cross-repo"
fi
if (( FROM_STEP > 4 )); then
  (( FROM_STEP <= 5 )) && require_file "$CORPUS_JSONL" "step 5 upserts to Pinecone"
  (( FROM_STEP <= 7 )) && require_file "$CORPUS_CODES" "step 7 ships beside the dataset"
fi

# ─── Step 3: download both archives ──────────────────────────────────
if ! step_active 3; then
  skiplog 3 "download"
else
  log "Step 3/9: download JSON + CSV for year $YEAR"
  Rscript src/02_download_hts.R --year "$YEAR"

  test -f "$JSON_PATH" || { echo "missing JSON: $JSON_PATH"; exit 2; }
  test -f "$CSV_PATH"  || { echo "missing CSV:  $CSV_PATH";  exit 2; }
  sublog "JSON: $JSON_PATH"
  sublog "CSV:  $CSV_PATH"
fi

# ─── Step 4: build the Ragie CSV ─────────────────────────────────────
if ! step_active 4; then
  skiplog 4 "build corpus"
else
  log "Step 4/9: build Pinecone corpus"
  python3 "$HERE/build_hts_corpus.py" "$CSV_PATH" "$HERE/chapters.json" "$STEM" \
    --jurisdiction US --revision "${YEAR}_rev_${REV_NUM}" --max-depth 10
  test -f "$CORPUS_JSONL" || { echo "missing built corpus: $CORPUS_JSONL"; exit 2; }
  test -f "$CORPUS_CODES" || { echo "missing node index: $CORPUS_CODES"; exit 2; }
  sublog "Built: $CORPUS_JSONL"
  sublog "Built: $CORPUS_CODES"
fi

# ─── Step 5: Pinecone namespace swap ─────────────────────────────────
# Replaces the retired Ragie swap. Each revision gets its OWN namespace rather
# than mutating one in place, so the new corpus is built alongside the live one
# and only becomes visible when step 6 points Supabase at it.
NAMESPACE="us__${YEAR}_rev_${REV_NUM}"
if ! step_active 5; then
  skiplog 5 "Pinecone swap"
elif [[ "$DRY_RUN" == "true" ]]; then
  log "Step 5/9: Pinecone swap (skipped — dry-run); namespace would be $NAMESPACE"
else
  log "Step 5/9: Pinecone namespace swap -> $NAMESPACE"
  python3 "$HERE/pinecone_sync.py" swap \
    --jsonl "$CORPUS_JSONL" \
    --namespace "$NAMESPACE"
fi

# ─── Step 6: Supabase upsert ─────────────────────────────────────────
if ! step_active 6; then
  skiplog 6 "Supabase upsert"
elif [[ "$DRY_RUN" == "true" ]]; then
  log "Step 6/9: Supabase upsert (skipped — dry-run)"
else
  log "Step 6/9: Supabase upsert"
  python3 "$HERE/supabase_insert_revision.py" \
    --country US \
    --year "$YEAR" \
    --rev-num "$REV_NUM" \
    --effective-date "$EFFECTIVE_DATE" \
    --effective-date-label "$EFFECTIVE_DATE_LABEL" \
    --tariff-schedule-name HTSUS \
    --ragie-partition-id us_hts_${YEAR}_latest \
    --pinecone-namespace "$NAMESPACE"
fi

# ─── Step 7: cross-repo commit (must precede env var update) ─────────
if ! step_active 7; then
  skiplog 7 "cross-repo commit"
else
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Step 7/9: cross-repo commit (dry-run mode)"
    DRY_FLAG=(--dry-run)
  else
    log "Step 7/9: cross-repo commit to $SAIL_GTX_PRODUCTION_BRANCH"
    DRY_FLAG=()
  fi
  # ONE destination as of 2026-07-27: server/data/hts/ is canonical.
  # public/data/hts-explorer/hts_*.json is gitignored and regenerated at build
  # time by vite/htsManifestPlugin.ts, which copies the latest revision across and
  # writes the manifest the SPA fetches. --prune-keep 3 bounds the directory: each
  # revision is ~13.5 MB, they land fortnightly, and both the SPA and the server
  # read exactly one revision at a time.
  python3 "$HERE/sail_gtx_commit.py" \
    --owner SAIL-Engineering \
    --repo sail-gtx-prerelease \
    --branch "$SAIL_GTX_PRODUCTION_BRANCH" \
    --source "$JSON_PATH" \
    --dest-path "server/data/hts/hts_${YEAR}_revision_${REV_NUM}.json" \
    --also "${CORPUS_CODES}:server/data/hts/us_${YEAR}_rev_${REV_NUM}.codes.json" \
    --prune-keep 3 \
    --tag-name "hts-${YEAR}-rev${REV_NUM}" \
    --commit-message "chore: HTS ${YEAR} Rev ${REV_NUM} dataset (effective ${EFFECTIVE_DATE})" \
    "${DRY_FLAG[@]}"
fi

# ─── Step 8: env var update ──────────────────────────────────────────
if ! step_active 8; then
  skiplog 8 "env vars"
elif [[ "$DRY_RUN" == "true" ]]; then
  log "Step 8/9: env vars (skipped — dry-run)"
else
  log "Step 8/9: Railway + Vercel env var update (snapshot → $SNAPSHOT_FILE)"
  python3 "$HERE/update_env_vars.py" set \
    --year "$YEAR" \
    --rev-num "$REV_NUM" \
    --effective-date-label "$EFFECTIVE_DATE_LABEL" \
    --snapshot-out "$SNAPSHOT_FILE"
fi

# ─── Step 9: smoke test ──────────────────────────────────────────────
SMOKE_ARGS=(--year "$YEAR" --rev-num "$REV_NUM")
if [[ "$SKIP_CLASSIFY" == "true" ]]; then
  SMOKE_ARGS+=(--skip-classify)
fi
if ! step_active 9; then
  skiplog 9 "smoke test"
elif [[ "$DRY_RUN" == "true" ]]; then
  log "Step 9/9: smoke test (skipped — dry-run)"
else
  log "Step 9/9: smoke test"
  if ! python3 "$HERE/smoke_test.py" "${SMOKE_ARGS[@]}"; then
    echo
    echo "Smoke test FAILED."
    if [[ -f "$SNAPSHOT_FILE" ]]; then
      echo "Rolling back env vars from snapshot..."
      python3 "$HERE/update_env_vars.py" revert --snapshot "$SNAPSHOT_FILE"
    else
      echo "No snapshot found at $SNAPSHOT_FILE — manual env var revert required."
    fi
    exit 9
  fi
fi

log "DONE — HTS ${YEAR} Rev ${REV_NUM} (effective ${EFFECTIVE_DATE}) rolled out."

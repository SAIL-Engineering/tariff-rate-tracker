#!/usr/bin/env bash
# =============================================================================
# run_locally.sh — US HTS revision rollout (wrapper).
#
# The pipeline now lives in refresh.py, driven by config/jurisdictions/us.json.
# This wrapper preserves the historical CLI exactly, including the old numeric
# --from-step values:
#   1 scrape / 2 resolve / 3 download  -> acquire   (resolve always runs)
#   4 build corpus                     -> build
#   5 Pinecone swap                    -> publish
#   6 Supabase upsert                  -> register
#   7 cross-repo commit                -> ship
#   8 env vars                         -> envvars
#   9 smoke test                       -> smoke
#
# Everything else passes straight through; see refresh.py --help.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from-step)
      case "$2" in
        1|2|3) ARGS+=(--from-step acquire) ;;
        4)     ARGS+=(--from-step build) ;;
        5)     ARGS+=(--from-step publish) ;;
        6)     ARGS+=(--from-step register) ;;
        7)     ARGS+=(--from-step ship) ;;
        8)     ARGS+=(--from-step envvars) ;;
        9)     ARGS+=(--from-step smoke) ;;
        *)     ARGS+=(--from-step "$2") ;;
      esac
      shift 2 ;;
    --skip-classify) shift ;;                      # the default; kept for compat
    *) ARGS+=("$1"); shift ;;
  esac
done

exec python3 "$HERE/refresh.py" --jurisdiction US "${ARGS[@]}"

#!/usr/bin/env bash
# =============================================================================
# refresh_ca.sh — Canadian Customs Tariff rollout (wrapper).
#
# The pipeline now lives in refresh.py, driven by config/jurisdictions/ca.json:
# acquire (CBSA download + TPHS export; or drop a CSV in data/ca_tariff_source/
# and use --acquire-adapter manual) -> build -> verify -> publish -> register
# -> ship (the ca_*.codes.json node index).
#
# Old flags map as: --csv PATH -> --acquire-adapter manual --source PATH.
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --csv)             ARGS+=(--acquire-adapter manual --source "$2"); shift 2 ;;
    --effective-label) shift 2 ;;                  # label derives from the date now
    *) ARGS+=("$1"); shift ;;
  esac
done

exec python3 "$HERE/refresh.py" --jurisdiction CA "${ARGS[@]}"

#!/usr/bin/env bash
# =============================================================================
# Fail if the committed frontend bundles have drifted from the YAML source.
# =============================================================================
# Regenerates the bundles, then checks whether the committed copies changed.
# If they did, the committed JSON was stale (someone edited a YAML without
# regenerating) — exit non-zero so CI / a pre-push hook blocks it.
#
# Covers BOTH repos when present:
#   * this repo's frontend/public/data/*.json   (always)
#   * the sail-gtx-prerelease constants/*.json   (if the sibling repo is found;
#     override its path with SAIL_GTX_REPO=/path/to/sail-gtx-prerelease)
#
# Local fix when this fails: scripts/emit_frontend_bundles.sh, then commit the
# regenerated JSON in BOTH repos. See docs/PROVENANCE_PIPELINE.md.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SAIL_GTX_REPO="${SAIL_GTX_REPO:-/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease/sail-gtx-prerelease}"

echo "Checking frontend bundles are in sync with config/*.yaml ..."
Rscript scripts/emit_duty_citations.R      >/dev/null
Rscript scripts/emit_legal_refs_json.R     >/dev/null
Rscript scripts/emit_program_symbols.R     >/dev/null
Rscript scripts/emit_program_countries.R   >/dev/null
Rscript scripts/emit_program_requirements.R >/dev/null

stale=0

if ! git diff --quiet -- frontend/public/data/duty_citations.json frontend/public/data/legal_refs.json frontend/public/data/program_symbols.json frontend/public/data/program_countries.json frontend/public/data/program_requirements.json; then
  echo "  STALE: frontend/public/data/*.json differ from the source (YAML / GN CSVs)."
  stale=1
fi

if [ -d "$SAIL_GTX_REPO/.git" ]; then
  sg_bundles="src/modules/tariff-rates/constants/dutyCitations.json src/modules/tariff-rates/constants/legalRefs.json src/modules/tariff-rates/constants/programSymbols.json src/modules/tariff-rates/constants/programCountries.json src/modules/tariff-rates/constants/programRequirements.json"
  if ! git -C "$SAIL_GTX_REPO" diff --quiet -- $sg_bundles; then
    echo "  STALE: sail-gtx-prerelease constants/*.json differ — commit them in that repo (Vercel reads them)."
    stale=1
  fi
else
  echo "  note: sail-gtx repo not found at SAIL_GTX_REPO — checked this repo's bundles only."
fi

if [ "$stale" -eq 0 ]; then
  echo "Bundles are fresh."
else
  echo
  echo "Fix: run scripts/emit_frontend_bundles.sh and commit the regenerated JSON in both repos."
  exit 1
fi

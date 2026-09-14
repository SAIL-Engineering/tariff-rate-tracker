#!/usr/bin/env bash
# =============================================================================
# Regenerate the frontend JSON bundles from the YAML source-of-truth.
# =============================================================================
# The frontend NEVER reads the YAML — it imports generated JSON bundles:
#   config/duty_citations.yaml  ─► constants/dutyCitations.json
#   config/legal_reference.yaml ─► constants/legalRefs.json
#   resources/ch99_legal_refs.csv ┘ (machine layer of legalRefs.json)
#
# Each generator writes to BOTH:
#   * frontend/public/data/*.json            (local duty explorer)
#   * <sail-gtx>/.../constants/*.json         (the Vercel app — source of truth
#                                              for production; MUST be committed
#                                              in that repo so Vercel picks it up)
#
# Override the sail-gtx location with SAIL_GTX_REPO=/path/to/sail-gtx-prerelease.
# Run after editing either YAML. See docs/PROVENANCE_PIPELINE.md.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Regenerating frontend bundles from config/*.yaml + resources/*.csv ..."
Rscript scripts/emit_duty_citations.R
Rscript scripts/emit_legal_refs_json.R
# Generated General Note 3 data (program symbol map + Column 2 list). Reads the
# committed resources/gn3_*.csv (refreshed by src/parse_general_note_3.R in the
# build). De-hardcodes the frontend program/Column-2 tables.
Rscript scripts/emit_program_symbols.R
# Generated beneficiary-country -> preference-program map (GSP/AGOA/CBERA), from
# resources/gn_program_countries.csv. De-hardcodes the frontend country membership
# table for list-based programs.
Rscript scripts/emit_program_countries.R
# Curated, GN-anchored eligibility requirements (the "missing facts" behind a
# suggested preference opportunity). Symbol keys validated against the GN3 map.
Rscript scripts/emit_program_requirements.R
echo
echo "Done. If the sail-gtx-prerelease constants/*.json changed, COMMIT them in"
echo "that repo so the Vercel deployment picks up the new legal/citation data."

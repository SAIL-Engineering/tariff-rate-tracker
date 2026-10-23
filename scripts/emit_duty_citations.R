#!/usr/bin/env Rscript
# =============================================================================
# Emit the frontend duty-citation registry (JSON) from the YAML source of truth
# =============================================================================
# config/duty_citations.yaml is the single source of legal provenance. The
# frontend bundles a JSON copy to resolve reason_codes -> legal text + narrative
# templates. Run this whenever the YAML registry changes:
#
#   Rscript scripts/emit_duty_citations.R
#
# Writes to the local prototype (frontend/public/data). Use --sail-dir PATH
# to explicitly select a SAIL checkout for the shared production module. Keeping the YAML authoritative + regenerating the
# JSON is the maintainable pattern (one edit point; no hand-synced duplicate).
# =============================================================================
suppressWarnings(suppressMessages({ library(yaml); library(jsonlite); library(here) }))

src <- here('config', 'duty_citations.yaml')
if (!file.exists(src)) stop('Missing registry: ', src)
reg <- yaml::read_yaml(src)
json <- jsonlite::toJSON(reg, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null')

args <- commandArgs(trailingOnly = TRUE)
targets <- here('frontend', 'public', 'data', 'duty_citations.json')
if (length(args)) {
  if (length(args) != 2 || args[1] != '--sail-dir') stop('Usage: emit_duty_citations.R [--sail-dir PATH]')
  sail_dir <- normalizePath(args[2], mustWork = TRUE)
  shared <- file.path(sail_dir, 'server', 'src', 'shared', 'duty', 'constants')
  if (!dir.exists(shared)) stop('SAIL shared duty module not found: ', shared)
  targets <- c(targets, file.path(shared, 'dutyCitations.json'))
}

for (t in targets) {
  d <- dirname(t)
  if (!dir.exists(d)) {
    ok <- dir.create(d, recursive = TRUE, showWarnings = FALSE)
    if (!ok) { cat('  skip (no dir):', t, '\n'); next }
  }
  writeLines(json, t)
  cat('  wrote:', t, '\n')
}
cat('Registry: ', length(reg$reasons), 'reasons,', length(reg$authorities), 'authorities\n')

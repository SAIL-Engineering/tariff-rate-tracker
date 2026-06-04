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
# Writes to the local prototype (frontend/public/data) AND, if present, the
# production frontend module. Keeping the YAML authoritative + regenerating the
# JSON is the maintainable pattern (one edit point; no hand-synced duplicate).
# =============================================================================
suppressWarnings(suppressMessages({ library(yaml); library(jsonlite); library(here) }))

src <- here('config', 'duty_citations.yaml')
if (!file.exists(src)) stop('Missing registry: ', src)
reg <- yaml::read_yaml(src)
json <- jsonlite::toJSON(reg, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null')

targets <- c(
  here('frontend', 'public', 'data', 'duty_citations.json'),
  file.path('/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
            'sail-gtx-prerelease/src/modules/tariff-rates/constants/dutyCitations.json')
)

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

#!/usr/bin/env Rscript
# =============================================================================
# Emit the frontend programRequirements bundle from config/program_requirements.yaml
# (curated, General-Note-anchored eligibility requirements). The opportunity model
# uses these as the "missing facts" behind a `suggested` preference; an importer's
# explicit assertion flips it to `applied`.
#
# GUARD: every `symbols` entry is validated against the generated
# resources/gn3_program_symbols.csv (latest revision) — an unknown symbol aborts,
# so a requirement set can't reference an invented/typo'd program.
#   Rscript scripts/emit_program_requirements.R
# =============================================================================
suppressWarnings(suppressMessages({ library(yaml); library(readr); library(dplyr); library(jsonlite); library(here) }))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

yaml_path <- here('config', 'program_requirements.yaml')
if (!file.exists(yaml_path)) stop('Missing ', yaml_path)
cfg <- yaml::read_yaml(yaml_path)

# Known symbols = latest revision of the generated GN3 symbol map.
sym_csv <- here('resources', 'gn3_program_symbols.csv')
known_symbols <- character()
if (file.exists(sym_csv)) {
  sym <- suppressMessages(read_csv(sym_csv, show_col_types = FALSE))
  rd  <- suppressMessages(read_csv(here('config', 'revision_dates.csv'), show_col_types = FALSE))
  ord <- if ('effective_date' %in% names(rd)) rd$revision[order(rd$effective_date)] else rd$revision
  latest <- tail(intersect(ord, unique(sym$revision)), 1)
  known_symbols <- unique(sym$symbol[sym$revision == latest])
} else {
  message('WARNING: ', sym_csv, ' not found — skipping symbol validation')
}

# Validate every declared symbol exists in the GN3 map (skip the _default_fta key).
bad <- character()
for (pk in names(cfg$programs)) {
  if (pk == '_default_fta') next
  syms <- cfg$programs[[pk]]$symbols %||% character()
  unknown <- setdiff(syms, known_symbols)
  if (length(known_symbols) > 0 && length(unknown) > 0)
    bad <- c(bad, sprintf('%s: unknown symbol(s) %s', pk, paste(unknown, collapse = ', ')))
}
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
if (length(bad) > 0)
  stop('program_requirements.yaml references symbols not in gn3_program_symbols.csv:\n  ',
       paste(bad, collapse = '\n  '))

# Build a symbol -> program-key index (so the frontend can look up requirements
# by the HTS Special symbol matched on a line).
by_symbol <- list()
for (pk in names(cfg$programs)) {
  for (s in (cfg$programs[[pk]]$symbols %||% character())) by_symbol[[s]] <- pk
}

out <- list(
  version = cfg$version %||% 1,
  source = 'config/program_requirements.yaml',
  note = 'Curated, General-Note-anchored eligibility requirements per preference program. Shown as the missing facts behind a SUGGESTED opportunity on top of the base-NTR/MFN default; SAIL never self-validates a claim. `_default_fta` is the fallback for FTAs without an explicit entry.',
  programs = cfg$programs,
  by_symbol = by_symbol
)
json <- toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null')

targets <- c(
  here('frontend', 'public', 'data', 'program_requirements.json'),
  file.path('/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
            'sail-gtx-prerelease/src/modules/tariff-rates/constants/programRequirements.json')
)
for (t in targets) {
  d <- dirname(t)
  if (dir.exists(d) || dir.create(d, recursive = TRUE, showWarnings = FALSE)) {
    writeLines(json, t); cat('  wrote:', t, '\n')
  } else cat('  skip (no dir):', t, '\n')
}
cat('programRequirements: ', length(cfg$programs) - ('_default_fta' %in% names(cfg$programs)),
    ' programs + default; ', length(by_symbol), ' symbols indexed; validated against ',
    length(known_symbols), ' known GN3 symbols\n', sep = '')

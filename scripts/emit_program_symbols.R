#!/usr/bin/env Rscript
# =============================================================================
# Emit the frontend programSymbols bundle from the GENERATED General Note 3 data
# (resources/gn3_program_symbols.csv + gn3_column2_countries.csv, produced by
# src/parse_general_note_3.R). This is what de-hardcodes the frontend's program
# symbol map + Column 2 country list — the values come from the HTS, not code.
#   Rscript scripts/emit_program_symbols.R   (run after parse_general_note_3.R)
# =============================================================================
suppressWarnings(suppressMessages({ library(readr); library(dplyr); library(jsonlite); library(here) }))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || (length(a) == 1 && is.na(a))) b else a
# Reuse the census matcher so the Column 2 list also carries census CODES (the
# frontend keys Column 2 detection by census code, not name). Sourcing only
# defines functions (the file's direct-run guard is gated on sys.nframe()).
suppressWarnings(suppressMessages(source(here('src', 'parse_general_note_3.R'))))

sym_csv  <- here('resources', 'gn3_program_symbols.csv')
col2_csv <- here('resources', 'gn3_column2_countries.csv')
if (!file.exists(sym_csv)) stop('Missing ', sym_csv, ' — run src/parse_general_note_3.R first')

sym  <- suppressMessages(read_csv(sym_csv, show_col_types = FALSE))
col2 <- if (file.exists(col2_csv)) suppressMessages(read_csv(col2_csv, show_col_types = FALSE)) else tibble()

# REVISION-AWARE: emit symbol/Column-2 maps per revision (GN 3 changes over time
# — Russia/Belarus entered Column 2 in 2022, Nepal NP added later). Order oldest
# -> newest by revision_dates; `latest` is the convenience default the frontend
# falls back to when a row's revision isn't in the bundle.
rd <- suppressMessages(read_csv(here('config', 'revision_dates.csv'), show_col_types = FALSE))
ord <- if ('effective_date' %in% names(rd)) rd$revision[order(rd$effective_date)] else rd$revision
revs <- intersect(ord, unique(sym$revision))
latest <- tail(revs, 1)

build_rev <- function(rv) {
  s <- sym[sym$revision == rv, , drop = FALSE]
  ps <- setNames(lapply(seq_len(nrow(s)), function(i) {
    o <- list(program = s$program_name[i])
    if ('general_note' %in% names(s) && !is.na(s$general_note[i])) o$general_note <- s$general_note[i]
    o
  }), s$symbol)
  c2_names <- if (nrow(col2) > 0) unique(col2$country_name[col2$revision == rv]) else character()
  c2_codes <- if (length(c2_names) > 0)
    unique(stats::na.omit(match_countries_to_census(c2_names)$census_code)) else character()
  list(program_symbols = ps,
       column2_countries = as.list(c2_names),
       column2_codes = as.list(c2_codes))
}
by_revision <- setNames(lapply(revs, build_rev), revs)

out <- list(
  version = 2,
  source = 'hts_general_note_3',
  generated_from = c(basename(sym_csv), basename(col2_csv)),
  latest_revision = latest,
  # Convenience top-level = the latest revision's map (frontend default).
  program_symbols = by_revision[[latest]]$program_symbols,
  column2_countries = by_revision[[latest]]$column2_countries,
  column2_codes = by_revision[[latest]]$column2_codes,
  by_revision = by_revision
)
json <- toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null')

targets <- c(
  here('frontend', 'public', 'data', 'program_symbols.json'),
  file.path('/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
            'sail-gtx-prerelease/src/modules/tariff-rates/constants/programSymbols.json')
)
for (t in targets) {
  d <- dirname(t)
  if (dir.exists(d) || dir.create(d, recursive = TRUE, showWarnings = FALSE)) {
    writeLines(json, t); cat('  wrote:', t, '\n')
  } else cat('  skip (no dir):', t, '\n')
}
cat('programSymbols: ', length(revs), ' revisions; latest ', latest, ' = ',
    length(by_revision[[latest]]$program_symbols), ' symbols, ',
    length(by_revision[[latest]]$column2_countries), ' Column 2\n', sep = '')

#!/usr/bin/env Rscript
# =============================================================================
# Emit the frontend programCountries bundle from the GENERATED beneficiary data
# (resources/gn_program_countries.csv, produced by src/parse_general_note_3.R).
# This de-hardcodes the frontend country -> preference-program membership map for
# the list-based programs (GSP / AGOA / CBERA) — the values come from HTS General
# Notes 4 / 16 / 7, not from app code. Surfaces, per census country, WHICH programs
# it is a beneficiary of, the governing symbol + General Note, and provenance, so
# the duty explorer can show real preference opportunities (not just FTAs).
#   Rscript scripts/emit_program_countries.R   (run after parse_general_note_3.R)
# =============================================================================
suppressWarnings(suppressMessages({ library(readr); library(dplyr); library(jsonlite); library(here) }))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

csv <- here('resources', 'gn_program_countries.csv')
if (!file.exists(csv)) stop('Missing ', csv, ' — run src/parse_general_note_3.R first')
d <- suppressMessages(read_csv(csv, show_col_types = FALSE)) %>%
  # Only mapped countries are addressable by census code; unmatched names (no code)
  # never assert eligibility (precision-first contract from the parser).
  filter(!is.na(census_code)) %>%
  mutate(census_code = as.character(census_code))

# A beneficiary marked with the family symbol qualifies for the *-suffixed
# variants too (A = GSP-all, A* = GSP-except-listed; E/E*). A+ (least-developed)
# is a distinct, smaller list we don't assert here. FTA codes come from the
# reviewed fta_partners.csv verbatim.
symbol_family <- function(sym) switch(sym, 'A' = c('A', 'A*'), 'E' = c('E', 'E*'), sym)

# FTA partner memberships (reviewed reference data; revision-stable for our range).
# Moves the former hardcoded frontend COUNTRY_MEMBERSHIPS into build-consumed data.
fta_path <- here('resources', 'fta_partners.csv')
fta <- if (file.exists(fta_path)) suppressMessages(read_csv(fta_path, show_col_types = FALSE)) else NULL
fta_by_code <- list()
if (!is.null(fta)) {
  fta$census_code <- as.character(fta$census_code)
  for (i in seq_len(nrow(fta))) {
    cc <- fta$census_code[i]
    fta_by_code[[cc]] <- c(fta_by_code[[cc]], list(list(
      label = fta$fta_label[i], program = fta$fta_label[i], kind = 'fta',
      general_note = if (is.na(fta$general_note[i])) NULL else as.character(fta$general_note[i]),
      # as.list keeps single-code arrays as JSON arrays (auto_unbox would turn
      # ["JP"] into "JP", which the frontend would iterate as ['J','P']).
      codes = as.list(strsplit(fta$codes[i], '\\|')[[1]]))))
  }
}

# program metadata (symbol -> program name + governing General Note)
programs <- d %>% distinct(symbol, program, general_note) %>% arrange(symbol)
prog_meta <- setNames(lapply(seq_len(nrow(programs)), function(i)
  list(program = programs$program[i], general_note = programs$general_note[i], kind = 'preference')),
  programs$symbol)
for (i in seq_len(nrow(fta %||% data.frame())))
  prog_meta[[fta$fta_label[i]]] <- list(program = fta$fta_label[i],
    general_note = if (is.na(fta$general_note[i])) NULL else as.character(fta$general_note[i]), kind = 'fta')

# REVISION-AWARE: beneficiary lists change by proclamation. Order oldest -> newest.
rd  <- suppressMessages(read_csv(here('config', 'revision_dates.csv'), show_col_types = FALSE))
ord <- if ('effective_date' %in% names(rd)) rd$revision[order(rd$effective_date)] else rd$revision
revs <- intersect(ord, unique(d$revision))
latest <- tail(revs, 1)

# census_code -> [ {label, program, general_note, kind, codes}, ... ] for one revision
# (parsed GSP/AGOA/CBERA beneficiaries) merged with the constant FTA partners.
build_rev <- function(rv) {
  s <- d[d$revision == rv, , drop = FALSE]
  by_code <- split(s, s$census_code)
  benef <- lapply(by_code, function(g) {
    g <- g[!duplicated(g$symbol), , drop = FALSE]
    lapply(seq_len(nrow(g)), function(i)
      list(label = g$program[i], program = g$program[i], kind = 'preference',
           general_note = as.character(g$general_note[i]),
           codes = as.list(symbol_family(g$symbol[i]))))
  })
  all_codes <- union(names(benef), names(fta_by_code))
  setNames(lapply(all_codes, function(cc) c(benef[[cc]], fta_by_code[[cc]])), all_codes)
}
by_revision <- setNames(lapply(revs, build_rev), revs)

# Compaction: beneficiary maps repeat across revisions (carry-forward). Keep a
# revision's full map only when it DIFFERS from the previous stored one; the
# frontend resolves a revision to the nearest stored revision <= it. revision_index
# maps EVERY revision to the stored key it should read.
sig <- vapply(by_revision, function(m) toJSON(m, auto_unbox = TRUE), '')
keep <- character(); idx <- setNames(character(length(revs)), revs); last_keep <- NA_character_; last_sig <- ''
for (rv in revs) {
  if (is.na(last_keep) || sig[[rv]] != last_sig) { keep <- c(keep, rv); last_keep <- rv; last_sig <- sig[[rv]] }
  idx[[rv]] <- last_keep
}
by_revision_compact <- by_revision[keep]

out <- list(
  version = 1,
  source = 'hts_general_notes_4_7_16 + fta_partners',
  generated_from = c(basename(csv), 'fta_partners.csv'),
  note = 'census_code -> programs the country can claim: parsed GSP/AGOA/CBERA beneficiaries (kind=preference, from HTS General Notes 4/16/7) merged with FTA partners (kind=fta, reviewed reference). `codes` are the HTS Special-subcolumn symbols matched against a line. A country absent here asserts no preference (defaults to base NTR/MFN); presence is a candidate, not proof of eligibility.',
  latest_revision = latest,
  programs = prog_meta,
  country_programs = by_revision[[latest]],   # latest revision = frontend default
  revision_index = as.list(idx),              # every revision -> stored key in by_revision
  by_revision = by_revision_compact
)
json <- toJSON(out, auto_unbox = TRUE, pretty = TRUE, null = 'null', na = 'null')

targets <- c(
  here('frontend', 'public', 'data', 'program_countries.json'),
  file.path('/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease',
            'sail-gtx-prerelease/src/modules/tariff-rates/constants/programCountries.json')
)
for (t in targets) {
  dd <- dirname(t)
  if (dir.exists(dd) || dir.create(dd, recursive = TRUE, showWarnings = FALSE)) {
    writeLines(json, t); cat('  wrote:', t, '\n')
  } else cat('  skip (no dir):', t, '\n')
}
cat('programCountries: ', length(revs), ' revisions (', length(keep), ' distinct maps); latest ',
    latest, ' = ', length(by_revision[[latest]]), ' beneficiary countries, ',
    length(prog_meta), ' programs\n', sep = '')

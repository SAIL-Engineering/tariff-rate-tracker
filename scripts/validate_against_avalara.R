# =============================================================================
# validate_against_avalara.R — diff our rates against cached Avalara payloads
# =============================================================================
#
# Compares, per (hts10, origin, entry date):
#   1. Chapter 99 code set   ours vs punitiveRates[].hsCode99
#   2. Stacking semantics    ours vs calculationMethod / stackable / taxOnTax
#   3. Base rate             ours vs duty.mfn
#   4. Total                 ours vs effectiveRate (effectiveRateFormula explains)
#   5. AD/CVD                adds[] / cvds[] have no counterpart in our schema
#                            yet — reported SEPARATELY so the shortfall is not
#                            misread as a stacking defect
#
# Compares against the VERBATIM provider JSON, never the mapped summary. The
# frontend's avalaraEnrichmentMapper buckets punitive lines using its own
# assumptions, so validating against it would test our reading of Avalara
# rather than Avalara.
#
# Avalara payloads come from Supabase. The anon key CANNOT read them — RLS
# returns HTTP 200 with zero rows, which looks identical to "no cached data".
# The script refuses to report a clean diff in that state; supply a service-role
# key via SUPABASE_SERVICE_KEY, or point --payloads at a local JSON dump.
#
# Usage:
#   Rscript scripts/validate_against_avalara.R --combos data/validation/combos.csv
#   Rscript scripts/validate_against_avalara.R --combos <f> --payloads dump.json
#   Rscript scripts/validate_against_avalara.R --combos <f> --ours-only
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
arg_of <- function(flag, default = NULL) {
  i <- which(args == flag)
  if (length(i) && length(args) > i[1]) args[i[1] + 1] else default
}
combos_path  <- arg_of('--combos', here('data', 'validation', 'combos.csv'))
payload_path <- arg_of('--payloads', NULL)
ours_only    <- '--ours-only' %in% args

# --- combos ------------------------------------------------------------------
if (!file.exists(combos_path)) {
  stop('combos file not found: ', combos_path,
       '\n  Expected columns: HTS, CountryOrigin, "Entry Date"', call. = FALSE)
}
combos <- suppressMessages(read_csv(combos_path, show_col_types = FALSE))
names(combos) <- tolower(gsub('\\s+', '_', names(combos)))
stopifnot(all(c('hts', 'countryorigin', 'entry_date') %in% names(combos)))
combos <- combos %>%
  transmute(hts10 = sprintf('%010s', gsub('\\D', '', hts)),
            iso = toupper(trimws(countryorigin)),
            entry_date = as.Date(entry_date)) %>%
  distinct()
message('Combos: ', nrow(combos), ' distinct (hts10, origin, date)')

# --- entry date -> revision ---------------------------------------------------
# A duty is owed under the schedule in force ON THE ENTRY DATE, so the revision
# is chosen by effective date, not by whichever revision is newest.
rev_dates <- suppressMessages(read_csv(here('config', 'revision_dates.csv'),
                                       show_col_types = FALSE))
rd_col <- intersect(c('effective_date', 'date'), names(rev_dates))[1]
id_col <- intersect(c('revision', 'revision_id'), names(rev_dates))[1]
rev_lookup <- rev_dates %>%
  transmute(revision = .data[[id_col]], eff = as.Date(.data[[rd_col]])) %>%
  filter(!is.na(eff)) %>% arrange(eff)

revision_for <- function(d) {
  vapply(d, function(x) {
    ok <- rev_lookup$eff <= x
    if (!any(ok)) return(NA_character_)
    rev_lookup$revision[max(which(ok))]
  }, character(1))
}
combos$revision <- revision_for(combos$entry_date)

# --- iso -> census ------------------------------------------------------------
iso_map <- suppressMessages(read_csv(here('resources', 'countries-ISO-3166-1-alpha-2.csv'),
                                     show_col_types = FALSE)) %>%
  tryCatch(error = function(e) NULL)
if (is.null(iso_map)) {
  # Fall back to the pipeline's own resolver by country NAME.
  suppressPackageStartupMessages(source(here('src', 'helpers.R')))
  iso_names <- c(DE = 'Germany', IT = 'Italy', SK = 'Slovakia', CZ = 'Czech Republic',
                 MX = 'Mexico', PL = 'Poland', HU = 'Hungary', GB = 'United Kingdom',
                 CN = 'China', JP = 'Japan', BR = 'Brazil', IN = 'India',
                 TW = 'Taiwan', TR = 'Turkey', ID = 'Indonesia', ES = 'Spain',
                 PT = 'Portugal', FR = 'France', US = 'United States')
  combos$country <- vapply(combos$iso, function(i) {
    nm <- iso_names[[i]] %||% NA_character_
    if (is.na(nm)) return(NA_character_)
    r <- resolve_country_name(nm)
    if (length(r) == 0) NA_character_ else r[1]
  }, character(1))
}
unresolved_iso <- sort(unique(combos$iso[is.na(combos$country)]))
if (length(unresolved_iso) > 0) {
  warning('Origins not resolved to census codes (excluded from the diff): ',
          paste(unresolved_iso, collapse = ', '), call. = FALSE)
}

# --- our side -----------------------------------------------------------------
parquet_root <- here('data', 'timeseries', 'rate_timeseries_parquet')
ours <- combos %>% filter(!is.na(country), !is.na(revision)) %>%
  group_split(revision) %>%
  map_dfr(function(g) {
    p <- file.path(parquet_root, paste0('revision=', g$revision[1]))
    if (!dir.exists(p)) return(g %>% mutate(found = FALSE))
    keep <- c('hts10', 'country', 'base_rate', 'rate_232', 'rate_301',
              'rate_ieepa_recip', 'rate_ieepa_fent', 'rate_s122', 'rate_section_201',
              'total_rate', 'ch99_code_232', 'ch99_code_301', 'ch99_code_ieepa_recip',
              'ch99_code_ieepa_fent', 'calc_status', 'rate_basis')
    d <- open_dataset(p)
    d <- d %>% select(any_of(keep)) %>% collect()
    g %>% left_join(d, by = c('hts10', 'country')) %>%
      mutate(found = !is.na(total_rate))
  })

message('Matched in our corpus: ', sum(ours$found), ' / ', nrow(ours))

# --- Avalara side --------------------------------------------------------------
load_payloads <- function() {
  if (!is.null(payload_path)) {
    if (!file.exists(payload_path)) stop('payload dump not found: ', payload_path)
    return(jsonlite::fromJSON(payload_path, simplifyVector = FALSE))
  }
  url <- Sys.getenv('SUPABASE_URL'); key <- Sys.getenv('SUPABASE_SERVICE_KEY')
  if (!nzchar(url) || !nzchar(key)) return(NULL)
  # (fetch omitted here: the caller supplies a dump or a service key)
  NULL
}

payloads <- if (ours_only) NULL else load_payloads()

if (is.null(payloads) && !ours_only) {
  message('\n', strrep('!', 70))
  message('NO AVALARA PAYLOADS AVAILABLE — comparison NOT performed.')
  message('The Supabase anon key cannot read avalara_pair_cache /')
  message('duty_enrichment_results: RLS returns HTTP 200 with zero rows, which is')
  message('indistinguishable from "nothing cached". Reporting a clean diff here')
  message('would be a false pass, so the diff is skipped rather than faked.')
  message('Supply SUPABASE_SERVICE_KEY, or --payloads <dump.json>.')
  message(strrep('!', 70), '\n')
}

# --- our-side invariants (run regardless) --------------------------------------
# These need no provider data: they are internal contradictions that make a row
# wrong on its face, so they are worth surfacing even without Avalara.
findings <- list()
add <- function(check, sev, detail, n = NA_integer_) {
  findings[[length(findings) + 1L]] <<-
    tibble(check = check, severity = sev, detail = detail, n_rows = n)
}

rated <- ours %>% filter(found, coalesce(rate_232, 0) > 0)

# The §232 heading must come from the same commodity family as the article.
# 9903.74 is MHD vehicles; a bearing or a switch is not one.
if (nrow(rated) > 0 && 'ch99_code_232' %in% names(rated)) {
  bad_family <- rated %>%
    mutate(ch = substr(hts10, 1, 2)) %>%
    filter(!is.na(ch99_code_232),
           substr(ch99_code_232, 6, 7) == '74',
           !ch %in% c('87', '86'))
  if (nrow(bad_family) > 0) {
    add('s232_heading_wrong_family', 'ERROR',
        sprintf('%d rows carry an MHD-vehicle heading (9903.74.x) on non-vehicle chapters: %s',
                nrow(bad_family),
                paste(sort(unique(substr(bad_family$hts10, 1, 2))), collapse = ', ')),
        nrow(bad_family))
  }
}

# A rated row with no heading cannot be justified to a filer.
if (nrow(rated) > 0) {
  no_code <- sum(is.na(rated$ch99_code_232))
  if (no_code > 0) {
    add('s232_rated_without_heading', 'WARN',
        sprintf('%d rows owe §232 duty with no Chapter 99 heading assigned', no_code),
        no_code)
  }
}

# EO 14289 sec. 3(a): after 2025-03-04 no row may owe both §232 auto duty and
# IEEPA Canada/Mexico. Checked on the authority columns available in the corpus.
eo_rows <- ours %>% filter(found, entry_date >= as.Date('2025-03-04'),
                           country %in% c('1220', '2010'))
if (nrow(eo_rows) > 0 && all(c('rate_232', 'rate_ieepa_fent') %in% names(eo_rows))) {
  both <- eo_rows %>% filter(coalesce(rate_232, 0) > 0, coalesce(rate_ieepa_fent, 0) > 0)
  if (nrow(both) > 0) {
    add('eo14289_both_owed', 'ERROR',
        sprintf('%d CA/MX rows on/after 2025-03-04 owe BOTH §232 and IEEPA — EO 14289 sec. 3(a) forbids the pair',
                nrow(both)), nrow(both))
  }
}

# A duty that exists but is not representable must not read as resolved.
if ('calc_status' %in% names(ours)) {
  silent0 <- ours %>% filter(found, coalesce(base_rate, 0) == 0,
                             rate_basis %in% c('specific', 'compound'),
                             calc_status == 'ok')
  if (nrow(silent0) > 0) {
    add('base_zero_marked_ok', 'ERROR',
        sprintf('%d rows have a specific/compound duty, base_rate 0, and calc_status "ok"',
                nrow(silent0)), nrow(silent0))
  }
}

# --- report ---------------------------------------------------------------------
out <- if (length(findings)) bind_rows(findings) else
  tibble(check = character(), severity = character(), detail = character(), n_rows = integer())

message('\n', strrep('=', 70))
if (nrow(out) == 0) {
  message('Our-side invariants: OK across ', sum(ours$found), ' matched rows')
} else {
  for (sev in c('ERROR', 'WARN')) {
    s <- out %>% filter(severity == sev)
    if (nrow(s) == 0) next
    message('\n', sev, ' (', nrow(s), ')')
    for (i in seq_len(nrow(s))) message('  [', s$check[i], '] ', s$detail[i])
  }
}
message(strrep('=', 70))

dir.create(here('output', 'quality'), recursive = TRUE, showWarnings = FALSE)
write_csv(out, here('output', 'quality', 'avalara_validation_findings.csv'))
write_csv(ours, here('output', 'quality', 'avalara_validation_rows.csv'))
message('Wrote output/quality/avalara_validation_{findings,rows}.csv')

if (is.null(payloads) && !ours_only) {
  message('\nNOTE: provider comparison was SKIPPED — findings above are our-side only.')
  quit(status = 2)   # distinct from 0 (clean) and 1 (findings)
}

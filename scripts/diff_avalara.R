# =============================================================================
# diff_avalara.R — diff our rates against the cached Avalara payloads
# =============================================================================
#
# Compares per (hts10, origin, entry date) against the VERBATIM provider JSON,
# never the mapped summary — the frontend mapper buckets punitive lines using
# its own assumptions, so validating against it would test our reading of
# Avalara rather than Avalara.
#
# The payload shape drives everything here, so the traps are worth stating:
#
#   * The timeline is `compliancePrediction.compliance[]`. Periods carry an
#     `effectiveDate` and NO end date — they are half-open, closed by the next
#     entry. Selection is: greatest effectiveDate <= target.
#   * A date BEFORE every period returns nothing. We do NOT fall back to the
#     first period; back-projecting a later regime onto an earlier entry would
#     manufacture agreement on the wrong period, which is worse than a visible
#     gap.
#   * `hsCode99` is DOTLESS ("99039405"). Ours has dots. Normalise or every
#     heading looks like a mismatch.
#   * `punitiveRates[].rate.effectiveRate == "0"` does NOT mean "not assigned".
#     Avalara routinely lists a heading and then zeroes it because a
#     higher-precedence action superseded it — observed on 8708407580/MX, where
#     9903.74.08 is listed at 0 while 9903.94.05 carries the 25%. Comparing
#     against the assigned SET would flag a false mismatch; comparing against
#     the set with duty > 0 is the meaningful test, so both are reported.
#   * Rates are fractions; punitive ones are strings, entry-level is numeric.
#
# Usage:
#   Rscript scripts/diff_avalara.R
#   Rscript scripts/diff_avalara.R --entries <f> --cache <f> --revision-map
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
arg_of <- function(flag, d = NULL) {
  i <- which(args == flag); if (length(i) && length(args) > i[1]) args[i[1] + 1] else d
}
entries_path <- arg_of('--entries', here('data', 'validation', 'entries.csv'))
cache_path   <- arg_of('--cache',   here('data', 'validation', 'avalara_cache.rds'))

# --- inputs -------------------------------------------------------------------
entries <- suppressMessages(read_csv(entries_path, show_col_types = FALSE))
names(entries) <- tolower(gsub('\\s+', '_', names(entries)))
entries <- entries %>%
  transmute(hts10 = sprintf('%010s', gsub('\\D', '', hts)),
            iso = toupper(trimws(countryorigin)),
            entry_date = as.Date(entry_date)) %>%
  distinct()

cache <- readRDS(cache_path)
message('Entries: ', nrow(entries), ' distinct triples | cache: ', nrow(cache), ' pairs')

# --- provider side: select the period covering each entry date ----------------
norm_code <- function(x) gsub('\\D', '', x %||% '')

period_for <- function(payload, on_date) {
  comp <- payload$compliancePrediction$compliance
  if (is.null(comp) || length(comp) == 0) return(NULL)
  eff <- as.Date(vapply(comp, function(e) e$effectiveDate %||% NA_character_,
                        character(1)))
  ok <- which(!is.na(eff) & eff <= on_date)
  if (length(ok) == 0) return(NULL)          # before every period — NO fallback
  comp[[ok[which.max(eff[ok])]]]
}

summarise_period <- function(e) {
  if (is.null(e)) return(NULL)
  pr <- e$duty$punitiveRates %||% list()
  num <- function(x) suppressWarnings(as.numeric(x %||% NA))
  codes_all <- vapply(pr, function(p) norm_code(p$hsCode99), character(1))
  eff_each  <- vapply(pr, function(p) num(p$rate$effectiveRate %||% p$rate$rate), numeric(1))
  stat_each <- vapply(pr, function(p) num(p$rate$rate), numeric(1))
  live <- !is.na(eff_each) & eff_each > 0
  list(
    effective_date  = e$effectiveDate %||% NA_character_,
    mfn             = num(e$duty$mfn$rate),
    mfn_effective   = num(e$duty$mfn$effectiveRate %||% e$duty$mfn$rate),
    total           = num(e$effectiveRate),
    formula         = e$effectiveRateFormula %||% NA_character_,
    codes_assigned  = paste(sort(codes_all), collapse = ','),
    codes_live      = paste(sort(codes_all[live]), collapse = ','),
    punitive_sum_eff  = if (length(eff_each)) sum(eff_each, na.rm = TRUE) else 0,
    punitive_sum_stat = if (length(stat_each)) sum(stat_each, na.rm = TRUE) else 0,
    n_add = length(e$adds %||% list()),
    n_cvd = length(e$cvds %||% list()),
    add_rate = if (length(e$adds %||% list()))
      sum(vapply(e$adds, function(a) num(a$rate$rate), numeric(1)), na.rm = TRUE) else 0,
    cvd_rate = if (length(e$cvds %||% list()))
      sum(vapply(e$cvds, function(a) num(a$rate$rate), numeric(1)), na.rm = TRUE) else 0,
    methods = paste(sort(unique(vapply(pr, function(p)
      p$calculationMethod %||% 'NA', character(1)))), collapse = ',')
  )
}

message('Selecting provider periods…')
prov <- entries %>%
  left_join(cache %>% select(hts10, origin_alpha2, raw_response,
                             coverage_start, coverage_end,
                             latest_revision_effective_date),
            by = c('hts10' = 'hts10', 'iso' = 'origin_alpha2'))

prov_rows <- pmap(list(prov$raw_response, prov$entry_date), function(payload, d) {
  if (is.null(payload)) return(NULL)
  summarise_period(period_for(payload, d))
})

prov <- prov %>%
  mutate(
    .have = !map_lgl(prov_rows, is.null),
    status = case_when(
      map_lgl(raw_response, is.null) ~ 'gap_no_pair',
      !.have                          ~ 'gap_before_timeline',
      entry_date > coverage_end       ~ 'gap_after_coverage',
      TRUE                            ~ 'covered'
    ))
for (f in c('effective_date', 'mfn', 'mfn_effective', 'total', 'formula',
            'codes_assigned', 'codes_live', 'punitive_sum_eff',
            'punitive_sum_stat', 'n_add', 'n_cvd', 'add_rate', 'cvd_rate',
            'methods')) {
  prov[[paste0('av_', f)]] <- map(prov_rows, ~ .x[[f]] %||% NA) |> map(~ .x %||% NA) |>
    unlist() %>% { if (length(.) == nrow(prov)) . else rep(NA, nrow(prov)) }
}
prov$raw_response <- NULL

message('  covered: ', sum(prov$status == 'covered'),
        ' | gap_no_pair: ', sum(prov$status == 'gap_no_pair'),
        ' | gap_before_timeline: ', sum(prov$status == 'gap_before_timeline'),
        ' | gap_after_coverage: ', sum(prov$status == 'gap_after_coverage'))

# --- our side -----------------------------------------------------------------
rev_dates <- suppressMessages(read_csv(here('config', 'revision_dates.csv'),
                                       show_col_types = FALSE))
idc <- intersect(c('revision', 'revision_id'), names(rev_dates))[1]
dc  <- intersect(c('effective_date', 'date'), names(rev_dates))[1]
rl  <- rev_dates %>% transmute(revision = .data[[idc]], eff = as.Date(.data[[dc]])) %>%
  filter(!is.na(eff)) %>% arrange(eff)
revision_for <- function(d) vapply(d, function(x) {
  ok <- rl$eff <= x; if (!any(ok)) NA_character_ else rl$revision[max(which(ok))]
}, character(1))
prov$revision <- revision_for(prov$entry_date)

iso_names <- c(DE='Germany', IT='Italy', SK='Slovakia', CZ='Czech Republic',
               MX='Mexico', PL='Poland', HU='Hungary', GB='United Kingdom',
               CN='China', JP='Japan', BR='Brazil', IN='India', TW='Taiwan',
               TR='Turkey', ID='Indonesia', ES='Spain', PT='Portugal',
               FR='France', US='United States')
suppressPackageStartupMessages(source(here('src', 'helpers.R')))
prov$country <- vapply(prov$iso, function(i) {
  nm <- iso_names[[i]] %||% NA_character_
  if (is.na(nm)) return(NA_character_)
  r <- resolve_country_name(nm); if (length(r) == 0) NA_character_ else r[1]
}, character(1))

parquet_root <- here('data', 'timeseries', 'rate_timeseries_parquet')
keep <- c('hts10','country','base_rate','rate_232','rate_301','rate_ieepa_recip',
          'rate_ieepa_fent','rate_s122','rate_section_201','rate_s301fl',
          'rate_s301br','rate_s338','rate_adcvd','total_rate','ch99_code_232',
          'ch99_code_301','ch99_code_ieepa_recip','ch99_code_ieepa_fent',
          'calc_status','column2_status','pending_activation_json')

ours <- prov %>% filter(!is.na(revision), !is.na(country)) %>%
  group_split(revision) %>%
  map_dfr(function(g) {
    p <- file.path(parquet_root, paste0('revision=', g$revision[1]))
    if (!dir.exists(p)) return(g %>% mutate(.matched = FALSE))
    d <- open_dataset(p) %>% select(any_of(keep)) %>% collect()
    g %>% left_join(d, by = c('hts10', 'country')) %>%
      mutate(.matched = !is.na(total_rate))
  })

message('Matched in our corpus: ', sum(ours$.matched), ' / ', nrow(ours))

# --- comparisons --------------------------------------------------------------
tol <- 5e-4
cmp <- ours %>% filter(status == 'covered', .matched) %>%
  mutate(
    our_codes = pmap_chr(list(ch99_code_232, ch99_code_301,
                              ch99_code_ieepa_recip, ch99_code_ieepa_fent),
                         function(...) {
                           v <- c(...); v <- v[!is.na(v)]
                           paste(sort(norm_code(v)), collapse = ',')
                         }),
    d_base  = base_rate - av_mfn,
    d_total = total_rate - av_total,
    mismatch_base  = abs(d_base)  > tol,
    mismatch_total = abs(d_total) > tol,
    mismatch_codes_live = our_codes != av_codes_live,
    has_adcvd = (av_n_add + av_n_cvd) > 0
  )

message('\n', strrep('=', 72))
message('COMPARED: ', nrow(cmp), ' rows')
message(strrep('-', 72))
message(sprintf('  base rate  mismatch: %5d (%.1f%%)', sum(cmp$mismatch_base),
                100 * mean(cmp$mismatch_base)))
message(sprintf('  total rate mismatch: %5d (%.1f%%)', sum(cmp$mismatch_total),
                100 * mean(cmp$mismatch_total)))
message(sprintf('  live Ch99 set differs: %5d (%.1f%%)', sum(cmp$mismatch_codes_live),
                100 * mean(cmp$mismatch_codes_live)))
message(sprintf('  rows where Avalara has AD/CVD (we do not): %d', sum(cmp$has_adcvd)))
message(strrep('=', 72))

dir.create(here('output', 'quality'), recursive = TRUE, showWarnings = FALSE)
write_csv(cmp %>% select(-any_of('.matched')),
          here('output', 'quality', 'avalara_diff.csv'))

summ <- cmp %>%
  group_by(revision, iso) %>%
  summarise(n = n(),
            base_mm = sum(mismatch_base), total_mm = sum(mismatch_total),
            code_mm = sum(mismatch_codes_live),
            mean_d_total = mean(d_total, na.rm = TRUE), .groups = 'drop') %>%
  arrange(desc(total_mm))
write_csv(summ, here('output', 'quality', 'avalara_diff_summary.csv'))
message('Wrote output/quality/avalara_diff{,_summary}.csv')
print(as.data.frame(summ %>% head(15)), row.names = FALSE)

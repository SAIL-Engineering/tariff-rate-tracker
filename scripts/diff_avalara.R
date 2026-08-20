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
# STATUTORY columns are the ones comparable to Avalara. base_rate/total_rate are
# TRADE-WEIGHTED — 06_calculate_rates.R scales them by the MFN exemption share
# and the USMCA share, so they answer "what does the average dollar of this
# trade flow pay" while Avalara answers "what does this entry owe". Comparing
# the weighted columns produced 650 false base mismatches (54.5%) and 954 false
# total mismatches (80.0%) on the first run of this script.
keep <- c('hts10','country','base_rate','statutory_base_rate',
          'total_rate','statutory_total_rate','statutory_total_additional',
          'statutory_alternatives_json',
          'rate_232','rate_301','rate_ieepa_recip',
          'rate_ieepa_fent','rate_s122','rate_section_201','rate_s301fl',
          'rate_s301br','rate_s338','rate_adcvd','ch99_code_232',
          'ch99_code_301','ch99_code_ieepa_recip','ch99_code_ieepa_fent',
          'ch99_code_s122','ch99_code_s201','ch99_code_s301fl',
          'ch99_code_s301br','ch99_code_s338',
          'calc_status','column2_status','pending_activation_json','rate_basis')

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

# A partition built before compute_statutory_totals() existed carries NA here.
# Those rows cannot be compared and must not be counted as agreement.
if (!'statutory_total_rate' %in% names(ours)) ours$statutory_total_rate <- NA_real_
# Attribution columns added over time — partitions built before one existed
# just contribute nothing to the heading-set comparison for that authority.
for (.c in c('ch99_code_232', 'ch99_code_301', 'ch99_code_ieepa_recip',
             'ch99_code_ieepa_fent', 'ch99_code_s122', 'ch99_code_s201',
             'ch99_code_s301fl', 'ch99_code_s301br', 'ch99_code_s338')) {
  if (!.c %in% names(ours)) ours[[.c]] <- NA_character_
}
n_stale <- sum(ours$.matched & is.na(ours$statutory_total_rate))
if (n_stale > 0) {
  message('  NOT COMPARABLE: ', n_stale, ' matched row(s) have no statutory_total_rate ',
          '(partition predates it). Rebuild those revisions before reading the totals below.')
  message('    revisions: ', paste(sort(unique(
    ours$revision[ours$.matched & is.na(ours$statutory_total_rate)])), collapse = ', '))
}

# --- comparisons --------------------------------------------------------------
tol <- 5e-4
cmp <- ours %>% filter(status == 'covered', .matched) %>%
  mutate(
    our_codes = pmap_chr(list(ch99_code_232, ch99_code_301,
                              ch99_code_ieepa_recip, ch99_code_ieepa_fent,
                              ch99_code_s122, ch99_code_s201,
                              ch99_code_s301fl, ch99_code_s301br,
                              ch99_code_s338),
                         function(...) {
                           v <- c(...); v <- v[!is.na(v)]
                           paste(sort(norm_code(v)), collapse = ',')
                         }),
    # Avalara did not always keep §232 out of duty.mfn. In periods from roughly
    # 2025-03 to 2025-06 it reported the §232 duty INSIDE mfn and listed no
    # Chapter 99 code at all; from ~2025-10 it switched to punitiveRates. Those
    # rows are a provider representation change, not a defect on our side, and
    # counting them as base mismatches overstated our error by 198 rows.
    av_mfn_absorbs_punitive =
      (is.na(av_codes_live) | av_codes_live == '') &
      !is.na(av_mfn) & !is.na(statutory_base_rate) &
      (av_mfn - statutory_base_rate) > tol &
      coalesce(rate_232, 0) > 0,

    d_base  = statutory_base_rate - av_mfn,
    mismatch_base  = abs(d_base) > tol & !av_mfn_absorbs_punitive,
    mismatch_codes_live = our_codes != av_codes_live & !av_mfn_absorbs_punitive,
    has_adcvd = (av_n_add + av_n_cvd) > 0,

    # On a CA/MX line the USMCA fork means TWO totals are legally defensible.
    # Our default is "preference not claimed"; the alternative rides in the
    # JSON. Avalara was measured to use the full statutory MFN on 240 of 314
    # CA/MX periods, i.e. it also assumes preference is NOT claimed — so the
    # default is the right primary comparison. The claimed branch is still
    # tested, because scoring a row as a mismatch when it matches the OTHER
    # legally-correct branch would be a false positive.
    alt_total = suppressWarnings(as.numeric(
      sub('.*"alternative":\\{[^}]*"total":([0-9.]+).*', '\\1',
          statutory_alternatives_json))),
    d_total       = statutory_total_rate - av_total,
    d_total_alt   = alt_total - av_total,
    matches_default = !is.na(d_total)     & abs(d_total)     <= tol,
    matches_alt     = !is.na(d_total_alt) & abs(d_total_alt) <= tol,

    # Classes that are NOT ours to answer, in priority order. Leaving any of
    # them in the total would attribute a known, explained gap to the stacking
    # engine.
    cls = case_when(
      substr(hts10, 1, 2) == '98' ~ 'out_of_scope_ch98',
      has_adcvd                   ~ 'adcvd_not_modelled',
      av_mfn_absorbs_punitive     ~ 'avalara_mfn_artifact',
      is.na(statutory_total_rate) ~ 'no_statutory_total',
      TRUE                        ~ 'comparable'
    ),
    mismatch_total = cls == 'comparable' & !matches_default & !matches_alt
  )

cmpbl <- cmp %>% filter(cls == 'comparable')
pct <- function(x, d) if (d > 0) 100 * x / d else NA_real_
message('\n', strrep('=', 72))
message('ROWS: ', nrow(cmp), '  (statutory basis, preference-not-claimed default)')
message(strrep('-', 72))
for (k in c('comparable','out_of_scope_ch98','adcvd_not_modelled',
            'avalara_mfn_artifact','no_statutory_total')) {
  n <- sum(cmp$cls == k)
  if (n > 0) message(sprintf('  %-22s %5d', k, n))
}
message(strrep('-', 72))
message('AGREEMENT on the ', nrow(cmpbl), ' comparable rows')
message(sprintf('  total rate mismatch : %5d (%.1f%%)',
                sum(cmpbl$mismatch_total), pct(sum(cmpbl$mismatch_total), nrow(cmpbl))))
message(sprintf('    of which matched via the USMCA alternative branch: %d',
                sum(cmpbl$matches_alt & !cmpbl$matches_default)))
message(sprintf('  base rate  mismatch : %5d (%.1f%%)',
                sum(cmpbl$mismatch_base), pct(sum(cmpbl$mismatch_base), nrow(cmpbl))))
message(sprintf('  live Ch99 set differs: %4d (%.1f%%)',
                sum(cmpbl$mismatch_codes_live),
                pct(sum(cmpbl$mismatch_codes_live), nrow(cmpbl))))
message(strrep('=', 72))

dir.create(here('output', 'quality'), recursive = TRUE, showWarnings = FALSE)
write_csv(cmp %>% select(-any_of('.matched')),
          here('output', 'quality', 'avalara_diff.csv'))

summ <- cmp %>%
  group_by(revision, iso) %>%
  summarise(n = n(),
            comparable = sum(cls == 'comparable'),
            base_mm = sum(mismatch_base),
            total_mm = sum(mismatch_total, na.rm = TRUE),
            code_mm = sum(mismatch_codes_live),
            av_artifact = sum(av_mfn_absorbs_punitive),
            mean_d_total = mean(d_total[cls == 'comparable'], na.rm = TRUE),
            .groups = 'drop') %>%
  arrange(desc(total_mm))
write_csv(summ, here('output', 'quality', 'avalara_diff_summary.csv'))
message('Wrote output/quality/avalara_diff{,_summary}.csv')
print(as.data.frame(summ %>% head(15)), row.names = FALSE)

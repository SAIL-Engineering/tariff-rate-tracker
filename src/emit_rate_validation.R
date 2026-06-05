# =============================================================================
# emit_rate_validation.R — base-rate reconciliation harness ("validate every case")
# =============================================================================
# Per-revision invariants over the rate parquet + the GENERATED General-Note
# reference data, so the data-driven rate universe (Phase 0) can't silently drift.
# Mirrors emit_quality_metrics.R: arrow pushdown per `revision=` partition, writes
# CSVs to output/quality/, prints a console box, and NEVER aborts by default.
#
#   SAIL_VALIDATE_RATES=strict  -> abort the build on a CORRECTNESS violation
#                                  (base>statutory, non-finite). Quality flags
#                                  (symbol coverage, bands) stay report-only.
#
# Invariants
#   C1  base_rate <= statutory_base_rate            (correctness)
#   C2  base_rate, statutory_base_rate finite & >=0 (correctness)
#   P3  blended row (base < 0.995*statutory) carries a preference_share AND a
#       blend reason in duty_provenance_json, never base_mfn_col1   (correctness)
#   P4  non-blended row (base == statutory) carries NO preference_share (quality)
#   P5  CA/MX never use the HS2 census blend (must be USMCA HTS10) — the 6c
#       double-count guard                            (correctness)
#   Q3  Special symbols used in rate lines are covered by the program map
#       (gn3 symbols + fta_partners codes + allowlist) -> rate_unknown_symbols.csv
#       (quality; the HTS legitimately exceeds the GN 3(c)(i) table)
#   Q4  base_rate_source resolved (own/inherited) for active lines, when the
#       column is present (rebuild to populate)      (quality)
#   Q5  Column 2 names all resolve to a census code; count in band   (quality)
#   Q6  GSP/AGOA/CBERA beneficiary counts within expected band       (quality)
#
# P3/P4/P5 parse duty_provenance_json via pushdown str_detect (no row collect);
# they ACTIVATE on the next full build (the committed parquet predates this code).
# =============================================================================
suppressWarnings(suppressMessages({
  library(here); library(dplyr); library(stringr); library(readr); library(purrr); library(tibble)
}))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a

# Expected count bands for the generated reference data (catch a broken parse).
.RATE_VALID_BANDS <- list(
  symbols  = c(20L, 35L),
  column2  = c(2L, 8L),
  GSP      = c(90L, 135L),
  AGOA     = c(25L, 45L),
  `CBERA (CBI)` = c(12L, 25L)
)

# Symbols valid in the HTS Special subcolumn but NOT in the GN 3(c)(i) program
# table: USMCA country qualifiers come from fta_partners.csv; J/J*/J+ are the
# defunct Andean (ATPA/ATPDEA) symbols that still appear in historical rate lines.
.SYMBOL_ALLOWLIST <- c('J', 'J*', 'J+')

# Extract the clean Special symbols used in RATE entries of a special_programs_json
# vector. Reference entries ("See U.S. note ...") and junk tokens are dropped — we
# only want the actual program indicators carried on a duty-bearing line.
.extract_symbols <- function(json_vec) {
  json_vec <- json_vec[!is.na(json_vec) & nzchar(json_vec)]
  if (length(json_vec) == 0) return(character())
  out <- tryCatch({
    unlist(lapply(unique(json_vec), function(j) {
      parsed <- tryCatch(jsonlite::fromJSON(j, simplifyVector = FALSE), error = function(e) NULL)
      if (is.null(parsed)) return(character())
      rate_entries <- Filter(function(e) identical(e$entry_type, 'rate'), parsed)
      progs <- unlist(lapply(rate_entries, function(e) e$programs %||% character()))
      # Drop prose elements (e.g. "see U.S. note 3 of this subchapter") that slip
      # in as a program string — a real Special symbol has NO lowercase letters,
      # so this prevents extracting a stray "U"/"S" from "U.S.". Then split the
      # remaining uppercase noise ("E IL" / ".OM" / "PA (PA") into clean tokens.
      progs <- progs[!is.na(progs) & !stringr::str_detect(progs, '[a-z]')]
      toks <- unlist(stringr::str_extract_all(progs, '[A-Z]{1,2}[*+]?'))
      toks
    }))
  }, error = function(e) character())
  unique(out[nzchar(out)])
}

emit_rate_validation <- function(output_dir = here::here('output', 'quality'),
                                 parquet_root = here::here('data', 'timeseries', 'rate_timeseries_parquet')) {
  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  if (!requireNamespace('arrow', quietly = TRUE)) {
    message('  [rate-valid] arrow unavailable — skipped'); return(invisible(NULL))
  }
  parts <- list.files(parquet_root, pattern = '^revision=', full.names = TRUE)
  if (length(parts) == 0) { message('  [rate-valid] no parquet partitions'); return(invisible(NULL)) }

  # --- generated reference data (per revision) -------------------------------
  ref <- function(f) tryCatch(suppressMessages(read_csv(here::here('resources', f), show_col_types = FALSE)),
                              error = function(e) NULL)
  gn_sym  <- ref('gn3_program_symbols.csv')
  gn_col2 <- ref('gn3_column2_countries.csv')
  gn_ben  <- ref('gn_program_countries.csv')
  fta     <- ref('fta_partners.csv')
  fta_codes <- if (!is.null(fta) && 'codes' %in% names(fta))
    unique(unlist(strsplit(paste(fta$codes, collapse = '|'), '\\|'))) else character()
  # census matcher (for the Column 2 resolvability check)
  has_matcher <- tryCatch({
    suppressWarnings(suppressMessages(source(here::here('src', 'parse_general_note_3.R')))); TRUE
  }, error = function(e) FALSE)

  # Known universe = GN 3(c)(i) program symbols (this revision) + USMCA/FTA country
  # qualifiers from fta_partners.csv + the defunct-but-valid allowlist. The HTS
  # Special subcolumn legitimately uses symbols beyond the GN3 program table, so an
  # uncovered symbol is a QUALITY review signal (frontend map gap), not a build error.
  symbols_for <- function(rev) unique(c(
    if (!is.null(gn_sym)) gn_sym$symbol[gn_sym$revision == rev] else character(),
    fta_codes, .SYMBOL_ALLOWLIST))

  viol <- list(); summ <- list(); unresolved <- list(); unknown_syms <- list()
  add <- function(rev, sev, invariant, detail, n = 1L)
    viol[[length(viol) + 1L]] <<- tibble(revision = rev, severity = sev, invariant = invariant,
                                         detail = detail, n_rows = n)

  for (p in parts) {
    rev <- sub('.*revision=', '', p)
    ds  <- tryCatch(arrow::open_dataset(p), error = function(e) NULL)
    if (is.null(ds)) next
    cols <- names(ds)
    has_src <- 'base_rate_source' %in% cols

    # --- C1/C2: per-row numeric invariants (cheap arrow aggregates) ----------
    agg <- tryCatch(
      ds %>% summarise(
        n = dplyr::n(),
        n_base_gt_stat = sum(base_rate > statutory_base_rate + 1e-6, na.rm = TRUE),
        n_bad_num = sum(is.na(base_rate) | is.na(statutory_base_rate) |
                          base_rate < 0 | statutory_base_rate < 0, na.rm = TRUE),
        mean_base = mean(base_rate, na.rm = TRUE),
        mean_stat = mean(statutory_base_rate, na.rm = TRUE)
      ) %>% collect(), error = function(e) NULL)
    n_rows <- if (!is.null(agg)) agg$n else NA_integer_
    if (!is.null(agg)) {
      if (agg$n_base_gt_stat > 0) add(rev, 'correctness', 'C1_base_gt_statutory',
        sprintf('%d rows have base_rate > statutory_base_rate', agg$n_base_gt_stat), agg$n_base_gt_stat)
      if (agg$n_bad_num > 0) add(rev, 'correctness', 'C2_nonfinite_or_negative',
        sprintf('%d rows have NA/negative base or statutory rate', agg$n_bad_num), agg$n_bad_num)
    }

    # --- Q3: Special symbols used in rate lines covered by the program map -----
    # Quality signal (frontend map gap), not a build error — the HTS Special
    # subcolumn legitimately carries symbols beyond GN 3(c)(i). Only meaningful for
    # revisions the GN3 extraction actually covers (reststop serves ~2024+).
    known <- symbols_for(rev)
    gn3_has_rev <- !is.null(gn_sym) && rev %in% gn_sym$revision
    if (gn3_has_rev && 'special_programs_json' %in% cols) {
      sj <- tryCatch(ds %>% select(special_programs_json) %>%
                       filter(!is.na(special_programs_json)) %>% distinct() %>% collect(),
                     error = function(e) NULL)
      if (!is.null(sj) && nrow(sj) > 0) {
        used <- .extract_symbols(sj$special_programs_json)
        unknown <- setdiff(used, known)
        if (length(unknown) > 0) {
          add(rev, 'quality', 'Q3_uncovered_special_symbol',
            sprintf('symbol(s) used but not in the program map: %s', paste(unknown, collapse = ', ')),
            length(unknown))
          unknown_syms[[rev]] <- tibble(revision = rev, symbol = unknown)
        }
      }
    }

    # --- Q4: base_rate_source resolution (only when the column is present) ----
    if (has_src) {
      ur <- tryCatch(ds %>% filter(is.na(base_rate_source) | base_rate_source == 'unresolved') %>%
                       summarise(n = dplyr::n()) %>% collect(), error = function(e) NULL)
      if (!is.null(ur) && ur$n > 0) {
        add(rev, 'quality', 'Q4_unresolved_base_rate_line',
            sprintf('%d active line(s) with no resolved base_rate_source', ur$n), ur$n)
        unresolved[[rev]] <- tibble(revision = rev, n_unresolved = ur$n)
      }
    }

    # --- P3/P4/P5: base provenance-JSON consistency (pushdown str_detect counts) -
    # base_reason / preference_share / preference_source are encoded in
    # duty_provenance_json (helpers.R:1634). They are deterministic functions of
    # (base_rate, statutory_base_rate, country), so the JSON must agree with the
    # columns. A row is "blended" when base_pref_share > 0.005, i.e.
    # base_rate < 0.995 * statutory_base_rate (the same cutoff helpers.R uses to
    # emit a preference_share). All checks are arrow aggregates — no row collect.
    #   P3  blended row carries a preference_share AND a blend reason (not col1)
    #   P4  non-blended row (base == statutory) carries NO preference_share
    #   P5  CA/MX never use the HS2 census blend (must be USMCA HTS10)   [6c guard]
    if ('duty_provenance_json' %in% cols) {
      pj <- tryCatch(ds %>% summarise(
        n_blend_no_share = sum(
          base_rate < statutory_base_rate * 0.995 &
            !str_detect(duty_provenance_json, '"preference_share"'), na.rm = TRUE),
        n_blend_col1 = sum(
          base_rate < statutory_base_rate * 0.995 &
            str_detect(duty_provenance_json, 'base_mfn_col1'), na.rm = TRUE),
        n_col1_with_share = sum(
          base_rate >= statutory_base_rate * 0.995 &
            str_detect(duty_provenance_json, '"preference_share"'), na.rm = TRUE),
        n_camx_hs2 = sum(
          (country == '1220' | country == '2010') &
            str_detect(duty_provenance_json, 'census_mfn_hs2'), na.rm = TRUE)
      ) %>% collect(), error = function(e) NULL)
      if (!is.null(pj)) {
        if (pj$n_blend_no_share > 0) add(rev, 'correctness', 'P3_blend_missing_share',
          sprintf('%d blended row(s) (base<0.995*statutory) with no preference_share in provenance',
                  pj$n_blend_no_share), pj$n_blend_no_share)
        if (pj$n_blend_col1 > 0) add(rev, 'correctness', 'P3_silent_blend',
          sprintf('%d blended row(s) labelled base_mfn_col1 (silent blend)', pj$n_blend_col1),
          pj$n_blend_col1)
        if (pj$n_col1_with_share > 0) add(rev, 'quality', 'P4_col1_with_share',
          sprintf('%d non-blended row(s) (base==statutory) carrying a preference_share',
                  pj$n_col1_with_share), pj$n_col1_with_share)
        if (pj$n_camx_hs2 > 0) add(rev, 'correctness', 'P5_camx_hs2_doublecount',
          sprintf('%d CA/MX row(s) using the HS2 census blend instead of USMCA HTS10 shares',
                  pj$n_camx_hs2), pj$n_camx_hs2)
      }
    }

    summ[[rev]] <- tibble(revision = rev, n_rows = n_rows,
      base_rate_source_present = has_src,
      mean_base = if (!is.null(agg)) round(agg$mean_base, 5) else NA_real_,
      mean_statutory = if (!is.null(agg)) round(agg$mean_stat, 5) else NA_real_)
  }

  # --- Q5/Q6: reference-data band checks (per revision, small CSVs) ----------
  band_check <- function(rev, label, count) {
    b <- .RATE_VALID_BANDS[[label]]; if (is.null(b)) return(invisible())
    if (count < b[1] || count > b[2]) add(rev, 'quality', paste0('band_', label),
      sprintf('%s count %d outside expected [%d, %d]', label, count, b[1], b[2]), count)
  }
  if (!is.null(gn_sym)) for (rev in unique(gn_sym$revision))
    band_check(rev, 'symbols', length(unique(gn_sym$symbol[gn_sym$revision == rev])))
  if (!is.null(gn_col2)) for (rev in unique(gn_col2$revision)) {
    nm <- unique(gn_col2$country_name[gn_col2$revision == rev])
    band_check(rev, 'column2', length(nm))
    if (has_matcher) {                                   # all Column 2 names must map to a census code
      m <- tryCatch(match_countries_to_census(nm), error = function(e) NULL)
      if (!is.null(m)) { miss <- m$country_name[is.na(m$census_code)]
        if (length(miss) > 0) add(rev, 'quality', 'Q5_column2_unmapped',
          sprintf('Column 2 name(s) with no census code: %s', paste(miss, collapse = ', ')), length(miss)) }
    }
  }
  if (!is.null(gn_ben)) {
    bb <- gn_ben %>% filter(!is.na(census_code)) %>% count(revision, program)
    for (i in seq_len(nrow(bb))) band_check(bb$revision[i], bb$program[i], bb$n[i])
  }

  # --- write outputs + console box -------------------------------------------
  viol_df <- if (length(viol)) bind_rows(viol) else
    tibble(revision = character(), severity = character(), invariant = character(),
           detail = character(), n_rows = integer())
  summ_df <- if (length(summ)) bind_rows(summ) else tibble()
  readr::write_csv(viol_df, file.path(output_dir, 'rate_reconciliation_base.csv'))
  if (nrow(summ_df) > 0) readr::write_csv(summ_df, file.path(output_dir, 'rate_reconciliation_base_summary.csv'))
  readr::write_csv(if (length(unresolved)) bind_rows(unresolved) else
                     tibble(revision = character(), n_unresolved = integer()),
                   file.path(output_dir, 'rate_lines_unresolved.csv'))
  readr::write_csv(if (length(unknown_syms)) bind_rows(unknown_syms) else
                     tibble(revision = character(), symbol = character()),
                   file.path(output_dir, 'rate_unknown_symbols.csv'))

  n_corr <- sum(viol_df$severity == 'correctness')
  n_qual <- sum(viol_df$severity == 'quality')
  message('\n  +- Rate validation (', length(parts), ' revisions) ',
          strrep('-', max(3, 30 - nchar(as.character(length(parts))))))
  message('  |   correctness violations : ', n_corr, if (n_corr == 0) '   (ok)' else '   (!!)')
  message('  |   quality / band flags   : ', n_qual, if (n_qual == 0) '   (ok)' else '   (review)')
  message('  |   output/quality/rate_reconciliation_base.csv (', nrow(viol_df), ' rows)')
  message('  +-', strrep('-', 46))

  strict <- identical(Sys.getenv('SAIL_VALIDATE_RATES', ''), 'strict')
  if (strict && n_corr > 0) {
    stop('SAIL_VALIDATE_RATES=strict: ', n_corr, ' correctness violation(s) — see ',
         file.path(output_dir, 'rate_reconciliation_base.csv'))
  }
  invisible(viol_df)
}

# Direct run: Rscript src/emit_rate_validation.R
if (sys.nframe() == 0) emit_rate_validation()

# =============================================================================
# emit_ch99_attribution.R — is every applied duty traceable to a provision?
# =============================================================================
#
# WHAT THIS ANSWERS
#
# For each revision and each authority: how many rated rows name the Chapter 99
# heading that carries their duty, how many do not, and — the sharper question —
# how many name a heading that CONTRADICTS the duty they carry.
#
# WHY IT EXISTS
#
# ch99_code_* used to be produced by inference: choose the heading whose
# published rate equals the rate already computed, breaking ties alphabetically.
# That is unfalsifiable from the output alone — a wrong heading and a right one
# are the same shape. Two long-lived defects came from it:
#
#   9903.94.01 on auto PARTS   .01 is vehicles, .05 is parts, both 25%, so the
#                              rate could not separate them and .01 won the tie
#   9903.41.05 on solar        alphabetically the first §201 heading in
#                              2025_rev_20 — a Japanese leather provision
#
# The headings are now RECORDED where the duty is applied. This report is how we
# see whether that actually holds across the corpus, and it is deliberately
# report-only: it never aborts a build, so one pass shows the whole residual
# instead of one failure per rebuild.
#
# THE TWO INVARIANTS
#
#   rate_contradiction   the cited heading's published rate disagrees with the
#                        rate charged, with no citation explaining it. This is
#                        what a filer would be challenged on.
#   scope_contradiction  the cited heading's product scope excludes the row's
#                        HTS10. Catches 9903.94.01-on-parts,
#                        9903.74.01-on-machinery and 9903.41.05-on-solar as ONE
#                        assertion, and holds for provisions not yet written.
#
# Usage:
#   Rscript -e "source('src/emit_ch99_attribution.R'); emit_ch99_attribution()"
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})

# Authority rate column -> the ch99 code column that should justify it.
.CH99_AUTHORITY_PAIRS <- tibble::tribble(
  ~authority,      ~rate_col,             ~code_col,
  's232',          'rate_232',            'ch99_code_232',
  's301',          'rate_301',            'ch99_code_301',
  'ieepa_recip',   'rate_ieepa_recip',    'ch99_code_ieepa_recip',
  'ieepa_fent',    'rate_ieepa_fent',     'ch99_code_ieepa_fent',
  's122',          'rate_s122',           'ch99_code_s122',
  's201',          'rate_section_201',    'ch99_code_s201'
)


#' Report Chapter 99 attribution coverage and contradictions
#'
#' @param output_dir Where to write ch99_attribution.csv
#' @param parquet_root Partitioned rate timeseries root
#' @param ch99_dir Directory holding ch99_<revision>.rds (for published rates
#'   and heading descriptions)
#' @return tibble, invisibly
emit_ch99_attribution <- function(
    output_dir   = here::here('output', 'quality'),
    parquet_root = here::here('data', 'timeseries', 'rate_timeseries_parquet'),
    ch99_dir     = here::here('data', 'timeseries')) {

  dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  if (!requireNamespace('arrow', quietly = TRUE)) {
    message('  [ch99-attrib] arrow unavailable — skipped'); return(invisible(NULL))
  }
  parts <- list.files(parquet_root, pattern = '^revision=', full.names = TRUE)
  if (length(parts) == 0) {
    message('  [ch99-attrib] no parquet partitions'); return(invisible(NULL))
  }

  has_scope <- tryCatch({
    suppressMessages(source(here::here('src', 'resolve_product_scope.R')))
    TRUE
  }, error = function(e) FALSE)

  out <- list()

  for (p in parts) {
    rev <- sub('^revision=', '', basename(p))
    tb <- tryCatch(arrow::open_dataset(p) %>% collect(), error = function(e) NULL)
    if (is.null(tb) || nrow(tb) == 0) next

    ch99 <- tryCatch(
      readRDS(file.path(ch99_dir, paste0('ch99_', rev, '.rds'))),
      error = function(e) NULL)
    pub <- if (!is.null(ch99) && all(c('ch99_code', 'rate') %in% names(ch99))) {
      ch99 %>% filter(!is.na(ch99_code)) %>%
        group_by(ch99_code) %>%
        summarise(pub_rate = suppressWarnings(max(rate, na.rm = TRUE)),
                  descr = first(description[!is.na(description)]),
                  .groups = 'drop') %>%
        mutate(pub_rate = if_else(is.finite(pub_rate), pub_rate, NA_real_))
    } else {
      tibble(ch99_code = character(0), pub_rate = numeric(0), descr = character(0))
    }

    for (i in seq_len(nrow(.CH99_AUTHORITY_PAIRS))) {
      a  <- .CH99_AUTHORITY_PAIRS$authority[i]
      rc <- .CH99_AUTHORITY_PAIRS$rate_col[i]
      cc <- .CH99_AUTHORITY_PAIRS$code_col[i]
      if (!rc %in% names(tb)) next

      rated <- tb[!is.na(tb[[rc]]) & tb[[rc]] > 0, , drop = FALSE]
      if (nrow(rated) == 0) next
      code <- if (cc %in% names(rated)) rated[[cc]] else rep(NA_character_, nrow(rated))

      n_rated <- nrow(rated)
      n_attr  <- sum(!is.na(code))

      # Invariant 1 — the heading must not contradict the rate it justifies.
      j <- match(code, pub$ch99_code)
      pr <- pub$pub_rate[j]
      contradict <- !is.na(code) & !is.na(pr) &
        abs(pr - rated[[rc]]) > 1e-9
      # A heading absent from the revision cannot justify anything.
      absent <- !is.na(code) & is.na(j)

      # Invariant 2 — the heading's product scope must include this HTS10.
      n_scope_bad <- NA_integer_
      if (has_scope && 'hts10' %in% names(rated) && nrow(pub) > 0) {
        n_scope_bad <- tryCatch({
          cand <- unique(code[!is.na(code)])
          bad <- 0L
          for (cd in cand) {
            d <- pub$descr[match(cd, pub$ch99_code)]
            if (is.na(d)) next
            sc <- extract_covered_subheadings(d)
            # Only headings that STATE their product reach can be checked. A
            # heading deferring to a note ('by_note') is not evidence of a
            # violation — silence is not a contradiction.
            if (sc$status != 'explicit' || length(sc$prefixes) == 0) next
            idx <- which(code == cd)
            h <- rated$hts10[idx]
            ok <- rep(FALSE, length(h))
            for (pfx in sc$prefixes) ok <- ok | startsWith(h, pfx)
            bad <- bad + sum(!ok)
          }
          as.integer(bad)
        }, error = function(e) NA_integer_)
      }

      out[[length(out) + 1L]] <- tibble(
        revision = rev, authority = a,
        rated_rows = n_rated,
        attributed = n_attr,
        unattributed = n_rated - n_attr,
        pct_attributed = round(100 * n_attr / max(n_rated, 1), 1),
        heading_absent_in_revision = sum(absent),
        rate_contradiction = sum(contradict),
        scope_contradiction = n_scope_bad,
        distinct_headings = dplyr::n_distinct(code[!is.na(code)])
      )
    }
  }

  res <- if (length(out)) bind_rows(out) else tibble()
  f <- file.path(output_dir, 'ch99_attribution.csv')
  readr::write_csv(res, f)

  if (nrow(res) > 0) {
    tot <- res %>% summarise(
      rated = sum(rated_rows), attr = sum(attributed),
      unattr = sum(unattributed),
      rate_bad = sum(rate_contradiction, na.rm = TRUE),
      scope_bad = sum(scope_contradiction, na.rm = TRUE),
      absent = sum(heading_absent_in_revision, na.rm = TRUE))
    message('  [ch99-attrib] ', nrow(res), ' revision x authority rows -> ',
            basename(f))
    message('    rated ', tot$rated, ' | attributed ', tot$attr,
            ' (', round(100 * tot$attr / max(tot$rated, 1), 1), '%)',
            ' | unattributed ', tot$unattr)
    message('    contradictions: rate ', tot$rate_bad, ', scope ', tot$scope_bad,
            ', heading absent ', tot$absent)
    worst <- res %>% filter(unattributed > 0) %>%
      arrange(desc(unattributed)) %>% head(5)
    if (nrow(worst) > 0) {
      message('    largest unattributed residuals:')
      for (k in seq_len(nrow(worst))) {
        message('      ', worst$revision[k], ' ', worst$authority[k], ': ',
                worst$unattributed[k], ' of ', worst$rated_rows[k])
      }
    }
  } else {
    message('  [ch99-attrib] no rated rows found')
  }
  invisible(res)
}

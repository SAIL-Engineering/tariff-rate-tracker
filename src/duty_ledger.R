# =============================================================================
# duty_ledger.R — forward provenance for every duty write
# =============================================================================
#
# WHY THIS EXISTS
#
# `06_calculate_rates.R` mutates 14 shared authority scalars across ~175
# assignment sites, then reconstructs provenance BACKWARDS from the final number
# with a case_when (`helpers.R:2226`). That inference cannot succeed: it sees a
# rate of 0.104375 and has no way to know it is an EU 15% floor that a later
# auto-rebate credit added 1.2375pp back onto. It emits `other_ch99` with
# `ch99_code: null`, and 100% of §232-rated rows in 2026_rev_13 carry duty that
# exceeds the sum of their per-action columns.
#
# Reverse-engineering a 42-step mutation chain from its output is not a method.
# Four hypotheses were needed to explain one 152-row class, three of them wrong.
#
# So: record forward. Every write to an authority rate appends to a ledger with
# the step that made it, the legal provision authorising it, and the citation
# key. "Why does this row owe X, under what text" becomes a lookup.
#
# COST MODEL
#
# Two tiers, because a full per-row ledger over 4.9M rows x 175 sites is 850M
# records and is not affordable:
#
#   ALWAYS ON   per-step aggregate — rows touched, rows changed, sum, non-zero
#               count, and the citation key. One vectorised comparison per call.
#               This alone answers "which step touched these rows".
#
#   OPT-IN      full per-row values, for a named set of (hts10, country) pairs.
#               This is what trace_row() reads. Costs nothing when unset.
#
# Instrumentation RECORDS, it must never COMPUTE. A parquet diff before/after
# instrumenting must be byte-identical; any rate delta is a bug in the ledger.
# =============================================================================

.duty_ledger <- new.env(parent = emptyenv())

#' Reset the ledger and choose which rows to trace in full
#'
#' @param trace_rows Optional data frame with hts10 + country columns. Rows
#'   matching any pair are recorded value-by-value at every step. NULL disables
#'   per-row capture and leaves only the aggregate tier.
#' @param revision,effective_date Stamped onto every record, because the same
#'   provision carries different rates and scopes in different revisions —
#'   provenance without the revision is not provenance.
duty_ledger_init <- function(trace_rows = NULL, revision = NA_character_,
                             effective_date = NA) {
  .duty_ledger$steps      <- list()
  .duty_ledger$rows       <- list()
  .duty_ledger$prev       <- list()
  .duty_ledger$trace      <- trace_rows
  .duty_ledger$revision   <- revision
  .duty_ledger$eff_date   <- as.character(effective_date)
  .duty_ledger$seq        <- 0L
  invisible(NULL)
}

duty_ledger_active <- function() !is.null(.duty_ledger$steps)

#' Record a write to an authority rate column
#'
#' Call AFTER the mutation. Reads the column's current value, diffs it against
#' the value seen at the previous record_duty() call for that column, and logs
#' what changed.
#'
#' @param df Rate frame, returned unchanged — this is a pass-through so it can
#'   be dropped into a pipe without restructuring the caller
#' @param step Pipeline step label, e.g. '4c' or '6e'. Must match the numbering
#'   already used in the 06_calculate_rates.R comments.
#' @param authority Program key: s232, ieepa_recip, ieepa_fent, s301, s122,
#'   s201, s301fl, s301br, s338, adcvd, base, column2, other
#' @param rate_col The column just written
#' @param reason Machine-readable cause, e.g. 'deal_floor_eu', 'auto_rebate'
#' @param citation_key Key into config/legal_reference.yaml. NA is permitted but
#'   is itself a finding — a duty with no citable authority.
#' @param note_ref US Note subdivision, e.g. 'note_33(r)'
#' @param ch99_code_col Column holding the Chapter 99 heading, when one applies
#' @return df, unchanged
record_duty <- function(df, step, authority, rate_col, reason,
                        citation_key = NA_character_, note_ref = NA_character_,
                        ch99_code_col = NULL) {
  if (!duty_ledger_active() || is.null(df) || nrow(df) == 0) return(df)
  if (!rate_col %in% names(df)) return(df)

  cur  <- df[[rate_col]]
  cur[is.na(cur)] <- 0
  prev <- .duty_ledger$prev[[rate_col]]
  if (is.null(prev) || length(prev) != length(cur)) prev <- rep(0, length(cur))
  changed <- abs(cur - prev) > 1e-12

  .duty_ledger$seq <- .duty_ledger$seq + 1L
  .duty_ledger$steps[[length(.duty_ledger$steps) + 1L]] <- list(
    seq = .duty_ledger$seq, step = step, authority = authority,
    rate_col = rate_col, reason = reason, citation_key = citation_key,
    note_ref = note_ref, revision = .duty_ledger$revision,
    effective_date = .duty_ledger$eff_date,
    n_rows = length(cur), n_changed = sum(changed),
    n_nonzero = sum(cur > 0), sum_rate = sum(cur),
    delta_sum = sum(cur - prev)
  )

  tr <- .duty_ledger$trace
  if (!is.null(tr) && nrow(tr) > 0 && all(c('hts10', 'country') %in% names(df))) {
    hit <- which(paste0(df$hts10, '|', df$country) %in%
                   paste0(tr$hts10, '|', tr$country))
    if (length(hit) > 0) {
      code <- if (!is.null(ch99_code_col) && ch99_code_col %in% names(df))
        df[[ch99_code_col]][hit] else NA_character_
      .duty_ledger$rows[[length(.duty_ledger$rows) + 1L]] <- tibble::tibble(
        seq = .duty_ledger$seq, step = step, authority = authority,
        rate_col = rate_col, reason = reason, citation_key = citation_key,
        note_ref = note_ref, revision = .duty_ledger$revision,
        hts10 = df$hts10[hit], country = df$country[hit],
        ch99_code = code, before = prev[hit], after = cur[hit],
        changed = changed[hit]
      )
    }
  }

  .duty_ledger$prev[[rate_col]] <- cur
  df
}

#' The per-step aggregate ledger
duty_ledger_steps <- function() {
  if (!duty_ledger_active() || length(.duty_ledger$steps) == 0)
    return(tibble::tibble())
  dplyr::bind_rows(lapply(.duty_ledger$steps, tibble::as_tibble))
}

#' The per-row ledger for traced rows
duty_ledger_rows <- function() {
  if (!duty_ledger_active() || length(.duty_ledger$rows) == 0)
    return(tibble::tibble())
  dplyr::bind_rows(.duty_ledger$rows)
}

#' Print the duty chain for one row
#'
#' Answers "why does this row owe this, under what legal text" by replaying the
#' writes in order. Only steps that CHANGED the value are shown by default —
#' a 42-step chain where 38 steps were no-ops is noise.
#'
#' @param hts10,country The row. `country` is the census code, not ISO.
#' @param all Show every recorded step, including no-ops
trace_row <- function(hts10, country, all = FALSE) {
  r <- duty_ledger_rows()
  if (nrow(r) == 0) {
    message('No per-row ledger. Call duty_ledger_init(trace_rows = ...) before the build.')
    return(invisible(NULL))
  }
  r <- r[r$hts10 == hts10 & r$country == country, ]
  if (!isTRUE(all)) r <- r[r$changed, ]
  if (nrow(r) == 0) {
    message('No recorded writes for ', hts10, '/', country,
            if (!all) ' (no step changed a value; pass all = TRUE)' else '')
    return(invisible(NULL))
  }
  r <- r[order(r$seq), ]
  message('\n', hts10, ' / ', country, '   revision ', r$revision[1])
  message(strrep('-', 108))
  message(sprintf('%-5s %-6s %-14s %-26s %10s %10s  %s',
                  'seq', 'step', 'authority', 'reason', 'before', 'after', 'citation / note'))
  for (i in seq_len(nrow(r))) {
    cite <- paste(na.omit(c(r$citation_key[i], r$note_ref[i])), collapse = ' / ')
    if (!nzchar(cite)) cite <- '*** NO CITATION ***'
    message(sprintf('%-5d %-6s %-14s %-26s %10.6f %10.6f  %s',
                    r$seq[i], r$step[i], r$authority[i], substr(r$reason[i], 1, 26),
                    r$before[i], r$after[i], cite))
  }
  message(strrep('-', 108))
  invisible(r)
}

#' Persist the ledger for this revision
#'
#' The build runs in its own process, so an in-memory ledger dies with it. Both
#' tiers are written per revision: the aggregate step table always, the per-row
#' table only when tracing was armed.
#'
#' @param dir Output directory; created if absent
#' @param revision Revision id, defaulting to the one passed to init
duty_ledger_save <- function(dir = here::here('output', 'provenance'),
                             revision = NULL) {
  if (!duty_ledger_active()) return(invisible(NULL))
  rev <- revision %||% .duty_ledger$revision %||% 'unknown'
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)

  steps <- duty_ledger_steps()
  if (nrow(steps) > 0) {
    readr::write_csv(steps, file.path(dir, paste0('duty_steps_', rev, '.csv')))
    n_uncited <- nrow(duty_ledger_uncited())
    message('  Duty ledger: ', nrow(steps), ' step(s) recorded',
            if (n_uncited > 0) paste0(', ', n_uncited,
              ' wrote duty with NO citation') else '',
            ' -> output/provenance/duty_steps_', rev, '.csv')
  }
  rows <- duty_ledger_rows()
  if (nrow(rows) > 0) {
    readr::write_csv(rows, file.path(dir, paste0('duty_rows_', rev, '.csv')))
    message('  Duty ledger: ', nrow(rows), ' traced row-write(s) -> ',
            'output/provenance/duty_rows_', rev, '.csv')
  }
  invisible(NULL)
}

#' Replay a saved per-row ledger without re-running the build
#'
#' @param revision Revision id
#' @param dir Provenance directory
duty_ledger_load <- function(revision, dir = here::here('output', 'provenance')) {
  f <- file.path(dir, paste0('duty_rows_', revision, '.csv'))
  if (!file.exists(f)) {
    message('No saved row ledger for ', revision, ' at ', f)
    return(invisible(NULL))
  }
  if (is.null(.duty_ledger$steps)) duty_ledger_init(revision = revision)
  .duty_ledger$rows <- list(suppressMessages(
    readr::read_csv(f, col_types = readr::cols(hts10 = readr::col_character(),
                                               country = readr::col_character(),
                                               .default = readr::col_guess()))))
  invisible(TRUE)
}


#' Steps that wrote a duty without naming a legal authority
#'
#' A non-zero duty with no citation_key is the defect this whole exercise is
#' about. Reported as a table rather than a warning so it can be triaged.
duty_ledger_uncited <- function() {
  s <- duty_ledger_steps()
  if (nrow(s) == 0) return(s)
  s[is.na(s$citation_key) & s$n_changed > 0 & s$delta_sum != 0,
    c('seq', 'step', 'authority', 'rate_col', 'reason', 'n_changed', 'delta_sum')]
}

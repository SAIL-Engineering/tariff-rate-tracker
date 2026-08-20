# =============================================================================
# validate_rate_constants.R — no config rate may silently shadow or outlive the law
# =============================================================================
#
# THE PROBLEM
#
# config/policy_params.yaml carries 36 hardcoded rate constants — solar_rate, 13
# section_232 default_rate, 18 s301_rate, floors, uk_rate. NONE carries a
# citation or an effective date:
#
#     grep -c 'citation_key' config/policy_params.yaml   ->  0
#
# Two failure modes follow, and both have already happened:
#
#   SHADOWING   A constant silently replaces the rate the HTS publishes. Measured
#               on 2025_rev_20: the HTS carries the solar safeguard at 30%,
#               section_201.solar_rate forces 14.5%, and the build logs the
#               substitution as though it were routine. We do not know how many
#               of the other 35 diverge, because nothing compares them.
#
#   STALENESS   A constant that was right on the day it was written keeps being
#               applied after the law moves. solar_rate's own comment states the
#               obligation and provides no enforcement:
#
#                 "- 2025-02-07 -> 2026-02-07 (Year 8 of extension): 14.5%
#                  - update annually based on USTR notice"
#
#               A safeguard that steps down annually, encoded as a bare number,
#               is wrong every year that nobody remembers.
#
# THE RULE
#
# A config rate may exist, because some rates genuinely are not in the HTS. What
# it may not do is diverge from a published rate without saying why, or outlive
# its own authority. So each constant declares:
#
#     value           the rate
#     citation_key    resolves in config/legal_reference.yaml
#     effective_from  when it starts
#     effective_to    when it stops  (or review_by, for open-ended rates)
#
# and the build refuses to apply one that is expired, out of window, or diverging
# without a citation. The anti-staleness rule is the important one:
#
#     an OPEN-ENDED constant is allowed only while it AGREES with the HTS.
#     The moment it diverges it needs a window, because divergence is a claim
#     about a specific period and claims expire.
#
# This file validates and reports; it does not itself change any rate.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

#' Every rate-like constant in policy params, with its config path
#'
#' Walks the parsed YAML rather than matching text, so a constant added in a new
#' section is picked up without editing this function.
#'
#' @param pp Parsed policy params
#' @return tibble(config_key, value, citation_key, effective_from, effective_to,
#'   review_by, ch99_pattern)
collect_rate_constants <- function(pp) {
  out <- list()
  .is_rate_name <- function(nm) {
    grepl('(^|_)(rate|floor_rate|uk_rate|s301_rate|solar_rate|default_rate)$', nm)
  }
  walk_node <- function(node, path) {
    if (is.null(node)) return(invisible(NULL))
    # Data frames are leaf data (loaded resource tables), not config structure —
    # descending into them yields column names, and `node$value` on one warns.
    if (is.data.frame(node)) return(invisible(NULL))
    # A declared constant: a list carrying `value`
    if (is.list(node) && !is.null(node[['value']]) && is.numeric(node[['value']])) {
      out[[length(out) + 1L]] <<- tibble(
        config_key     = path,
        value          = as.numeric(node$value),
        citation_key   = node$citation_key %||% NA_character_,
        effective_from = as.character(node$effective_from %||% NA),
        effective_to   = as.character(node$effective_to %||% NA),
        review_by      = as.character(node$review_by %||% NA),
        ch99_pattern   = node$ch99_pattern %||% NA_character_)
      return(invisible(NULL))
    }
    if (is.list(node)) {
      nms <- names(node)
      for (i in seq_along(node)) {
        nm <- if (!is.null(nms)) nms[i] else as.character(i)
        child <- node[[i]]
        sub <- if (nzchar(path)) paste0(path, '.', nm) else nm
        # A bare numeric under a rate-shaped name: an UNDECLARED constant. Record
        # it — the absence of metadata is exactly what we are looking for.
        if (is.numeric(child) && length(child) == 1 && .is_rate_name(nm)) {
          sibling_pat <- if (is.list(node)) node$ch99_pattern %||% NA_character_ else NA_character_
          out[[length(out) + 1L]] <<- tibble(
            config_key = sub, value = as.numeric(child),
            citation_key = NA_character_, effective_from = NA_character_,
            effective_to = NA_character_, review_by = NA_character_,
            ch99_pattern = sibling_pat)
        } else if (is.list(child)) {
          walk_node(child, sub)
        }
      }
    }
    invisible(NULL)
  }
  walk_node(pp, '')
  if (length(out) == 0) return(tibble())
  bind_rows(out) %>% distinct(config_key, .keep_all = TRUE)
}


#' Reconcile constants against the published HTS rate and their own validity window
#'
#' @param pp Parsed policy params
#' @param ch99_data Per-revision Chapter 99 table (needs ch99_code, rate)
#' @param revision Revision id
#' @param effective_date The revision's effective date
#' @param legal_reference_keys Known citation keys, for resolvability
#' @return tibble with one row per constant and a `status`
reconcile_rate_constants <- function(pp, ch99_data = NULL, revision = NA_character_,
                                     effective_date = NULL,
                                     legal_reference_keys = character(0)) {
  k <- collect_rate_constants(pp)
  if (nrow(k) == 0) return(tibble())

  # The published rate, where the constant names a Chapter 99 heading.
  k$hts_rate <- NA_real_
  if (!is.null(ch99_data) && all(c('ch99_code', 'rate') %in% names(ch99_data))) {
    for (i in seq_len(nrow(k))) {
      pat <- k$ch99_pattern[i]
      if (is.na(pat) || !nzchar(pat)) next
      hit <- ch99_data$rate[startsWith(ch99_data$ch99_code, pat)]
      hit <- hit[!is.na(hit)]
      if (length(hit) > 0) k$hts_rate[i] <- hit[1]
    }
  }

  eff <- if (is.null(effective_date)) NA else as.Date(effective_date)
  as_d <- function(x) suppressWarnings(as.Date(x))

  k %>%
    mutate(
      revision   = revision,
      delta      = hts_rate - value,
      diverges   = !is.na(hts_rate) & abs(hts_rate - value) > 1e-9,
      comparable = !is.na(hts_rate),
      cited      = !is.na(citation_key) & nzchar(citation_key),
      citation_resolves = cited &
        (length(legal_reference_keys) == 0 | citation_key %in% legal_reference_keys),
      windowed   = !is.na(effective_from) | !is.na(effective_to),
      expired    = !is.na(effective_to) & !is.na(eff) & eff > as_d(effective_to),
      not_yet    = !is.na(effective_from) & !is.na(eff) & eff < as_d(effective_from),
      overdue_review = !is.na(review_by) & !is.na(eff) & eff > as_d(review_by),
      status = case_when(
        expired                        ~ 'FAIL_EXPIRED',
        not_yet                        ~ 'FAIL_NOT_YET_EFFECTIVE',
        # The anti-staleness rule: divergence is a claim about a period, so an
        # open-ended constant may not diverge from the published rate.
        diverges & !windowed           ~ 'FAIL_OPEN_ENDED_DIVERGENCE',
        diverges & !cited              ~ 'FAIL_UNCITED_DIVERGENCE',
        diverges & cited & !citation_resolves ~ 'FAIL_CITATION_UNRESOLVABLE',
        overdue_review                 ~ 'WARN_REVIEW_OVERDUE',
        diverges & cited               ~ 'OK_CITED_DIVERGENCE',
        comparable & !diverges         ~ 'OK_MATCHES_HTS',
        TRUE                           ~ 'UNCOMPARED_NO_HTS_COUNTERPART'
      )) %>%
    select(revision, config_key, value, hts_rate, delta, citation_key,
           effective_from, effective_to, review_by, status)
}


#' Report, persist, and optionally fail the build
#'
#' @param fail_on_error Stop when any FAIL_* status is present
report_rate_constants <- function(pp, ch99_data = NULL, revision = NA_character_,
                                  effective_date = NULL,
                                  legal_reference_keys = character(0),
                                  fail_on_error = FALSE,
                                  out_dir = here::here('output', 'quality')) {
  r <- reconcile_rate_constants(pp, ch99_data, revision, effective_date,
                                legal_reference_keys)
  if (nrow(r) == 0) return(invisible(r))

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  f <- file.path(out_dir, 'rate_overrides.csv')
  readr::write_csv(r, f, append = file.exists(f) && !is.na(revision))

  n_fail <- sum(grepl('^FAIL_', r$status))
  n_warn <- sum(grepl('^WARN_', r$status))
  n_unc  <- sum(r$status == 'UNCOMPARED_NO_HTS_COUNTERPART')
  message('  Rate constants: ', nrow(r), ' checked | ', n_fail, ' FAIL, ',
          n_warn, ' WARN, ', n_unc, ' with no HTS counterpart to compare')
  if (n_fail > 0 || n_warn > 0) {
    bad <- r[grepl('^(FAIL|WARN)_', r$status), ]
    for (i in seq_len(min(8, nrow(bad)))) {
      message(sprintf('    %-30s %-30s config=%.4f hts=%s',
                      bad$status[i], bad$config_key[i], bad$value[i],
                      if (is.na(bad$hts_rate[i])) 'n/a' else sprintf('%.4f', bad$hts_rate[i])))
    }
  }
  if (isTRUE(fail_on_error) && n_fail > 0) {
    stop('rate constant validation failed on ', n_fail, ' constant(s); see ', f,
         call. = FALSE)
  }
  invisible(r)
}

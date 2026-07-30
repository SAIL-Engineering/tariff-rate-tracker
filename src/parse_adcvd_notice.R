# =============================================================================
# parse_adcvd_notice.R — read Commerce AD/CVD notices from the Federal Register
# =============================================================================
#
# Two hard truths shape this layer, and both are why we never assert a single
# AD/CVD rate for an HTS x country:
#
#   1. SCOPE IS NARRATIVE. Commerce defines an order's scope in prose; the HTS
#      numbers listed in a notice are expressly "provided for convenience and
#      customs purposes" and are NOT dispositive. Whether a given article falls
#      inside a scope is a factual determination we cannot make from the tariff
#      line alone.
#   2. RATES ARE FIRM-SPECIFIC. Every producer/exporter carries its own margin,
#      plus an "all-others" rate, and administrative reviews reset cash-deposit
#      rates roughly annually per case. A single rate column on an order goes
#      stale by construction — which is the flaw in the upstream template this
#      replaces.
#
# So the output is a determination-grade CANDIDATE, not an asserted duty, and
# the rates are a TIME SERIES keyed by (case, exporter, effective_from).
#
# Notice titles follow a rigid grammar, which is what makes this parseable:
#   "{Product} From {Country}: {Amended Final|Final} Results of
#    {Antidumping|Countervailing} Duty Administrative Review; {period}"
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

#' Parse a Commerce AD/CVD notice title
#'
#' @param title Federal Register document title
#' @return list(product, country, duty_type, notice_kind, period) — fields NA
#'   when the title does not match the administrative-review grammar
parse_adcvd_title <- function(title) {
  out <- list(product = NA_character_, country = NA_character_,
              duty_type = NA_character_, notice_kind = NA_character_,
              period = NA_character_)
  if (is.na(title) || !nzchar(title)) return(out)

  # "Initiation of ..." notices announce reviews rather than set rates. They
  # carry no rate table and must not be mistaken for results.
  if (grepl('^Initiation of', title, ignore.case = TRUE)) {
    out$notice_kind <- 'initiation'
    return(out)
  }

  m <- regmatches(title, regexec(
    '^(.+?)\\s+From\\s+(.+?):\\s*(.*?)(Antidumping|Countervailing)\\s+Duty',
    title, perl = TRUE))[[1]]
  if (length(m) >= 5) {
    out$product   <- trimws(m[2])
    out$country   <- trimws(m[3])
    out$duty_type <- if (grepl('^Anti', m[5], ignore.case = TRUE)) 'AD' else 'CVD'
    pre <- tolower(m[4])
    # The whole title after the colon, so ORDER-lifecycle notices — which carry
    # no "Results of" clause — can be told apart. These are what define the
    # order UNIVERSE, as distinct from the review notices that reset rates:
    #
    #   order         establishes an order        "…: Antidumping Duty Order"
    #   continuation  keeps it alive post-sunset  "…: Continuation of …Order"
    #   revocation    ends it                     "…: Revocation of …Order"
    #
    # Active universe = established + continued − revoked. That is derivable
    # entirely from the Federal Register, which matters because the ITA dataset
    # API is unreachable and the ADCVD search app is a Blazor server app with no
    # public JSON endpoint. It is also self-maintaining: an order created in
    # 2027 arrives as a new notice with no code change.
    tail_txt <- tolower(sub('^.*?:\\s*', '', title))
    out$notice_kind <-
      if (grepl('amended final', pre))                      'amended_final'
      else if (grepl('final', pre))                         'final'
      else if (grepl('prelim', pre))                        'preliminary'
      else if (grepl('revocation|revoking', tail_txt))      'revocation'
      else if (grepl('continuation', tail_txt))             'continuation'
      else if (grepl('duty order\\s*$', tail_txt))          'order'
      else 'other'
  }
  p <- regmatches(title, regexec(';\\s*(\\d{4}[-–]\\d{4})', title))[[1]]
  if (length(p) >= 2) out$period <- gsub('–', '-', p[2])
  out
}


#' Extract the per-exporter rate table from a notice's raw text
#'
#' Commerce lays these out as a producer/exporter name followed by a
#' weighted-average margin. Rates are percentages in the notice and are
#' returned as decimals.
#'
#' @param txt Raw text of the Federal Register document
#' @return tibble(exporter, rate, is_all_others)
parse_adcvd_rates <- function(txt) {
  empty <- tibble(exporter = character(), rate = numeric(),
                  is_all_others = logical())
  if (is.na(txt) || !nzchar(txt)) return(empty)

  lines <- strsplit(txt, '\n', fixed = TRUE)[[1]]
  m <- regmatches(lines, regexec(
    '^(.{5,90}?)[\\s\\.]{2,}([0-9]{1,3}\\.[0-9]{2})\\s*$', lines, perl = TRUE))
  keep <- lengths(m) >= 3
  if (!any(keep)) return(empty)

  nm  <- vapply(m[keep], function(x) trimws(x[2]), character(1))
  val <- vapply(m[keep], function(x) as.numeric(x[3]), numeric(1))

  # Strip footnote markers ("\10\") and FR entity escapes that survive the
  # text dump ("Asociaci[oacute]n").
  nm <- gsub('\\\\[0-9]+\\\\', '', nm)
  nm <- gsub('\\[([a-z]+)\\]', '', nm)
  nm <- trimws(gsub('\\s{2,}', ' ', nm))

  # Drop rows that are clearly not company names: pure numbers, period ranges,
  # or table furniture.
  # Bracket expressions here use POSIX classes: R's default TRE engine does not
  # accept \s inside brackets, and a trailing \- reads as an invalid range.
  drop <- grepl('^[0-9[:space:]/-]+$', nm) |
    grepl('^(Period|Total|Table|Rate|Margin|Percent)', nm, ignore.case = TRUE) |
    nchar(nm) < 4
  nm <- nm[!drop]; val <- val[!drop]
  if (length(nm) == 0) return(empty)

  tibble(
    exporter = nm,
    rate = val / 100,
    # The residual rate applying to firms without their own margin. Naming
    # varies by case type and source, and is NOT one canonical string:
    #   market economy      "All Others"
    #   administrative rev. "Review-Specific Rate for Non-Examined Companies"
    #   non-market economy  "<Country>-Wide Entity" — "China-Wide Entity",
    #                       "PRC-Wide Entity", "Vietnam-Wide Entity"
    #   Avalara payloads    "ALL COMPANIES" (manufactureName on adds[]/cvds[])
    #
    # The NME form is the rate an unlisted Chinese exporter actually pays and is
    # routinely the highest in the table. "ALL COMPANIES" was found in real
    # cached Avalara data — 8483308040/CN and 8483908080/CN both carry an ADD of
    # 93% under that name — and the earlier pattern missed it, which would have
    # filed the residual rate as if it were one firm's specific margin.
    is_all_others = grepl(
      paste0('all[- ]others|all companies|non-examined|review-specific|',
             '[a-z]+-wide entity|country-wide'),
      nm, ignore.case = TRUE)
  ) %>% distinct(exporter, .keep_all = TRUE)
}


#' Should this notice update cash-deposit rates?
#'
#' Preliminary results and initiation notices do not set the operative rate.
#' Treating them as authoritative would churn the series with numbers that are
#' later superseded.
is_rate_setting_notice <- function(notice_kind) {
  !is.na(notice_kind) & notice_kind %in% c('final', 'amended_final')
}

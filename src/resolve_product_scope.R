# =============================================================================
# resolve_product_scope.R — which PRODUCTS a Chapter 99 heading covers
# =============================================================================
#
# The country-scope counterpart is resolve_country_scope.R. This answers the
# other half of the determination: given a Chapter 99 heading, which tariff
# lines does it reach?
#
# WHY IT MATTERS
#
# A heading with a rate and a country but no product linkage cannot attach to
# anything, so its duty is silently never collected. That is the state of the
# §201 washing-machine safeguard today: the schedule publishes its rates
# (note 17(d)/(e), now in resources/ch99_staged_rates.csv) and its term, but
# nothing maps it to an HTS10, so it has never applied — including during
# 2018-2023 when it was live.
#
# The existing answer is a hand-curated CSV per program
# (resources/s201_solar_products.csv covers 3 HTS10s). That does not scale and
# goes stale the same way a hardcoded rate does.
#
# THE SCOPE IS IN THE TEXT
#
# Chapter 99 headings state their own product reach:
#
#   "Household-type (residential) washing machines ... (as defined in note
#    17(c) to this subchapter and provided for in subheading 8450.11.00 or
#    8450.20.00)"
#   "Parts ... provided for in subheading 8450.90.20 or 8450.90.60"
#   "Bovine ... leather (provided for in heading 4104 or 4107)"
#
# Measured on 2025_rev_20: 358 of 625 headings name their covered subheadings
# this way, including 168 of the 247 RATED headings.
#
# THE TRAP
#
# The same phrase introduces Chapter 99 CROSS-REFERENCES, which are exclusions,
# not product scope:
#
#   9903.01.25  "... except for products provided for in headings 9903.01.34
#                and 9903.02.01"
#
# Treating those as covered products would scope a heading to other Chapter 99
# headings — nonsense that would silently match nothing (or worse, match a
# 9903 line). A covered product is never in chapter 99, so the two are
# separable by the chapter number alone.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

#' Extract the product subheadings a Chapter 99 heading covers
#'
#' @param description Heading description text
#' @return list(prefixes, ch99_refs, note_ref, status)
#'   status is 'explicit' when subheadings are named, 'by_note' when the text
#'   defers to a note subdivision ("enumerated in subdivision (g) of this
#'   note"), and 'none' otherwise. `by_note` is NOT a failure — it says where
#'   to look — but it must be visible, because an unresolved by_note heading
#'   covers nothing.
extract_covered_subheadings <- function(description) {
  out <- list(prefixes = character(0), ch99_refs = character(0),
              note_ref = NA_character_, status = 'none')
  if (is.null(description) || is.na(description) || !nzchar(description)) return(out)

  # "provided for in subheading 8450.11.00 or 8450.20.00", "in heading 4104 or 4107"
  pat <- 'provided for in (?:sub)?headings?\\s+([0-9][0-9.,   or and]*)'
  hits <- regmatches(description, gregexpr(pat, description, perl = TRUE,
                                           ignore.case = TRUE))[[1]]
  codes <- character(0)
  for (h in hits) {
    codes <- c(codes, unlist(regmatches(h, gregexpr('[0-9]{4}(?:\\.[0-9]{2}){0,3}', h))))
  }
  codes <- unique(trimws(codes))

  # Chapter 99 codes here are cross-references (exclusions), never products.
  is99 <- startsWith(codes, '99')
  out$ch99_refs <- codes[is99]
  out$prefixes  <- gsub('\\.', '', codes[!is99])   # 8450.11.00 -> 84501100

  # Scope delegated to a note subdivision.
  nm <- regmatches(description, regexec(
    '(?:enumerated|described|set forth) in subdivision \\(([a-z]+)\\) (?:of|to) (?:this )?(?:U\\.S\\. )?note(?:\\s+(\\d+))?',
    description, ignore.case = TRUE))[[1]]
  if (length(nm) >= 2) {
    out$note_ref <- if (length(nm) >= 3 && nzchar(nm[3]))
      sprintf('note_%s(%s)', nm[3], nm[2]) else sprintf('subdivision_(%s)', nm[2])
  }

  out$status <- if (length(out$prefixes) > 0) 'explicit'
                else if (!is.na(out$note_ref)) 'by_note'
                else 'none'
  out
}


#' Which HTS10s does a Chapter 99 heading cover?
#'
#' Prefix match against the real product universe, so a 4-digit heading
#' ("heading 4104") expands to every line beneath it and a 10-digit subheading
#' matches exactly.
#'
#' @param description Heading description
#' @param hts10 Character vector of HTS10 codes in the revision
#' @return Character vector of matching HTS10s
covered_hts10 <- function(description, hts10) {
  sc <- extract_covered_subheadings(description)
  if (length(sc$prefixes) == 0) return(character(0))
  keep <- rep(FALSE, length(hts10))
  for (p in sc$prefixes) keep <- keep | startsWith(hts10, p)
  unique(hts10[keep])
}


#' Resolve product scope across the HTS INDENT HIERARCHY
#'
#' Product scope inherits exactly as country scope does, and for the same
#' reason: the parent states what the group covers, the children state the
#' tiers. The §201 safeguards are entirely this shape —
#'
#'   (no code) indent 0  "Household-type (residential) washing machines ...
#'                        provided for in subheading 8450.11.00 or 8450.20.00:"
#'   9903.45.01 indent 1 "If entered in an aggregate quantity ..."       14%
#'   9903.45.02 indent 1 "Other"                                         30%
#'
#' Reading only the leaf returns nothing, which is why 203 of 247 rated headings
#' appear to cover no products — including every §201 heading, the reason that
#' program has only ever applied through a hand-curated 3-row CSV.
#'
#' @param df Chapter 99 rows in document order INCLUDING unnumbered parents,
#'   with `description` and integer `indent`
#' @param hts10 Product universe for the revision (dotless)
#' @return df plus prefixes (list), n_products, scope_status, scope_source
resolve_product_scope_hierarchical <- function(df, hts10 = character(0)) {
  stopifnot(all(c('description', 'indent') %in% names(df)))
  n <- nrow(df)
  ind <- suppressWarnings(as.integer(df$indent))

  sc <- lapply(df$description, extract_covered_subheadings)
  prefixes <- lapply(sc, `[[`, 'prefixes')
  status   <- vapply(sc, `[[`, character(1), 'status')
  src      <- ifelse(status == 'explicit', 'own_text', NA_character_)

  for (k in seq_len(n)) {
    if (length(prefixes[[k]]) > 0) next
    if (is.na(ind[k]) || ind[k] <= 0) next
    j <- k - 1L; depth <- ind[k]
    while (j >= 1L) {
      if (!is.na(ind[j]) && ind[j] < depth) {
        if (length(prefixes[[j]]) > 0) {
          prefixes[[k]] <- prefixes[[j]]
          status[k] <- 'inherited'
          src[k] <- 'inherited'
          break
        }
        depth <- ind[j]
      }
      j <- j - 1L
    }
  }

  df$prefixes <- prefixes
  df$scope_status <- status
  df$scope_source <- src
  df$n_products <- vapply(prefixes, function(p) {
    if (length(p) == 0 || length(hts10) == 0) return(0L)
    keep <- rep(FALSE, length(hts10))
    for (x in p) keep <- keep | startsWith(hts10, x)
    sum(keep)
  }, integer(1))
  df
}


#' Product-scope coverage report for a revision
#'
#' Reports what each RATED heading covers and — the point — which rated
#' headings cover nothing, since those carry duty that can never attach.
#'
#' @param ch99_data Parsed Chapter 99 table
#' @param hts10 Product universe for the revision
#' @return tibble(ch99_code, rate, scope_status, n_products, note_ref)
report_product_scope <- function(ch99_data, hts10) {
  rated <- ch99_data[!is.na(ch99_data$rate) & ch99_data$rate > 0, , drop = FALSE]
  if (nrow(rated) == 0) return(tibble())
  map_dfr(seq_len(nrow(rated)), function(i) {
    sc <- extract_covered_subheadings(rated$description[i])
    n <- if (length(sc$prefixes) > 0)
      length(covered_hts10(rated$description[i], hts10)) else 0L
    tibble(ch99_code = rated$ch99_code[i], rate = rated$rate[i],
           scope_status = sc$status, n_products = n,
           note_ref = sc$note_ref)
  })
}

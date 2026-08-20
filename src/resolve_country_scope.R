# =============================================================================
# resolve_country_scope.R — one country-scope resolver for all Chapter 99 text
# =============================================================================
#
# WHY THIS EXISTS
#
# Three separate implementations recovered country scope from tariff-line prose,
# each with its own hardcoded country list and its own closed set of sentence
# patterns:
#
#   03_parse_chapter99.R:43   parse_countries()                  literal cascade
#   03_parse_chapter99.R:166  extract_country_names()            25-country map
#   05_parse_policy_params.R:90 extract_countries_from_description()
#                                                                closed terminators
#
# Meanwhile resources/census_codes.csv holds 241 countries and
# resources/country_name_aliases.csv holds the spelling variants. Both are
# maintained. Neither was used by the first two.
#
# The failure mode is structural, not incidental. From parse_countries()'s own
# comment, describing the last time this broke:
#
#   "That branch used to consult a hardcoded 7-country shortlist ... and, for any
#    country NOT on it, returned type='all' with an EMPTY country list —
#    silently converting a country-specific duty into a blanket all-countries
#    rate ... In 2026 rev_13 that mis-scoped 53 rated headings."
#
# Measured instances of the same class in the current corpus: §201 drops 18 of 20
# safeguard headings every revision; IEEPA drops 5-10. Examples:
#
#   "product of Brazil that (1) were loaded"    'that are' != 'that (1) were'
#   "derivative products, of Brazil, as ..."    a comma breaks 'product of'
#
# TWO CHANGES OF PRINCIPLE
#
# 1. MATCH THE UNIVERSE, NOT THE SENTENCE. Detect that a description is
#    country-scoped, then find which of the 241 known countries appear anywhere
#    in it. Legal drafting varies without limit; the set of countries does not.
#    A phrasing we have never seen cannot break this, and adding a country is a
#    data edit to census_codes.csv.
#
# 2. THREE OUTCOMES, NEVER A SILENT DEFAULT.
#
#      country_scoped      known countries found            -> apply to them
#      not_country_scoped  scope is by product or end use   -> NOT a failure
#      unresolved          scope intent, no country found   -> fail closed AND report
#
#    Collapsing the last two is why a civil-aircraft heading (9903.01.82, scoped
#    by product) is counted as a parse failure beside a genuine miss, and why the
#    "18 of 20" figure cannot be acted on.
#
# CASE SENSITIVITY IS LOAD-BEARING
#
# Country names are matched CASE-SENSITIVELY against the original text. Several
# country names are also ordinary nouns — "china" (porcelain, ch. 69), "turkey"
# (poultry, ch. 2). HTS descriptions capitalise country names and lowercase the
# nouns, so case separates them with no ambiguity list to maintain. Matching
# case-insensitively would scope every porcelain heading to China.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
})

.country_universe_cache <- new.env(parent = emptyenv())

#' Normalise text so a name matches however the HTS typeset it
#'
#' The corpus mixes typographic and ASCII punctuation and carries diacritics:
#' "Côte d'Ivoire" in a heading vs "Cote d'Ivoire" in census_codes.csv, and
#' curly apostrophes in FTZ provisions ("privileged foreign status"). Neither is
#' a country-specific problem, so neither gets a country-specific fix.
#'
#' BOTH the universe names and the description pass through this, so matching
#' happens in one normalised space and character offsets stay internally
#' consistent for the overlap logic in `find_countries_in_text()`.
.normalize_text <- function(x) {
  if (length(x) == 0) return(x)
  x <- gsub('[‘’ʼ´`]', "'", x)      # curly/acute apostrophes
  x <- gsub('[“”]', '"', x)                    # curly double quotes
  x <- gsub('[‐-―]', '-', x)                   # dashes
  # Diacritic folding. Applied to both sides, so "Côte" and "Cote" meet.
  y <- iconv(x, 'UTF-8', 'ASCII//TRANSLIT')
  ifelse(is.na(y), x, y)
}

#' The country universe: every name we can recognise, longest first
#'
#' One row per NAME, with `census_codes` a list column, because a name may denote
#' a group: "European Union" resolves to 27 origins. Modelling groups as data in
#' the same table — rather than as a branch in the resolver — is what keeps a new
#' bloc (or a change in EU membership) a config edit instead of a code change.
#'
#' Longest-first ordering is required so "Democratic Republic of the Congo" wins
#' over "Congo", and "Republic of Korea" over "Korea". Shorter names falling
#' inside a longer match are dropped in `find_countries_in_text()`.
#'
#' @return tibble(name, census_codes (list), source), longest name first
load_country_universe <- function(
    census_path = here::here('resources', 'census_codes.csv'),
    alias_path  = here::here('resources', 'country_name_aliases.csv'),
    policy_params = NULL) {
  key <- paste(census_path, alias_path,
               file.mtime(census_path), file.mtime(alias_path))
  if (!is.null(.country_universe_cache[[key]])) return(.country_universe_cache[[key]])

  census <- suppressMessages(readr::read_csv(
    census_path, col_types = readr::cols(.default = readr::col_character())))
  names(census) <- tolower(names(census))
  u <- tibble(name = trimws(census$name),
              census_codes = as.list(trimws(census$code)),
              source = 'census')

  # --- Split parenthetical composites -------------------------------------
  # 15 census names carry both a short and a formal name in one string:
  #   "South Korea (Republic of Korea)"   "Burma (Myanmar)"
  #   "Syria (Syrian Arab Republic)"      "Germany (Federal Republic of Germany)"
  # Legal text uses ONE of the two, never the composite, so the composite form
  # matches nothing. Splitting is a rule about the FILE FORMAT, not about any
  # particular country — it covers all 15 and any added later.
  paren <- u %>% filter(grepl('\\(', name))
  if (nrow(paren) > 0) {
    split_rows <- paren %>%
      mutate(outer = trimws(sub('\\s*\\(.*$', '', name)),
             inner = trimws(gsub('^[^(]*\\(|\\)\\s*$', '', name))) %>%
      { bind_rows(
          transmute(., name = outer, census_codes, source = 'census_short'),
          transmute(., name = inner, census_codes, source = 'census_formal')) } %>%
      filter(nzchar(name))
    u <- bind_rows(u, split_rows)
  }

  if (file.exists(alias_path)) {
    al <- suppressMessages(readr::read_csv(
      alias_path, col_types = readr::cols(.default = readr::col_character())))
    if (all(c('gn_name', 'census_code') %in% names(al))) {
      u <- bind_rows(u, tibble(name = trimws(al$gn_name),
                               census_codes = as.list(trimws(al$census_code)),
                               source = 'alias'))
    }
  }

  # --- Supranational groups -------------------------------------------------
  # A Chapter 99 heading may be scoped to a bloc rather than a state: "articles
  # the product of a member state of the European Union". The bloc is not in
  # census_codes.csv because it is not an origin, so it must come from the
  # membership data the pipeline already maintains (policy_params$eu27_codes).
  # Adding a bloc is a config edit; the resolver needs no branch for it.
  pp <- policy_params
  if (is.null(pp)) pp <- tryCatch(load_policy_params(), error = function(e) NULL)
  eu <- NULL
  if (!is.null(pp)) eu <- pp$EU27_CODES %||% pp$eu27_codes
  if (length(eu) > 0) {
    eu_codes <- as.character(if (!is.null(names(eu))) names(eu) else eu)
    eu_codes <- eu_codes[nzchar(eu_codes)]
    if (length(eu_codes) > 0) {
      u <- bind_rows(u, tibble(
        name = c('European Union', 'a member state of the European Union'),
        census_codes = list(eu_codes, eu_codes),
        source = 'group'))
    }
  }

  u <- u %>%
    mutate(name = .normalize_text(name)) %>%
    filter(!is.na(name), nzchar(name), lengths(census_codes) > 0) %>%
    distinct(name, .keep_all = TRUE) %>%
    mutate(.n = nchar(name)) %>%
    arrange(desc(.n)) %>%
    select(-.n)

  .country_universe_cache[[key]] <- u
  u
}


#' Signals that a description is scoped BY COUNTRY at all
#'
#' Deliberately loose. This decides only whether country scope is *intended*;
#' WHICH country is then answered by matching the universe, not by this pattern.
#' That split is the point — the old code had to parse the country out of the
#' sentence, so every new phrasing was a new failure.
#' A proper noun may follow, optionally behind articles/prepositions:
#'   "product of Brazil"                        -> Brazil
#'   "product of the Democratic Republic of ..." -> the ... Democratic
#'   "products of iron or steel"                -> iron  (lowercase: NOT a country)
#' Capitalisation is what separates a country from a material or an end use, and
#' it needs no maintained list of materials to stay correct.
.PROPER_NOUN_AFTER <- '(?:the\\s+|a\\s+|an\\s+|any\\s+)*[A-Z]'

.COUNTRY_SCOPE_INTENT <- paste0(
  '(?:',
  paste(
    paste0('products?,?\\s+of\\s+', .PROPER_NOUN_AFTER),
    paste0('origin(?:ating)?\\s+in\\s+', .PROPER_NOUN_AFTER),
    'member\\s+state\\s+of\\b',
    'country[- ]wide\\b',
    'of\\s+any\\s+country\\b',
    sep = '|'),
  ')')

#' Find every known country named in a text
#'
#' @param text Description text, ORIGINAL CASE (see header note)
#' @param universe From load_country_universe()
#' @return tibble(name, census_code, start, end) with overlaps removed
find_countries_in_text <- function(text, universe = load_country_universe()) {
  empty <- tibble(name = character(), census_codes = list(),
                  start = integer(), end = integer())
  if (is.null(text) || is.na(text) || !nzchar(text)) return(empty)
  text <- .normalize_text(text)

  hits <- list()
  claimed <- rep(FALSE, nchar(text))   # character positions already matched

  for (i in seq_len(nrow(universe))) {
    nm <- universe$name[i]
    # Word-bounded, case-SENSITIVE, literal (country names contain "." and "(")
    pat <- paste0('(?<![A-Za-z])', stringr::str_escape(nm), '(?![A-Za-z])')
    m <- stringr::str_locate_all(text, stringr::regex(pat))[[1]]
    if (nrow(m) == 0) next
    for (r in seq_len(nrow(m))) {
      s <- m[r, 'start']; e <- m[r, 'end']
      # Longest-first ordering means an overlap is always a shorter name sitting
      # inside a longer one already taken — e.g. "Congo" inside "Democratic
      # Republic of the Congo", or "Ireland" inside "a member state of the
      # European Union" is not an overlap but "Union" inside it would be.
      if (any(claimed[s:e])) next
      claimed[s:e] <- TRUE
      hits[[length(hits) + 1L]] <- tibble(
        name = nm, census_codes = universe$census_codes[i],
        start = as.integer(s), end = as.integer(e))
    }
  }
  if (length(hits) == 0) return(empty)
  bind_rows(hits) %>% arrange(start)
}


#' Resolve the country scope of one Chapter 99 description
#'
#' @param description Description text, original case
#' @param universe Optional preloaded universe
#' @return list(outcome, census_codes, country_names, evidence, has_intent)
resolve_country_scope <- function(description, universe = load_country_universe()) {
  out <- list(outcome = 'unresolved', census_codes = character(0),
              country_names = character(0), evidence = character(0),
              has_intent = FALSE)
  if (is.null(description) || is.na(description) || !nzchar(description)) {
    out$outcome <- 'not_country_scoped'
    return(out)
  }

  ndesc <- .normalize_text(description)
  # isTRUE(): str_detect returns NA on text it cannot decode, and `if (NA)` is an
  # error. An undecodable description is not evidence of country intent.
  has_intent <- isTRUE(stringr::str_detect(
    ndesc, stringr::regex(.COUNTRY_SCOPE_INTENT)))
  out$has_intent <- has_intent

  found <- find_countries_in_text(ndesc, universe)

  if (nrow(found) > 0) {
    out$outcome       <- 'country_scoped'
    out$census_codes  <- unique(unlist(found$census_codes))
    out$country_names <- unique(found$name)
    out$evidence      <- unique(found$name)
    return(out)
  }

  # No country named. "of any country" is an explicit ALL-countries scope, not a
  # failure — it is how the notes write a universal provision.
  if (isTRUE(stringr::str_detect(ndesc,
        stringr::regex('of\\s+any\\s+country', ignore_case = TRUE)))) {
    out$outcome  <- 'country_scoped'
    out$evidence <- 'of any country'
    return(out)   # empty census_codes = all origins; caller expands
  }

  # Intent to scope by country, but no country resolvable -> genuine failure,
  # reported individually. Without intent, the heading is scoped by product or
  # end use (civil aircraft, ADP machines) and there is nothing to fail.
  out$outcome <- if (has_intent) 'unresolved' else 'not_country_scoped'
  out
}


#' Resolve scope across the HTS INDENT HIERARCHY
#'
#' The tariff schedule is a tree. An unnumbered parent line carries the country
#' scope and the numbered children inherit it:
#'
#'   (no code) indent 0   "New pneumatic tires, of rubber, the foregoing the
#'                         product China, under the terms of note 14..."
#'   9903.40.05 indent 1  "Radial tires of a kind used on motor cars..."   25%
#'
#'   (no code) indent 0   "Articles the product of Japan:"
#'   9903.41.15 indent 1  "Automatic data processing machines..."         100%
#'
#' Reading only the leaf leaves those headings looking scope-less, which is why
#' §201 reported 18 of 20 "unresolved" and why a 100% Japan retaliation rate
#' looked like a global duty on computers. Measured on 2025_rev_20: 254 of 625
#' headings are scoped by their own text and a further **226 only through a
#' parent** — 36% of the chapter, silently lost.
#'
#' Requires DOCUMENT ORDER, so it takes the whole table rather than one string.
#'
#' @param df Chapter 99 rows in document order, including unnumbered parent
#'   lines, with `description` and integer `indent`
#' @param universe Optional preloaded universe
#' @return df plus outcome, census_codes, country_names, scope_source
#'   ('own_text' | 'inherited' | NA)
resolve_country_scope_hierarchical <- function(df, universe = load_country_universe()) {
  stopifnot(all(c('description', 'indent') %in% names(df)))
  n <- nrow(df)
  ind <- suppressWarnings(as.integer(df$indent))

  own <- resolve_country_scope_vec(df$description, universe)
  outcome <- own$outcome
  codes   <- own$census_codes
  names_  <- own$country_names
  src     <- ifelse(outcome == 'country_scoped', 'own_text', NA_character_)

  # Nearest preceding line at a SHALLOWER indent that resolved to countries.
  # Walking upward (rather than taking the immediately preceding line) is what
  # makes this correct for nested lists, where a child sits several lines below
  # its scoping ancestor.
  for (k in seq_len(n)) {
    if (outcome[k] == 'country_scoped') next
    if (is.na(ind[k]) || ind[k] <= 0) next
    j <- k - 1L
    depth <- ind[k]
    while (j >= 1L) {
      if (!is.na(ind[j]) && ind[j] < depth) {
        if (outcome[j] == 'country_scoped' && src[j] %in% c('own_text', 'inherited')) {
          outcome[k] <- 'country_scoped'
          codes[[k]] <- codes[[j]]
          names_[[k]] <- names_[[j]]
          src[k] <- 'inherited'
          break
        }
        depth <- ind[j]        # keep climbing past a non-scoping ancestor
      }
      j <- j - 1L
    }
  }

  df$outcome       <- outcome
  df$census_codes  <- codes
  df$country_names <- names_
  df$scope_source  <- src
  df
}


#' Vectorised wrapper
#'
#' @return tibble(outcome, census_codes (list), country_names (list), has_intent)
resolve_country_scope_vec <- function(descriptions,
                                      universe = load_country_universe()) {
  res <- lapply(descriptions, resolve_country_scope, universe = universe)
  tibble(
    outcome       = vapply(res, `[[`, character(1), 'outcome'),
    census_codes  = lapply(res, `[[`, 'census_codes'),
    country_names = lapply(res, `[[`, 'country_names'),
    has_intent    = vapply(res, `[[`, logical(1), 'has_intent')
  )
}

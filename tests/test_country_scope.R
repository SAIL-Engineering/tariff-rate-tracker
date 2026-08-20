# =============================================================================
# test_country_scope.R — country scope resolves against the universe, not patterns
# =============================================================================
# Run: Rscript tests/test_country_scope.R
#
# The tests that matter here are INVARIANTS, not per-country cases. The defect
# being fixed was a closed pattern set over hardcoded country lists, so a suite
# of "does Brazil work / does India work" cases would reproduce the same
# brittleness one layer up. Specific headings appear only at the end, as
# regression guards.
#
# Corpus effect measured while building this (unresolved AND rate > 0):
#   2019_rev_11  52 -> 0     2025_rev_20  84 -> 0
#   2025_rev_11  82 -> 0     2026_rev_13  88 -> 0
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'helpers.R'))
source(here('src', 'resolve_country_scope.R'))

.pass <- 0L; .fail <- 0L
run_test <- function(desc, expr) {
  ok <- tryCatch({ force(expr); TRUE }, error = function(e) {
    message('  FAIL: ', desc, ' — ', conditionMessage(e)); FALSE })
  if (ok) { message('  PASS: ', desc); .pass <<- .pass + 1L } else .fail <<- .fail + 1L
}

U <- load_country_universe()

message('\n--- The universe is data, not code ---')

run_test('every census country is recognised, not a hand-picked subset', {
  census <- suppressMessages(readr::read_csv(
    here('resources', 'census_codes.csv'),
    col_types = readr::cols(.default = readr::col_character())))
  names(census) <- tolower(names(census))
  # The old extract_country_names() knew 25 names; census_codes.csv holds 241.
  stopifnot(nrow(U) >= nrow(census))
  # Spot the property, not the members: a name drawn from the file resolves.
  for (i in c(5, 60, 120, 200)) {
    nm <- .normalize_text(trimws(census$name[i]))
    nm <- sub('\\s*\\(.*$', '', nm)          # short form of a composite
    r <- resolve_country_scope(paste0('Articles the product of ', nm,
                                      ', as provided for in note 2'))
    if (r$outcome != 'country_scoped')
      stop('census row ', i, ' (', nm, ') did not resolve')
  }
})

run_test('parenthetical census names resolve by EITHER of their two forms', {
  # "South Korea (Republic of Korea)" — legal text uses one or the other, never
  # the composite. This is a rule about the file format, so it must hold for all
  # 15 such rows, not just Korea.
  paren <- U %>% filter(source %in% c('census_short', 'census_formal'))
  stopifnot(nrow(paren) >= 20)   # 15 composites x 2 forms
  for (nm in c('South Korea', 'Republic of Korea', 'Burma', 'Myanmar')) {
    r <- resolve_country_scope(paste0('articles the product of ', nm, ', as provided'))
    if (r$outcome != 'country_scoped') stop('did not resolve: ', nm)
  }
})

run_test('a supranational bloc expands to its member origins', {
  r <- resolve_country_scope(
    'articles the product of a member state of the European Union, as provided')
  stopifnot(r$outcome == 'country_scoped')
  stopifnot(length(r$census_codes) > 20)   # EU-27
})

message('\n--- Invariants that hold for text we have never seen ---')

run_test('an unseen sentence shape still resolves — the terminator set is gone', {
  # Each of these broke the old closed-terminator regex. They are here as SHAPES,
  # and any future shape must work for the same reason: the country is found by
  # identity, not by parsing the sentence around it.
  shapes <- c(
    'Articles the product of Brazil that (1) were loaded onto a vessel',
    'derivative products, of India, as provided in subdivision (z)(iii)',
    'articles the product of Japan; provided that the importer certifies',
    'goods of Norway entered under any provision of this subchapter',
    'articles the product of Chile — see subdivision (q)')
  for (s in shapes) {
    r <- resolve_country_scope(s)
    if (r$outcome != 'country_scoped') stop('unresolved shape: ', s)
  }
})

run_test('a country is matched however the HTS typesets it', {
  # Diacritics and typographic punctuation are an encoding problem, not a
  # country problem, so the fix must be general.
  for (s in c('articles the product of Türkiye, as provided for in U.S. note 52',
              'articles the product of Côte d’Ivoire, as provided for in note 2')) {
    r <- resolve_country_scope(s)
    if (r$outcome != 'country_scoped') stop('typography defeated the match: ', s)
  }
})

message('\n--- The three outcomes are distinct ---')

run_test('a product-scoped heading is NOT a parse failure', {
  # This is the distinction that made "18 of 20 dropped" unactionable: a §201
  # safeguard covers a PRODUCT across all origins. Reporting it as a failure
  # buried the genuine misses among it.
  for (s in c('Radial tires of a kind used on motor cars (other than racing cars)',
              'Automatic data processing machines, of the type of which the units',
              'Articles of civil aircraft; their engines, parts, and components',
              'If entered in an aggregate quantity, in any quarterly period')) {
    r <- resolve_country_scope(s)
    if (r$outcome != 'not_country_scoped')
      stop('product scope misread as ', r$outcome, ': ', s)
  }
})

run_test('a MATERIAL after "products of" is not read as a country', {
  # "Products of iron or steel" is intent-shaped but names a material. Capital
  # letters separate the two without a maintained list of materials.
  r <- resolve_country_scope(
    'Products of iron or steel provided for in subdivision (j) of note 16, admitted to a foreign trade zone')
  stopifnot(r$outcome == 'not_country_scoped')
  stopifnot(length(r$census_codes) == 0)
})

run_test('an ordinary noun that is also a country name does not scope the heading', {
  # "china" the porcelain, "turkey" the poultry. Case is the discriminator.
  for (s in c('Ceramic tableware and kitchenware, of china, other than porcelain',
              'Meat of turkey, fresh or chilled, not cut in pieces')) {
    r <- resolve_country_scope(s)
    if (r$outcome == 'country_scoped')
      stop('common noun scoped as a country: ', s)
  }
})

run_test('an explicit all-countries provision is scoped, not unresolved', {
  r <- resolve_country_scope(
    'Articles the product of any country, as provided for in subdivision (v)(iii)(b)')
  stopifnot(r$outcome == 'country_scoped')
})

run_test('country intent with no resolvable country stays UNRESOLVED, not blanket', {
  # The failure mode recorded in parse_countries()' own comment: an unknown
  # country silently became "all countries", converting a targeted duty into a
  # global one. It must fail closed instead.
  r <- resolve_country_scope(
    'articles the product of Wakanda, as provided for in U.S. note 2')
  stopifnot(r$outcome == 'unresolved')
  stopifnot(length(r$census_codes) == 0)
})

message('\n--- Longest-match and multi-country handling ---')

run_test('a longer country name wins over one contained inside it', {
  r <- resolve_country_scope(
    'products of the Democratic Republic of the Congo, as provided')
  stopifnot(r$outcome == 'country_scoped')
  stopifnot(length(r$census_codes) == 1)     # not Congo AND DRC
  stopifnot(any(grepl('Democratic', r$country_names)))
})

run_test('two origins on one heading both resolve', {
  r <- resolve_country_scope(
    'articles the product of Cameroon or the Democratic Republic of the Congo')
  stopifnot(r$outcome == 'country_scoped')
  stopifnot(length(r$census_codes) == 2)
})

message('\n--- Scope inherits down the HTS indent hierarchy ---')

# The schedule is a tree. An unnumbered parent carries the country; the numbered
# children carry the rate. Reading only the leaf is why §201 reported 18 of 20
# unresolved, and why a 100% JAPAN retaliation rate looked like a global duty on
# computers. Measured on 2025_rev_20: 262 of 625 headings are scoped ONLY this way.
.hts_fragment <- function() {
  tibble::tibble(
    htsno       = c('',           '9903.40.05', '9903.40.10',
                    '',           '9903.41.05', '9903.41.15',
                    '',           '9903.41.20'),
    indent      = c(0L, 1L, 1L, 0L, 1L, 1L, 1L, 2L),
    description = c(
      'New pneumatic tires, of rubber, the foregoing the product China, under the terms of note 14',
      'Radial tires of a kind used on motor cars (other than racing cars)',
      'Other tires of a kind used on motor cars (other than racing cars)',
      'Articles the product of Japan:',
      'Bovine (including buffalo) and equine leather (provided for in heading 4104)',
      'Automatic data processing machines, of the type of which the constituent units',
      'Automatic data processing machines, of the type of which the constituent units',
      'Having a microprocessor-based calculating mechanism'))
}

run_test('a numbered child inherits the country from its unnumbered parent', {
  r <- resolve_country_scope_hierarchical(.hts_fragment())
  get1 <- function(code) r[r$htsno == code, ][1, ]
  a <- get1('9903.40.05')
  stopifnot(a$outcome == 'country_scoped', a$scope_source == 'inherited')
  stopifnot(identical(a$country_names[[1]], 'China'))
  b <- get1('9903.41.05')
  stopifnot(b$outcome == 'country_scoped', b$scope_source == 'inherited')
  stopifnot(identical(b$country_names[[1]], 'Japan'))
})

run_test('inheritance climbs past intermediate lines to the scoping ancestor', {
  # 9903.41.20 sits at indent 2 under a non-scoping indent-1 line, which sits
  # under the "product of Japan:" parent. A one-step lookback would miss it.
  r <- resolve_country_scope_hierarchical(.hts_fragment())
  x <- r[r$htsno == '9903.41.20', ][1, ]
  stopifnot(x$outcome == 'country_scoped')
  stopifnot(identical(x$country_names[[1]], 'Japan'))
})

run_test('a new parent ends the previous parent’s scope', {
  # China tires must not leak onto the Japan block that follows them.
  r <- resolve_country_scope_hierarchical(.hts_fragment())
  jp <- r[r$htsno %in% c('9903.41.05', '9903.41.15', '9903.41.20'), ]
  for (i in seq_len(nrow(jp))) {
    if (!identical(jp$country_names[[i]], 'Japan'))
      stop('scope leaked across parents at ', jp$htsno[i])
  }
})

run_test('own text still wins over an inherited parent', {
  df <- tibble::tibble(
    htsno = c('', '9903.99.01'), indent = c(0L, 1L),
    description = c('Articles the product of Japan:',
                    'articles the product of Brazil, as provided for in note 2'))
  r <- resolve_country_scope_hierarchical(df)
  x <- r[r$htsno == '9903.99.01', ][1, ]
  stopifnot(x$scope_source == 'own_text')
  stopifnot(identical(x$country_names[[1]], 'Brazil'))
})

run_test('a product-scoped heading under no country parent stays unscoped', {
  df <- tibble::tibble(
    htsno = c('', '9903.45.22'), indent = c(0L, 1L),
    description = c('Crystalline silicon photovoltaic cells:',
                    'If entered during the period from February 7, 2025'))
  r <- resolve_country_scope_hierarchical(df)
  x <- r[r$htsno == '9903.45.22', ][1, ]
  stopifnot(x$outcome == 'not_country_scoped')
  stopifnot(is.na(x$scope_source))
})

message('\n--- Regression guards (specific headings, from the logs) ---')

run_test('the headings dropped every revision now classify correctly', {
  cases <- list(
    list(t = 'Articles the product of Brazil that (1) were loaded onto a vessel at the port of loading',
         o = 'country_scoped'),
    list(t = 'Articles the product of India that (1) were loaded onto a vessel',
         o = 'country_scoped'),
    list(t = 'Articles of civil aircraft (all aircraft other than military aircraft); their engines',
         o = 'not_country_scoped'))
  for (cs in cases) {
    r <- resolve_country_scope(cs$t)
    if (r$outcome != cs$o)
      stop('expected ', cs$o, ' got ', r$outcome, ' for: ', substr(cs$t, 1, 50))
  }
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)

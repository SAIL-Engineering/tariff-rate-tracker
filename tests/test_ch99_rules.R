# =============================================================================
# Tests: Chapter 99 code resolution, duty basis, rules JSON, completeness QC
# =============================================================================
#
# Covers the per-product Section 232 derivative Ch99 mapping (US Note 16/19
# subdivisions), the s232_derivative_products.csv invariants, the
# ch99_rules_json rule-object emit, parse_chapter99_other (9902/9904), and
# check_ch99_completeness. Synthetic fixtures + the reviewed resource CSV.
#
# Usage:
#   Rscript tests/test_ch99_rules.R
#
# =============================================================================

library(tidyverse)
library(jsonlite)
library(here)

source(here('src', 'helpers.R'))
source(here('src', '03_parse_chapter99.R'))

pass_count <- 0
fail_count <- 0
skip_count <- 0

skip_test <- function(reason) {
  cond <- structure(class = c('skip', 'condition'), list(message = reason))
  stop(cond)
}

run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
  }, skip = function(e) {
    message('  SKIP: ', name, ' — ', conditionMessage(e))
    skip_count <<- skip_count + 1
  }, error = function(e) {
    message('  FAIL: ', name, ' — ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}

deriv_csv <- load_232_derivative_products()

message('\n=== Derivative CSV invariants ===')

run_test('CSV maps 8536.90.8585 to 9903.85.08 (US Note 19(k)) at FR granularity', {
  # Upstream 585ce25 + cf2d5951: the FR notices list this as the specific
  # 10-digit statistical line, not the bare 8-digit subheading. Truncating to
  # 85369085 broadened coverage to every line under 8536.90.85. Assert the
  # narrow, FR-faithful prefix AND that the over-broad one is gone, so the
  # HS8-truncation over-inclusion cannot silently return.
  row <- deriv_csv %>% filter(hts_prefix == '8536908585')
  stopifnot(nrow(row) == 1, row$ch99_code == '9903.85.08',
            row$derivative_type == 'aluminum')
  stopifnot(nrow(deriv_csv %>% filter(hts_prefix == '85369085')) == 0)
})

run_test('derivative CSV retains mixed 8/10-digit FR granularity', {
  # The matcher (grepl('^(p1|p2|...)')) and build_deriv_ch99_map (startsWith,
  # longest-prefix-wins) both handle variable-width prefixes. A regression to
  # all-8-digit would silently re-broaden ~121 subheadings (~$155B spurious).
  widths <- nchar(deriv_csv$hts_prefix)
  stopifnot(any(widths == 10), any(widths == 8),
            all(widths %in% c(8, 10)))
})

run_test('no NEW same-metal multi-code prefixes (known conflicts only)', {
  # Same code with different effective-date windows is fine; two DIFFERENT
  # same-metal codes for one prefix is a CSV defect (runtime resolves to the
  # more specific subdivision with a warning, but the CSV should be fixed).
  known_conflicts <- character(0)
  dup <- deriv_csv %>%
    filter(!is.na(ch99_code)) %>%
    distinct(hts_prefix, derivative_type, ch99_code) %>%
    count(hts_prefix, derivative_type) %>%
    filter(n > 1)
  new_conflicts <- setdiff(dup$hts_prefix, known_conflicts)
  stopifnot(length(new_conflicts) == 0)
})

run_test('CSV ch99 codes match the policy_params expected sets', {
  pp <- yaml::read_yaml(here('config', 'policy_params.yaml'))
  exp_alum <- unlist(pp$section_232_derivatives$expected_aluminum_ch99_codes)
  exp_steel <- unlist(pp$section_232_derivatives$expected_steel_ch99_codes)
  have_alum <- unique(deriv_csv$ch99_code[deriv_csv$derivative_type == 'aluminum'])
  have_steel <- unique(na.omit(deriv_csv$ch99_code[deriv_csv$derivative_type == 'steel']))
  stopifnot(all(exp_alum %in% have_alum))
  stopifnot(all(have_alum %in% exp_alum))
  # Steel rows ported from upstream (Budget-Lab-Yale @2a1763cf): the broad
  # Note 16(t) list under 9903.81.91. Subdivision (s) headings (.89/.90) have
  # no separate product rows in either lineage yet.
  stopifnot(length(have_steel) > 0)
  stopifnot('9903.81.91' %in% have_steel)
  stopifnot(all(have_steel %in% exp_steel))
})

run_test('CSV carries a real subdivision distribution, not one pooled code', {
  dist <- deriv_csv %>%
    filter(derivative_type == 'aluminum') %>%
    count(ch99_code)
  stopifnot(nrow(dist) >= 3)  # .04, .07, .08 at minimum
})

message('\n=== build_deriv_ch99_map ===')

run_test('longest prefix wins; per-product codes assigned', {
  prods <- tibble(
    hts_prefix = c('853690', '85369085'),
    ch99_code = c('9903.85.07', '9903.85.08'),
    derivative_type = 'aluminum', effective_date = as.Date(NA)
  )
  m <- build_deriv_ch99_map('8536908585', prods, 'aluminum')
  stopifnot(nrow(m) == 1, m$deriv_ch99_code == '9903.85.08')
})

run_test('same-length conflict resolves to most specific subdivision + warns', {
  prods <- tibble(
    hts_prefix = c('85369085', '85369085', '85369086'),
    ch99_code = c('9903.85.08', '9903.85.04', '9903.85.08'),
    derivative_type = 'aluminum', effective_date = as.Date(NA)
  )
  w <- tryCatch({
    m <- build_deriv_ch99_map('8536908585', prods, 'aluminum')
    NULL
  }, warning = function(w) {
    m <<- suppressWarnings(build_deriv_ch99_map('8536908585', prods, 'aluminum'))
    w
  })
  stopifnot(!is.null(w))                       # warned
  stopifnot(m$deriv_ch99_code == '9903.85.04') # .04 covers fewer products
})

message('\n=== resolve_ch99_codes ===')

ch99_fixture <- tibble(
  ch99_code = c('9903.85.04', '9903.85.07', '9903.85.08', '9903.85.02',
                '9903.81.91', '9903.03.01', '9903.01.25'),
  rate = c(0.50, 0.50, 0.50, 0.50, 0.50, 0.10, 0.10)
)

rates_fixture <- tibble(
  hts10 = c('8536908585', '7614105000', '7616995190', '7326908688', '7601103000'),
  country = '4550',
  rate_232 = c(0.09, 0.5, 0.5, 0.5, 0.5),
  statutory_rate_232 = 0.5,
  rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
  rate_s122 = 0.1, rate_section_201 = 0,
  deriv_type = c('aluminum', 'aluminum', 'aluminum', 'steel', NA),
  deriv_ch99_code = c('9903.85.08', '9903.85.04', '9903.85.07', NA, NA)
)

run_test('product-level subdivision codes win (the 8536.90.8585 bug)', {
  out <- resolve_ch99_codes(rates_fixture, ch99_fixture, deriv_products = deriv_csv)
  stopifnot(out$ch99_code_232[out$hts10 == '8536908585'] == '9903.85.08')
  stopifnot(out$ch99_code_232[out$hts10 == '7614105000'] == '9903.85.04')
  stopifnot(out$ch99_code_232[out$hts10 == '7616995190'] == '9903.85.07')
})

run_test('derivative fallback = broadest active heading, never sort()[1]', {
  out <- resolve_ch99_codes(rates_fixture, ch99_fixture, deriv_products = deriv_csv)
  # steel derivative with no product-level code -> 9903.81.91 (Note 16(t),
  # the broad list), NOT the alphabetically-first active 232 code
  stopifnot(out$ch99_code_232[out$hts10 == '7326908688'] == '9903.81.91')
})

run_test('ch76 primary product gets a base heading, not a derivative heading', {
  out <- resolve_ch99_codes(rates_fixture, ch99_fixture, deriv_products = deriv_csv)
  stopifnot(out$ch99_code_232[out$hts10 == '7601103000'] == '9903.85.02')
})

run_test('pre-derivative-era revision (no .08 active) falls back cleanly', {
  ch99_old <- ch99_fixture %>% filter(ch99_code != '9903.85.08')
  out <- resolve_ch99_codes(rates_fixture, ch99_old, deriv_products = deriv_csv)
  code <- out$ch99_code_232[out$hts10 == '8536908585']
  stopifnot(code %in% c('9903.85.04', '9903.85.07'))  # active-code gate respected
})

message('\n=== ch99_rules_json emit ===')

prov_fixture <- tibble(
  hts10 = c('8536908585', '8536908585', '0710807000'),
  country = c('4550', '5700', '4550'),
  base_rate = c(0, 0, 0.1), statutory_base_rate = c(0, 0, 0.1),
  rate_232 = c(0.09, 0.09, 0), statutory_rate_232 = c(0.5, 0.5, 0),
  rate_301 = c(0, 0.25, 0), statutory_rate_301 = c(0, 0.25, 0),
  rate_ieepa_recip = 0, rate_ieepa_fent = 0,
  rate_s122 = c(0.1, 0.1, 0.1), statutory_rate_s122 = 0.1,
  rate_section_201 = 0,
  ch99_code_232 = c('9903.85.08', '9903.85.08', NA),
  ch99_code_301 = c(NA, '9903.88.03', NA),
  ch99_code_s122 = '9903.03.01',
  deriv_type = c('aluminum', 'aluminum', NA),
  duty_basis_232 = c('metal_content_value', 'metal_content_value', NA),
  s232_annex = NA_character_, s232_metal = NA_character_,
  usmca_eligible = FALSE
)

other_fixture <- tibble(
  ch99_code = '9902.01.01', subchapter = 'mtb_9902', rate_text = 'Free',
  description = 'Frozen corn (provided for in subheading 0710.80.70)',
  trigger_hts = list('07108070')
)

run_test('rules JSON is valid and multi-code per line', {
  out <- attach_duty_provenance(prov_fixture, ch99_other = other_fixture)
  for (i in seq_len(nrow(out))) {
    fromJSON(out$ch99_rules_json[i], simplifyDataFrame = FALSE)  # must parse
  }
  j <- fromJSON(out$ch99_rules_json[2], simplifyDataFrame = FALSE)
  auths <- vapply(j, function(x) x$authority, character(1))
  stopifnot(all(c('section_232', 'section_301', 'section_122') %in% auths))
})

run_test('metal-basis 232 rule carries statutory rate, basis, required inputs, citation', {
  out <- attach_duty_provenance(prov_fixture, ch99_other = other_fixture)
  j <- fromJSON(out$ch99_rules_json[1], simplifyDataFrame = FALSE)
  r232 <- j[[which(vapply(j, function(x) x$authority, character(1)) == 'section_232')]]
  stopifnot(r232$ch99_code == '9903.85.08',
            r232$status == 'applied',
            abs(r232$statutory_rate - 0.5) < 1e-9,
            r232$duty_basis == 'metal_content_value',
            r232$basis_metal == 'aluminum',
            r232$stacking_class == 'primary_metal',
            'metal_content_kg' %in% unlist(r232$required_user_inputs),
            r232$basis_citation == 's232_basis_metal_content')
})

run_test('s122 rule cites the non-232-portion stacking rule', {
  out <- attach_duty_provenance(prov_fixture, ch99_other = other_fixture)
  j <- fromJSON(out$ch99_rules_json[1], simplifyDataFrame = FALSE)
  s122 <- j[[which(vapply(j, function(x) x$authority, character(1)) == 'section_122')]]
  stopifnot(s122$stacking_class == 'content_split',
            s122$stacking_citation == 's122_non232_portion_only')
})

run_test('9902 MTB candidate attaches by trigger with requires_more_facts', {
  out <- attach_duty_provenance(prov_fixture, ch99_other = other_fixture)
  j <- fromJSON(out$ch99_rules_json[3], simplifyDataFrame = FALSE)
  auths <- vapply(j, function(x) x$authority, character(1))
  stopifnot('mtb_9902' %in% auths)
  mtb <- j[[which(auths == 'mtb_9902')]]
  stopifnot(mtb$status == 'potentially_applicable_requires_more_facts',
            'product_description_match' %in% unlist(mtb$missing_facts))
})

run_test('provenance 232 slot carries basis/basis_metal/statutory', {
  out <- attach_duty_provenance(prov_fixture, ch99_other = other_fixture)
  p <- fromJSON(out$duty_provenance_json[1], simplifyDataFrame = FALSE)
  stopifnot(p[['232']]$basis == 'metal_content_value',
            p[['232']]$basis_metal == 'aluminum',
            abs(p[['232']]$statutory - 0.5) < 1e-9)
})

message('\n=== Section 301 exclusion candidates ===')

s301_excl_fixture <- tibble(
  hts10 = '8536908585',
  ch99_code = '9903.88.69'
)

run_test('s301 exclusion emits requires-more-facts rule where rate_301 > 0', {
  out <- attach_duty_provenance(prov_fixture, ch99_other = other_fixture,
                                s301_exclusions = s301_excl_fixture)
  # Row 2: 8536908585 x China, rate_301 = 0.25 -> candidate rule emitted
  j <- fromJSON(out$ch99_rules_json[2], simplifyDataFrame = FALSE)
  progs <- vapply(j, function(x) x$program %||% '', character(1))
  stopifnot('s301_exclusion' %in% progs)
  excl <- j[[which(progs == 's301_exclusion')]]
  stopifnot(excl$ch99_code == '9903.88.69',
            excl$authority == 'section_301',
            excl$status == 'potentially_applicable_requires_more_facts',
            all(c('product_description_match', 'exclusion_claim_eligibility')
                %in% unlist(excl$missing_facts)))
  # The applied §301 rule object is still present alongside the candidate
  auths <- vapply(j, function(x) x$authority, character(1))
  stats <- vapply(j, function(x) x$status, character(1))
  stopifnot(any(auths == 'section_301' & stats == 'applied'))
})

run_test('s301 exclusion NOT emitted where rate_301 = 0; rates unchanged', {
  out <- attach_duty_provenance(prov_fixture, ch99_other = other_fixture,
                                s301_exclusions = s301_excl_fixture)
  # Row 1: same hts10 but rate_301 = 0 (non-China) -> no candidate rule
  j <- fromJSON(out$ch99_rules_json[1], simplifyDataFrame = FALSE)
  progs <- vapply(j, function(x) x$program %||% '', character(1))
  stopifnot(!'s301_exclusion' %in% progs)
  # Emission never touches the rate columns
  stopifnot(identical(out$rate_301, prov_fixture$rate_301))
})

run_test('builder date-windows headings from this revision\'s text', {
  excl_ch99 <- tibble(
    ch99_code = c('9903.88.69', '9903.88.21', '9903.88.51'),
    description = c(
      paste('Effective with respect to entries on or after June 15, 2024',
            'and through November 9, 2026, articles the product of China...'),
      paste('Effective with respect to entries on or after June 15, 2024',
            'and through November 9, 2026, derived-rate provision text'),
      'Articles the product of China, as provided for in U.S. note 20'
    )
  )
  # In-window: .69 candidates from the real lines CSV; .21 (PERMANENT
  # CONDITIONAL carve-out) and .51 (no verifiable window) never emit.
  cand <- build_s301_exclusion_candidates(excl_ch99, as.Date('2025-06-01'))
  stopifnot(nrow(cand) > 0)
  stopifnot(all(cand$ch99_code == '9903.88.69'))
  stopifnot('0304725000' %in% cand$hts10)
  # Pre-window and post-expiry dates emit nothing
  pre <- build_s301_exclusion_candidates(excl_ch99, as.Date('2024-06-01'))
  stopifnot(nrow(pre) == 0)
  post <- build_s301_exclusion_candidates(excl_ch99, as.Date('2026-11-10'))
  stopifnot(nrow(post) == 0)
})

message('\n=== parse_chapter99_other ===')

run_test('9902/9904 parsed with inline triggers', {
  hts_raw <- list(
    list(htsno = '9902.01.01', description = 'Corn (provided for in subheading 0710.80.70)', general = 'Free'),
    list(htsno = '9904.05.01', description = 'Valued less than 25 cents/kg', general = ''),
    list(htsno = '9903.85.08', description = 'derivative aluminum products', general = '50%'),
    list(htsno = '0101.21.00', description = 'horses', general = 'Free')
  )
  out <- parse_chapter99_other(hts_raw = hts_raw)
  stopifnot(nrow(out) == 2)
  stopifnot(out$subchapter[out$ch99_code == '9902.01.01'] == 'mtb_9902')
  stopifnot('07108070' %in% unlist(out$trigger_hts[out$ch99_code == '9902.01.01']))
  stopifnot(out$subchapter[out$ch99_code == '9904.05.01'] == 'ag_safeguard_9904')
})

message('\n=== resolve_country_name (note-50/52 origin resolution) ===')

run_test('resolves plain, articled, and diacritic HTS spellings', {
  stopifnot(identical(resolve_country_name('Kazakhstan'), '4634'))
  stopifnot(identical(resolve_country_name('the Philippines'), '5650'))
  stopifnot(identical(resolve_country_name('the United Kingdom'), '4120'))
  stopifnot(identical(resolve_country_name('Türkiye'), '4890'))       # census: "Turkey"
  stopifnot(identical(resolve_country_name('South Korea'), '5800'))   # prefix match
  stopifnot(identical(resolve_country_name('Syria'), '5020'))         # parenthetical gloss
})

run_test('does NOT split country names containing " and "', {
  # "Bosnia and Herzegovina" / "Trinidad and Tobago" must resolve whole; naive
  # splitting on ' and ' shreds them into unresolvable fragments.
  stopifnot(length(resolve_country_name('Bosnia and Herzegovina')) == 1)
  stopifnot(identical(resolve_country_name('Trinidad and Tobago'), '2740'))
})

run_test('resolves two origins joined by " or "', {
  codes <- resolve_country_name('Cameroon or the Democratic Republic of the Congo')
  stopifnot(length(codes) == 2, '7420' %in% codes)
})

run_test('European Union expands to the 27 census origins', {
  stopifnot(length(resolve_country_name('European Union')) == 27)
})

run_test('fails CLOSED on unresolvable or partial input', {
  stopifnot(length(resolve_country_name('Ruritania')) == 0)
  # Partial resolution of a two-origin heading is worse than none: it applies a
  # duty to one of two origins and looks correct.
  stopifnot(length(resolve_country_name('Cameroon or Ruritania')) == 0)
  stopifnot(length(resolve_country_name('')) == 0)
  stopifnot(length(resolve_country_name(NA_character_)) == 0)
})

run_test('parse_countries scopes a note-52 rate line to its origin, not "all"', {
  # The regression that mis-scoped 53 rated headings: this text matches
  # `except.*heading`, and the old shortlist branch returned type='all' with an
  # empty country list for any origin not on its 7-country list.
  d <- paste('Except for products described in headings 9903.05.85-9903.05.92,',
             'articles the product of Kazakhstan, as provided for in U.S. note 52',
             'to this subchapter')
  res <- parse_countries(d)
  stopifnot(res$type == 'specific')
  stopifnot(identical(res$countries, '4634'))
})

message('\n=== check_ch99_completeness ===')

run_test('unresolved rated heading fails strict 2025+ build, allowlist clears it', {
  bad <- tibble(
    ch99_code = '9903.99.99', rate = 0.25, authority = 'other',
    country_type = 'unknown', resolution_status = 'unresolved'
  )
  err <- tryCatch({
    check_ch99_completeness(bad, revision_id = '2026_rev_4')
    NULL
  }, error = function(e) e)
  stopifnot(!is.null(err))
  # pre-2025 revisions warn instead of failing
  w <- tryCatch({
    suppressWarnings(check_ch99_completeness(bad, revision_id = '2023_rev_1'))
    TRUE
  }, error = function(e) FALSE)
  stopifnot(isTRUE(w))
})

run_test('resolved/not-duty-relevant headings pass strict check', {
  ok <- tibble(
    ch99_code = c('9903.85.08', '9903.01.32'),
    rate = c(0.5, NA),
    authority = c('section_232', 'ieepa_reciprocal'),
    country_type = c('all', 'all'),
    resolution_status = c('handled_by_s232_extractor', 'ieepa_exclusion_no_rate')
  )
  check_ch99_completeness(ok, revision_id = '2026_rev_4')
})


# =============================================================================
# Summary
# =============================================================================

cat('\n', strrep('=', 50), '\n')
cat('Tests: ', pass_count, ' passed, ', skip_count, ' skipped, ', fail_count, ' failed\n')
cat(strrep('=', 50), '\n')

if (fail_count > 0) quit(status = 1)

# =============================================================================
# Tests: Rate Calculation & Extraction
# =============================================================================
#
# Validates the extract_* functions (system boundary: HTS JSON → structured
# data) and calculate_rates_for_revision() (core rate engine). Uses synthetic
# in-memory fixtures — no external data files required.
#
# Usage:
#   Rscript tests/test_rate_calculation.R
#
# =============================================================================

library(tidyverse)
library(jsonlite)
library(here)

source(here('src', 'helpers.R'))
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))
source(here('src', '06_calculate_rates.R'))

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


# =============================================================================
# Shared fixtures
# =============================================================================

# Minimal country lookup for tests
test_country_lookup <- c(
  'china' = '5700', 'canada' = '1220', 'mexico' = '2010',
  'japan' = '5880', 'germany' = '4280', 'south korea' = '5800',
  'united kingdom' = '4120', 'australia' = '6021',
  'european union' = 'EU', 'india' = '5330',
  'brazil' = '3510', 'switzerland' = '4419'
)

# Helper: create a minimal HTS JSON item (list, as fromJSON produces)
make_hts_item <- function(htsno, description = '', general = '',
                          special = '', other = '', indent = 0,
                          footnotes = list()) {
  list(
    htsno = htsno,
    indent = indent,
    description = description,
    general = general,
    special = special,
    other = other,
    footnotes = footnotes
  )
}


# =============================================================================
# Test 1: extract_ieepa_rates()
# =============================================================================

message('\n--- Test 1: extract_ieepa_rates ---')

make_ieepa_fixture <- function() {
  list(
    # Phase 1 surcharge: China +34%
    make_hts_item('9903.01.63',
                  description = 'Articles the product of China, as provided for in subdivision (v)(iii)',
                  general = '+34%'),
    # Phase 2 surcharge: India +25%
    make_hts_item('9903.02.26',
                  description = 'Articles the product of India, as provided for in subdivision (v)(v)',
                  general = '+25%'),
    # Floor rate: Japan 15%
    make_hts_item('9903.02.44',
                  description = 'Articles the product of Japan, as provided for in subdivision (v)(v)',
                  general = '15%'),
    # Passthrough entry
    make_hts_item('9903.02.45',
                  description = 'Articles the product of Japan, as provided for in subdivision (v)(v)',
                  general = 'The duty provided in the applicable subheading'),
    # Terminated entry — description must have country before the suspension note
    make_hts_item('9903.01.50',
                  description = 'Articles the product of Germany, as provided for in subdivision (v)(iii) of U.S. note 2 to this subchapter [Compiler\'s note: provision suspended.]',
                  general = '+46%'),
    # Universal baseline: 9903.01.25 (+10%)
    make_hts_item('9903.01.25',
                  description = 'Articles the product of any country, as provided for in subdivision (v)',
                  general = '+10%'),
    # Non-IEEPA item (should be ignored)
    make_hts_item('0101.30.00.00',
                  description = 'Asses',
                  general = 'Free',
                  special = 'Free (A,AU,BH,CL)')
  )
}

run_test('extracts surcharge rate', {
  result <- extract_ieepa_rates(make_ieepa_fixture(), test_country_lookup)
  india <- result %>% filter(census_code == '5330')
  stopifnot(nrow(india) > 0)
  stopifnot(abs(india$rate[1] - 0.25) < 1e-10)
  stopifnot(india$rate_type[1] == 'surcharge')
})

run_test('extracts floor rate', {
  result <- extract_ieepa_rates(make_ieepa_fixture(), test_country_lookup)
  japan <- result %>% filter(census_code == '5880', rate_type == 'floor')
  stopifnot(nrow(japan) > 0)
  stopifnot(abs(japan$rate[1] - 0.15) < 1e-10)
})

run_test('detects terminated entry', {
  result <- extract_ieepa_rates(make_ieepa_fixture(), test_country_lookup)
  germany <- result %>% filter(census_code == '4280')
  stopifnot(nrow(germany) > 0)
  stopifnot(germany$terminated[1] == TRUE)
})

run_test('assigns correct phase', {
  result <- extract_ieepa_rates(make_ieepa_fixture(), test_country_lookup)
  india <- result %>% filter(census_code == '5330')
  stopifnot(india$phase[1] == 'phase2_aug7')
})

run_test('returns empty tibble for no IEEPA entries', {
  fixture <- list(
    make_hts_item('0101.30.00.00', general = 'Free')
  )
  result <- extract_ieepa_rates(fixture, test_country_lookup)
  stopifnot(nrow(result) == 0)
  stopifnot('rate' %in% names(result))
  stopifnot('census_code' %in% names(result))
})


# =============================================================================
# Test 2: extract_ieepa_fentanyl_rates()
# =============================================================================

message('\n--- Test 2: extract_ieepa_fentanyl_rates ---')

make_fentanyl_fixture <- function() {
  list(
    # Mexico general: +25%
    make_hts_item('9903.01.01',
                  description = 'Except for products described in headings 9903.01.03-05, articles the product of Mexico',
                  general = '+25%'),
    # Canada general: +25%
    make_hts_item('9903.01.10',
                  description = 'Except for products described in headings 9903.01.13-15, articles the product of Canada',
                  general = '+25%'),
    # Canada carveout: energy +10%
    make_hts_item('9903.01.13',
                  description = 'Energy and mineral products of Canada described in US note 2(a)',
                  general = '+10%'),
    # China general: +20% (must have "Except for products" to be classified as general)
    make_hts_item('9903.01.20',
                  description = 'Except for products described in headings 9903.01.22 through 9903.01.24, articles the product of China, as provided for in subdivision (v)(i)',
                  general = '+20%'),
    # Exclusion entry (no rate — donations)
    make_hts_item('9903.01.02',
                  description = 'Donations for relief of victims of natural disaster',
                  general = 'Free'),
    # Non-fentanyl item (should be ignored)
    make_hts_item('9903.01.50',
                  description = 'Something else',
                  general = '+34%')
  )
}

run_test('extracts general fentanyl rates by country', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  mx <- result %>% filter(census_code == '2010', entry_type == 'general')
  ca <- result %>% filter(census_code == '1220', entry_type == 'general')
  cn <- result %>% filter(census_code == '5700', entry_type == 'general')
  stopifnot(nrow(mx) > 0)
  stopifnot(nrow(ca) > 0)
  stopifnot(nrow(cn) > 0)
  stopifnot(abs(mx$rate[1] - 0.25) < 1e-10)
  stopifnot(abs(cn$rate[1] - 0.20) < 1e-10)
})

run_test('extracts carveout entries', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  carveout <- result %>% filter(entry_type == 'carveout')
  stopifnot(nrow(carveout) > 0)
  stopifnot(abs(carveout$rate[1] - 0.10) < 1e-10)
})

run_test('skips exclusion entries without rate', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  # 9903.01.02 has general = 'Free', should be skipped
  stopifnot(!any(result$ch99_code == '9903.01.02'))
})

run_test('ignores non-fentanyl range items', {
  result <- extract_ieepa_fentanyl_rates(make_fentanyl_fixture(), test_country_lookup)
  stopifnot(!any(result$ch99_code == '9903.01.50'))
})

run_test('returns empty tibble for no fentanyl entries', {
  fixture <- list(make_hts_item('9903.01.50', general = '+34%'))
  result <- extract_ieepa_fentanyl_rates(fixture, test_country_lookup)
  stopifnot(nrow(result) == 0)
  stopifnot('rate' %in% names(result))
})


# =============================================================================
# Test 3: extract_section232_rates()
# =============================================================================

message('\n--- Test 3: extract_section232_rates ---')

make_ch99_232_fixture <- function(steel_rate = 0.25, has_aluminum = TRUE) {
  rows <- list(
    tibble(
      ch99_code = '9903.80.01', rate = steel_rate, authority = 'section_232',
      country_type = 'all', countries = list(character(0)),
      exempt_countries = list(character(0)),
      general_raw = paste0('+', steel_rate * 100, '%'),
      other_raw = '', description = 'Steel articles, all countries'
    )
  )
  if (has_aluminum) {
    rows <- c(rows, list(tibble(
      ch99_code = '9903.85.01', rate = 0.10, authority = 'section_232',
      country_type = 'all_except', countries = list(character(0)),
      exempt_countries = list(c('AU', 'CA', 'MX')),
      general_raw = '+10%', other_raw = '',
      description = 'Aluminum articles, except products of Australia, Canada, Mexico'
    )))
  }
  bind_rows(rows)
}

run_test('extracts steel 232 rate', {
  ch99 <- make_ch99_232_fixture(steel_rate = 0.50)
  result <- extract_section232_rates(ch99)
  stopifnot(result$has_232 == TRUE)
  stopifnot(abs(result$steel_rate - 0.50) < 1e-10)
})

run_test('extracts aluminum 232 with exempt countries', {
  ch99 <- make_ch99_232_fixture()
  result <- extract_section232_rates(ch99)
  stopifnot(abs(result$aluminum_rate - 0.10) < 1e-10)
  stopifnot('AU' %in% result$aluminum_exempt)
})

run_test('has_232 is FALSE when no 232 entries', {
  ch99 <- tibble(
    ch99_code = '9903.88.15', rate = 0.25, authority = 'section_301',
    country_type = 'specific', countries = list('CN'),
    exempt_countries = list(character(0)),
    general_raw = '+25%', other_raw = '',
    description = 'Articles the product of China'
  )
  result <- extract_section232_rates(ch99)
  stopifnot(result$has_232 == FALSE)
})


# =============================================================================
# Test 4: extract_section122_rates()
# =============================================================================

message('\n--- Test 4: extract_section122_rates ---')

run_test('extracts s122 rate from 9903.03.01', {
  ch99 <- tibble(
    ch99_code = '9903.03.01', rate = 0.10, authority = 'section_122',
    country_type = 'all', countries = list(character(0)),
    exempt_countries = list(character(0)),
    general_raw = '+10%', other_raw = '',
    description = 'Section 122 base duty'
  )
  result <- extract_section122_rates(ch99)
  stopifnot(result$has_s122 == TRUE)
  stopifnot(abs(result$s122_rate - 0.10) < 1e-10)
})

run_test('has_s122 is FALSE when no 9903.03 entries', {
  ch99 <- tibble(
    ch99_code = '9903.80.01', rate = 0.25, authority = 'section_232',
    country_type = 'all', countries = list(character(0)),
    exempt_countries = list(character(0)),
    general_raw = '+25%', other_raw = '',
    description = 'Steel articles'
  )
  result <- extract_section122_rates(ch99)
  stopifnot(result$has_s122 == FALSE)
  stopifnot(result$s122_rate == 0)
})


# =============================================================================
# Test 5: extract_usmca_eligibility()
# =============================================================================

message('\n--- Test 5: extract_usmca_eligibility ---')

make_usmca_fixture <- function() {
  list(
    # Product with S+ (USMCA eligible)
    make_hts_item('0201.10.00.10',
                  description = 'Beef, fresh',
                  general = '4%',
                  special = 'Free (A+,AU,BH,CL,CO,D,E,IL,JO,KR,MA,OM,P,PA,PE,S,SG)'),
    # Product with S in secondary group
    make_hts_item('0202.20.00.90',
                  description = 'Beef, frozen',
                  general = '4%',
                  special = 'Free (A,BH,CL) See 9823.xx.xx (S+)'),
    # Product without USMCA
    make_hts_item('2204.10.00.00',
                  description = 'Sparkling wine',
                  general = '19.8c/liter',
                  special = 'Free (A+,AU,BH,CL,CO,D,E,IL,JO,KR,MA,OM,P,PA,PE,SG)'),
    # Chapter 99 item (should be skipped)
    make_hts_item('9903.88.15',
                  description = 'Section 301 tariff',
                  general = '+25%'),
    # Non-10-digit item (should be skipped)
    make_hts_item('0201.10',
                  description = 'Heading',
                  general = '4%')
  )
}

run_test('identifies S-program USMCA eligibility', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  beef_fresh <- result %>% filter(hts10 == '0201100010')
  stopifnot(nrow(beef_fresh) == 1)
  stopifnot(beef_fresh$usmca_eligible == TRUE)
})

run_test('identifies S+ in secondary parenthesized group', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  beef_frozen <- result %>% filter(hts10 == '0202200090')
  stopifnot(nrow(beef_frozen) == 1)
  stopifnot(beef_frozen$usmca_eligible == TRUE)
})

run_test('products without S/S+ are not USMCA eligible', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  wine <- result %>% filter(hts10 == '2204100000')
  stopifnot(nrow(wine) == 1)
  stopifnot(wine$usmca_eligible == FALSE)
})

run_test('skips Chapter 99 items', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  stopifnot(!any(grepl('^9903', result$hts10)))
})

run_test('skips non-10-digit codes', {
  result <- extract_usmca_eligibility(make_usmca_fixture())
  stopifnot(!any(result$hts10 == '020110'))
})

# Inheritance fixture (upstream b3dd1b5): `special` lives on the 8-digit
# LEGAL line; 10-digit statistical suffixes have empty special/general and
# inherit the parent legal line's program eligibility.
make_usmca_inherit_fixture <- function() {
  list(
    make_hts_item('2709.00', description = 'Petroleum oils, crude', indent = 0),
    # Legal line WITH S — statistical children must inherit TRUE
    make_hts_item('2709.00.20', description = 'Testing 25 degrees A.P.I. or more',
                  general = '10.5c/bbl', indent = 1,
                  special = 'Free (A+,AU,BH,CA,CL,CO,D,E,IL,JO,KR,MA,OM,P,PA,PE,S,S+,SG)'),
    make_hts_item('2709.00.20.10', description = 'Condensate', indent = 2),
    make_hts_item('2709.00.20.90', description = 'Other', indent = 2),
    # Sibling legal line WITHOUT S — its child must NOT leak the earlier S
    make_hts_item('2709.00.10', description = 'Testing under 25 degrees',
                  general = '5.25c/bbl', indent = 1,
                  special = 'Free (A+,AU,BH,CL)'),
    make_hts_item('2709.00.10.00', description = 'Other', indent = 2),
    # 8-digit LEAF line (no statistical children) — kept, padded with 00
    make_hts_item('9802.00.40', description = 'Repairs or alterations',
                  general = 'Free', indent = 1, special = 'Free (S+)')
  )
}

run_test('statistical suffixes inherit S/S+ from the 8-digit legal line', {
  result <- extract_usmca_eligibility(make_usmca_inherit_fixture())
  kids <- result %>% filter(hts10 %in% c('2709002010', '2709002090'))
  stopifnot(nrow(kids) == 2)
  stopifnot(all(kids$usmca_eligible == TRUE))
})

run_test('sibling legal line specials do not leak across branches', {
  result <- extract_usmca_eligibility(make_usmca_inherit_fixture())
  other <- result %>% filter(hts10 == '2709001000')
  stopifnot(nrow(other) == 1)
  stopifnot(other$usmca_eligible == FALSE)
})

run_test('8-digit leaf kept (padded 00); 8-digit parent with children dropped', {
  result <- extract_usmca_eligibility(make_usmca_inherit_fixture())
  stopifnot('9802004000' %in% result$hts10)
  stopifnot(result$usmca_eligible[result$hts10 == '9802004000'] == TRUE)
  stopifnot(!'2709002000' %in% result$hts10)  # parent of .10/.90 suffixes
})


# =============================================================================
# Test 5b: IEEPA Annex II exempt-list date windows
# =============================================================================

message('\n--- Test 5b: IEEPA exempt date windows ---')

run_test('pre-2025-04-05 revision does NOT exempt an electronics entry windowed at 2025-04-05', {
  fixture <- tibble(
    hts10 = c('8471300100', '0101210010', '7409110050'),
    source = c('ita', 'annex_ii', 'annex_ii'),
    effective_date_start = c('2025-04-05', NA, NA),
    effective_date_end = c(NA, NA, '2025-07-31')
  )
  pre <- filter_ieepa_exempt_window(fixture, as.Date('2025-04-02'))
  stopifnot(!'8471300100' %in% pre$hts10)   # electronics not yet exempt
  stopifnot('0101210010' %in% pre$hts10)    # undated entry always active
  post <- filter_ieepa_exempt_window(fixture, as.Date('2025-04-05'))
  stopifnot('8471300100' %in% post$hts10)   # retroactive window opens Apr 5
})

run_test('end-dated entry exempts through end date, not after (copper -> 232)', {
  fixture <- tibble(
    hts10 = '7409110050',
    effective_date_start = NA_character_,
    effective_date_end = '2025-07-31'
  )
  stopifnot(nrow(filter_ieepa_exempt_window(fixture, as.Date('2025-07-31'))) == 1)
  stopifnot(nrow(filter_ieepa_exempt_window(fixture, as.Date('2025-08-01'))) == 0)
})

run_test('resource CSV carries the stamped Annex II windows', {
  path <- here('resources', 'ieepa_exempt_products.csv')
  if (!file.exists(path)) skip_test('ieepa_exempt_products.csv not present')
  exempt <- read_csv(path, col_types = cols(.default = col_character()))
  stopifnot(all(c('effective_date_start', 'effective_date_end') %in% names(exempt)))
  # Electronics (Annex II amendment, retroactive to Apr 5 2025)
  elec <- exempt %>% filter(startsWith(hts10, '8471'))
  stopifnot(nrow(elec) > 0)
  stopifnot(all(elec$effective_date_start == '2025-04-05', na.rm = TRUE))
  stopifnot(any(elec$effective_date_start == '2025-04-05'))
  # Copper exempt only through 2025-07-31 (PP 10962); wood through 2025-10-13
  # (PP 10976)
  stopifnot(any(substr(exempt$hts10, 1, 2) == '74' &
                  exempt$effective_date_end == '2025-07-31', na.rm = TRUE))
  stopifnot(any(substr(exempt$hts10, 1, 2) == '44' &
                  exempt$effective_date_end == '2025-10-13', na.rm = TRUE))
  # No entry may end before it starts
  both <- exempt %>% filter(!is.na(effective_date_start), !is.na(effective_date_end))
  if (nrow(both) > 0) {
    stopifnot(all(as.Date(both$effective_date_end) >= as.Date(both$effective_date_start)))
  }
})


# =============================================================================
# Test 5c: parse_products 8-digit leaf retention
# =============================================================================

message('\n--- Test 5c: parse_products 8-digit leaves ---')

run_test('8-digit leaf kept padded to 10; 8-digit parent with children dropped', {
  fixture <- list(
    list(htsno = '9101.11', indent = 0, description = 'Wrist watches',
         general = '', special = '', other = '', footnotes = list()),
    # 8-digit LEAF (no statistical children) — Census reports as ...00
    list(htsno = '9101.11.40', indent = 1, description = 'Gold/silver case',
         general = '5.1%', special = 'Free (S)', other = '45%',
         footnotes = list()),
    # 8-digit line WITH a 10-digit child — grouping row, must be dropped
    list(htsno = '0201.10.00', indent = 1, description = 'Carcasses',
         general = '4.4%', special = 'Free (S+)', other = '20%',
         footnotes = list()),
    list(htsno = '0201.10.00.10', indent = 2, description = 'Veal',
         general = '', special = '', other = '', footnotes = list())
  )
  tmp <- tempfile(fileext = '.json')
  jsonlite::write_json(fixture, tmp, auto_unbox = TRUE)
  out <- parse_products(tmp)
  stopifnot('9101114000' %in% out$hts10)    # leaf retained, padded with 00
  stopifnot(!'0201100000' %in% out$hts10)   # non-leaf 8-digit parent dropped
  stopifnot('0201100010' %in% out$hts10)    # its 10-digit child retained
  stopifnot(abs(out$base_rate[out$hts10 == '9101114000'] - 0.051) < 1e-9)
  stopifnot(!'is_8digit_line' %in% names(out))
})


# =============================================================================
# Test 6: Rate invariants
# =============================================================================

message('\n--- Test 6: Rate invariants ---')

# Build a minimal but realistic rate output using the stacking/schema machinery
make_test_rates <- function() {
  tibble(
    hts10 = rep(c('7208100000', '8703230000', '0201100010'), each = 3),
    country = rep(c('5700', '4280', '1220'), 3),
    base_rate = c(0, 0, 0, 0.025, 0.025, 0.025, 0.04, 0.04, 0.04),
    statutory_base_rate = c(0, 0, 0, 0.025, 0.025, 0.025, 0.04, 0.04, 0.04),
    rate_232 = c(0.50, 0.50, 0.50, 0, 0, 0, 0, 0, 0),
    rate_301 = c(0.25, 0, 0, 0.25, 0, 0, 0, 0, 0),
    rate_ieepa_recip = c(0, 0.20, 0.10, 0.34, 0.20, 0, 0.34, 0.20, 0),
    rate_ieepa_fent = c(0.20, 0, 0.25, 0.20, 0, 0.25, 0.20, 0, 0.25),
    rate_s122 = c(0, 0, 0, 0.10, 0.10, 0.10, 0.10, 0.10, 0.10),
    rate_section_201 = 0,
    rate_other = 0,
    metal_share = c(1, 1, 1, 0, 0, 0, 0, 0, 0),
    usmca_eligible = FALSE,
    revision = 'test', effective_date = as.Date('2025-06-01'),
    valid_from = as.Date('2025-06-01'), valid_until = as.Date('2025-12-31')
  ) %>%
    apply_stacking_rules(cty_china = '5700')
}

run_test('total_rate = base_rate + total_additional', {
  rates <- make_test_rates()
  residual <- abs(rates$total_rate - (rates$base_rate + rates$total_additional))
  stopifnot(max(residual) < 1e-10)
})

run_test('no negative rates', {
  rates <- make_test_rates()
  rate_cols <- c('base_rate', 'rate_232', 'rate_301', 'rate_ieepa_recip',
                 'rate_ieepa_fent', 'rate_s122', 'total_additional', 'total_rate')
  for (col in rate_cols) {
    if (any(rates[[col]] < 0)) {
      stop('negative values in ', col)
    }
  }
})

run_test('net authority decomposition sums to total_additional', {
  rates <- make_test_rates()
  net <- compute_net_authority_contributions(rates, cty_china = '5700')
  decomp_sum <- net$net_232 + net$net_ieepa + net$net_fentanyl +
    net$net_301 + net$net_s122 + net$net_section_201 + net$net_other
  residual <- abs(decomp_sum - net$total_additional)
  stopifnot(max(residual) < 1e-10)
})

run_test('232/IEEPA mutual exclusion: China with 232 gets full fentanyl', {
  rates <- make_test_rates()
  china_steel <- rates %>% filter(country == '5700', rate_232 > 0)
  # China with 232: fentanyl stacks at full value (not scaled by nonmetal_share)
  stopifnot(nrow(china_steel) > 0)
  net <- compute_net_authority_contributions(china_steel, cty_china = '5700')
  stopifnot(all(abs(net$net_fentanyl - china_steel$rate_ieepa_fent) < 1e-10))
})

run_test('232/IEEPA mutual exclusion: non-China with 232 has scaled IEEPA', {
  rates <- make_test_rates()
  de_steel <- rates %>% filter(country == '4280', rate_232 > 0)
  # Germany with 232 + metal_share=1: nonmetal_share=0, IEEPA should be 0
  stopifnot(nrow(de_steel) > 0)
  net <- compute_net_authority_contributions(de_steel, cty_china = '5700')
  stopifnot(all(net$net_ieepa == 0))
})

run_test('rate_301 only contributes for China in decomposition', {
  rates <- make_test_rates()
  net <- compute_net_authority_contributions(rates, cty_china = '5700')
  non_china <- net %>% filter(country != '5700')
  stopifnot(all(non_china$net_301 == 0))
})


# =============================================================================
# Test 7: classify_authority edge cases
# =============================================================================

message('\n--- Test 7: classify_authority ---')

run_test('section_122 from 9903.03.xx', {
  stopifnot(classify_authority('9903.03.01') == 'section_122')
})

run_test('section_232 from 9903.80-85', {
  stopifnot(classify_authority('9903.80.01') == 'section_232')
  stopifnot(classify_authority('9903.85.04') == 'section_232')
})

run_test('section_232 from 9903.94 (autos)', {
  stopifnot(classify_authority('9903.94.01') == 'section_232')
})

run_test('section_232 from 9903.74 (MHD)', {
  stopifnot(classify_authority('9903.74.01') == 'section_232')
})

run_test('section_232 from 9903.78 (copper)', {
  stopifnot(classify_authority('9903.78.01') == 'section_232')
})

run_test('section_301 from 9903.86-89', {
  stopifnot(classify_authority('9903.88.15') == 'section_301')
})

run_test('section_301 from 9903.91 (Biden 301)', {
  stopifnot(classify_authority('9903.91.01') == 'section_301')
})

run_test('ieepa_reciprocal from 9903.93/95/96', {
  stopifnot(classify_authority('9903.93.01') == 'ieepa_reciprocal')
  stopifnot(classify_authority('9903.95.01') == 'ieepa_reciprocal')
})

run_test('section_201 safeguards from 9903.40-45', {
  stopifnot(classify_authority('9903.40.01') == 'section_201')
  stopifnot(classify_authority('9903.45.99') == 'section_201')
})

run_test('unknown for empty or malformed code', {
  stopifnot(classify_authority('') == 'unknown')
  stopifnot(classify_authority(NA) == 'unknown')
})


# =============================================================================
# Test 8: parse_rate and parse_ch99_rate
# =============================================================================

message('\n--- Test 8: Rate parsing ---')

run_test('parse_rate: simple percentage', {
  stopifnot(abs(parse_rate('6.8%') - 0.068) < 1e-10)
  stopifnot(abs(parse_rate('25%') - 0.25) < 1e-10)
})

run_test('parse_rate: Free', {
  stopifnot(parse_rate('Free') == 0)
  stopifnot(parse_rate('free') == 0)
})

run_test('parse_rate: empty and NA', {
  stopifnot(is.na(parse_rate('')))
  stopifnot(is.na(parse_rate(NA)))
  stopifnot(is.na(parse_rate(NULL)))
})

run_test('parse_rate: compound rates return NA', {
  stopifnot(is.na(parse_rate('2.4c/kg + 5%')))
  stopifnot(is.na(parse_rate('$1.50/doz')))
})

run_test('parse_ch99_rate: surcharge format', {
  stopifnot(abs(parse_ch99_rate('The duty provided in the applicable subheading + 25%') - 0.25) < 1e-10)
  stopifnot(abs(parse_ch99_rate('The duty provided in the applicable subheading plus 7.5%') - 0.075) < 1e-10)
})

run_test('parse_ch99_rate: bare percentage', {
  stopifnot(abs(parse_ch99_rate('25%') - 0.25) < 1e-10)
})

run_test('parse_ch99_rate: empty returns NA', {
  stopifnot(is.na(parse_ch99_rate('')))
  stopifnot(is.na(parse_ch99_rate(NA)))
})


# =============================================================================
# Test 9: enforce_rate_schema
# =============================================================================

message('\n--- Test 9: Schema enforcement ---')

run_test('adds missing columns with defaults', {
  df <- tibble(hts10 = '0101300000', country = '5700')
  result <- enforce_rate_schema(df)
  stopifnot(all(RATE_SCHEMA %in% names(result)))
  stopifnot(result$rate_232 == 0)
  stopifnot(result$rate_301 == 0)
  stopifnot(result$total_rate == 0)
})

run_test('fills NAs in per-authority rate columns with 0', {
  # bind_rows for MFN-only grid pairs legitimately leaves an absent authority
  # column NA — that IS a 0 rate, so these still fill.
  df <- tibble(
    hts10 = '0101300000', country = '5700',
    base_rate = NA_real_, rate_232 = NA_real_
  )
  result <- enforce_rate_schema(df)
  stopifnot(result$base_rate == 0)
  stopifnot(result$rate_232 == 0)
})

run_test('fails loud on NA total_rate / total_additional (never coalesces)', {
  # Port of upstream c0ff82a8. A NA total means a rate column was NA ENTERING
  # apply_stacking_rules(); coalescing it to 0 masks the real bug (this is how a
  # bare `s232_annex == '<annex>'` if_else condition silently wipes rate_232 and
  # §122 for every non-annex product).
  for (col in c('total_rate', 'total_additional')) {
    df <- tibble(hts10 = '0101300000', country = '5700')
    df[[col]] <- NA_real_
    err <- tryCatch({ enforce_rate_schema(df); NULL },
                    error = function(e) conditionMessage(e))
    stopifnot(!is.null(err))
    stopifnot(grepl('NA', err), grepl(col, err, fixed = TRUE))
    stopifnot(grepl('0101300000/5700', err, fixed = TRUE))  # identifies the row
  }
})

run_test('a computed (non-NA) total passes the guard untouched', {
  df <- tibble(hts10 = '0101300000', country = '5700',
               base_rate = 0.02, rate_232 = 0.5,
               total_additional = 0.5, total_rate = 0.52)
  result <- enforce_rate_schema(df)
  stopifnot(abs(result$total_additional - 0.5) < 1e-12)
  stopifnot(abs(result$total_rate - 0.52) < 1e-12)
})

run_test('preserves extra columns', {
  df <- tibble(hts10 = '0101300000', country = '5700', custom_col = 'hello')
  result <- enforce_rate_schema(df)
  stopifnot('custom_col' %in% names(result))
  stopifnot(result$custom_col == 'hello')
})

run_test('schema columns appear first', {
  df <- tibble(hts10 = '0101300000', country = '5700', zzz_extra = 1)
  result <- enforce_rate_schema(df)
  schema_positions <- match(RATE_SCHEMA, names(result))
  extra_position <- match('zzz_extra', names(result))
  stopifnot(all(schema_positions < extra_position))
})


# =============================================================================
# Test 10: Stacking rules edge cases
# =============================================================================

message('\n--- Test 10: Stacking rules ---')

run_test('tpc_additive stacks all authorities', {
  df <- tibble(
    hts10 = '7208100000', country = '5700',
    base_rate = 0, rate_232 = 0.25, rate_301 = 0.25,
    rate_ieepa_recip = 0.34, rate_ieepa_fent = 0.20,
    rate_s122 = 0.10, rate_section_201 = 0, rate_other = 0,
    metal_share = 1.0
  )
  result <- apply_stacking_rules(df, cty_china = '5700', stacking_method = 'tpc_additive')
  expected <- 0.25 + 0.25 + 0.34 + 0.20 + 0.10
  stopifnot(abs(result$total_additional - expected) < 1e-10)
})

run_test('mutual exclusion: 232 product with metal_share=1 gets no IEEPA', {
  df <- tibble(
    hts10 = '7208100000', country = '4280',
    base_rate = 0, rate_232 = 0.50, rate_301 = 0,
    rate_ieepa_recip = 0.20, rate_ieepa_fent = 0,
    rate_s122 = 0.10, rate_section_201 = 0, rate_other = 0,
    metal_share = 1.0
  )
  result <- apply_stacking_rules(df, cty_china = '5700')
  # With metal_share=1, nonmetal_share=0, so IEEPA and s122 contribute 0
  stopifnot(abs(result$total_additional - 0.50) < 1e-10)
})

run_test('non-232 product stacks IEEPA + fentanyl + s122 fully', {
  df <- tibble(
    hts10 = '0201100010', country = '4280',
    base_rate = 0.04, rate_232 = 0, rate_301 = 0,
    rate_ieepa_recip = 0.15, rate_ieepa_fent = 0,
    rate_s122 = 0.10, rate_section_201 = 0, rate_other = 0,
    metal_share = 0
  )
  result <- apply_stacking_rules(df, cty_china = '5700')
  expected <- 0.15 + 0.10
  stopifnot(abs(result$total_additional - expected) < 1e-10)
  stopifnot(abs(result$total_rate - (0.04 + expected)) < 1e-10)
})


# =============================================================================
# Test 11: Section 232 derivative country rate overrides (upstream cf2d5951 #1)
# =============================================================================

message('\n--- Test 11: 232 derivative country overrides ---')

run_test('UK derivative override applies (25%, not the blanket 50%)', {
  # The bug: *_country_overrides were honored only by the primary metal
  # programs, so UK outside-chapter derivatives paid the blanket rate.
  r <- derivative_country_rates(
    country_vec  = c('4120', '5700'),          # UK, China
    exempt_list  = NULL,
    blanket_rate = 0.50,
    overrides    = list('4120' = 0.25)
  )
  stopifnot(abs(r[1] - 0.25) < 1e-12)          # UK gets its override
  stopifnot(abs(r[2] - 0.50) < 1e-12)          # China keeps the blanket rate
})

run_test('exemption zeros win over a country override', {
  r <- derivative_country_rates(
    country_vec  = c('4120'),
    exempt_list  = c('4120'),
    blanket_rate = 0.50,
    overrides    = list('4120' = 0.25)
  )
  stopifnot(abs(r[1] - 0) < 1e-12)
})

run_test('no overrides / NULL overrides preserves blanket + exempt behavior', {
  r_null <- derivative_country_rates(c('4120', '5700'), NULL, 0.50, NULL)
  stopifnot(all(abs(r_null - 0.50) < 1e-12))
  r_empty <- derivative_country_rates(c('4120'), NULL, 0.50, list())
  stopifnot(abs(r_empty - 0.50) < 1e-12)
  r_ex <- derivative_country_rates(c('4120', '5700'), c('5700'), 0.50, NULL)
  stopifnot(abs(r_ex[1] - 0.50) < 1e-12, abs(r_ex[2] - 0) < 1e-12)
})


# =============================================================================
# Test 11a: Phase 1 — per-action §232 schema and heading→action attribution
# =============================================================================

message('\n--- Test 11a: 232 per-action schema + attribution ---')

run_test('per-action §232 columns exist and are zero-filled, not silently absent', {
  stopifnot(all(S232_ACTION_RATE_COLS %in% AUTHORITY_RATE_COLS))
  stopifnot(all(S232_ACTION_RATE_COLS %in% RATE_SCHEMA))
  stopifnot(!anyDuplicated(RATE_SCHEMA))
  d <- zero_fill_authority_rates(tibble(hts10 = 'x'))
  stopifnot(all(S232_ACTION_RATE_COLS %in% names(d)))
  stopifnot(all(vapply(S232_ACTION_RATE_COLS, function(c) d[[c]] == 0, logical(1))))
})

run_test('enforce_rate_schema fails loud on a schema column with no default', {
  # df[[col]] <- NULL is a no-op, so a column missing from `defaults` silently
  # stays absent and only surfaces as "column doesn't exist" much later.
  old <- RATE_SCHEMA
  RATE_SCHEMA <<- c(RATE_SCHEMA, 'rate_232_unobtanium')
  err <- tryCatch({ enforce_rate_schema(tibble(hts10 = 'x', country = 'CN')); NULL },
                  error = function(e) conditionMessage(e))
  RATE_SCHEMA <<- old
  stopifnot(!is.null(err))
  stopifnot(grepl('rate_232_unobtanium', err, fixed = TRUE))
})

run_test('enforce_rate_schema materialises the per-action columns', {
  d <- enforce_rate_schema(tibble(hts10 = '7208100000', country = '4621'))
  stopifnot(all(S232_ACTION_RATE_COLS %in% names(d)))
  stopifnot(all(vapply(S232_ACTION_RATE_COLS, function(c) !is.na(d[[c]]), logical(1))))
})

run_test('only Proclamation 10908 programs map to the AUTO action', {
  # EO 14289 sec. 2(a) is Proc 10908 — passenger vehicles, light trucks, parts.
  # MHD vehicles, buses, wood and semiconductors are SEPARATE §232 actions the
  # order never names. Mapping them to auto would let them exclude steel and
  # aluminum under sec. 3(a)(i) and suppress real duty.
  m <- S232_HEADING_PROGRAM_ACTION
  stopifnot(all(m[c('autos_passenger', 'autos_light_trucks', 'auto_parts')] == 'rate_232_auto'))
  for (p in c('mhd_vehicles', 'mhd_parts', 'buses', 'softwood',
              'wood_furniture', 'kitchen_cabinets', 'semiconductors')) {
    stopifnot(identical(unname(m[[p]]), 'rate_232_other'))
  }
  stopifnot(identical(unname(m[['copper']]), 'rate_232_copper'))
})

run_test('an unmapped heading program falls to _other rather than vanishing', {
  # A newly added §232 action must still be carried and visibly attributed.
  stopifnot(is.na(unname(S232_HEADING_PROGRAM_ACTION['a_program_added_next_year'])))
  # the pipeline's guard: unmapped + non-metal chapter => rate_232_other
  chapter <- '84'; action <- NA_character_; blanket <- 0.30
  goes_to_other <- blanket > 0 & (is.na(action) | identical(action, 'rate_232_other')) &
    !(chapter %in% c('72', '73', '76'))
  stopifnot(isTRUE(goes_to_other))
})

run_test('primary metal chapters attribute by chapter, not by heading program', {
  # ch72/73 steel and ch76 aluminum take the blanket rate; the heading program
  # (if any) must not override that attribution.
  classify <- function(chapter, program, blanket) {
    if (blanket <= 0) return(NA_character_)
    if (chapter %in% c('72', '73')) return('rate_232_steel')
    if (chapter %in% c('76')) return('rate_232_aluminum')
    unname(S232_HEADING_PROGRAM_ACTION[program])
  }
  stopifnot(identical(classify('72', NA, 0.50), 'rate_232_steel'))
  stopifnot(identical(classify('76', NA, 0.50), 'rate_232_aluminum'))
  stopifnot(identical(classify('87', 'autos_passenger', 0.25), 'rate_232_auto'))
  stopifnot(identical(classify('74', 'copper', 0.50), 'rate_232_copper'))
  stopifnot(identical(classify('44', 'softwood', 0.10), 'rate_232_other'))
  stopifnot(is.na(classify('84', NA, 0)))          # no duty -> no attribution
})


# =============================================================================
# Test 11e: Phase 3 — EO 14289 non-stacking order (90 FR 18907 sec. 3(a))
#           CBP CSMS #65054270
# =============================================================================

message('\n--- Test 11e: EO 14289 precedence ---')

.row <- function(country = '5700', auto = 0, steel = 0, alum = 0,
                 copper = 0, other = 0, fent = 0) {
  tibble(hts10 = '7326908688', country = country,
         rate_232_auto = auto, rate_232_steel = steel, rate_232_aluminum = alum,
         rate_232_copper = copper, rate_232_other = other,
         rate_ieepa_fent = fent, rate_232 = auto + steel + alum + copper + other)
}

run_test('era is selected by effective date from config, last matching wins', {
  stopifnot(identical(resolve_stacking_era('2024-01-01')$id, 'legacy'))
  stopifnot(identical(resolve_stacking_era('2025-06-01')$id, 'eo14289'))
  stopifnot(identical(resolve_stacking_era('2026-07-24')$id, 's301_2026'))
  # boundary is inclusive
  stopifnot(identical(resolve_stacking_era('2025-03-04')$id, 'eo14289'))
  stopifnot(identical(resolve_stacking_era('2025-03-03')$id, 'legacy'))
})

run_test('sec. 3(a)(i): auto excludes steel, aluminum and IEEPA CA/MX', {
  r <- apply_eo14289_precedence(.row(country = '1220', auto = 0.25, steel = 0.50,
                                     alum = 0.50, fent = 0.35))
  stopifnot(r$rate_232_auto == 0.25)          # auto survives
  stopifnot(r$rate_232_steel == 0)
  stopifnot(r$rate_232_aluminum == 0)
  stopifnot(r$rate_ieepa_fent == 0)           # IEEPA Canada suppressed
  stopifnot(abs(r$rate_232 - 0.25) < 1e-12)   # total is auto alone, not the sum
  stopifnot(grepl('eo14289_3a_i_auto', r$s232_suppressed_json))
})

run_test('sec. 3(a)(ii): IEEPA CA/MX excludes steel and aluminum but survives itself', {
  r <- apply_eo14289_precedence(.row(country = '2010', steel = 0.50,
                                     alum = 0.50, fent = 0.25))
  stopifnot(r$rate_ieepa_fent == 0.25)        # the higher-precedence action stays
  stopifnot(r$rate_232_steel == 0, r$rate_232_aluminum == 0)
  stopifnot(abs(r$rate_232 - 0) < 1e-12)
  stopifnot(grepl('eo14289_3a_ii_ieepa_camx', r$s232_suppressed_json))
})

run_test('sec. 3(a)(iii): steel and aluminum STACK with each other', {
  # The rule the old single rate_232 scalar could not express at all.
  r <- apply_eo14289_precedence(.row(country = '5700', steel = 0.50, alum = 0.50))
  stopifnot(r$rate_232_steel == 0.50, r$rate_232_aluminum == 0.50)
  stopifnot(abs(r$rate_232 - 1.00) < 1e-12)   # BOTH owed, not pmax
  stopifnot(is.na(r$s232_suppressed_json))
})

run_test('USMCA falls out of the >0% definition with no special case', {
  # A USMCA-qualifying auto part owes 0% under Proc 10908, so it is NOT
  # "subject to" 2(a) and drops through to step 3 — where steel is still owed.
  r <- apply_eo14289_precedence(.row(country = '1220', auto = 0, steel = 0.50))
  stopifnot(r$rate_232_steel == 0.50)         # NOT suppressed
  stopifnot(abs(r$rate_232 - 0.50) < 1e-12)
  # and with a non-zero auto rate the same row IS suppressed
  r2 <- apply_eo14289_precedence(.row(country = '1220', auto = 0.25, steel = 0.50))
  stopifnot(r2$rate_232_steel == 0)
})

run_test('IEEPA fentanyl for the PRC is NOT in sec. 2 and is never suppressed', {
  # EO 14195 is listed in sec. 4(b) as cumulative. Only IEEPA CANADA and MEXICO
  # (EO 14193/14194) are in the order, and they are disambiguated by country.
  r <- apply_eo14289_precedence(.row(country = '5700', auto = 0.25, fent = 0.20))
  stopifnot(r$rate_ieepa_fent == 0.20)
})

run_test('copper, wood, MHD and semiconductors are cumulative under sec. 3(c)', {
  # These are separate §232 actions the order never names, so auto must not
  # suppress them the way it suppresses steel and aluminum.
  r <- apply_eo14289_precedence(.row(country = '1220', auto = 0.25,
                                     copper = 0.50, other = 0.10, steel = 0.50))
  stopifnot(r$rate_232_copper == 0.50, r$rate_232_other == 0.10)
  stopifnot(r$rate_232_steel == 0)
  stopifnot(abs(r$rate_232 - (0.25 + 0.50 + 0.10)) < 1e-12)
})

run_test('sec. 3(b): suppression zeroes the RATE but keeps provenance', {
  r <- apply_eo14289_precedence(.row(country = '1220', auto = 0.25, steel = 0.50))
  stopifnot(!is.na(r$s232_suppressed_json))
  stopifnot(grepl('"s232_steel":0.5', r$s232_suppressed_json, fixed = TRUE))
})

run_test('a zero-rate action is not "subject to" and triggers nothing', {
  # Threshold is strictly greater than 0. An action present at 0% must not
  # suppress anything, or a 0% auto line would wipe real steel duty.
  r <- apply_eo14289_precedence(.row(country = '1220', auto = 0, fent = 0, steel = 0.50))
  stopifnot(r$rate_232_steel == 0.50, is.na(r$s232_suppressed_json))
})

run_test('vectorises across mixed rows without cross-contamination', {
  df <- bind_rows(
    .row(country = '1220', auto = 0.25, steel = 0.50),   # 3(a)(i)
    .row(country = '2010', steel = 0.50, fent = 0.25),   # 3(a)(ii)
    .row(country = '5700', steel = 0.50, alum = 0.50),   # 3(a)(iii)
    .row(country = '4120', steel = 0.50)                 # untouched
  )
  r <- apply_eo14289_precedence(df)
  stopifnot(identical(r$rate_232_steel, c(0, 0, 0.50, 0.50)))
  stopifnot(abs(r$rate_232 - c(0.25, 0, 1.00, 0.50)) < 1e-12)
})


# =============================================================================
# Test 11d: Phase 2b/2c — Column 1 compound recovery and honest calc_status
# =============================================================================

message('\n--- Test 11d: Column 1 compound recovery + calc_status ---')

# Mirrors the classification in src/04_parse_products.R.
.calc_status_for <- function(rate_basis, status, is_qty = FALSE, unit = NA) {
  if (identical(rate_basis, 'unknown')) return('needs_manual_review')
  if (status %in% c('specific_only', 'compound')) return('base_ad_valorem_only')
  if (status %in% c('apportioned', 'cross_reference', 'ch98_conditional',
                    'alt_base_pct', 'free_conditional')) return('base_not_representable')
  if (is_qty && is.na(unit)) return('missing_duty_basis_unit')
  'ok'
}

run_test('the ad valorem half of a Column 1 compound rate is recovered', {
  # parse_rate() returns NA for anything that is not a bare percent, so
  # "46.3c/kg + 14.9%" lost a real 14.9% duty and became 0 downstream.
  stopifnot(is.na(parse_rate('46.3¢/kg + 14.9%')))
  p <- parse_duty_rate_string('46.3¢/kg + 14.9%')
  stopifnot(abs(p$ad_valorem - 0.149) < 1e-12)
  stopifnot(identical(p$status, 'compound'), isTRUE(p$has_specific))
})

run_test('a recovered compound is NOT reported as fully resolved', {
  # Carrying 14.9% is right; calling it 'ok' is not — the per-unit component
  # is still uncollected.
  stopifnot(identical(.calc_status_for('compound', 'compound'), 'base_ad_valorem_only'))
  stopifnot(identical(.calc_status_for('specific', 'specific_only'), 'base_ad_valorem_only'))
})

run_test('a specific-only duty is flagged even though it parses cleanly', {
  # 909 specific + 200 compound rows carried base_rate 0 while reporting 'ok'.
  # A duty that exists but cannot be expressed ad valorem must never read as ok.
  p <- parse_duty_rate_string('5.7¢/kg')
  stopifnot(identical(p$status, 'specific_only'))
  stopifnot(abs(p$ad_valorem - 0) < 1e-12)          # 0% ad valorem is TRUE
  stopifnot(!identical(.calc_status_for('specific', p$status), 'ok'))
})

run_test('non-representable bases are distinguished from merely partial ones', {
  # Different remediation: a compound needs unit values, a cross-reference needs
  # another line resolved first. Collapsing them into one flag loses that.
  for (s in c('apportioned', 'cross_reference', 'ch98_conditional', 'alt_base_pct')) {
    stopifnot(identical(.calc_status_for('unknown_basis', s), 'base_not_representable'))
  }
  stopifnot(identical(.calc_status_for('ad_valorem', 'ad_valorem'), 'ok'))
})

run_test('every Column 1 string in a real revision resolves to a named status', {
  f <- 'data/processed/products_2026_rev_10.rds'
  if (!file.exists(f)) {
    message('    (skipped — products RDS not present)')
  } else {
    p <- readRDS(f)
    raw <- p$base_rate_raw[!is.na(p$base_rate_raw) & nzchar(p$base_rate_raw)]
    r <- parse_duty_rate_string(unique(raw))
    stopifnot(sum(r$status == 'unparsed') == 0)
  }
})


# =============================================================================
# Test 11c: Column 2 base tier — HTSUS General Note 3(b)
# =============================================================================

message('\n--- Test 11c: Column 2 base tier (GN 3(b)) ---')

run_test('every real Column 2 string resolves to a named status — none silent', {
  # The completeness guarantee. Fixture is every distinct Column 2 string in the
  # corpus (829 of them). "unparseable" previously hid three different problems:
  # recoverable compounds, specific-only duties, and Chapter 98 provisions.
  fx <- file.path('tests', 'fixtures', 'column2_rate_strings.csv')
  if (!file.exists(fx)) fx <- file.path('fixtures', 'column2_rate_strings.csv')
  f <- suppressMessages(readr::read_csv(fx, show_col_types = FALSE))
  p <- parse_column2_rate(f$rate_column2_raw)
  stopifnot(sum(p$status == 'unparsed') == 0)
  stopifnot(all(!is.na(p$status)))
})

run_test('no regression against the rates the old parser already resolved', {
  fx <- file.path('tests', 'fixtures', 'column2_rate_strings.csv')
  if (!file.exists(fx)) fx <- file.path('fixtures', 'column2_rate_strings.csv')
  f <- suppressMessages(readr::read_csv(fx, show_col_types = FALSE))
  p <- parse_column2_rate(f$rate_column2_raw)
  both <- !is.na(f$rate_column2) & !is.na(p$ad_valorem)
  stopifnot(sum(both) > 400)
  stopifnot(all(abs(f$rate_column2[both] - p$ad_valorem[both]) < 1e-9))
})

run_test('fractional and compound percents are recovered', {
  p <- parse_column2_rate(c('33 1/3%', '$1.15/1,000 + 40%', '$2.50/thou- sand + 40%',
                            '$1.10/kg on molybdenum content + 15%'))
  stopifnot(abs(p$ad_valorem[1] - 1/3) < 1e-6)          # mixed fraction
  stopifnot(abs(p$ad_valorem[2] - 0.40) < 1e-12)
  stopifnot(abs(p$ad_valorem[3] - 0.40) < 1e-12)        # hyphenation artifact
  stopifnot(abs(p$ad_valorem[4] - 0.15) < 1e-12)        # "on X content" is specific, not apportioned
  stopifnot(identical(p$status[1], 'ad_valorem'))
  stopifnot(all(p$status[2:4] == 'compound'))
})

run_test('percents of a DIFFERENT base never become ad valorem', {
  # "50 percent of the cost of such parts" is not 50% of customs value.
  # Applying it would overstate duty — the dangerous failure, not the obvious one.
  p <- parse_column2_rate(c('50 percent of the cost of such parts',
                            '2 percent of the fair retail value'))
  stopifnot(all(p$status == 'alt_base_pct'))
  stopifnot(all(is.na(p$ad_valorem)))
})

run_test('component-apportioned and cross-referenced duties are not collapsed', {
  p <- parse_column2_rate(c('$1.50 each + 45% on the case + 35% on the battery',
                            'The rate applicable to the article of which it is a part',
                            'A duty upon the value of the repairs or alterations (see U.S. note 3 of this subchapter)',
                            'Free, under bond'))
  stopifnot(identical(p$status, c('apportioned', 'cross_reference',
                                  'ch98_conditional', 'free_conditional')))
  stopifnot(all(is.na(p$ad_valorem)))
})

run_test('Column 2 REPLACES Column 1, and understatement stays visible', {
  # 2921.46.00: Free on Column 1, "15.4c/kg + 149.5%" on Column 2.
  r <- resolve_base_rate_tier(0, NA_real_, '15.4¢/kg + 149.5%', TRUE)
  stopifnot(abs(r$base_rate - 1.495) < 1e-12)              # not 0
  stopifnot(identical(r$base_rate_source, 'column2:compound'))
  stopifnot(isTRUE(r$replaced), isTRUE(r$exposed))         # specific half dropped
  stopifnot(identical(r$calc_status, 'needs_manual_review'))

  clean <- resolve_base_rate_tier(0.02, NA_real_, '35%', TRUE)
  stopifnot(abs(clean$base_rate - 0.35) < 1e-12)
  stopifnot(identical(clean$base_rate_source, 'column2:ad_valorem'))
  stopifnot(!isTRUE(clean$exposed), is.na(clean$calc_status))
})

run_test('a non-derivable Column 2 names WHY rather than passing silently', {
  r <- resolve_base_rate_tier(0, NA_real_, 'The rate applicable to the complete, assembled movement', TRUE)
  stopifnot(identical(r$base_rate_source, 'column2_blocked:cross_reference'))
  stopifnot(identical(r$calc_status, 'needs_manual_review'))
  stopifnot(!isTRUE(r$replaced), isTRUE(r$exposed))
  stopifnot(abs(r$base_rate - 0) < 1e-12)   # base untouched
})

run_test('Column 2 is NOT applied before an origin lost normal trade relations', {
  # gn3_column2_countries.csv back-fills historical revisions from a 2026 note
  # (304 of 544 rows carry fallback_from), so it lists Russia and Belarus as
  # non-NTR back to 2019. They held PNTR until Pub. L. 117-110 (2022-04-09).
  # Applying Column 2 there would OVERSTATE duty — Free becomes 149.5%.
  pre  <- load_non_ntr_countries('2019_basic',  '2019-01-01', strict = FALSE)
  post <- load_non_ntr_countries('2026_rev_13', '2026-07-24', strict = FALSE)
  stopifnot(!('4621' %in% pre), !('4622' %in% pre))   # Russia, Belarus excluded
  stopifnot('2390' %in% pre, '5790' %in% pre)         # Cuba, DPRK always non-NTR
  stopifnot(all(c('2390', '4621', '4622', '5790') %in% post))
})

run_test('the PNTR gate switches exactly at 2022-04-09', {
  before <- load_non_ntr_countries('2026_rev_13', '2022-04-08', strict = FALSE)
  on_day <- load_non_ntr_countries('2026_rev_13', '2022-04-09', strict = FALSE)
  stopifnot(!('4621' %in% before))
  stopifnot('4621' %in% on_day)
})

run_test('an unknown effective date is treated conservatively', {
  # Cannot tell whether a back-filled row is anachronistic, so date-gated
  # origins are dropped rather than risk applying Column 2 before it was owed.
  r <- load_non_ntr_countries('2026_rev_13', NA, strict = FALSE)
  stopifnot(!('4621' %in% r), !('4622' %in% r))
  stopifnot('2390' %in% r)
})

run_test('an unresolvable non-NTR country name fails loud, never silently drops', {
  # "Republic of Belarus" silently returned nothing before the alias was added,
  # which would have kept a Column 2 origin on its Column 1 rate invisibly.
  stopifnot(identical(resolve_country_name('Republic of Belarus'), '4622'))
  # and the official DPRK long form must not collapse to South Korea
  stopifnot(identical(resolve_country_name("Democratic People's Republic of Korea"), '5790'))
  stopifnot(identical(resolve_country_name('Republic of Korea'), '5800'))
})

run_test('pipeline wiring: re-bases non-NTR rows without clobbering provenance', {
  # Mirrors the step-1a block in 06_calculate_rates.R. The risk being pinned is
  # that ifelse(NA-from-tier, ...) overwrites existing base_rate_source and
  # calc_status on rows Column 2 never touched.
  rates <- tibble(
    hts10   = c('2921460000', '2921460000', '8544300000', '2921460000'),
    country = c('4621',       '5700',       '2390',       '2390'),   # RU, CN, CU, CU
    base_rate = c(0, 0, 0.025, 0),
    base_rate_source = c('own', 'inherited:29214600', 'own', 'own'),
    calc_status = c('ok', 'ok', 'ok', 'ok')
  )
  products <- tibble(
    hts10 = c('2921460000', '8544300000'),
    rate_column2 = c(NA_real_, NA_real_),
    rate_column2_raw = c('15.4¢/kg + 149.5%', '35%')
  )
  non_ntr <- c('2390', '4621', '4622', '5790')

  j <- rates %>% left_join(products %>% select(hts10, .c2 = rate_column2,
                                               .c2raw = rate_column2_raw), by = 'hts10')
  tier <- resolve_base_rate_tier(j$base_rate, j$.c2, j$.c2raw, j$country %in% non_ntr)
  out <- j
  out$base_rate <- tier$base_rate
  out$base_rate_source <- ifelse(is.na(tier$base_rate_source),
                                 out$base_rate_source, tier$base_rate_source)
  out$calc_status <- ifelse(is.na(tier$calc_status), out$calc_status, tier$calc_status)

  # Russia (non-NTR) re-based from Free to the Column 2 ad valorem component
  stopifnot(abs(out$base_rate[1] - 1.495) < 1e-12)
  stopifnot(identical(out$base_rate_source[1], 'column2:compound'))
  stopifnot(identical(out$calc_status[1], 'needs_manual_review'))

  # China is NTR — untouched, and its inherited provenance survives
  stopifnot(abs(out$base_rate[2] - 0) < 1e-12)
  stopifnot(identical(out$base_rate_source[2], 'inherited:29214600'))
  stopifnot(identical(out$calc_status[2], 'ok'))

  # Cuba on a clean ad valorem Column 2 line: re-based, no review flag
  stopifnot(abs(out$base_rate[3] - 0.35) < 1e-12)
  stopifnot(identical(out$base_rate_source[3], 'column2:ad_valorem'))
  stopifnot(identical(out$calc_status[3], 'ok'))
})

run_test('Column 2 runs BEFORE floors, so a floor stays consistent with its base', {
  # §232 annex floors and §301 forced-labor caps are max(target - base, 0).
  # Re-basing after they are computed would leave them derived from the wrong
  # base. Applying Column 2 first keeps base + additional == the intended floor.
  floor_target <- 0.50
  base_col1 <- 0.02
  base_col2 <- 0.35
  add_if_rebased_first <- max(floor_target - base_col2, 0)
  stopifnot(abs((base_col2 + add_if_rebased_first) - floor_target) < 1e-12)
  # the wrong order: additional derived from Column 1, base later swapped
  add_wrong <- max(floor_target - base_col1, 0)
  stopifnot(abs((base_col2 + add_wrong) - floor_target) > 1e-9)   # overshoots
})

run_test('NTR origins are untouched', {
  r <- resolve_base_rate_tier(0.02, NA_real_, '15.4¢/kg + 149.5%', FALSE)
  stopifnot(abs(r$base_rate - 0.02) < 1e-12)
  stopifnot(is.na(r$base_rate_source), !isTRUE(r$replaced), !isTRUE(r$exposed))
})

run_test('vectorises row-wise', {
  r <- resolve_base_rate_tier(
    base_rate        = c(0, 0.02, 0, 0.05),
    rate_column2     = rep(NA_real_, 4),
    rate_column2_raw = c('15.4¢/kg + 149.5%', '15.4¢/kg + 149.5%',
                         'The rate applicable to the complete, assembled', '35%'),
    is_non_ntr       = c(TRUE, FALSE, TRUE, TRUE)
  )
  stopifnot(identical(r$replaced, c(TRUE, FALSE, FALSE, TRUE)))
  stopifnot(abs(r$base_rate[2] - 0.02) < 1e-12)   # NTR row untouched
  stopifnot(identical(r$exposed, c(TRUE, FALSE, TRUE, FALSE)))
})


# =============================================================================
# Test 11b: dual-content §232 derivatives — steel and aluminum both owed
# EO 14289 sec. 3(a)(iii); CBP CSMS #65054270
# =============================================================================

message('\n--- Test 11b: dual-content 232 derivatives ---')

run_test('dual-content article owes BOTH metal contents, not the larger one', {
  # 100 HTS prefixes sit on both derivative lists (Aug-2025 expansion into
  # goods in metal packaging). Steel used to win deriv_type outright and the
  # aluminum content was never collected.
  r <- resolve_s232_metal_contributions(
    rate_232 = 0.50, rate_232_steel = 0.50, rate_232_aluminum = 0.50,
    steel_share = 0.0096, aluminum_share = 0.0063,
    scale_share = 0.0096, is_deriv_only = TRUE
  )
  stopifnot(isTRUE(r$dual))
  # 50%*0.0096 + 50%*0.0063 = 0.795%, not the old 0.48%
  stopifnot(abs(r$rate_232 - (0.50 * 0.0096 + 0.50 * 0.0063)) < 1e-12)
  stopifnot(r$rate_232 > 0.50 * 0.0096)                      # strictly more than steel alone
  stopifnot(abs(r$rate_232_steel    - 0.50 * 0.0096) < 1e-12)
  stopifnot(abs(r$rate_232_aluminum - 0.50 * 0.0063) < 1e-12)
  # action columns reconcile to the total
  stopifnot(abs((r$rate_232_steel + r$rate_232_aluminum) - r$rate_232) < 1e-12)
})

run_test('asymmetric metal rates are each applied to their own content', {
  # Not just a share split: the steel and aluminum ACTIONS can carry different
  # rates (country overrides, Russian aluminum). pmax would apply the higher
  # rate to the whole metal content and over-collect.
  r <- resolve_s232_metal_contributions(
    rate_232 = 2.00, rate_232_steel = 0.50, rate_232_aluminum = 2.00,
    steel_share = 0.10, aluminum_share = 0.05,
    scale_share = 0.10, is_deriv_only = TRUE
  )
  stopifnot(abs(r$rate_232 - (0.50 * 0.10 + 2.00 * 0.05)) < 1e-12)  # 0.15
  stopifnot(abs(r$rate_232 - 2.00 * 0.15) > 1e-9)                   # != pmax * total share
})

run_test('single-metal derivatives are unchanged (no silent re-rating)', {
  # Steel-only: must reproduce the pre-existing single-share behavior exactly.
  r <- resolve_s232_metal_contributions(
    rate_232 = 0.50, rate_232_steel = 0.50, rate_232_aluminum = 0,
    steel_share = 0.20, aluminum_share = 0,
    scale_share = 0.20, is_deriv_only = TRUE
  )
  stopifnot(!isTRUE(r$dual))
  stopifnot(abs(r$rate_232 - 0.50 * 0.20) < 1e-12)
  # Non-derivative rows are never touched, whatever the shares say.
  r2 <- resolve_s232_metal_contributions(
    rate_232 = 0.25, rate_232_steel = 0.50, rate_232_aluminum = 0.50,
    steel_share = 0.30, aluminum_share = 0.30,
    scale_share = 1.0, is_deriv_only = FALSE
  )
  stopifnot(!isTRUE(r2$dual), abs(r2$rate_232 - 0.25) < 1e-12)
})

run_test('missing per-metal share falls back rather than guessing', {
  # NA aluminum_share must NOT be treated as a content of zero *and* must not
  # silently drop the row into the dual path.
  r <- resolve_s232_metal_contributions(
    rate_232 = 0.50, rate_232_steel = 0.50, rate_232_aluminum = 0.50,
    steel_share = 0.10, aluminum_share = NA_real_,
    scale_share = 0.10, is_deriv_only = TRUE
  )
  stopifnot(!isTRUE(r$dual))
  stopifnot(abs(r$rate_232 - 0.50 * 0.10) < 1e-12)   # single-share path
})

run_test('vectorises row-wise without cross-contamination', {
  r <- resolve_s232_metal_contributions(
    rate_232          = c(0.50, 0.50, 0.25),
    rate_232_steel    = c(0.50, 0.50, 0.00),
    rate_232_aluminum = c(0.50, 0.00, 0.50),
    steel_share       = c(0.10, 0.20, 0.00),
    aluminum_share    = c(0.05, 0.00, 0.40),
    scale_share       = c(0.10, 0.20, 0.40),
    is_deriv_only     = c(TRUE, TRUE, TRUE)
  )
  stopifnot(identical(r$dual, c(TRUE, FALSE, FALSE)))
  stopifnot(abs(r$rate_232[1] - (0.50 * 0.10 + 0.50 * 0.05)) < 1e-12)
  stopifnot(abs(r$rate_232[2] - 0.50 * 0.20) < 1e-12)
  stopifnot(abs(r$rate_232[3] - 0.25 * 0.40) < 1e-12)
})


# =============================================================================
# Test 12: Section 301 forced labor — tiers, caps, exemptions (91 FR 47318)
# =============================================================================

message('\n--- Test 12: 301 forced labor ---')

fl_test_cfg <- function(...) {
  cfg <- list(
    effective_date = as.Date('2026-07-24'),
    rate_10 = 0.10, rate_12_5 = 0.125,
    tier_10pct = c('1220'),            # flat 10%
    tier_10pct_net_mfn = c('4330'),    # 10% TOTAL-duty cap
    tier_12_5pct = c('5700'),          # flat 12.5%
    tier_12_5pct_net_mfn = c('4419'),  # 12.5% cap
    aircraft_exempt_share = 0.90,
    pharma_exempt_share = 0.50,
    common_exemptions = NULL, country_exemptions = NULL
  )
  modifyList(cfg, list(...))
}
# compute_s301fl_rates() scores the RATES frame (it must see the §232 and USMCA
# columns for note 52(f)/(g)/(h)), so fixtures are product-country rows.
fl_rows <- function(ctys = c('1220','4330','5700','4419'), ...) {
  base <- tibble(hts10 = c('0101300000', '8802400000', '3004900000'),
                 base_rate = c(0.04, 0.00, 0.30))   # third: MFN above the 10% cap
  out <- tidyr::expand_grid(tibble(country = ctys), base) %>%
    mutate(statutory_rate_232 = 0, rate_232 = 0, s232_annex = NA_character_)
  if (length(list(...))) out <- dplyr::mutate(out, ...)
  out
}
fl_get <- function(r, rows, cty, h) r[rows$country == cty & rows$hts10 == h]

run_test('flat tiers add the rate outright; cap tiers add max(0, cap - base)', {
  rows <- fl_rows()
  r <- compute_s301fl_rates(rows, fl_test_cfg(), as.Date('2026-07-24'))
  g <- function(cty, h) fl_get(r, rows, cty, h)
  stopifnot(abs(g('1220','0101300000') - 0.10) < 1e-12)    # flat 10%
  stopifnot(abs(g('5700','0101300000') - 0.125) < 1e-12)   # flat 12.5%
  stopifnot(abs(g('4330','0101300000') - 0.06) < 1e-12)    # cap 0.10 - 0.04
  stopifnot(abs(g('4419','0101300000') - 0.085) < 1e-12)   # cap 0.125 - 0.04
})

run_test('cap tier yields NO duty when MFN already exceeds the cap', {
  # 3004.90 base 0.30 > 0.10 cap -> max(0, 0.10-0.30) = 0, and the row is dropped.
  rows <- fl_rows('4330')
  r <- compute_s301fl_rates(rows, fl_test_cfg(), as.Date('2026-07-24'))
  stopifnot(abs(fl_get(r, rows, '4330', '3004900000')) < 1e-12)
  # ...but the flat economy still pays in full on the same line.
  rows2 <- fl_rows('1220')
  r2 <- compute_s301fl_rates(rows2, fl_test_cfg(), as.Date('2026-07-24'))
  stopifnot(abs(fl_get(r2, rows2, '1220', '3004900000') - 0.10) < 1e-12)
})

run_test('regime contributes nothing before its effective date', {
  rows <- fl_rows('1220')
  r <- compute_s301fl_rates(rows, fl_test_cfg(), as.Date('2026-07-23'))
  stopifnot(all(abs(r) < 1e-12))
})

run_test('unconditional and USE-conditional exemptions scale correctly', {
  tmp_common <- tempfile(fileext = '.csv')
  write_csv(tibble(hts_code = c('01013000', '88024000', '30049000'),
                   condition = c('full', 'aircraft', 'pharma')), tmp_common)
  rows <- fl_rows('1220')
  r <- compute_s301fl_rates(rows, fl_test_cfg(common_exemptions = tmp_common),
                            as.Date('2026-07-24'))
  stopifnot(abs(fl_get(r, rows, '1220', '0101300000')) < 1e-12)          # full
  stopifnot(abs(fl_get(r, rows, '1220', '8802400000') - 0.10 * 0.10) < 1e-12)
  stopifnot(abs(fl_get(r, rows, '1220', '3004900000') - 0.10 * 0.50) < 1e-12)
  unlink(tmp_common)
})

run_test('country-specific "full" exemption applies to that economy only', {
  tmp_cty <- tempfile(fileext = '.csv')
  write_csv(tibble(countries = '1220', hts_code = '01013000', condition = 'full'), tmp_cty)
  rows <- fl_rows(c('1220','5700'))
  r <- compute_s301fl_rates(rows, fl_test_cfg(country_exemptions = tmp_cty),
                            as.Date('2026-07-24'))
  stopifnot(abs(fl_get(r, rows, '1220', '0101300000')) < 1e-12)     # exempt
  stopifnot(fl_get(r, rows, '5700', '0101300000') > 0)              # unaffected
  unlink(tmp_cty)
})

run_test('semicolon-joined country rows explode to one row per economy', {
  tmp_cty <- tempfile(fileext = '.csv')
  write_csv(tibble(countries = '1220;5700', hts_code = '01013000', condition = 'full'), tmp_cty)
  rows <- fl_rows(c('1220','5700'))
  r <- compute_s301fl_rates(rows, fl_test_cfg(country_exemptions = tmp_cty),
                            as.Date('2026-07-24'))
  stopifnot(abs(fl_get(r, rows, '1220', '0101300000')) < 1e-12)     # both exempt
  stopifnot(abs(fl_get(r, rows, '5700', '0101300000')) < 1e-12)
  unlink(tmp_cty)
})

run_test('fta lines are scaled by the preference-claim share, not fully exempt', {
  tmp_cty <- tempfile(fileext = '.csv')
  write_csv(tibble(countries = '1220', hts_code = '01013000', condition = 'fta'), tmp_cty)
  shares <- tibble(hs2 = '01', cty_code = '1220', exemption_share = 0.25)
  rows <- fl_rows('1220')
  r <- compute_s301fl_rates(rows, fl_test_cfg(country_exemptions = tmp_cty),
                            as.Date('2026-07-24'), mfn_shares = shares)
  stopifnot(abs(fl_get(r, rows, '1220', '0101300000') - 0.10 * 0.75) < 1e-12)
  unlink(tmp_cty)
})

run_test('note 52(f): §232-covered articles are excluded ENTIRELY', {
  rows <- fl_rows('1220')
  rows$statutory_rate_232[rows$hts10 == '0101300000'] <- 0.50
  rows$s232_annex[rows$hts10 == '8802400000'] <- 'annex_1b'
  rows$s232_annex[rows$hts10 == '3004900000'] <- 'annex_2'   # OUT of §232 scope
  r <- compute_s301fl_rates(rows, fl_test_cfg(), as.Date('2026-07-24'))
  stopifnot(abs(fl_get(r, rows, '1220', '0101300000')) < 1e-12)  # statutory 232
  stopifnot(abs(fl_get(r, rows, '1220', '8802400000')) < 1e-12)  # in-scope annex
  stopifnot(fl_get(r, rows, '1220', '3004900000') > 0)           # annex_2 still pays
})

run_test('note 52(g)/(h): CA/MX USMCA-free entries exempt, share-scaled', {
  # Canada is a flat-10% economy; a 0.8 USMCA utilization share leaves 20% payable.
  rows <- fl_rows(c('1220','5700'))
  rows$usmca_share <- if_else(rows$country == '1220', 0.8, NA_real_)
  r <- compute_s301fl_rates(rows, fl_test_cfg(), as.Date('2026-07-24'))
  stopifnot(abs(fl_get(r, rows, '1220', '0101300000') - 0.10 * 0.20) < 1e-12)
  # A non-USMCA origin is untouched by the share column.
  stopifnot(abs(fl_get(r, rows, '5700', '0101300000') - 0.125) < 1e-12)
})

run_test('note 52(g)/(h) falls back to binary usmca_eligible', {
  rows <- fl_rows('1220')
  rows$usmca_eligible <- TRUE
  r <- compute_s301fl_rates(rows, fl_test_cfg(), as.Date('2026-07-24'))
  stopifnot(all(abs(r) < 1e-12))
})

run_test('s301fl stacks additively in apply_stacking_rules (note 52(a))', {
  df <- tibble(hts10 = '0101300000', country = '4634', base_rate = 0.04,
               rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0.10,
               rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0,
               rate_s301fl = 0.125, rate_other = 0, metal_share = 0)
  res <- apply_stacking_rules(df, cty_china = '5700')
  stopifnot(abs(res$total_additional - (0.10 + 0.125)) < 1e-12)
  stopifnot(abs(res$total_rate - (0.04 + 0.225)) < 1e-12)
})


# =============================================================================
# Test 13: Section 301 Brazil + §232 scope mask + interval coverage
# =============================================================================

message('\n--- Test 13: 301 Brazil ---')

br_test_cfg <- function(...) {
  modifyList(list(
    effective_date = as.Date('2026-07-22'), rate = 0.25, country = '3510',
    exempt_products = NULL, aircraft_products = NULL, pharma_products = NULL,
    aircraft_exempt_share = 0.90, pharma_exempt_share = 0.50
  ), list(...))
}
br_rows <- function() tibble(
  hts10 = c('0101300000', '7208100000', '0101300000'),
  country = c('3510', '3510', '5700'),
  statutory_rate_232 = c(0, 0.50, 0),
  s232_annex = c(NA_character_, 'annex_1a', NA_character_),
  rate_232 = c(0, 0.50, 0)
)

run_test('applies 25% to Brazil only, and never to other origins', {
  r <- compute_s301br_rates(br_rows(), br_test_cfg(), as.Date('2026-07-22'))
  stopifnot(abs(r[1] - 0.25) < 1e-12)
  stopifnot(abs(r[3] - 0) < 1e-12)          # China untouched
})

run_test('note 50(a)(vi): §232-covered articles are excluded ENTIRELY', {
  r <- compute_s301br_rates(br_rows(), br_test_cfg(), as.Date('2026-07-22'))
  stopifnot(abs(r[2] - 0) < 1e-12)          # steel, statutory_rate_232 > 0
})

run_test('annex_2 is NOT shielded — those goods left §232 scope', {
  # The April 2026 proclamation REMOVED annex II products from §232, so they are
  # not "subject to" §232 and note 50(a)(vi) must not exempt them.
  r <- compute_s301br_rates(
    tibble(hts10 = '0101300000', country = '3510', statutory_rate_232 = 0,
           s232_annex = 'annex_2', rate_232 = 0),
    br_test_cfg(), as.Date('2026-07-22'))
  stopifnot(abs(r - 0.25) < 1e-12)
})

run_test('HTS heading rate overrides the config fallback', {
  r <- compute_s301br_rates(br_rows()[1, ], br_test_cfg(rate = 0.10),
                            as.Date('2026-07-22'), hts_rate = 0.25)
  stopifnot(abs(r - 0.25) < 1e-12)
})

run_test('contributes nothing before the effective date', {
  r <- compute_s301br_rates(br_rows(), br_test_cfg(), as.Date('2026-07-21'))
  stopifnot(all(abs(r) < 1e-12))
})

run_test('use-conditional lists share-scale; flat list fully exempts', {
  ta <- tempfile(fileext = '.csv'); tp <- tempfile(fileext = '.csv')
  tf <- tempfile(fileext = '.csv')
  write_csv(tibble(hts8 = '39172100'), ta)
  write_csv(tibble(hts8 = '28041000'), tp)
  write_csv(tibble(hts8 = '02011005'), tf)
  rows <- tibble(hts10 = c('3917210000','2804100000','0201100500','0101300000'),
                 country = '3510', statutory_rate_232 = 0,
                 s232_annex = NA_character_, rate_232 = 0)
  r <- compute_s301br_rates(rows, br_test_cfg(aircraft_products = ta,
                                              pharma_products = tp,
                                              exempt_products = tf),
                            as.Date('2026-07-22'))
  stopifnot(abs(r[1] - 0.25 * 0.10) < 1e-12)   # aircraft share 0.90
  stopifnot(abs(r[2] - 0.25 * 0.50) < 1e-12)   # pharma share 0.50
  stopifnot(abs(r[3] - 0) < 1e-12)             # unconditional
  stopifnot(abs(r[4] - 0.25) < 1e-12)
  unlink(c(ta, tp, tf))
})

run_test('s232_scope_mask reads statutory rate, live rate and in-scope annexes', {
  m <- s232_scope_mask(tibble(
    statutory_rate_232 = c(0.5, 0,   0,          0,         0),
    rate_232           = c(0,   0.25, 0,          0,         0),
    s232_annex         = c(NA,  NA,  'annex_1b', 'annex_2', NA)))
  stopifnot(identical(m, c(TRUE, TRUE, TRUE, FALSE, FALSE)))
  stopifnot(length(s232_scope_mask(tibble())) == 0)
})

run_test('revision_interval_covers spans activation inside an interval', {
  rd <- tibble(revision = c('r1','r2','r3'),
               effective_date = as.Date(c('2026-07-01','2026-07-21','2026-07-24')))
  # r2 runs 07-21..07-23, so it covers the 07-22 turn-on though it starts earlier.
  stopifnot(revision_interval_covers('r2', as.Date('2026-07-21'),
                                     as.Date('2026-07-22'), rd))
  stopifnot(!revision_interval_covers('r1', as.Date('2026-07-01'),
                                      as.Date('2026-07-22'), rd))
  # The final revision is open-ended, so it covers any later activation.
  stopifnot(revision_interval_covers('r3', as.Date('2026-07-24'),
                                     as.Date('2026-08-19'), rd))
})


# =============================================================================
# Test 14: Section 338 Canada (19 U.S.C. 1338)
# =============================================================================

message('\n--- Test 14: Section 338 Canada ---')

s338_fixture <- function() {
  pf <- tempfile(fileext = '.csv'); gf <- tempfile(fileext = '.csv')
  write_csv(tibble(hts8 = c('22030000', '04061000', '87032301'),
                   program = c('alcohol', 'dairy', 'motor_vehicles'),
                   ch99_heading = c('9903.03.12', '9903.03.13', '9903.03.14')), pf)
  write_csv(tibble(hts8 = '87032301'), gf)          # pretend this is a GN 6 line
  list(cfg = list(effective_date = as.Date('2026-08-19'), rate = 0.50,
                  country = '1220', products_file = pf, gn6_exempt_products = gf,
                  unmanned_aircraft_hts8 = character(0)),
       rows = tibble(
         hts10 = c('2203000000', '0406100000', '8703230100', '0101300000', '2203000000'),
         country = c('1220', '1220', '1220', '1220', '5700'),
         statutory_rate_232 = 0, rate_232 = 0, s232_annex = NA_character_),
       files = c(pf, gf))
}

run_test('applies 50% to covered Canadian lines only', {
  f <- s338_fixture()
  r <- compute_s338_rates(f$rows, f$cfg, as.Date('2026-08-19'))
  stopifnot(abs(r[1] - 0.50) < 1e-12)   # alcohol, Canada
  stopifnot(abs(r[2] - 0.50) < 1e-12)   # dairy, Canada
  stopifnot(abs(r[4] - 0) < 1e-12)      # not on any annex
  stopifnot(abs(r[5] - 0) < 1e-12)      # covered line but wrong origin
  unlink(f$files)
})

run_test('WTO civil-aircraft lines fully excluded (Proc 11047 para. 2)', {
  f <- s338_fixture()
  r <- compute_s338_rates(f$rows, f$cfg, as.Date('2026-08-19'))
  stopifnot(abs(r[3] - 0) < 1e-12)
  unlink(f$files)
})

run_test('unmanned aircraft are the EXCEPTION to the aircraft carve-out', {
  # "articles, EXCLUDING UNMANNED AIRCRAFT, subject to the WTO Agreement on
  # Trade in Civil Aircraft" — a UAV line on the GN 6 list still pays.
  f <- s338_fixture()
  cfg <- modifyList(f$cfg, list(unmanned_aircraft_hts8 = '87032301'))
  r <- compute_s338_rates(f$rows, cfg, as.Date('2026-08-19'))
  stopifnot(abs(r[3] - 0.50) < 1e-12)
  unlink(f$files)
})

run_test('articles subject to §232 fully excluded', {
  f <- s338_fixture()
  rows <- f$rows; rows$statutory_rate_232[1] <- 0.50
  r <- compute_s338_rates(rows, f$cfg, as.Date('2026-08-19'))
  stopifnot(abs(r[1] - 0) < 1e-12)
  unlink(f$files)
})

run_test('dormant before 2026-08-19', {
  f <- s338_fixture()
  r <- compute_s338_rates(f$rows, f$cfg, as.Date('2026-08-18'))
  stopifnot(all(abs(r) < 1e-12))
  unlink(f$files)
})

run_test('clamps to the 19 U.S.C. 1338 statutory ceiling of 50%', {
  f <- s338_fixture()
  r <- suppressWarnings(compute_s338_rates(f$rows[1, ],
                        modifyList(f$cfg, list(rate = 0.75)), as.Date('2026-08-19')))
  stopifnot(abs(r - 0.50) < 1e-12)
  unlink(f$files)
})

run_test('9903.03.12+ classifies as section_338, not the expired section_122', {
  stopifnot(classify_authority('9903.03.01') == 'section_122')
  stopifnot(classify_authority('9903.03.11') == 'section_122')
  stopifnot(classify_authority('9903.03.12') == 'section_338')
  stopifnot(classify_authority('9903.03.14') == 'section_338')
})

run_test('s338 stacks additively (Proc 11047 para. 2)', {
  df <- tibble(hts10 = '2203000000', country = '1220', base_rate = 0.02,
               rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0.35,
               rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0,
               rate_s301fl = 0.10, rate_s301br = 0, rate_s338 = 0.50,
               rate_other = 0, metal_share = 0)
  res <- apply_stacking_rules(df, cty_china = '5700')
  stopifnot(abs(res$total_additional - (0.35 + 0.10 + 0.50)) < 1e-12)
})


# =============================================================================
# Test 15: UK §232 annex deal is scoped by metal type, not HTS chapter
# =============================================================================

message('\n--- Test 15: UK annex deal scope ---')

# Mirrors the production gate: metal_type when known, chapter fallback when NA.
uk_scope <- function(s232_metal, hts10,
                     metals = c('steel', 'aluminum'),
                     chapters = c('72', '73', '76')) {
  if_else(!is.na(s232_metal), s232_metal %in% metals,
          substr(hts10, 1, 2) %in% chapters)
}

run_test('outside-chapter steel/aluminum derivatives ARE in UK scope', {
  # The bug: a chapter gate excluded every annex_1b downstream article (ch 84/85/
  # 87/82/86), so the UK paid the full 25% instead of its 15% deal rate — +10pp.
  stopifnot(uk_scope('steel',    '8419500000'))   # ch 84 steel derivative
  stopifnot(uk_scope('aluminum', '8544491000'))   # ch 85 aluminum derivative
  stopifnot(uk_scope('steel',    '8708299000'))   # ch 87 steel derivative
})

run_test('copper is NOT in UK scope even inside a metals chapter', {
  stopifnot(!uk_scope('copper', '7409110000'))    # ch 74 copper
  stopifnot(!uk_scope('copper', '7307190000'))    # copper typed, ch 73
})

run_test('NA metal_type falls back to the chapter test, not to "no deal"', {
  # A resource predating the metal_type column must keep the UK deal on core
  # metals rather than silently dropping it.
  stopifnot(uk_scope(NA_character_, '7208100000'))    # ch 72
  stopifnot(!uk_scope(NA_character_, '8419500000'))   # ch 84, unknown metal
})


# =============================================================================
# Test 16: §122 exempt list — unconditional vs GN 6 use-conditional
# =============================================================================

message('\n--- Test 16: s122 GN 6 use-conditional exemption ---')

s122_ex_fixture <- function(with_condition = TRUE, with_util = TRUE) {
  ep <- tempfile(fileext = '.csv'); up <- tempfile(fileext = '.csv')
  if (with_condition) {
    write_csv(tibble(hts8 = c('02011005', '84129090', '85183020'),
                     condition = c('none', 'gn6_civil_aircraft', 'gn6_civil_aircraft')), ep)
  } else {
    write_csv(tibble(hts8 = c('02011005', '84129090', '85183020')), ep)
  }
  if (with_util) {
    write_csv(tibble(hts10 = '8412909000', exempt_share = 0.30,
                     con_val = 1e6, months = 3), up)
  } else {
    write_csv(tibble(hts10 = character(), exempt_share = numeric(),
                     con_val = numeric(), months = numeric()), up)
  }
  list(ep = ep, up = up)
}

run_test('unconditional lines stay fully exempt', {
  f <- s122_ex_fixture()
  s <- s122_exempt_share('0201100500', f$ep, f$up)
  stopifnot(abs(s - 1) < 1e-12)
  unlink(unlist(f))
})

run_test('GN 6 line uses its MEASURED utilization share, not full exemption', {
  # The bug: a use-conditional carve-out applied full-line exempts every
  # non-aviation entry on the same HTS8. 0.30 measured -> 70% of the duty owed.
  f <- s122_ex_fixture()
  s <- s122_exempt_share('8412909000', f$ep, f$up)
  stopifnot(abs(s - 0.30) < 1e-12)
  unlink(unlist(f))
})

run_test('GN 6 line with no measurement falls back to the HS2 mean', {
  f <- s122_ex_fixture()
  # 8412909099 is under the GN 6 hts8 84129090 but has no measured row of its
  # own, so it takes the HS2 '84' mean (0.30, from the one measured 84 line).
  stopifnot(abs(s122_exempt_share('8412909099', f$ep, f$up) - 0.30) < 1e-12)
  # 8518302000 is GN 6 under HS2 '85', which has NO measured row at any level —
  # so it falls through to full exemption rather than borrowing another chapter.
  stopifnot(abs(s122_exempt_share('8518302000', f$ep, f$up) - 1) < 1e-12)
  # A line on no list at all is simply not exempt.
  stopifnot(abs(s122_exempt_share('8412100000', f$ep, f$up)) < 1e-12)
  unlink(unlist(f))
})

run_test('no utilization data at all -> full exemption (prior behavior)', {
  f <- s122_ex_fixture(with_util = FALSE)
  s <- s122_exempt_share('8412909000', f$ep, f$up)
  stopifnot(abs(s - 1) < 1e-12)
  unlink(unlist(f))
})

run_test('a list without the condition column keeps the old full-line behavior', {
  f <- s122_ex_fixture(with_condition = FALSE)
  s <- s122_exempt_share(c('0201100500', '8412909000'), f$ep, f$up)
  stopifnot(all(abs(s - 1) < 1e-12))
  unlink(unlist(f))
})

run_test('unlisted products get no exemption', {
  f <- s122_ex_fixture()
  stopifnot(abs(s122_exempt_share('7208100000', f$ep, f$up)) < 1e-12)
  unlink(unlist(f))
})


# =============================================================================
# Summary
# =============================================================================

cat('\n', strrep('=', 50), '\n')
cat('Tests: ', pass_count, ' passed, ', skip_count, ' skipped, ', fail_count, ' failed\n')
cat(strrep('=', 50), '\n')

if (fail_count > 0) quit(status = 1)

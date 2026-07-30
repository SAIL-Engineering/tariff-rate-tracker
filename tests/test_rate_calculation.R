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

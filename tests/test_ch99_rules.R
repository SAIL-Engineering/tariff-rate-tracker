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
  deriv_ch99_code = c('9903.85.08', '9903.85.04', '9903.85.07', NA, NA),
  # Action subtotals do not prove product-specific reporting headings.
  rate_232_auto = 0,
  rate_232_steel = c(0, 0, 0, 0.5, 0),
  rate_232_aluminum = c(0.09, 0.5, 0.5, 0, 0.5),
  rate_232_copper = 0,
  rate_232_other = 0
)

run_test('product-level subdivision codes win (the 8536.90.8585 bug)', {
  out <- resolve_ch99_codes(rates_fixture, ch99_fixture, deriv_products = deriv_csv)
  stopifnot(out$ch99_code_232[out$hts10 == '8536908585'] == '9903.85.08')
  stopifnot(out$ch99_code_232[out$hts10 == '7614105000'] == '9903.85.04')
  stopifnot(out$ch99_code_232[out$hts10 == '7616995190'] == '9903.85.07')
})

run_test('a missing derivative reporting source remains unresolved', {
  out <- resolve_ch99_codes(rates_fixture, ch99_fixture, deriv_products = deriv_csv)
  stopifnot(is.na(out$ch99_code_232[out$hts10 == '7326908688']))
})

run_test('a metal chapter and matching rate do not prove a base reporting heading', {
  out <- resolve_ch99_codes(rates_fixture, ch99_fixture, deriv_products = deriv_csv)
  stopifnot(is.na(out$ch99_code_232[out$hts10 == '7601103000']))
})

run_test('a withdrawn derivative heading cannot be replaced by another equal-rate heading', {
  ch99_old <- ch99_fixture %>% filter(ch99_code != '9903.85.08')
  out <- resolve_ch99_codes(rates_fixture, ch99_old, deriv_products = deriv_csv)
  code <- out$ch99_code_232[out$hts10 == '8536908585']
  stopifnot(is.na(code))
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

message('\n=== Conditional-scope §232 states the published rate ===')

# 8708.30.50.90 from China in 2026 Rev 23 published 23.76% as the §232
# statutory rate: rate_232 keeps the modelled US-assembly credit (25% less
# 3.75% x 33%), the scope markers blank statutory_rate_232 because the parts
# use is a shipment fact, and the rule fell back to rate_232. The rule must
# state the posted 25% (published_rate_232), ask for the scope fact, and never
# publish the modelled figure as a statutory rate.
#   1 auto part, scope needs the vehicle-use fact
#   2 conditional row with no published rate recorded
#   3 full-value §232 row with no open scope fact
#   4 pre-annex legacy derivative: basis kept beside the published rate
#   5 Korea reciprocal floor, MFN 8.5%, trade-weighted base 1%
cond_fixture <- tibble(
  hts10 = c('8708305090', '8708305090', '8708305090', '7318158085', '6403406000'),
  country = c('5700', '5700', '5700', '5700', '5800'),
  base_rate = c(0.025, 0.025, 0.025, 0.05, 0.01),
  statutory_base_rate = c(0.025, 0.025, 0.025, 0.05, 0.085),
  rate_232 = c(0.237625, 0.237625, 0.237625, 0.1, 0),
  statutory_rate_232 = c(NA, NA, NA, NA, 0),
  published_rate_232 = c(0.25, NA, 0.25, 0.5, NA),
  published_duty_basis_232 = c(NA, NA, NA, 'metal_content_value', NA),
  duty_basis_232 = c('full_value', 'full_value', 'full_value', NA, NA),
  shipment_232_scope_status = c('needs_inputs', 'needs_inputs', NA, NA, NA),
  shipment_232_required_facts_json = c('["is_part_for_passenger_vehicle_or_light_truck"]',
                                       '["is_part_for_passenger_vehicle_or_light_truck"]',
                                       NA, NA, NA),
  rate_301 = 0, rate_ieepa_fent = 0, rate_section_201 = 0,
  rate_ieepa_recip = c(0.1, 0, 0.1, 0.1, 0.14),
  statutory_rate_ieepa_recip = c(0.1, 0, 0.1, 0.1, 0.065),
  rate_s122 = c(0.1, 0, 0, 0.1, 0), statutory_rate_s122 = c(0.1, 0, 0, 0.1, 0),
  metal_share = c(1, 1, 1, 0.4, 1),
  ch99_code_232 = c('9903.94.05', '9903.94.05', '9903.94.05', '9903.81.91', NA),
  ch99_code_ieepa_recip = c('9903.01.25', NA, '9903.01.25', '9903.01.25', '9903.02.73'),
  ch99_code_s122 = c('9903.03.01', NA, NA, '9903.03.01', NA),
  deriv_type = c(NA, NA, NA, 'steel', NA),
  s232_annex = NA_character_, s232_metal = NA_character_,
  usmca_eligible = FALSE
)
cond_ieepa <- tibble(census_code = c('5700', '5800'), ieepa_country_rate = c(0.1, 0.15),
                     ieepa_type = c('surcharge', 'floor'),
                     ieepa_recip_ch99 = c('9903.01.25', '9903.02.73'))
cond_out <- attach_duty_provenance(cond_fixture, country_ieepa = cond_ieepa)
rule_of <- function(i, authority) {
  j <- fromJSON(cond_out$ch99_rules_json[i], simplifyDataFrame = FALSE)
  hit <- Filter(function(x) identical(x$authority, authority), j)
  if (length(hit)) hit[[1]] else NULL
}

run_test('conditional auto part states the published 25%, applied, with the use fact', {
  r <- rule_of(1, 'section_232')
  stopifnot(r$status == 'applied', abs(r$statutory_rate - 0.25) < 1e-9,
            'is_part_for_passenger_vehicle_or_light_truck' %in% unlist(r$required_user_inputs),
            r$stacking_class == 'primary_full')
  p <- fromJSON(cond_out$duty_provenance_json[1], simplifyDataFrame = FALSE)
  stopifnot(abs(p[['232']]$statutory - 0.25) < 1e-9)
})

run_test('a modelled rate_232 is never published as the statutory rate', {
  r <- rule_of(2, 'section_232')
  stopifnot(!is.null(r), r$status == 'applied', is.null(r$statutory_rate))
})

run_test('a full-value row with no open scope fact asks for nothing', {
  r <- rule_of(3, 'section_232')
  stopifnot(abs(r$statutory_rate - 0.25) < 1e-9, is.null(r$required_user_inputs))
})

run_test('reciprocal and §122 are replaced, not applied, where §232 covers the full value', {
  rec <- rule_of(1, 'ieepa_reciprocal'); s122 <- rule_of(1, 'section_122')
  stopifnot(rec$status == 'exempt_or_replaced', s122$status == 'exempt_or_replaced',
            rec$stacking_citation == 's232_full_value_no_content_split',
            s122$stacking_citation == 's232_full_value_no_content_split')
})

run_test('legacy derivative keeps its metal-content basis beside the published rate', {
  r <- rule_of(4, 'section_232')
  stopifnot(abs(r$statutory_rate - 0.5) < 1e-9, r$duty_basis == 'metal_content_value',
            r$stacking_class == 'primary_metal', 'metal_content_value' %in% unlist(r$required_user_inputs))
  # Content split: the reciprocal still applies to the non-metal remainder.
  stopifnot(rule_of(4, 'ieepa_reciprocal')$status == 'applied')
})

run_test('a duty the non-stacking order removes reads replaced and cites the clause', {
  # Mexican auto part (sec. 3(a)(i) removes IEEPA Mexico; §232 stays) and a
  # Canadian steel article before June 4, 2025 (sec. 3(a)(ii) removes §232
  # steel). The weighted columns still carry a remainder; the rules must not
  # say applied.
  auto_trace <- '{"rule":"eo14289_3a_i_auto","suppressed":{"ieepa_camx":0.25},"rules":[{"rule":"eo14289_3a_i_auto","action":"ieepa_mexico","rate":0.25,"citation_key":"eo_14289_non_stacking","cite_locator":"sec. 3(a)(i)"}]}'
  steel_trace <- '{"rule":"eo14289_3a_ii_ieepa_camx","suppressed":{"s232_steel":0.25},"rules":[{"rule":"eo14289_3a_ii_ieepa_camx","action":"s232_steel","rate":0.25,"citation_key":"eo_14289_non_stacking","cite_locator":"sec. 3(a)(ii)"}]}'
  fx <- tibble(hts10 = c('8708936000', '7208101500'), country = c('2010', '1220'),
               base_rate = 0, statutory_base_rate = 0,
               rate_232 = c(0.25, 0.25), statutory_rate_232 = c(0.25, 0),
               rate_301 = 0, rate_ieepa_recip = 0, rate_s122 = 0, rate_section_201 = 0,
               rate_ieepa_fent = c(0.0537, 0.25), statutory_rate_ieepa_fent = c(0, 0.25),
               ch99_code_232 = c('9903.94.05', '9903.80.01'), ch99_code_ieepa_fent = c('9903.01.01', '9903.01.10'),
               duty_basis_232 = 'full_value', metal_share = 1, deriv_type = NA_character_,
               s232_annex = NA_character_, s232_metal = NA_character_, usmca_eligible = FALSE,
               statutory_suppressed_json = c(auto_trace, steel_trace))
  out <- attach_duty_provenance(fx)
  rule <- function(i, a) Filter(function(x) identical(x$authority, a),
                                fromJSON(out$ch99_rules_json[i], simplifyDataFrame = FALSE))[[1]]
  stopifnot(rule(1, 'ieepa_fentanyl')$status == 'exempt_or_replaced',
            rule(1, 'ieepa_fentanyl')$stacking_citation == 'eo14289_3a_i_auto',
            rule(1, 'section_232')$status == 'applied',
            rule(2, 'section_232')$status == 'exempt_or_replaced',
            rule(2, 'section_232')$stacking_citation == 'eo14289_3a_ii_ieepa_camx',
            rule(2, 'ieepa_fentanyl')$status == 'applied')
})

message('\n=== Conditions, in-transit candidates and country-specific IEEPA actions ===')

cx <- tibble(
  # 1 laptop (general-purpose 8471, potential)  2 brake part (8708, applied + confirm)
  # 3 Brazil sweater Aug 10 2025 (reciprocal 10% + EO 40%)  4 China sweater Apr 15 2025 (125%)
  # 5 aluminum derivative from Germany Jul 10 2025 (content split)
  hts10 = c('8471300100', '8708305090', '6110202079', '6110202079', '7616995190'),
  country = c('5700', '5700', '3510', '5700', '4280'),
  effective_date = as.Date(c('2025-07-10', '2025-07-10', '2025-08-10', '2025-04-15', '2025-07-10')),
  base_rate = 0, statutory_base_rate = 0,
  rate_232 = c(0.237625, 0.237625, 0, 0, 0.1), statutory_rate_232 = c(NA, NA, 0, 0, NA),
  published_rate_232 = c(0.25, 0.25, NA, NA, 0.5),
  published_duty_basis_232 = c(NA, NA, NA, NA, 'metal_content_value'),
  duty_basis_232 = c('full_value', 'full_value', NA, NA, NA),
  s232_scope_default = c('potential', 'applied', NA, NA, NA),
  s232_scope_citation = c('s232_auto_parts_use_condition', 's232_auto_parts_use_condition', NA, NA, NA),
  shipment_232_scope_status = c('needs_inputs', 'needs_inputs', NA, NA, NA),
  shipment_232_required_facts_json = c('["is_part_for_passenger_vehicle_or_light_truck"]',
                                       '["is_part_for_passenger_vehicle_or_light_truck"]', NA, NA, NA),
  rate_301 = 0, rate_ieepa_fent = 0, rate_section_201 = 0, rate_s122 = 0,
  rate_ieepa_recip = c(0.1, 0.1, 0.5, 1.25, 0.15), statutory_rate_ieepa_recip = c(0.1, 0.1, 0.5, 1.25, 0.15),
  modeled_ieepa_country_eo_rate = c(0, 0, 0.4, 0, 0),
  ch99_src_ieepa_country_eo = c(NA, NA, '9903.01.77', NA, NA),
  metal_share = c(1, 1, 1, 1, 0.3),
  ch99_code_232 = c('9903.94.05', '9903.94.05', NA, NA, '9903.85.08'),
  ch99_code_ieepa_recip = c('9903.01.25', '9903.01.25', NA, '9903.01.63', '9903.02.20'),
  deriv_type = c(NA, NA, NA, NA, 'aluminum'),
  s232_annex = NA_character_, s232_metal = NA_character_, usmca_eligible = FALSE)
cx_ieepa <- tibble(census_code = c('5700', '3510', '4280'), ieepa_country_rate = c(0.1, 0.5, 0.15),
                   ieepa_type = 'surcharge', ieepa_recip_ch99 = c('9903.01.25', '9903.01.25', '9903.02.20'))
cx_out <- attach_duty_provenance(cx, country_ieepa = cx_ieepa)
rules_of <- function(i) fromJSON(cx_out$ch99_rules_json[i], simplifyDataFrame = FALSE)
pick <- function(i, f) Filter(f, rules_of(i))

run_test('a general-purpose auto-parts provision is potentially applicable, explained, and leaves IEEPA applied', {
  r <- pick(1, function(x) x$authority == 'section_232')[[1]]
  stopifnot(r$status == 'potentially_applicable_requires_more_facts', abs(r$statutory_rate - 0.25) < 1e-9,
            r$scope_citation == 's232_auto_parts_use_condition',
            'is_part_for_passenger_vehicle_or_light_truck' %in% unlist(r$required_user_inputs),
            pick(1, function(x) x$authority == 'ieepa_reciprocal' && !startsWith(x$program, 'in_transit_'))[[1]]$status == 'applied')
  a <- pick(2, function(x) x$authority == 'section_232')[[1]]
  stopifnot(a$status == 'applied', a$scope_citation == 's232_auto_parts_use_condition')
})

run_test('Brazil states the reciprocal and the 40% under their own headings, with its in-transit window', {
  rec <- pick(3, function(x) x$authority == 'ieepa_reciprocal' && x$status == 'applied')
  codes <- vapply(rec, function(x) x$ch99_code, character(1))
  stopifnot(setequal(codes, c('9903.01.25', '9903.01.77')),
            abs(Filter(function(x) x$ch99_code == '9903.01.77', rec)[[1]]$statutory_rate - 0.4) < 1e-9,
            abs(Filter(function(x) x$ch99_code == '9903.01.25', rec)[[1]]$statutory_rate - 0.1) < 1e-9)
  it <- pick(3, function(x) identical(x$program, 'in_transit_brazil_2025_08_06'))
  stopifnot(length(it) == 1, it[[1]]$ch99_code == '9903.01.78',
            it[[1]]$status == 'potentially_applicable_requires_more_facts',
            'date_loaded_for_export' %in% unlist(it[[1]]$required_user_inputs))
  # The 10% component is the baseline itself: no country-rate in-transit relief.
  stopifnot(length(pick(3, function(x) grepl('^in_transit_reciprocal_20', x$program) && x$ch99_code == '9903.01.25')) == 0)
})

run_test('China on April 15, 2025: the 9903.01.28 in-transit candidate, the 125% stays applied', {
  it <- pick(4, function(x) identical(x$program, 'in_transit_reciprocal_2025_04_05'))
  # Loaded Apr 5-8 or (China) on Apr 9: 10% instead of 125% under 9903.01.25.
  cr <- pick(4, function(x) x$program %in% c('in_transit_reciprocal_2025_04_09', 'in_transit_reciprocal_cn_2025_04_10'))
  stopifnot(length(it) == 1, it[[1]]$ch99_code == '9903.01.28', length(cr) == 2,
            pick(4, function(x) x$authority == 'ieepa_reciprocal' && x$status == 'applied')[[1]]$statutory_rate == 1.25)
  stopifnot(length(pick(1, function(x) grepl('^in_transit', x$program))) == 0)   # July: no open window
})

run_test('the reciprocal on a metal-content derivative cites the non-metal-content rule', {
  rec <- pick(5, function(x) x$authority == 'ieepa_reciprocal' && x$status == 'applied')[[1]]
  stopifnot(rec$stacking_citation == 'proc10947_6_non_metal_content')
})

run_test('a floor or cap states its published rate beside what it adds', {
  # Korea reciprocal floor 15% (row 5 of cond_fixture: 6.5% on an 8.5% base);
  # a Japanese auto part under the 15% deal floor; a Korean shoe under the
  # note 52 12.5% net-of-MFN cap (4% on an 8.5% base).
  rec <- rule_of(5, 'ieepa_reciprocal')
  stopifnot(abs(rec$floor_rate - 0.15) < 1e-9, abs(rec$statutory_rate - 0.065) < 1e-9)
  fx <- tibble(hts10 = c('8708305090', '6403406000'), country = c('5880', '5800'),
               base_rate = c(0.025, 0.01), statutory_base_rate = c(0.025, 0.085),
               rate_232 = c(0.125, 0), statutory_rate_232 = c(0.125, 0), floor_rate_232 = c(0.15, NA),
               rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0,
               rate_s301fl = c(0, 0.1149), statutory_rate_s301fl = c(0, 0.04), floor_rate_s301fl = c(NA, 0.125),
               ch99_code_232 = c('9903.94.52', NA), ch99_code_s301fl = c(NA, '9903.05.29'),
               duty_basis_232 = c('full_value', NA), metal_share = 1, deriv_type = NA_character_,
               s232_annex = NA_character_, s232_metal = NA_character_, usmca_eligible = FALSE)
  out <- attach_duty_provenance(fx)
  r <- function(i, a) Filter(function(x) identical(x$authority, a), fromJSON(out$ch99_rules_json[i], simplifyDataFrame = FALSE))[[1]]
  stopifnot(r(1, 'section_232')$rate_type == 'floor_static', abs(r(1, 'section_232')$floor_rate - 0.15) < 1e-9,
            abs(r(1, 'section_232')$statutory_rate - 0.125) < 1e-9,
            r(2, 's301_forced_labor')$rate_type == 'floor_post_mfn', abs(r(2, 's301_forced_labor')$floor_rate - 0.125) < 1e-9,
            abs(r(2, 's301_forced_labor')$statutory_rate - 0.04) < 1e-9, r(2, 's301_forced_labor')$ch99_code == '9903.05.29')
})

run_test('reciprocal floor states the rate closed against the statutory base', {
  r <- rule_of(5, 'ieepa_reciprocal')
  stopifnot(r$status == 'applied', r$rate_type == 'floor_post_mfn',
            abs(r$statutory_rate - 0.065) < 1e-9)
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

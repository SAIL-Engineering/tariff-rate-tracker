# Targeted integration verification: run REAL 2026_rev_4 data through the
# full calculate_rates_for_revision() path on a small product/country subset
# and assert the determination-layer outputs. Same code path as the build,
# minutes instead of a full-grid rebuild.
suppressPackageStartupMessages({
  library(tidyverse); library(jsonlite); library(here)
})
# Run from the repo root.
source(here('src', 'logging.R'))
source(here('src', 'helpers.R'))
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))
source(here('src', '06_calculate_rates.R'))

rev_id <- '2026_rev_4'
json_path <- 'data/hts_archives/hts_2026_rev_4.json'
rev_dates <- load_revision_dates('config/revision_dates.csv', use_policy_dates = TRUE)
eff_date <- rev_dates$effective_date[rev_dates$revision == rev_id]
cat('Effective date for', rev_id, ':', as.character(eff_date), '\n')

hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
ch99_data <- parse_chapter99(json_path, revision_id = rev_id)
ch99_other <- parse_chapter99_other(hts_raw = hts_raw, revision_id = rev_id)
check_ch99_completeness(ch99_data, ch99_other = ch99_other,
                        revision_id = rev_id, output_dir = NULL)
cat('Completeness QC: PASS (no unresolved-with-rate headings)\n')

products_all <- parse_products(json_path)
country_lookup <- build_country_lookup('resources/census_codes.csv')
ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup, effective_date = eff_date)
fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup, effective_date = eff_date)
s232_rates <- extract_section232_rates(ch99_data)
usmca <- extract_usmca_eligibility(hts_raw)

# Subset: the bug product + .04 aluminum subdivision + a TRUE steel derivative
# (outside primary ch72/73, picked from the CSV) + primary ch76/ch73 + the
# 9902 MTB trigger product.
deriv_csv <- load_232_derivative_products(effective_date = as.Date(eff_date))
steel_prefixes <- deriv_csv$hts_prefix[deriv_csv$derivative_type == 'steel' &
                                         !substr(deriv_csv$hts_prefix, 1, 2) %in% c('72', '73')]
steel_deriv_hts <- products_all$hts10[
  Reduce(`|`, lapply(utils::head(steel_prefixes, 40),
                     function(p) startsWith(products_all$hts10, p)))][1]
cat('Chosen real steel-derivative product:', steel_deriv_hts, '\n')

# A real product matching a 9902 MTB trigger in THIS revision
mtb_triggers <- unique(unlist(ch99_other$trigger_hts[ch99_other$subchapter == 'mtb_9902']))
mtb_hts <- products_all$hts10[
  Reduce(`|`, lapply(utils::head(mtb_triggers, 60),
                     function(p) startsWith(products_all$hts10, p)))][1]
cat('Chosen real MTB-trigger product:', mtb_hts, '\n')

keep <- c('8536908585',           # Note 19(k) -> 9903.85.08 (the headline bug)
          '7614105000',           # Note 19(i) -> 9903.85.04 (ch76 primary -> full value)
          steel_deriv_hts,        # Note 16(t) -> 9903.81.91, metal_content_value
          '7601103000',           # ch76 primary aluminum
          mtb_hts)                # 9902 MTB trigger
products <- products_all %>% filter(hts10 %in% keep)
cat('Subset products:', nrow(products), 'of', nrow(products_all), '\n')

countries <- c('4550', '5700', '1220', '4621', '4280')  # PL, CN, CA, RU, DE

s301_exclusions <- tryCatch(
  if (exists('build_s301_exclusion_candidates', mode = 'function')) {
    build_s301_exclusion_candidates(ch99_data, effective_date = eff_date)
  } else NULL,
  error = function(e) { cat('s301 exclusion builder error:', conditionMessage(e), '\n'); NULL }
)

args_list <- list(
  products, ch99_data, ieepa_rates, usmca,
  countries, rev_id, eff_date,
  s232_rates = s232_rates,
  fentanyl_rates = fentanyl_rates,
  stacking_method = 'mutual_exclusion',
  policy_params = load_policy_params(use_policy_dates = TRUE),
  ch99_other = ch99_other
)
if (!is.null(s301_exclusions) &&
    's301_exclusions' %in% names(formals(calculate_rates_for_revision))) {
  args_list$s301_exclusions <- s301_exclusions
}
Sys.setenv(SAIL_EMIT_NORMALIZED = '0')
rates <- do.call(calculate_rates_for_revision, args_list)
cat('\nCalculated rows:', nrow(rates), '\n\n')

row <- rates %>% filter(hts10 == '8536908585', country == '4550')
cat('=== 8536908585 x Poland ===\n')
cat('ch99_code_232:', row$ch99_code_232, '| duty_basis_232:', row$duty_basis_232,
    '| rate_232:', row$rate_232, '| statutory_rate_232:', row$statutory_rate_232, '\n')
stopifnot(nrow(row) == 1,
          row$ch99_code_232 == '9903.85.08',
          row$duty_basis_232 == 'metal_content_value',
          abs(row$statutory_rate_232 - 0.5) < 1e-9)

rules <- fromJSON(row$ch99_rules_json, simplifyDataFrame = FALSE)
auths <- vapply(rules, function(x) x$authority, character(1))
cat('rules:', paste(paste0(auths, '/', vapply(rules, function(x) x$status, character(1))), collapse = ' ; '), '\n')
r232 <- rules[[which(auths == 'section_232')[1]]]
stopifnot(r232$ch99_code == '9903.85.08',
          r232$duty_basis == 'metal_content_value',
          abs(r232$statutory_rate - 0.5) < 1e-9,
          'metal_content_kg' %in% unlist(r232$required_user_inputs),
          r232$basis_citation == 's232_basis_metal_content')
if ('section_122' %in% auths) {
  rs122 <- rules[[which(auths == 'section_122')[1]]]
  stopifnot(rs122$stacking_citation == 's122_non232_portion_only')
  cat('s122 rule present with non-232-portion stacking citation\n')
}
prov <- fromJSON(row$duty_provenance_json, simplifyDataFrame = FALSE)
stopifnot(prov[['232']]$basis == 'metal_content_value',
          abs(prov[['232']]$statutory - 0.5) < 1e-9)
# IEEPA must be terminated/not-applied at 2026_rev_4 (post EO 14389)
stopifnot(row$rate_ieepa_recip == 0, row$rate_ieepa_fent == 0)
cat('IEEPA reciprocal/fentanyl = 0 (post-termination revision) OK\n')

cat('\n=== subdivision codes ===\n')
chk <- rates %>% filter(country == '4550') %>%
  select(hts10, ch99_code_232, duty_basis_232, rate_232, statutory_rate_232)
print(chk, n = 20)
stopifnot(chk$ch99_code_232[chk$hts10 == '7614105000'] == '9903.85.04')
stopifnot(chk$ch99_code_232[chk$hts10 == steel_deriv_hts] == '9903.81.91')
stopifnot(chk$duty_basis_232[chk$hts10 == steel_deriv_hts] == 'metal_content_value')
stopifnot(chk$duty_basis_232[chk$hts10 == '7601103000'] == 'full_value')

# Every row's rules JSON must parse cleanly
for (i in seq_len(nrow(rates))) {
  fromJSON(rates$ch99_rules_json[i], simplifyDataFrame = FALSE)
}
cat('\nAll', nrow(rates), 'ch99_rules_json strings parse as valid JSON\n')

mtb_row <- rates %>% filter(hts10 == mtb_hts, country == '4280')
stopifnot(nrow(mtb_row) == 1)
mtb_rules <- fromJSON(mtb_row$ch99_rules_json, simplifyDataFrame = FALSE)
mtb_auths <- vapply(mtb_rules, function(x) x$authority, character(1))
stopifnot('mtb_9902' %in% mtb_auths)
mtb <- mtb_rules[[which(mtb_auths == 'mtb_9902')[1]]]
stopifnot(mtb$status == 'potentially_applicable_requires_more_facts')
cat('9902 MTB candidate attached to', mtb_hts, 'with requires_more_facts OK\n')

cat('\nALL INTEGRATION ASSERTIONS PASSED\n')

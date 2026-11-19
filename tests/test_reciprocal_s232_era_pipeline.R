suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
# EO 14257 sec. 3(b) (heading 9903.01.33): an article subject to §232 is wholly
# outside the reciprocal duty. Proclamation 10947 clause (6) subjects the
# non-steel, non-aluminum content of derivatives to it only from June 4, 2025
# (CSMS 65236374). Beer in aluminum cans (2203.00, an aluminum derivative)
# from China therefore owes no reciprocal duty on April 15, 2025, while a
# sweater (6110.20.20.79, no §232) owes the 125%; on June 4 the derivative's
# reciprocal returns for its non-metal content. Point diagnostic: two products,
# one origin, no full revision or timeseries is rebuilt.
Sys.setenv(SAIL_EMIT_NORMALIZED='0')
run <- function(revision, date, country = '5700') {
  path <- paste0('data/hts_archives/hts_', revision, '.json')
  raw <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  chapter <- ''; kept <- list()
  for (row in raw) { if (nzchar(row$htsno %||% '')) chapter <- substr(row$htsno, 1, 2)
    if (chapter %in% c('22', '61')) kept[[length(kept) + 1L]] <- row }
  subset <- tempfile(fileext = '.json'); jsonlite::write_json(kept, subset, auto_unbox = TRUE, null = 'null')
  products <- parse_products(subset) %>% filter(hts10 %in% c('2203000030', '6110202079')); unlink(subset)
  stopifnot(nrow(products) == 2)
  ch99 <- parse_chapter99(path, revision_id = revision)
  ieepa <- extract_ieepa_rates(raw, build_country_lookup('resources/census_codes.csv'), effective_date = as.Date(date))
  calculate_rates_for_revision(products, ch99, ieepa, NULL, country, revision, as.Date(date),
    policy_params = load_policy_params())
}
april <- run('2025_rev_10', '2025-04-15')
beer <- april[april$hts10 == '2203000030', ]; sweater <- april[april$hts10 == '6110202079', ]
stopifnot(beer$rate_232 > 0, beer$rate_ieepa_recip == 0, beer$statutory_rate_ieepa_recip == 0,
  abs(sweater$rate_ieepa_recip - 1.25) < 1e-9)
june <- run('2025_rev_14', '2025-06-04')
beer <- june[june$hts10 == '2203000030', ]
stopifnot(beer$rate_232 > 0, abs(beer$rate_ieepa_recip - 0.1) < 1e-9)
# EO 14323 sec. 3(a): Brazil's additional 40% does not apply to an article
# subject to §232 (the whole article); the 10% reciprocal reaches its non-metal
# content as above. A Brazilian sweater owes both: 50%.
aug <- run('2025_rev_18', '2025-08-10', '3510')
beer <- aug[aug$hts10 == '2203000030', ]; sweater <- aug[aug$hts10 == '6110202079', ]
stopifnot(beer$rate_232 > 0, abs(beer$rate_ieepa_recip - 0.1) < 1e-9, beer$modeled_ieepa_country_eo_rate == 0,
  abs(sweater$rate_ieepa_recip - 0.5) < 1e-9)
cat('Reciprocal excludes the whole §232 article before June 4, 2025 and its metal content after; Brazil +40% excludes §232 articles\n')

suppressPackageStartupMessages({library(tidyverse); library(here)})
source(here('src','helpers.R'))
# Non-example identifiers make it impossible for an HTS-specific production
# exception to satisfy the model-invariance tests.
headings <- tibble(hts10=c('1111111111','2222222222'), heading_232_rate=c(.25,.4))
for (qualifying in c(0,.2,1)) for (end_use in c(0,.3,1)) {
  m <- model_s232_semiconductors(headings, '1111111111',
    tibble(hts10='1111111111', qualifying_share=qualifying), end_use)
  stopifnot(m$published_rate_232_semiconductors[1] == .25,
    abs(m$heading_232_rate[1] - .25*qualifying*(1-end_use))<1e-12,
    m$modeled_semi_qualifying_share[1] == qualifying,
    m$modeled_semi_end_use_exemption_share[1] == end_use,
    m$heading_232_rate[2] == .4, is.na(m$published_rate_232_semiconductors[2]))
}
missing <- model_s232_semiconductors(headings, '1111111111',
  tibble(hts10=character(), qualifying_share=numeric()))
stopifnot(missing$modeled_semi_qualifying_share[1] == 1,
  missing$modeled_semi_qualifying_basis[1] == 'upper_bound_missing_calibration')
for (bad in list(-.1,1.1,NA_real_,Inf)) stopifnot(inherits(try(
  model_s232_semiconductors(headings,'1111111111',tibble(hts10='1111111111',qualifying_share=bad)),
  silent=TRUE),'try-error'))
stopifnot(inherits(try(model_s232_semiconductors(headings,'1111111111',
  tibble(hts10=rep('1111111111',2),qualifying_share=c(.2,.2))), silent=TRUE),'try-error'))
# Unknown scope/rate must not turn into zero in statutory totals, even when the
# legacy aggregate has a numeric projection. Cover each named tariff authority.
for (unknown in c('statutory_base_rate','statutory_rate_232','statutory_rate_ieepa_fent','statutory_rate_s122',
                  'statutory_rate_301','statutory_rate_s301fl','statutory_rate_s338')) {
  x <- zero_fill_authority_rates(tibble(hts10='1111111111',country='5700',base_rate=.05,
    statutory_base_rate=.05,metal_share=1,total_rate=.05))
  for (col in unname(STATUTORY_RATE_COL_MAP)) x[[col]] <- 0
  x[[unknown]] <- NA_real_
  y <- enforce_rate_schema(compute_statutory_totals(x))
  stopifnot(is.na(y[[unknown]]))
  stopifnot(is.na(y$statutory_total_rate), is.na(y$statutory_total_additional),
    is.na(y$statutory_alternatives_json), y$total_rate == .05,
    all(is.na(y[STATUTORY_S232_ACTION_RATE_COLS])))
}
# Exercise the actual final pipeline helper, including zero-model-duty rows
# added after the earlier heading join and an adjacent unscoped product.
cfg <- load_policy_params()$section_232_headings$semiconductors
rows <- tibble(hts10=headings$hts10, country='5700', rate_232=c(0,.4),
  statutory_rate_232=c(0,.4), deriv_type=NA_character_, deriv_ch99_code=NA_character_,
  deriv_content_scaled=FALSE)
for (share in c(0,.5,1)) {
  h <- model_s232_semiconductors(headings,'1111111111',
    tibble(hts10='1111111111',qualifying_share=share))
  out <- restore_s232_semiconductor_model(rows,h,'1111111111',cfg)
  stopifnot(is.na(out$statutory_rate_232[1]),out$published_rate_232_semiconductors[1]==.25,
    out$statutory_rate_232[2]==.4, out$rate_232[1]==.25*share,
    out$shipment_232_scope_status[1]=='needs_inputs',
    length(jsonlite::fromJSON(out$shipment_232_required_facts_json[1]))==4)
}
cat('Semiconductor modeling invariance and missing-statute regressions passed\n')

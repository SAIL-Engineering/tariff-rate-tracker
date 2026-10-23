suppressPackageStartupMessages({library(tidyverse);library(here)})
source('src/helpers.R');source('src/section232_revision.R')
x <- load_s232_note16_source('2026_rev_21')
products <- c('7308200035','7308200036','7616995160','7616995161','7202115000','8427104000')
m <- s232_note16_matches(x,products)
p <- s232_note16_projection(x,m,products)
stopifnot(setequal(m$metal[m$hts10==products[1]],c('steel','aluminum')),
  identical(m$metal[m$hts10==products[2]],'steel'),
  !any(products[4:5] %in% m$hts10),
  p$s232_annex[p$hts10==products[6]]=='annex_1b')
reversed <- x; reversed$lists <- rev(x$lists)
stopifnot(identical(s232_note16_projection(reversed,s232_note16_matches(reversed,rev(products)),rev(products)),p))

# Lowered/retired metal rates must not resurrect through stale action columns.
# Source list memberships, not chapter or magnitude, identify the model action.
r <- zero_fill_authority_rates(tibble(hts10=products,country='1220',
  rate_232=c(.5,.5,.5,0,0,.25),base_rate=0,statutory_base_rate=0,metal_share=1,total_rate=0))
r$rate_232_steel <- .6
out <- reconcile_s232_note16_model_actions(r,p)
stopifnot(all(abs(rowSums(out[S232_ACTION_RATE_COLS])-out$rate_232)<1e-12),
  out$rate_232_other[1]==.5,out$modeled_s232_note16_combined_metals[1],
  out$rate_232_steel[2]==.5,all(rowSums(out[4:5,S232_ACTION_RATE_COLS])==0))
# A separate heading program is outside this metals reconciliation.
keep <- reconcile_s232_note16_model_actions(r,p,products[4])
stopifnot(keep$rate_232_steel[4]==.6)

for(c in unname(STATUTORY_RATE_COL_MAP)) out[[c]] <- 0
out$statutory_rate_232 <- out$rate_232
marked <- mark_s232_note16_scope(out,p)
stopifnot(identical(marked$rate_232,out$rate_232),all(is.na(marked$statutory_rate_232[c(1:3,6)])))
total <- compute_statutory_totals(marked,apply_eo=FALSE)
stopifnot(all(is.na(total$statutory_total_rate[c(1:3,6)])))

# An inferred residual may preserve the model but cannot certify a shipment.
for(amount in c(.2,.8)) {
  row <- r[1,]; row$rate_232 <- amount
  for(c in unname(STATUTORY_RATE_COL_MAP)) row[[c]] <- 0
  row$statutory_rate_232 <- amount
  row <- attribute_s232_residual(row,verbose=FALSE)
  stopifnot(row$s232_action_attribution_status=='unresolved_action_attribution',
    is.na(compute_statutory_totals(row,apply_eo=FALSE)$statutory_total_rate))
}
cat('Revision note 16 exact scopes, mixed metals, retirement and completeness checks passed\n')

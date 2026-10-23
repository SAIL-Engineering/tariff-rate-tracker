suppressPackageStartupMessages({library(tidyverse);library(here)})
source('src/helpers.R');source('src/05_parse_policy_params.R')
lookup <- build_country_lookup('resources/census_codes.csv')
raw <- function(rev) jsonlite::fromJSON(paste0('data/hts_archives/hts_',rev,'.json'),simplifyVector=FALSE)
extract <- function(rev,day) extract_ieepa_rates(raw(rev),lookup,day)
choose <- function(x) select_ieepa_country_actions(x,unique(unname(lookup)),c('1220','2010','4631','4649','5790','2390'))
rate <- function(x,country) x$ieepa_country_rate[x$census_code==country]
# EO 14266 suspends the operative country headings from April 10, not April 9.
x <- extract('2025_rev_8','2025-04-09'); before <- choose(x)
y <- extract('2025_rev_9','2025-04-10'); after <- choose(y)
stopifnot(rate(before,'5880')==.24,rate(after,'5880')==.1,
  rate(before,'7990')==.5,rate(after,'7990')==.1,
  x$phase[x$ch99_code=='9903.01.76']=='phase1_apr9',
  y$rate[y$ch99_code=='9903.01.76']==.5,
  all(before$ieepa_type[before$census_code %in% c('1220','2010','4631','4649','5790','2390')]=='passthrough'),
  rate(before,'1220')==0,rate(before,'2010')==0,
  before$ieepa_recip_ch99[before$census_code=='1220']=='9903.01.26',
  before$ieepa_recip_ch99[before$census_code=='2010']=='9903.01.27',
  before$ieepa_recip_ch99[before$census_code=='4631']=='9903.01.29')
# FR 2025-17908, 21940, 23316: entry dates, not later publication/revision dates.
for(rev in c('2025_rev_18','2025_rev_23')) {
 j <- choose(extract(rev,'2025-08-07')) %>% filter(census_code=='5880')
 stopifnot(j$ieepa_type=='floor',j$ieepa_recip_ch99=='9903.02.73',j$ieepa_country_rate==.15)
}
k <- extract('2025_rev_31','2025-11-13'); old <- choose(k)
k <- extract('2025_rev_31','2025-11-14'); new <- choose(k)
stopifnot(old$ieepa_type[old$census_code=='5800']=='surcharge',
  all(new$ieepa_type[new$census_code %in% c('5800','4419','4411')]=='floor'),
  all(new$ieepa_country_rate[new$census_code %in% c('5800','4419','4411')]==.15),
  any(k$amendment_source_id=='FR-2025-23316',na.rm=TRUE))
# A review/reconsideration date in the Swiss notice is not automatic expiry.
swiss <- choose(extract('2026_rev_5','2026-04-06')) %>% filter(census_code=='4419')
stopifnot(swiss$ieepa_type=='floor')
# Country-EO surcharge and ordinary reciprocal baseline are independent.
braw <- extract('2025_rev_18','2025-08-07')
braw <- braw %>% filter(ch99_code!='9903.02.09') # baseline plus the separate published emergency action
b <- choose(braw) %>% filter(census_code=='3510')
stopifnot(abs(b$ieepa_country_rate-.5)<1e-12,b$country_eo_rate==.4,
  b$ieepa_recip_ch99=='9903.01.25',b$country_eo_ch99=='9903.01.77')
stopifnot(ieepa_heading_terminated('This provision was terminated on November 14, 2025.','2025-11-14'),
  !ieepa_heading_terminated('This provision was terminated on November 14, 2025.','2025-11-13'))
stopifnot(!ieepa_heading_terminated('This provision was terminated as of February 7, 2026.','2026-02-06'),
  ieepa_heading_terminated('This provision was terminated as of February 7, 2026.','2026-02-07'))
# Components, exemptions and a modeled floor deduction cannot erase another EO.
for(base in c(0,.08,.2,NA_real_)) {
 a <- ieepa_action_components(.65,.5,'floor',base,reciprocal_exempt=TRUE)
 stopifnot(a$reciprocal==0,a$country_eo==.5)
 a <- ieepa_action_components(.65,.5,'floor',base,eo_exempt=TRUE)
 stopifnot(a$country_eo==0,if(is.na(base)) is.na(a$reciprocal) else abs(a$reciprocal-max(0,.15-base))<1e-12)
}
# Source ordering and exact duplication are harmless; overlapping rates fail.
z <- choose(k); dup <- bind_rows(k,k);attr(dup,'universal_baseline') <- attr(k,'universal_baseline')
stopifnot(identical(z,choose(dup)),identical(z,choose(k[rev(seq_len(nrow(k))),])))
bad <- k %>% filter(!terminated,!is.na(rate)) %>% slice(1)
bad$rate <- bad$rate+.01
bad <- bind_rows(k,bad);attr(bad,'universal_baseline') <- attr(k,'universal_baseline')
stopifnot(inherits(try(choose(bad),silent=TRUE),'try-error'))
# Baseline-only revisions must retain the rate even without country rows.
baseline <- extract_ieepa_rates(Filter(function(r) r$htsno %in%
  c('9903.01.25','9903.01.26','9903.01.27','9903.01.29'),raw('2025_rev_7')),lookup)
stopifnot(nrow(baseline)==0,rate(choose(baseline),'5880')==.1)
# Missing source parameters are not proof of a zero action, even when another
# independent country action remains available. Explicit exclusions are zero.
missing_baseline <- baseline;attr(missing_baseline,'universal_baseline') <- NA_real_
stopifnot(inherits(try(choose(missing_baseline),silent=TRUE),'try-error'))
missing_baseline <- braw;attr(missing_baseline,'universal_baseline') <- NULL
stopifnot(inherits(try(choose(missing_baseline),silent=TRUE),'try-error'))
missing_exclusion <- baseline;attr(missing_exclusion,'country_exclusions') <- NULL
stopifnot(inherits(try(choose(missing_exclusion),silent=TRUE),'try-error'))
missing_rate <- k;i <- which(!k$terminated & !is.na(k$rate))[1];missing_rate$rate[i] <- NA_real_
stopifnot(inherits(try(choose(missing_rate),silent=TRUE),'try-error'),
  is.na(ieepa_reciprocal_increment(NA_real_,'surcharge',0)),
  ieepa_reciprocal_increment(NA_real_,'surcharge',0,exempt=TRUE)==0,
  is.na(ieepa_action_components(.65,NA_real_,'surcharge',0)$country_eo))
stopifnot(identical(ieepa_reciprocal_increment(c(.1,NA_real_,.2),'surcharge',0),c(.1,NA_real_,.2)),
  isTRUE(all.equal(ieepa_reciprocal_increment(.15,'floor',c(0,.1,.2)),c(.15,.05,0))),
  identical(ieepa_action_components(c(.1,NA_real_,.2),0,'surcharge',0)$reciprocal,c(.1,NA_real_,.2)))
cat('IEEPA operative headings, retroactive amendments, independent actions and missing inputs passed\n')

# CBP collection, not the ruling date, gates the at-entry aggregate path.
for(day in c('2026-02-20','2026-02-21','2026-02-23')) stopifnot(!has_ieepa_collection_ended(day))
stopifnot(!has_ieepa_collection_ended('2026-02-23T23:59:59-05:00'),
  has_ieepa_collection_ended('2026-02-24T00:00:00-05:00'),has_ieepa_collection_ended('2026-10-22'))
# Normalized evidence preserves source versions and suppressed old headings.
evidence <- ieepa_action_decisions(k,choose(k),'2025_rev_31')
stopifnot(any(evidence$ch99_code=='9903.02.56' & evidence$decision=='retired_heading'),
  any(evidence$ch99_code=='9903.02.80' & evidence$decision=='ordinary_action_selected'),
  any(evidence$ch99_code=='9903.01.25' & evidence$decision=='ordinary_action_selected'),
  any(evidence$ch99_code=='9903.01.26' & evidence$country=='1220' & evidence$rate==0 & evidence$decision=='ordinary_action_selected'),
  any(evidence$ch99_code=='9903.01.29' & evidence$country=='4631' & evidence$rate==0 & evidence$decision=='ordinary_action_selected'),
  all(nchar(evidence$hts_sha256)==64))
fragment <- ieepa_evidence_fragment(k,'2025_rev_31')
stopifnot(length(fragment$rules)==0,length(fragment$coverage)==0,
  all(c('FR-2025-17908','FR-2025-21940','FR-2025-23316') %in% vapply(fragment$sources,`[[`,'','id')))
# Normalized action exemptions agree with the wide model formula.
source('src/resolve_rate_normalized.R');source('src/07_emit_normalized.R')
out <- tempfile();dir.create(out)
ci <- b;ci$ieepa_type <- 'floor';ci$ieepa_country_rate <- .55
state <- list(country_ieepa=ci,country_eo_exemptions=tibble(ch99_code='9903.01.77',hts8_prefix='87654321'))
acr <- emit_authority_country_rates(NULL,NULL,NULL,NULL,c('3510'),'test','2025-08-07',pp=NULL,output_dir=out,denorm_state=state)
ex <- emit_authority_exemptions('1234567890',NULL,NULL,'test','2025-08-07',out,denorm_state=state)
for(base in c(0,.08,.2)) {
 stopifnot(abs(.compute_ieepa_projection(acr,ex,'1234567890','3510',base)$rate-.4)<1e-12,
  abs(.compute_ieepa_projection(acr,ex,'8765432190','3510',base)$rate-max(0,.15-base))<1e-12,
  abs(.compute_ieepa_projection(acr,ex,'1111111111','3510',base)$rate-(.4+max(0,.15-base)))<1e-12)
}
legacy <- acr;legacy$reciprocal_parameter <- NULL
stopifnot(inherits(try(.compute_ieepa_projection(legacy,ex,'1111111111','3510',0),silent=TRUE),'try-error'),
  inherits(try(.compute_ieepa_projection(acr,ex,'1111111111','9999',0),silent=TRUE),'try-error'),
  inherits(try(.compute_ieepa_projection(acr,ex,'1111111111','3510',NA_real_),silent=TRUE),'try-error'),
  .compute_ieepa_projection(acr,ex,'1234567890','3510',NA_real_)$rate==.4)
state$country_ieepa <- before[before$census_code %in% c('1220','2010','4631'),]
zeros <- emit_authority_country_rates(NULL,NULL,NULL,NULL,state$country_ieepa$census_code,'test','2025-04-09',pp=NULL,output_dir=out,denorm_state=state)
for(country in state$country_ieepa$census_code)
  stopifnot(.compute_ieepa_projection(zeros,ex,'1111111111',country,NA_real_)$rate==0)
unlink(out,recursive=TRUE)
cat('IEEPA collection chronology, source evidence and normalized independent-action parity passed\n')
pp <- load_policy_params()
stopifnot(is.null(pp$SWISS_FRAMEWORK$expiry_date),
  !any(vapply(collect_expiry_adjustments(pp),function(x) identical(x$label,'Swiss framework'),logical(1))))
# No rate matching or universal baseline guessing can manufacture a reporting code.
r <- tibble(hts10='1234567890',country='9999',rate_232=.25,rate_ieepa_recip=.25,
  rate_232_steel=.25,rate_232_auto=0,rate_232_aluminum=0,rate_232_copper=0,rate_232_other=0)
ch <- tibble(ch99_code=c('9903.81.99','9903.01.25'),rate=c(.25,.1),description='Synthetic')
z <- resolve_ch99_codes(r,ch)
stopifnot(is.na(z$ch99_code_232),is.na(z$ch99_code_ieepa_recip))

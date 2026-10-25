suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
# Small actual-source fixtures only; no revision/timeseries rebuild.
out <- tempfile('reciprocal-pipeline-');dir.create(out)
save_ledger <- duty_ledger_save
duty_ledger_save <- function(...) save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
lookup <- build_country_lookup('resources/census_codes.csv')
run <- function(rev,day,codes,countries='6021') {
 path <- paste0('data/hts_archives/hts_',rev,'.json')
 raw <- jsonlite::fromJSON(path,simplifyVector=FALSE)
 chapters <- unique(substr(codes,1,2));chapter <- '';kept <- list()
 for(r in raw) {
   if(nzchar(r$htsno %||% '')) chapter <- substr(r$htsno,1,2)
   if(chapter %in% chapters) kept[[length(kept)+1L]] <- r
 }
 subset <- tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
 products <- parse_products(subset) %>% filter(hts10 %in% codes)
 unlink(subset)
 stopifnot(nrow(products)==length(codes))
 hts <- jsonlite::fromJSON(path,simplifyVector=FALSE)
 ch99 <- parse_chapter99(path,revision_id=rev)
  calculate_rates_for_revision(products,ch99,extract_ieepa_rates(hts,lookup,day),NULL,countries,rev,as.Date(day),
   policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date(day))
}
early <- run('2025_rev_7','2025-04-06',c('0106199120','8528520000'))
stopifnot(early$rate_ieepa_recip[early$hts10=='0106199120']==.1,
 early$rate_ieepa_recip[early$hts10=='8528520000']==0)
late <- run('2025_rev_28','2025-11-13',c('1905901070','0803900035','4403420000','8505110070'))
stopifnot(all(late$rate_ieepa_recip[late$hts10!='1905901070']==0),
 is.na(late$statutory_rate_ieepa_recip[late$hts10=='1905901070']),
 is.na(late$statutory_total_rate[late$hts10=='1905901070']))
scopes <- arrow::read_parquet(file.path(out,'2025_rev_28','ieepa_reciprocal_scope_decisions.parquet'))
stopifnot(any(scopes$condition=='article_description'),all(scopes$hts10 %in% late$hts10))
exempt <- arrow::read_parquet(file.path(out,'2025_rev_28','authority_exemptions.parquet')) %>%
 filter(authority=='ieepa_reciprocal',exemption_type=='annex_a')
stopifnot(!'1905901070' %in% exempt$hts10,'0803900035' %in% exempt$hts10,
 all(exempt$source=='ieepa_reciprocal_scope_decisions.parquet'))
source('src/compile_shipment_rules.R')
f <- read_shipment_rule_fragment(file.path(out,'2025_rev_28','ieepa_reciprocal_scope_evidence.json'))
stopifnot(f$reciprocal_scope$revision=='2025_rev_28',length(f$coverage)==0)
for(spec in list(list(rev='2025_rev_8',day='2025-04-09',expected=c('5700'=.84,'4279'=.2,'6021'=.1)),
                 list(rev='2025_rev_9',day='2025-04-10',expected=c('5700'=1.25,'5820'=1.25,'5660'=1.25,'4279'=.1)),
                 list(rev='2025_rev_12',day='2025-05-14',expected=c('5700'=.1,'4279'=.1)))) {
  r<-run(spec$rev,spec$day,'0106199120',names(spec$expected))
  stopifnot(all(abs(r$rate_ieepa_recip-unname(spec$expected[r$country]))<1e-9))
  fragment<-read_shipment_rule_fragment(file.path(out,spec$rev,'ieepa_reciprocal_initial_rules.json'))
  stopifnot(length(fragment$rules)>0,length(fragment$coverage)==0)
}
unlink(out,recursive=TRUE)
cat('Tests: 13 passed, 0 failed\n')

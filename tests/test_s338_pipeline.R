suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R');source('src/compile_shipment_rules.R')
# Four-product calculator/emitter fixture. Does not rebuild any revision output.
products<-readRDS('data/processed/products_2026_rev_4.rds') %>%
 filter(hts10 %in% c('2203000030','0402101000','8537109120','8537109130'))
stopifnot(nrow(products)==4)
ch99<-parse_chapter99('data/hts_archives/hts_2026_rev_17.json',revision_id='2026_rev_17')
out<-tempfile('s338-pipeline-');dir.create(out)
save_ledger<-duty_ledger_save
duty_ledger_save<-function(...) save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
r<-calculate_rates_for_revision(products,ch99,NULL,NULL,'1220','2026_rev_17',as.Date('2026-09-15'),
 policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
stopifnot(r$modeled_legacy_statutory_rate_s338[r$hts10=='8537109120']==0,
 r$modeled_legacy_statutory_rate_s338[r$hts10=='8537109130']==.5,
 all(is.na(r$statutory_rate_s338)),all(is.na(r$statutory_total_rate)),
 all(r$shipment_status=='unresolved_source'),setequal(r$country,'1220'),nrow(r)==4)
fragment<-read_shipment_rule_fragment(file.path(out,'2026_rev_17','section338_rules.json'))
stopifnot(fragment$id=='section338_2026_rev_17',length(fragment$rules)>0,
 length(fragment$action_history)==5,!length(fragment$coverage))
app<-arrow::read_parquet(file.path(out,'2026_rev_17','authority_product_applicability.parquet')) %>% filter(authority=='section_338')
stopifnot(nrow(app)==101+52+513,all(is.na(app$statutory_rate)),all(app$legal_rate_parameter==.5),
 '8537109130'%in%app$hts10,!'85371091'%in%app$hts_prefix,
 all(app$requires_section232_inventory==(app$program=='section338_dairy')),
 all(app$valid_from==as.Date('2026-09-15')))
# Reconcile the same normal-build bundle at the amendment's exact instant.
# Before00:01 the 232 interaction is unresolved; afterwards the independent
# motor action is executable, while a complete total still needs other coverage.
facts <- list(customs_value=100,ieepa_ftz_entry=FALSE,s338_personal_baggage=FALSE,
 s338_chapter98_claimed=FALSE,s338_ftz_entry=FALSE)
for(at in c('2026-09-15T00:00:59-04:00','2026-09-15T00:01:00-04:00')) {
 result <- resolve_shipment_duties(file.path(out,'2026_rev_17'),'8537109130','1220',at,facts)
 stopifnot(result$status=='unresolved_source',is.null(result$complete_total))
 action <- Filter(function(c)c$authority=='section_338'&&c$status=='applied'&&
   '9903.03.14' %in% unlist(c$reporting_codes),result$components)
 if(grepl('00:00:59',at,fixed=TRUE))stopifnot(length(action)==0L,
   any(grepl('coverage_dependency_unverified:section_232',result$source_errors,fixed=TRUE)))
 else stopifnot(length(action)==1L,action[[1]]$amount==50)
}
source('src/legal_intervals.R')
cfg<-load_policy_params()
segments<-revision_legal_segments('2026_rev_16',data.frame(revision=c('2026_rev_16','next'),
 effective_date=as.Date(c('2026-08-14','2026-08-24'))),cfg)
stopifnot('2026-08-22' %in% as.character(segments$valid_from))
unlink(out,recursive=TRUE)
cat('Section338 bounded calculator, normalized emission and inter-revision start passed\n')

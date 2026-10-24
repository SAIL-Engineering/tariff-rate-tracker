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
stopifnot(r$statutory_rate_s338[r$hts10=='8537109120']==0,
 r$statutory_rate_s338[r$hts10=='8537109130']==.5,setequal(r$country,'1220'),nrow(r)==4)
fragment<-read_shipment_rule_fragment(file.path(out,'2026_rev_17','section338_rules.json'))
stopifnot(fragment$id=='section338_2026_rev_17',length(fragment$rules)>0,
 length(fragment$action_history)==5,!length(fragment$coverage))
app<-arrow::read_parquet(file.path(out,'2026_rev_17','authority_product_applicability.parquet')) %>% filter(authority=='section_338')
stopifnot(nrow(app)==101+52+513,all(is.na(app$statutory_rate)),all(app$legal_rate_parameter==.5),
 '8537109130'%in%app$hts10,!'85371091'%in%app$hts_prefix,
 all(app$requires_section232_inventory==(app$program=='section338_dairy')),
 all(app$valid_from==as.Date('2026-09-15')))
source('src/legal_intervals.R')
cfg<-load_policy_params()
segments<-revision_legal_segments('2026_rev_16',data.frame(revision=c('2026_rev_16','next'),
 effective_date=as.Date(c('2026-08-14','2026-08-24'))),cfg)
stopifnot('2026-08-22' %in% as.character(segments$valid_from))
unlink(out,recursive=TRUE)
cat('Section338 bounded calculator, normalized emission and inter-revision start passed\n')

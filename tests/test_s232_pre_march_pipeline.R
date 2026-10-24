suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R');source('src/section232_legacy.R')
# Six real products, seven origins, temporary outputs: not a revision rebuild.
wanted<-c('7208101500','7202115000','7317005503','7317005590','7604101000','7605290000')
raw<-jsonlite::fromJSON('data/hts_archives/hts_2025_basic.json',simplifyVector=FALSE)
stack<-list();kept<-list()
for(row in raw) {
 depth<-as.integer(row$indent %||% 0);stack<-head(stack,depth);stack[[length(stack)+1L]]<-row
 if(gsub('\\.','',row$htsno %||% '') %in% wanted) kept<-c(kept,stack)
}
keys<-vapply(kept,function(x) as.character(jsonlite::toJSON(x,auto_unbox=TRUE)),character(1))
fixture<-tempfile(fileext='.json');jsonlite::write_json(kept[!duplicated(keys)],fixture,auto_unbox=TRUE)
products<-parse_products(fixture) %>% filter(hts10 %in% wanted)
unlink(fixture)
stopifnot(nrow(products)==6)
ch99<-parse_chapter99('data/hts_archives/hts_2025_basic.json',revision_id='2025_basic')
out<-tempfile('pre-march-pipeline-');dir.create(out)
save_fixture_ledger<-duty_ledger_save
duty_ledger_save<-function(...) save_fixture_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
r<-calculate_rates_for_revision(products,ch99,NULL,NULL,c('5700','1220','2010','5880','5800','3510','4623'),'2025_basic',as.Date('2025-01-01'),
 policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2025-02-04'))
stopifnot(all(r$rate_232[r$hts10 %in% c('7202115000','7317005590')]==0))
stopifnot(all(r$rate_232_aluminum[r$hts10=='7604101000' & r$country %in% c('5880','5800','3510','4623')]==.1))
stopifnot(all(is.na(r$statutory_rate_232[r$hts10 %in% c('7208101500','7317005503','7604101000','7605290000')])))
x<-jsonlite::fromJSON(file.path(out,'2025_basic','section232_legacy_rules.json'),simplifyVector=FALSE)
grant_snapshot<-Sys.getenv('SECTION232_GRANT_SNAPSHOT',unset='')
if(nzchar(grant_snapshot)) {
 stopifnot(identical(x$grant_snapshot$snapshot_sha256,digest::digest(file=grant_snapshot,algo='sha256')),
   any(vapply(x$rules,function(r) !is.null(r$grant_id),logical(1))))
 source('src/compile_shipment_rules.R')
 checked<-read_shipment_rule_fragment(file.path(out,'2025_basic','section232_legacy_rules.json'))
 stopifnot(identical(checked$grant_snapshot,x$grant_snapshot))
 cat('Configured grant snapshot and all retained evidence verified through normalized emission\n')
}
stopifnot(length(x$rules)>0,any(vapply(x$rules,function(z)'9903.81.85'%in%unlist(z$reporting_codes),logical(1))))
m<-arrow::read_parquet(file.path(out,'2025_basic','section232_scope_decisions.parquet'))
stopifnot(setequal(m$hts10,c('7208101500','7317005503','7604101000','7605290000')))
a<-arrow::read_parquet(file.path(out,'2025_basic','authority_product_applicability.parquet'))
stopifnot(!any(a$authority=='section_232' & a$hts_prefix %in% c('72','73','76')))
p<-extract_section232_rates(ch99,as.Date('2025-01-01'))
stopifnot(p$steel_rate==.25,p$aluminum_rate==.1,p$steel_rate_ch99=='9903.80.01',p$aluminum_rate_ch99=='9903.85.01')
# A high unrelated/retired rate cannot win the ordinary model parameter.
z<-ch99;z$rate[z$ch99_code=='9903.80.03']<-.45
p<-extract_section232_rates(z,as.Date('2025-01-01'));stopifnot(p$steel_rate==.25,p$steel_derivative_rate==.45)
unlink(out,recursive=TRUE)
cat('Pre-March source scope, separate model parameters and normalized rule delivery passed\n')

suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R');source('scripts/lib/shipment_partition_validation.R')
# Five cells, not a revision/timeseries rebuild; through the ordinary emitter.
export<-Sys.getenv('MHD_PIPELINE_EXPORT','');parent<-if(nzchar(export))export else tempfile('mhd-normal-')
stopifnot(!file.exists(parent));dir.create(parent,recursive=TRUE)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
save_ledger<-duty_ledger_save;duty_ledger_save<-function(...)save_ledger(dir=file.path(parent,'provenance'),...)
rev<-'2026_rev_4';day<-as.Date('2026-04-05');hts<-c('8705900080','8705900020','8702103100','8706000300','8704600000')
out<-file.path(parent,rev);dir.create(out)
path<-paste0('data/hts_archives/hts_',rev,'.json');raw<-jsonlite::fromJSON(path,simplifyVector=FALSE)
chapter<-'';kept<-list()
for(row in raw){if(nzchar(row$htsno%||%''))chapter<-substr(row$htsno,1,2);if(chapter=='87')kept[[length(kept)+1L]]<-row}
subset<-tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
products<-parse_products(subset)%>%filter(hts10%in%hts);unlink(subset);stopifnot(nrow(products)==length(hts))
ch99<-parse_chapter99(path,revision_id=rev)
rates<-calculate_rates_for_revision(products,ch99,NULL,NULL,'2010',rev,day,policy_params=load_policy_params(),
 normalized_output_dir=out,normalized_valid_until=day)
arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
dir<-file.path(out,rev)
stopifnot(file.exists(file.path(dir,'section232_mhd_vehicles_rules.json')))
members<-arrow::read_parquet(file.path(dir,'authority_product_candidates.parquet'))
for(spec in list(c('s232_mhd_vehicles','8705900080','8705900080','exact_hts10'),
                c('s232_mhd_buses','8702103100','87021031','prefix'),
                c('s232_mhd_parts_listed','8706000300','87060003','prefix'))) {
 row<-members%>%filter(program==spec[1],hts10==spec[2])
 stopifnot(nrow(row)==1L,row$scope_code==spec[3],row$scope_grain==spec[4],
  row$status=='candidate_requires_legal_predicates',nzchar(row$source_sha256))
}
validation<-validate_shipment_partition(dir,file.path(out,'rates_fixture.parquet'))
stopifnot(validation$grid_cells==5L,!validation$legal_coverage_complete)
base<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_vehicle_parts_certification='none',s232_mhd_vehicle=TRUE,
 s232_mhd_manufacture_year=2020,s232_auto_passenger_vehicle=FALSE,s232_auto_parts_use=FALSE,s232_mhd_parts_use=FALSE,
 s232_auto_usmca_eligible=FALSE,s232_mhd_usmca_eligible=FALSE)
cases<-list()
for(product in hts) {
 for(content in if(product=='8705900080')c(FALSE,TRUE) else FALSE) {
  facts<-base
  if(product=='8705900020')facts$s232_mhd_vehicle<-FALSE
  if(content) {
   facts$claims<-list('SECTION_232_MHD_US_CONTENT');facts$usmca_origin_eligible<-TRUE;facts$usmca_properly_claimed<-TRUE
   # The peer base action owns this conclusion; contradictory legacy aliases
   # cannot reintroduce Section122 on a verified duty-free USMCA entry.
   facts$s122_usmca_entered_free<-FALSE
   facts$s232_mhd_commerce_us_content_approved<-TRUE;facts$s232_mhd_cbp_overstatement_applies<-FALSE;facts$s232_mhd_non_us_content_value<-40
  }
  at<-'2026-04-05T12:00:00-04:00';r<-resolve_shipment_duties(dir,product,'2010',at,facts)
  applied<-Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components)
  got<-sum(vapply(applied,`[[`,numeric(1),'amount'))
  expected<-if(product=='8702103100')10 else if(product=='8705900020')0 else if(content)10 else 25
  if(!isTRUE(all.equal(got,expected))){print(list(product=product,got=got,result=r[c('missing_inputs','source_errors')]));stop('Ordinary build MHD duty did not carry through')}
  stopifnot(is.null(r$complete_total))
  cases[[length(cases)+1L]]<-list(hts10=product,country='2010',entry_at=at,facts=facts,expected=shipment_result_for_json(r))
 }
}
jsonlite::write_json(list(revision_dir=rev,cases=cases),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17)
if(!nzchar(export))unlink(parent,recursive=TRUE)
cat('Five normal Parquet cells and six vehicle/bus/content API fixtures passed; overall coverage remains unverified\n')

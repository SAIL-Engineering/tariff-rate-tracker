suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('scripts/lib/shipment_partition_validation.R')
# Two real products, two origins, one day: a point-calculator regression,
# not a revision or timeseries rebuild. Product examples exist only in tests.
revision <- '2025_rev_20';hts <- paste0('data/hts_archives/hts_',revision,'.json')
raw <- jsonlite::fromJSON(hts,simplifyVector=FALSE)
chapter <- '';kept <- list()
for(r in raw) {
  if(nzchar(r$htsno %||% ''))chapter <- substr(r$htsno,1,2)
  if(chapter %in% c('40','84'))kept[[length(kept)+1L]] <- r
}
subset <- tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
products <- parse_products(subset) %>% filter(hts10 %in% c('8473301180','4009120020'))
unlink(subset)
stopifnot(nrow(products)==2L)
ch99 <- parse_chapter99(hts,revision_id=revision)
export <- Sys.getenv('LATER_PIPELINE_EXPORT','')
out <- if(nzchar(export))export else tempfile('later-reciprocal-normal-')
if(file.exists(out))stop('Fixture destination already exists')
dir.create(out)
save_ledger <- duty_ledger_save
duty_ledger_save <- function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates <- calculate_rates_for_revision(products,ch99,NULL,NULL,c('4280','5700'),revision,as.Date('2025-09-01'),
  policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2025-09-02'))
revision_dir <- file.path(out,revision)
stopifnot(nrow(rates)==4L,all(is.na(rates$statutory_total_rate)),all(rates$shipment_status=='unresolved_source'))
arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
verified <- validate_shipment_partition(revision_dir,file.path(out,'rates_fixture.parquet'))
stopifnot(verified$grid_cells==4L,!verified$legal_coverage_complete)
q <- list(customs_value=100,ieepa_ftz_entry=FALSE,ieepa_personal_accompanied_baggage=FALSE,
  ieepa_qualifying_humanitarian_donation=FALSE,ieepa_informational_material=FALSE,ieepa_de_minimis_claimed=FALSE,
  reciprocal_cbp_transshipment_evasion_determination=FALSE,s232_auto_usmca_eligible=FALSE)
cases <- list()
for(country in c('4280','5700'))for(hts10 in products$hts10)for(aircraft in c(TRUE,FALSE))for(at in c('2025-09-01T00:00:59-04:00','2025-09-01T00:01:00-04:00')) {
 facts<-c(q,list(s232_auto_parts_use=FALSE,reciprocal_partner_civil_aircraft_gn6_excluding_unmanned=aircraft))
 result<-resolve_shipment_duties(revision_dir,hts10,country,at,facts)
 applied<-Filter(function(c)c$status=='applied'&&c$authority=='ieepa_reciprocal',result$components)
 codes<-unique(unlist(lapply(applied,`[[`,'reporting_codes')))
 if(hts10=='8473301180')stopifnot(setequal(codes,'9903.01.32'))
 else if(country=='4280'&&aircraft&&at=='2025-09-01T00:01:00-04:00')stopifnot(setequal(codes,'9903.02.76'))
 else stopifnot(!length(codes),'coverage_dependency_unverified:section_232' %in% result$source_errors)
 stopifnot(is.null(result$complete_total),result$status=='unresolved_source')
 cases[[length(cases)+1L]]<-list(hts10=hts10,country=country,entry_at=at,facts=facts,expected=shipment_result_for_json(result))
}
if(nzchar(export))jsonlite::write_json(list(revision_dir=revision,cases=cases),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17) else unlink(out,recursive=TRUE)
cat(length(cases),'actual-source later reciprocal boundary cases and full four-cell Parquet verification passed\n')

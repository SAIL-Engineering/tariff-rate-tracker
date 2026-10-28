suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('scripts/lib/shipment_partition_validation.R')
# One real source product and origin, not a revision/timeseries rebuild.
revision<-'2026_rev_19';hts<-paste0('data/hts_archives/hts_',revision,'.json')
raw<-jsonlite::fromJSON(hts,simplifyVector=FALSE);chapter<-'';kept<-list()
for(r in raw){if(nzchar(r$htsno %||% ''))chapter<-substr(r$htsno,1,2);if(chapter=='73')kept[[length(kept)+1L]]<-r}
subset<-tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
products<-parse_products(subset) %>% filter(hts10=='7304313000');unlink(subset);stopifnot(nrow(products)==1L)
ch99<-parse_chapter99(hts,revision_id=revision)
export<-Sys.getenv('AIRCRAFT_PIPELINE_EXPORT','');out<-if(nzchar(export))export else tempfile('civil-aircraft-normal-')
stopifnot(!file.exists(out));dir.create(out)
save_ledger<-duty_ledger_save;duty_ledger_save<-function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates<-calculate_rates_for_revision(products,ch99,NULL,NULL,'4280',revision,as.Date('2026-09-15'),
 policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
dir<-file.path(out,revision);arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
stopifnot(nrow(rates)==1L,is.na(rates$statutory_total_rate),rates$shipment_status=='unresolved_source')
check<-validate_shipment_partition(dir,file.path(out,'rates_fixture.parquet'));stopifnot(check$grid_cells==1L,!check$legal_coverage_complete)
facts<-list(customs_value=100,ieepa_ftz_entry=FALSE,column1_duty_amount=0,
 steel_weight_fraction=1,aluminum_weight_fraction=0,copper_weight_fraction=0,
 us_steel_origin_fraction=0,uk_steel_origin_fraction=0)
cases<-list()
for(eligible in c(FALSE,TRUE)) {
 q<-facts;q$reciprocal_partner_civil_aircraft_gn6_excluding_unmanned<-eligible
 # These fixtures are ordinary steel versus a qualifying manned GN6 article.
 # Note52(d) has its own broader GN6 condition; the narrower reciprocal fact
 # being FALSE alone would not exclude unmanned civil-aircraft eligibility.
 q$s301_labor_civil_aircraft_gn6<-eligible
 result<-resolve_shipment_duties(dir,'7304313000','4280','2026-09-15T12:00:00-04:00',q)
 metals<-Filter(function(c)c$action_id=='s232_note16_metals'&&c$status=='applied',result$components)
 relief<-Filter(function(c)c$authority=='section_232'&&c$status=='applied'&&'9903.02.76' %in% c$reporting_codes,result$components)
 if(eligible)stopifnot(!length(metals),length(relief)==1L,relief[[1]]$amount==0)
 else stopifnot(length(metals)==1L,metals[[1]]$amount==50,'9903.82.02' %in% metals[[1]]$reporting_codes,!length(relief))
 stopifnot(is.null(result$complete_total),!length(result$missing_inputs),!length(Filter(function(c)c$authority=='ieepa_reciprocal'&&c$status=='applied',result$components)))
 cases[[length(cases)+1L]]<-list(hts10='7304313000',country='4280',entry_at='2026-09-15T12:00:00-04:00',facts=q,expected=shipment_result_for_json(result))
 q$modeled_steel_share<-if(eligible)0 else 1;q$modeled_assembly_credit<-99999
 modeled<-resolve_shipment_duties(dir,'7304313000','4280','2026-09-15T12:00:00-04:00',q)
 stopifnot(identical(shipment_result_for_json(result),shipment_result_for_json(modeled)))
}
if(nzchar(export))jsonlite::write_json(list(revision_dir=revision,cases=cases),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17) else unlink(out,recursive=TRUE)
cat('Actual-source steel: USD50 ordinary metal versus sourced aircraft waiver; model invariance and complete one-cell Parquet check passed\n')

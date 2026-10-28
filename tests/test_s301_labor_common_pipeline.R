suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('scripts/lib/shipment_partition_validation.R')
# One real point calculation through the ordinary emitter; no revision rebuild.
revision<-'2026_rev_19';hts<-paste0('data/hts_archives/hts_',revision,'.json')
raw<-jsonlite::fromJSON(hts,simplifyVector=FALSE);chapter<-'';kept<-list()
for(r in raw){if(nzchar(r$htsno %||% ''))chapter<-substr(r$htsno,1,2);if(chapter=='84')kept[[length(kept)+1L]]<-r}
subset<-tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
products<-parse_products(subset)%>%filter(hts10=='8471500150');unlink(subset);stopifnot(nrow(products)==1L)
ch99<-parse_chapter99(hts,revision_id=revision)
export<-Sys.getenv('LABOR_COMMON_PIPELINE_EXPORT','');out<-if(nzchar(export))export else tempfile('common-labor-normal-')
stopifnot(!file.exists(out));dir.create(out)
save_ledger<-duty_ledger_save;duty_ledger_save<-function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates<-calculate_rates_for_revision(products,ch99,NULL,NULL,'4280',revision,as.Date('2026-09-15'),
 policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
dir<-file.path(out,revision);arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
check<-validate_shipment_partition(dir,file.path(out,'rates_fixture.parquet'));stopifnot(check$grid_cells==1L,!check$legal_coverage_complete)
facts<-list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_parts_use=FALSE,contains_logic_integrated_circuit=FALSE)
r<-resolve_shipment_duties(dir,'8471500150','4280','2026-09-15T12:00:00-04:00',facts)
fl<-Filter(function(c)startsWith(c$action_id,'s301_forced_labor_'),r$components)
applied<-Filter(function(c)c$status=='applied',fl)
stopifnot(length(applied)==1L,applied[[1]]$amount==0,'9903.05.86'%in%unlist(applied[[1]]$reporting_codes),
 !length(unlist(lapply(fl,`[[`,'source_errors'))),!length(unlist(lapply(fl,`[[`,'missing_inputs'))),is.null(r$complete_total))
q<-facts;q$modeled_aircraft_share<-1;q$modeled_exclusion_share<-0;q$assembly_credit<-99999
stopifnot(identical(shipment_result_for_json(r),shipment_result_for_json(resolve_shipment_duties(dir,'8471500150','4280','2026-09-15T12:00:00-04:00',q))))
if(nzchar(export))jsonlite::write_json(list(revision_dir=revision,cases=list(list(hts10='8471500150',country='4280',entry_at='2026-09-15T12:00:00-04:00',facts=facts,expected=shipment_result_for_json(r)))),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17) else unlink(out,recursive=TRUE)
cat('Ordinary computer point: exact sourced forced-labor product exemption, model invariance and Parquet relationships passed; full total remains incomplete\n')

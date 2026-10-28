suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('scripts/lib/shipment_partition_validation.R')
# Source-selected points through the ordinary emitter, not a revision or
# timeseries rebuild. Incomplete other authorities cannot become a full total.
revision<-'2026_rev_19';hts<-paste0('data/hts_archives/hts_',revision,'.json')
raw<-jsonlite::fromJSON(hts,simplifyVector=FALSE);chapter<-'';kept<-list()
for(r in raw){if(nzchar(r$htsno %||% ''))chapter<-substr(r$htsno,1,2);if(chapter%in%c('69','76','82'))kept[[length(kept)+1L]]<-r}
subset<-tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
products<-parse_products(subset)%>%filter(hts10%in%c('6912004810','8211912000','7602000075'));unlink(subset);stopifnot(nrow(products)==3L)
ch99<-parse_chapter99(hts,revision_id=revision)
export<-Sys.getenv('VALUATION_PIPELINE_EXPORT','');out<-if(nzchar(export))export else tempfile('valuation-normal-')
stopifnot(!file.exists(out));dir.create(out)
save_ledger<-duty_ledger_save;duty_ledger_save<-function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates<-calculate_rates_for_revision(products,ch99,NULL,NULL,c('5800','5700'),revision,as.Date('2026-09-15'),
 policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
dir<-file.path(out,revision);arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
validation<-validate_shipment_partition(dir,file.path(out,'rates_fixture.parquet'));stopifnot(validation$grid_cells==6L,!validation$legal_coverage_complete)
facts<-list(customs_value=100,quantity_each=10,ieepa_ftz_entry=FALSE,steel_weight_fraction=1,us_steel_origin_fraction=0)
r<-resolve_shipment_duties(dir,'8211912000','5800','2026-09-15T12:00:00-04:00',facts)
amount<-function(authority)sum(vapply(Filter(function(c)c$authority==authority&&c$status=='applied',r$components),`[[`,numeric(1),'amount'))
stopifnot(abs(amount('base')-6.44)<1e-9,amount('section_232')==25)
fl<-Filter(function(c)startsWith(c$action_id,'s301_forced_labor_'),r$components)
applied<-Filter(function(c)c$status=='applied',fl)
stopifnot(length(applied)==1L,applied[[1]]$amount==0,'9903.05.90'%in%unlist(applied[[1]]$reporting_codes),
 !length(unlist(lapply(fl,`[[`,'source_errors'))),!length(unlist(lapply(fl,`[[`,'missing_inputs'))),is.null(r$complete_total))
q<-facts;q$modeled_fta_share<-1;q$assembly_credit<-999999;q$column1_duty_amount<-999999
stopifnot(identical(shipment_result_for_json(r),shipment_result_for_json(resolve_shipment_duties(dir,'8211912000','5800','2026-09-15T12:00:00-04:00',q))))
cases<-list(list(hts10='8211912000',country='5800',entry_at='2026-09-15T12:00:00-04:00',facts=facts,expected=shipment_result_for_json(r)))
ftz<-list(ieepa_ftz_entry=TRUE,s122_ftz_entry=FALSE,s338_ftz_entry=FALSE,ftz_status='nonprivileged_foreign',
 ftz_valuation_method='admission_transaction',ftz_admission_price_reasonably_representative=TRUE,
 ftz_admission_price=100,ftz_statutory_additions=10,ftz_included_international_freight_insurance=4,
 ftz_included_us_inland_freight=6,ftz_allowance_claimed=FALSE,customs_value=999999)
r<-resolve_shipment_duties(dir,'6912004810','5800','2026-09-15T12:00:00-04:00',ftz)
stopifnot(abs(amount('base')-9.8)<1e-9,is.null(r$complete_total),length(r$source_errors)>0L)
cases[[2]]<-list(hts10='6912004810',country='5800',entry_at='2026-09-15T12:00:00-04:00',facts=ftz,expected=shipment_result_for_json(r))
scrap<-list(ieepa_ftz_entry=TRUE,ftz_status='recoverable_waste',ftz_valuation_method='recoverable_waste_sale',
 ftz_waste_sale_price=40,ftz_allowance_claimed=FALSE,customs_value=999999)
r<-resolve_shipment_duties(dir,'7602000075','5700','2026-09-15T12:00:00-04:00',scrap)
stopifnot(amount('base')==0,amount('section_301')==10,is.null(r$complete_total))
cases[[3]]<-list(hts10='7602000075',country='5700',entry_at='2026-09-15T12:00:00-04:00',facts=scrap,expected=shipment_result_for_json(r))
if(nzchar(export))jsonlite::write_json(list(revision_dir=revision,cases=cases),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17) else unlink(out,recursive=TRUE)
cat('Ordinary knife, FTZ ceramic and NPF scrap: six-cell normal Parquet relationships, native values, actual reporting and source-owned additional duties passed; unverified authorities remain incomplete\n')

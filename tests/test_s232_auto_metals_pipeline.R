suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
# Two actual products/origins. Preserve their complete source chapter hierarchy for
# the aggregate inputs; the authoritative base extractor reads the original file.
path <- 'data/hts_archives/hts_2026_rev_19.json'
raw <- jsonlite::fromJSON(path,simplifyVector=FALSE);chapter <- '';kept <- list()
for(r in raw) {
  if(nzchar(r$htsno %||% ''))chapter <- substr(r$htsno,1,2)
  if(chapter %in% c('40','73'))kept[[length(kept)+1L]] <- r
}
subset <- tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
products <- parse_products(subset) %>% filter(hts10 %in% c('7320103000','4009120020'));unlink(subset)
stopifnot(nrow(products)==2L)
ch99 <- parse_chapter99(path,revision_id='2026_rev_19')
export <- Sys.getenv('AUTO_METAL_PIPELINE_EXPORT','')
out <- if(nzchar(export))export else tempfile('auto-metal-normal-')
if(file.exists(out))stop('Use a new fixture directory')
dir.create(out,recursive=TRUE)
save_ledger <- duty_ledger_save;duty_ledger_save <- function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates <- calculate_rates_for_revision(products,ch99,NULL,NULL,c('2010','4120'),'2026_rev_19',as.Date('2026-09-15'),
  policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
stopifnot(all(is.na(rates$statutory_rate_232)),all(is.na(rates$statutory_total_rate)),all(rates$shipment_status=='unresolved_source'))
stopifnot(all(rates$valid_from==as.Date('2026-09-15')),all(rates$valid_until==as.Date('2026-09-16')))
base <- list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_parts_use=TRUE,s232_auto_usmca_eligible=FALSE,
  steel_weight_fraction=1,aluminum_weight_fraction=0,copper_weight_fraction=0,us_steel_origin_fraction=0)
facts <- list(covered=base,nonauto=base,eligible=base,kit=base)
facts$nonauto$s232_auto_parts_use <- FALSE
for(name in c('eligible','kit')) {facts[[name]]$s232_auto_usmca_eligible <- TRUE;facts[[name]]$s232_auto_knockdown_kit_or_compilation <- name=='kit'}
expected <- c(covered=25,nonauto=50,eligible=0,kit=25);cases <- list()
for(name in names(facts)) {
  at <- '2026-09-15T12:00:00-04:00'
  r <- resolve_shipment_duties(file.path(out,'2026_rev_19'),'7320103000','2010',at,facts[[name]])
  applied <- Filter(function(c)c$authority=='section_232'&&c$status=='applied',r$components)
  stopifnot(sum(vapply(applied,`[[`,numeric(1),'amount'))==expected[[name]],is.null(r$complete_total))
  cases[[length(cases)+1L]] <- list(hts10='7320103000',country='2010',entry_at=at,facts=facts[[name]],expected=shipment_result_for_json(r))
}
for(mode in c('uk_auto','other_auto','nonauto','unknown_auto_origin')) {
  f <- list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_parts_use=mode!='nonauto',s232_auto_usmca_eligible=FALSE)
  if(mode!='unknown_auto_origin')f$s232_uk_auto_parts_uk_vehicle_use <- mode=='uk_auto'
  at <- '2026-09-15T12:00:00-04:00'
  r <- resolve_shipment_duties(file.path(out,'2026_rev_19'),'4009120020','4120',at,f)
  priced <- Filter(function(c)c$authority %in% c('base','section_232')&&c$status=='applied',r$components)
  expected <- c(uk_auto=10,other_auto=27.5,nonauto=2.5,unknown_auto_origin=0)
  stopifnot(sum(vapply(priced,`[[`,numeric(1),'amount'))==expected[[mode]],is.null(r$complete_total))
  if(mode=='uk_auto')stopifnot(any(vapply(r$components,function(c)c$authority=='base'&&c$status=='suppressed',logical(1))))
  if(mode=='unknown_auto_origin')stopifnot('s232_uk_auto_parts_uk_vehicle_use' %in% r$missing_inputs)
  cases[[length(cases)+1L]] <- list(hts10='4009120020',country='4120',entry_at=at,facts=f,expected=shipment_result_for_json(r))
}
if(nzchar(export)) {
  arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
  jsonlite::write_json(list(revision_dir='2026_rev_19',cases=cases),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17)
} else unlink(out,recursive=TRUE)
cat('8 actual-source normal auto/metal/USMCA/kit and UK combined-base calculations passed\n')

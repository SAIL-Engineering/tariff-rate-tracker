suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('scripts/lib/shipment_partition_validation.R')
# Two real products, two origins, one day: a point-calculator regression,
# not a revision or timeseries rebuild. Product examples exist only in tests.
revision <- '2025_rev_18';hts <- paste0('data/hts_archives/hts_',revision,'.json')
raw <- jsonlite::fromJSON(hts,simplifyVector=FALSE)
chapter <- '';kept <- list()
for(r in raw) {
  if(nzchar(r$htsno %||% ''))chapter <- substr(r$htsno,1,2)
  if(chapter %in% c('40','84'))kept[[length(kept)+1L]] <- r
}
subset <- tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
products <- parse_products(subset) %>% filter(hts10 %in% c('8471500150','4009120020'))
unlink(subset)
stopifnot(nrow(products)==2L)
ch99 <- parse_chapter99(hts,revision_id=revision)
export <- Sys.getenv('AUGUST_PIPELINE_EXPORT','')
out <- if(nzchar(export))export else tempfile('august-reciprocal-normal-')
if(file.exists(out))stop('Fixture destination already exists')
dir.create(out)
save_ledger <- duty_ledger_save
duty_ledger_save <- function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates <- calculate_rates_for_revision(products,ch99,NULL,NULL,c('4279','5880'),revision,as.Date('2025-08-08'),
  policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2025-08-09'))
revision_dir <- file.path(out,revision)
stopifnot(nrow(rates)==4L,all(is.na(rates$statutory_total_rate)),all(rates$shipment_status=='unresolved_source'))
arrow::write_parquet(rates,file.path(out,'rates.parquet'))
verified <- validate_shipment_partition(revision_dir,file.path(out,'rates.parquet'))
stopifnot(verified$grid_cells==4L,!verified$legal_coverage_complete)
q <- list(customs_value=100,ieepa_ftz_entry=FALSE,ieepa_personal_accompanied_baggage=FALSE,
  ieepa_qualifying_humanitarian_donation=FALSE,ieepa_informational_material=FALSE,ieepa_de_minimis_claimed=FALSE,
  reciprocal_cbp_transshipment_evasion_determination=FALSE,s232_auto_usmca_eligible=FALSE)
cases <- 0L
for(country in c('4279','5880'))for(hts10 in products$hts10)for(auto_use in c(TRUE,FALSE)) {
  facts <- c(q,list(s232_auto_parts_use=auto_use))
  result <- resolve_shipment_duties(revision_dir,hts10,country,'2025-08-08T12:00:00-04:00',facts)
  applied <- Filter(function(c)c$status=='applied',result$components)
  by_authority <- function(authority)sum(vapply(Filter(function(c)c$authority==authority,applied),`[[`,numeric(1),'amount'))
  base <- if(hts10=='4009120020')2.5 else 0
  auto <- if(auto_use)if(country=='4279')15-base else 25 else 0
  # The ordinary build does not yet attest the complete232 inventory. An
  # actual matched auto action establishes its reciprocal exception. For a
  # non-auto, non-product-exempt article, absence of another232 action is
  # still unverified: do not invent a complete inventory to price the floor.
  unverified_inventory <- !auto_use&&hts10=='4009120020'
  reciprocal <- 0
  print(list(hts10=hts10,country=country,auto_use=auto_use,
    amounts=c(base=by_authority('base'),auto=by_authority('section_232'),reciprocal=by_authority('ieepa_reciprocal')),
    result=result[c('status','known_subtotal','missing_inputs','source_errors')]))
  if(unverified_inventory)stopifnot('coverage_dependency_unverified:section_232' %in% result$source_errors)
  stopifnot(by_authority('base')==base,by_authority('section_232')==auto,
    by_authority('ieepa_reciprocal')==reciprocal,is.null(result$complete_total),result$status=='unresolved_source')
  codes <- unique(unlist(lapply(Filter(function(c)c$authority=='ieepa_reciprocal',applied),`[[`,'reporting_codes')))
  expected <- if(hts10=='8471500150')'9903.01.32' else if(auto_use)'9903.01.33' else character()
  if(!setequal(codes,expected)) {
    print(list(hts10=hts10,country=country,auto_use=auto_use,expected=expected,codes=codes,
      result=result[c('status','known_subtotal','missing_inputs','source_errors')]))
    stop('Normal-build reciprocal reporting mismatch')
  }
  cases <- cases+1L
}
if(!nzchar(export))unlink(out,recursive=TRUE)
cat(cases,'actual-source August ordinary-build base/auto/reciprocal cases and complete-grid Parquet validation passed\n')

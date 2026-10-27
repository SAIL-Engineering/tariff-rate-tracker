suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('scripts/lib/shipment_partition_validation.R')
# A bounded point-calculator test, not a revision/timeseries rebuild. In this
# source the selected products have no Chapter99 footnotes. The post-IEEPA
# grid must still accept the actual, non-null eligibility table from the driver.
revision <- '2026_rev_19';path <- paste0('data/hts_archives/hts_',revision,'.json')
raw <- jsonlite::fromJSON(path,simplifyVector=FALSE)
selected <- c('4009120020','8471500150');chapter <- '';kept <- list()
for(row in raw) {
  if(nzchar(row$htsno %||% ''))chapter <- substr(row$htsno,1,2)
  if(chapter %in% substr(selected,1,2))kept[[length(kept)+1L]] <- row
}
subset <- tempfile(fileext='.json');jsonlite::write_json(kept,subset,auto_unbox=TRUE,null='null')
products <- parse_products(subset) %>% filter(hts10 %in% selected);unlink(subset)
stopifnot(nrow(products)==2L,all(lengths(products$ch99_refs)==0L))
eligibility <- extract_usmca_eligibility(raw)
stopifnot(all(products$hts10 %in% eligibility$hts10),any(eligibility$usmca_eligible[match(products$hts10,eligibility$hts10)]))
ch99 <- parse_chapter99(path,revision_id=revision)
export <- Sys.getenv('USMCA_GRID_EXPORT','');out <- if(nzchar(export))export else tempfile('usmca-empty-grid-')
if(file.exists(out))stop('Fixture destination already exists')
dir.create(out)
save_ledger <- duty_ledger_save
duty_ledger_save <- function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
countries <- c('1220','2010','4280')
rates <- calculate_rates_for_revision(products,ch99,NULL,eligibility,countries,revision,as.Date('2026-09-15'),
  policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
expected <- eligibility$usmca_eligible[match(rates$hts10,eligibility$hts10)] & rates$country %in% c('1220','2010')
stopifnot(nrow(rates)==6L,identical(rates$usmca_eligible,expected),
  !any(grepl('^usmca_eligible\\.',names(rates))),!anyNA(rates$usmca_eligible),
  all(rates$shipment_status=='unresolved_source'),all(is.na(rates$statutory_total_rate)))
arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
verified <- validate_shipment_partition(file.path(out,revision),file.path(out,'rates_fixture.parquet'))
stopifnot(verified$grid_cells==6L,!verified$legal_coverage_complete)
# The aggregate eligibility column must not establish a shipment preference
# claim, auto use or semiconductor end use. Facts stay explicit in the rules.
cases <- lapply(seq_len(nrow(rates)),function(i) {
  at <- '2026-09-15T12:00:00-04:00'
  result <- resolve_shipment_duties(file.path(out,revision),rates$hts10[i],rates$country[i],at,list(customs_value=100))
  stopifnot(result$status=='unresolved_source',is.null(result$complete_total))
  list(hts10=rates$hts10[i],country=rates$country[i],entry_at=at,facts=list(customs_value=100),
    expected=shipment_result_for_json(result))
})
if(nzchar(export))jsonlite::write_json(list(revision_dir=revision,cases=cases),file.path(out,'delivery_cases.json'),
  auto_unbox=TRUE,null='null',digits=17) else unlink(out,recursive=TRUE)
cat('Six actual-source empty-seed grid rows retain sourced USMCA eligibility and explicit shipment incompleteness\n')

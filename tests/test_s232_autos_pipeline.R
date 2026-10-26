suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
# Three actual source products and two origins only. This is not a complete
# revision/timeseries rebuild. Use the identified revision's product inputs.
hts <- 'data/hts_archives/hts_2025_rev_11.json'
products <- parse_products(hts) %>% filter(hts10 %in% c('8703230190','8471500150','4009120020'))
stopifnot(nrow(products)==3L)
ch99 <- parse_chapter99(hts,revision_id='2025_rev_11')
export <- Sys.getenv('AUTO_PIPELINE_EXPORT','')
out <- if(nzchar(export))export else tempfile('auto-normal-pipeline-')
if(file.exists(out))stop('Fixture destination already exists')
dir.create(out,recursive=TRUE)
save_ledger <- duty_ledger_save
duty_ledger_save <- function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates <- calculate_rates_for_revision(products,ch99,NULL,NULL,c('2010','5700'),'2025_rev_11',as.Date('2025-05-03'),
  policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2025-05-04'))
revision_dir <- file.path(out,'2025_rev_11')
fragment <- read_shipment_rule_fragment(file.path(revision_dir,'section232_automobile_rules.json'))
stopifnot(length(fragment$rules)>0L,!length(fragment$coverage),length(fragment$derived_facts)==8L,
  all(is.na(rates$statutory_total_rate)),all(rates$shipment_status=='unresolved_source'))
inventory <- arrow::read_parquet(file.path(revision_dir,'chapter99_provisions.parquet'))
row <- inventory %>% filter(reporting_code=='9903.94.05')
stopifnot(nrow(row)==1L,grepl('auto_2025_rev_11_',row$rule_links_json,fixed=TRUE))
candidates <- arrow::read_parquet(file.path(revision_dir,'authority_product_candidates.parquet')) %>%
  filter(program=='s232_automobile_parts')
stopifnot(setequal(candidates$hts10,c('8471500150','4009120020')))
stopifnot(candidates$scope_code[candidates$hts10=='8471500150']=='8471',
  candidates$scope_grain[candidates$hts10=='8471500150']=='prefix',
  candidates$scope_code[candidates$hts10=='4009120020']=='4009120020',
  all(candidates$source_sha256=='84c26c9856d6bf258712481168f7ce0064833868b9403b7078c3b6e26c0b8973'))
cases <- list()
for(country in c('2010','5700'))for(hts10 in products$hts10)for(covered_use in c(TRUE,FALSE)) {
  facts <- list(customs_value=100,ieepa_ftz_entry=FALSE,s232_auto_passenger_vehicle=covered_use,
    s232_auto_manufacture_year=2020,s232_auto_parts_use=covered_use,s232_auto_usmca_eligible=FALSE,
    # Deliberately contradict obsolete independently entered aliases. The
    # composed rules must derive these decisions from the actual automobile facts.
    s232_usmca_auto_parts_not_kits=TRUE,s122_usmca_auto_parts_not_kits=TRUE)
  at <- '2025-05-03T12:00:00-04:00'
  result <- resolve_shipment_duties(revision_dir,hts10,country,at,facts)
  components <- Filter(function(c)c$action_id %in% c('s232_automobiles','s232_automobile_parts')&&c$status=='applied',result$components)
  stopifnot(length(components)==1L,components[[1]]$amount==if(covered_use)25 else 0,
    is.null(result$complete_total),result$status=='unresolved_source')
  cases[[length(cases)+1L]] <- list(hts10=hts10,country=country,entry_at=at,facts=facts,expected=shipment_result_for_json(result))
}
if(nzchar(export)) {
  arrow::write_parquet(rates,file.path(out,'rates_fixture.parquet'))
  jsonlite::write_json(list(revision_dir='2025_rev_11',cases=cases),file.path(out,'delivery_cases.json'),auto_unbox=TRUE,null='null',digits=17)
} else unlink(out,recursive=TRUE)
cat('12 actual-source normal automobile/parts and adjacent-use shipment calculations passed\n')

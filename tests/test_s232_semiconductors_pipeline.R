suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R');source('src/compile_shipment_rules.R')
# Two actual-source products and one origin, not a revision/timeseries build.
products <- readRDS('data/processed/products_2026_rev_4.rds') %>% filter(hts10 %in% c('8471500150','8471410150'))
stopifnot(nrow(products)==2)
ch99 <- parse_chapter99('data/hts_archives/hts_2026_rev_17.json',revision_id='2026_rev_17')
export <- Sys.getenv('SHIPMENT_PIPELINE_EXPORT','')
out <- if(nzchar(export))export else tempfile('semiconductor-pipeline-')
if(file.exists(out))stop('Fixture export destination already exists')
dir.create(out,recursive=TRUE)
save_ledger <- duty_ledger_save
duty_ledger_save <- function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
r <- calculate_rates_for_revision(products,ch99,NULL,NULL,'4280','2026_rev_17',as.Date('2026-09-15'),
  policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
path <- file.path(out,'2026_rev_17','section232_semiconductors_rules.json')
stopifnot(file.exists(path))
f <- read_shipment_rule_fragment(path)
stopifnot(length(f$rules)==45,!length(f$coverage),all(vapply(f$rules,function(r)identical(unlist(r$scope$hts_exact),'8471500150'),logical(1))))
candidate <- arrow::read_parquet(file.path(out,'2026_rev_17','authority_product_candidates.parquet')) %>%
  filter(program=='semiconductor_note39')
stopifnot(identical(candidate$hts10,'8471500150'),candidate$scope_code=='847150',
  candidate$status=='candidate_requires_legal_predicates')
inventory <- arrow::read_parquet(file.path(out,'2026_rev_17','chapter99_provisions.parquet'))
semi <- inventory %>% filter(reporting_code=='9903.79.01')
stopifnot(nrow(semi)==1,grepl('s232_semiconductors_99037901_window4',semi$rule_links_json,fixed=TRUE),
  grepl('semiconductor_ftz_admission_status',semi$executable_gaps_json,fixed=TRUE),
  is.na(r$statutory_rate_232[r$hts10=='8471500150']),is.na(r$statutory_total_rate[r$hts10=='8471500150']))
revision_dir <- file.path(out,'2026_rev_17')
index <- jsonlite::fromJSON(file.path(revision_dir,'shipment_rules.json'),simplifyVector=FALSE)
memberships <- arrow::read_parquet(file.path(revision_dir,'shipment_decision_membership.parquet'))
classes <- arrow::read_parquet(file.path(revision_dir,'shipment_decision_classes.parquet'))
stopifnot(index$contract_version=='sail.shipment-bundle-index/v1',length(index$bundles)>=1L,
  all(r$shipment_status=='unresolved_source'),all(is.na(r$statutory_total_rate)),
  all(memberships$class_id %in% classes$class_id),all(memberships$dataset_version==r$shipment_dataset_version[1]))
facts <- list(customs_value=100,ieepa_ftz_entry=FALSE,contains_logic_integrated_circuit=TRUE,
  all_logic_ic_specs_reviewed=TRUE,total_processing_performance=15000,dram_bandwidth_gb_s=4700,semiconductor_end_use='none')
cases <- list()
for(hts in c('8471500150','8471410150')) {
  at <- '2026-09-15T12:00:00-04:00'
  result <- resolve_shipment_duties(revision_dir,hts,'4280',at,facts)
  stopifnot(result$status=='unresolved_source',is.null(result$complete_total))
  semi <- Filter(function(c)c$action_id=='s232_semiconductors_20260115'&&c$status=='applied',result$components)
  if(hts=='8471500150')stopifnot(length(semi)==1L,semi[[1]]$amount==25,'9903.79.01' %in% unlist(semi[[1]]$reporting_codes))
  else stopifnot(length(semi)==0L)
  cases[[length(cases)+1L]] <- list(hts10=hts,country='4280',entry_at=at,facts=facts,expected=shipment_result_for_json(result))
}
if(nzchar(export)) {
  arrow::write_parquet(r,file.path(out,'rates_fixture.parquet'))
  jsonlite::write_json(list(revision_dir='2026_rev_17',cases=cases),file.path(out,'delivery_cases.json'),
    auto_unbox=TRUE,null='null',digits=NA)
} else unlink(out,recursive=TRUE)
cat('Semiconductor normal emission, exact scope, source inventory and statutory incompleteness passed\n')

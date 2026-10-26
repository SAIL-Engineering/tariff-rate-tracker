suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
path <- 'data/hts_archives/hts_2026_rev_19.json'
products <- parse_products(path) %>% filter(hts10 %in% c('8703230190','9801001010'))
stopifnot(nrow(products)==2L)
ch99 <- parse_chapter99(path,revision_id='2026_rev_19')
out <- tempfile('special-normal-pipeline-');dir.create(out)
save_ledger <- duty_ledger_save;duty_ledger_save <- function(...)save_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates <- calculate_rates_for_revision(products,ch99,NULL,NULL,'2010','2026_rev_19',as.Date('2026-09-15'),
 policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-09-16'))
special <- rates %>% filter(hts10=='9801001010')
stopifnot(nrow(special)==1L,is.na(special$statutory_base_rate),is.na(special$statutory_total_rate),special$shipment_status=='unresolved_source')
r <- resolve_shipment_duties(file.path(out,'2026_rev_19'),'9801001010','2010','2026-09-15T12:00:00-04:00',
 list(customs_value=100,ieepa_ftz_entry=FALSE))
stopifnot(is.null(r$complete_total),r$known_subtotal==0,
 any(grepl('chapter98_entitlement_valuation_and_cross_program_reconciliation',r$source_errors,fixed=TRUE)))
source('scripts/lib/shipment_partition_validation.R')
arrow::write_parquet(rates,file.path(out,'rates.parquet'))
v <- validate_shipment_partition(file.path(out,'2026_rev_19'),file.path(out,'rates.parquet'))
stopifnot(v$grid_cells==2L)
only <- calculate_rates_for_revision(products %>% filter(hts10=='9801001010'),ch99,NULL,NULL,'2010',
 '2026_rev_19',as.Date('2026-09-15'),policy_params=load_policy_params(),
 normalized_output_dir=file.path(out,'special-only'),normalized_valid_until=as.Date('2026-09-16'))
stopifnot(nrow(only)==1L,is.na(only$statutory_base_rate),is.na(only$statutory_total_rate),
 only$shipment_status=='unresolved_source')
unlink(out,recursive=TRUE)
cat('Native Chapter98 and ordinary product coexist in normal emission without false zero or build rejection\n')

suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('scripts/lib/shipment_partition_validation.R')
# One entry-date point through the ordinary calculator, not the revision's
# legal-state/timeseries builder. Reuse the user's entire diagnostic cohort.
input <- readRDS('/tmp/usmca-cohort-point-input.rds')
stopifnot(identical(input$source_version,load_shipment_build_context()$dataset_version))
revision <- input$revision;day <- input$day;products <- input$products
stopifnot(nrow(products)==11L)
ch99 <- input$ch99;other <- input$other;eligibility <- input$eligibility
countries <- c('2010','1220','5700','4120','4280','5880','5800','5830')
out <- '/tmp/usmca-complete-cohort-point-final'
if(file.exists(out))stop('Point output already exists')
dir.create(out)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
rates <- calculate_rates_for_revision(products,ch99,input$ieepa,
  eligibility,countries,revision,day,s232_rates=input$s232,
  fentanyl_rates=input$fentanyl,
  policy_params=load_policy_params(),ch99_other=other,normalized_output_dir=out,normalized_valid_until=day)
stopifnot(nrow(rates)==88L,all(rates$shipment_status=='unresolved_source'),
  all(is.na(rates$statutory_total_rate)),!any(grepl('^usmca_eligible\\.',names(rates))))
expected <- eligibility$usmca_eligible[match(rates$hts10,eligibility$hts10)]
expected[is.na(expected)] <- FALSE
expected <- expected & rates$country %in% c('1220','2010')
stopifnot(identical(rates$usmca_eligible,expected))
arrow::write_parquet(rates,file.path(out,'rates.parquet'))
verified <- validate_shipment_partition(file.path(out,revision),file.path(out,'rates.parquet'))
stopifnot(verified$grid_cells==88L,!verified$legal_coverage_complete)
jsonlite::write_json(list(kind='bounded_one_date_point_calculation',revision_build_executed=FALSE,
  products=nrow(products),countries=length(countries),verification=verified),file.path(out,'verification.json'),
  pretty=TRUE,auto_unbox=TRUE,null='null',digits=17)
cat('All88 manual diagnostic cohort cells pass the one-date normal calculator and complete-grid validation\n')

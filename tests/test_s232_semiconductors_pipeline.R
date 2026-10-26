suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R');source('src/compile_shipment_rules.R')
# Two actual-source products and one origin, not a revision/timeseries build.
products <- readRDS('data/processed/products_2026_rev_4.rds') %>% filter(hts10 %in% c('8471500150','8471410150'))
stopifnot(nrow(products)==2)
ch99 <- parse_chapter99('data/hts_archives/hts_2026_rev_17.json',revision_id='2026_rev_17')
out <- tempfile('semiconductor-pipeline-');dir.create(out)
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
unlink(out,recursive=TRUE)
cat('Semiconductor normal emission, exact scope, source inventory and statutory incompleteness passed\n')

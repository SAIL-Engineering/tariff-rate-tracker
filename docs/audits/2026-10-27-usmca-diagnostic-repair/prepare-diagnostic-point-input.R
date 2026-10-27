suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R')
source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R')
source('src/shipment_build.R')
revision <- '2026_rev_19';day <- as.Date('2026-09-15')
path <- paste0('data/hts_archives/hts_',revision,'.json')
raw <- jsonlite::fromJSON(path,simplifyVector=FALSE)
requested <- read.csv('tests/fixtures/shipment/diagnostic-cohort.csv',colClasses='character')$hts10
products <- parse_products(path) %>% filter(hts10 %in% requested)
ch99 <- parse_chapter99(path,revision_id=revision)
other <- parse_chapter99_other(hts_raw=raw,revision_id=revision)
eligibility <- extract_usmca_eligibility(raw)
lookup <- build_country_lookup('resources/census_codes.csv')
saveRDS(list(revision=revision,day=day,products=products,ch99=ch99,other=other,eligibility=eligibility,
  ieepa=extract_ieepa_rates(raw,lookup,effective_date=day),
  s232=extract_section232_rates(ch99,effective_date=day),
  fentanyl=extract_ieepa_fentanyl_rates(raw,lookup,effective_date=day,revision_id=revision),
  source_version=load_shipment_build_context()$dataset_version),'/tmp/usmca-cohort-point-input.rds')
cat('Parsed cohort inputs retained without calculating any rates\n')

suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/05_parse_policy_params.R')
source('src/06_calculate_rates.R');source('src/section232_legacy.R');source('src/legal_intervals.R')
# Bounded calculator fixture: three products and one origin, temporary output.
# This is not a revision or timeseries build.
products<-readRDS('data/processed/products_2026_rev_4.rds') %>%
 filter(hts10 %in% c('7201100000','7202115000','7318158085'))
stopifnot(nrow(products)==3)
ch99<-parse_chapter99('data/hts_archives/hts_2026_rev_4.json',revision_id='2026_rev_4')
out<-tempfile('legacy-normalized-fixture-');dir.create(out)
save_fixture_ledger<-duty_ledger_save
duty_ledger_save<-function(...) save_fixture_ledger(dir=file.path(out,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
r<-calculate_rates_for_revision(products,ch99,NULL,NULL,'5700','2026_rev_4',as.Date('2026-03-01'),
 policy_params=load_policy_params(),normalized_output_dir=out,normalized_valid_until=as.Date('2026-04-05'))
stopifnot(all(r$rate_232[r$hts10 %in% c('7201100000','7202115000')]==0),
 r$rate_232[r$hts10=='7318158085']>0,is.na(r$statutory_rate_232[r$hts10=='7318158085']))
part<-arrow::read_parquet(file.path(out,'2026_rev_4','section232_scope_decisions.parquet'))
stopifnot(identical(names(part),c(names(s232_note16_matches(list(lists=list()),character())),
 'revision','authority','state_valid_from','state_valid_until')))
stopifnot(setequal(unique(part$hts10),'7318158085'),all(part$state_valid_from==as.Date('2026-03-01')),
 file.exists(file.path(out,'2026_rev_4','section232_legacy_rules.json')))
app<-arrow::read_parquet(file.path(out,'2026_rev_4','authority_product_applicability.parquet'))
metal<-app %>% filter(authority=='section_232',program %in% c('steel_base','alum_base','steel_deriv','aluminum_deriv'))
stopifnot(!any(metal$hts_prefix %in% c('72','73','76'),na.rm=TRUE),
 all(coalesce(metal$hts10,metal$hts_prefix)=='7318158085'))
candidates<-arrow::read_parquet(file.path(out,'2026_rev_4','authority_product_candidates.parquet'))
stopifnot(any(startsWith(candidates$program,'legacy_metals_')))
# The early-published March source creates a March 12 legal state.
x<-load_s232_legacy_source('2025_rev_4')
dates<-data.frame(revision=c('2025_rev_4','next'),effective_date=as.Date(c('2025-03-07','2025-03-14')))
s<-revision_legal_segments('2025_rev_4',dates,list(),x)
stopifnot('2025-03-12' %in% as.character(s$valid_from))
# Epoch filtering reaches the footnote path as well as rate extraction.
h<-tibble(ch99_code=c('9903.80.01','9903.81.87','9903.85.01','9903.85.02','9903.88.01'))
stopifnot(setequal(filter_active_ch99(h,'2025-03-11')$ch99_code,c('9903.80.01','9903.85.01','9903.88.01')),
 setequal(filter_active_ch99(h,'2025-03-12')$ch99_code,c('9903.81.87','9903.85.02','9903.88.01')))
unlink(out,recursive=TRUE)
cat('Bounded calculator, exact normalized model scopes, temporal decisions and rule artifacts passed\n')

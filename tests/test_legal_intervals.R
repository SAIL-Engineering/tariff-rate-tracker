suppressPackageStartupMessages({library(tidyverse);library(here);library(arrow)})
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/legal_intervals.R')
rd<-data.frame(revision=c('r1','r2'),effective_date=as.Date(c('2025-11-13','2025-11-21')))
segments<-revision_legal_segments('r1',rd,list(SERIES_HORIZON_END=as.Date('2025-12-31')),load_ieepa_country_amendments())
stopifnot(identical(as.character(segments$valid_from),c('2025-11-13','2025-11-14')),
  identical(as.character(segments$valid_until),c('2025-11-13','2025-11-20')))
source('src/09_daily_series.R')
# One product and origin, two legal states in a single source revision. A
# later state must neither duplicate the pair nor contaminate earlier days.
x<-enforce_rate_schema(tibble(hts10='0101210010',country='5800',revision='r1',
  base_rate=c(.05,.05),statutory_base_rate=c(.05,.05),rate_ieepa_recip=c(.15,.1),
  valid_from=segments$valid_from,valid_until=segments$valid_until))
x<-apply_stacking_rules(x)
stopifnot(nrow(validate_snapshot_intervals(x,as.Date('2025-11-13'),as.Date('2025-11-20')))==2)
bad<-x;bad$valid_until[1]<-as.Date('2025-11-14')
stopifnot(inherits(try(validate_snapshot_intervals(bad,min(x$valid_from),max(x$valid_until)),silent=TRUE),'try-error'))
daily<-build_daily_aggregates(x,policy_params=list())
stopifnot(nrow(daily$daily_overall)==8,all(daily$daily_overall$n_pairs==1),
  abs(daily$daily_overall$mean_total_exposed[1]-.2)<1e-12,
  all(abs(daily$daily_overall$mean_total_exposed[-1]-.15)<1e-12))
stopifnot(get_rates_at_date(x,'2025-11-13',list())$rate_ieepa_recip==.15,
  get_rates_at_date(x,'2025-11-14',list())$rate_ieepa_recip==.1)
tmp<-tempfile();dir.create(tmp)
roots<-file.path(tmp,c('first','second'));destination<-file.path(tmp,'output');dir.create(destination)
for(i in seq_along(roots)) {
 dir.create(file.path(roots[i],'r1'),recursive=TRUE)
 arrow::write_parquet(x[i,],file.path(roots[i],'r1','products_base.parquet'))
 for(file in c('authority_country_rates.parquet','authority_product_applicability.parquet','authority_exemptions.parquet'))
   arrow::write_parquet(data.frame(revision=character(),valid_from=as.Date(character()),valid_until=as.Date(character())),file.path(roots[i],'r1',file))
 arrow::write_parquet(data.frame(claim='test',valid_from='2025-01-01T00:01:00-05:00'),
   file.path(roots[i],'r1','claim_effects.parquet'))
}
merge_normalized_segments(roots,'r1',destination,segments)
y<-arrow::read_parquet(file.path(destination,'r1','products_base.parquet'))
stopifnot(nrow(y)==2,identical(y$valid_from,segments$valid_from))
claims<-arrow::read_parquet(file.path(destination,'r1','claim_effects.parquet'))
stopifnot(nrow(claims)==1,claims$valid_from=='2025-01-01T00:01:00-05:00')
# Failed preparation must not replace the previous complete revision.
for(i in seq_along(roots)) jsonlite::write_json(list(legal_rule=i),file.path(roots[i],'r1','rules.json'))
hash<-digest::digest(file=file.path(destination,'r1','products_base.parquet'))
stopifnot(inherits(try(merge_normalized_segments(roots,'r1',destination,segments),silent=TRUE),'try-error'),
  hash==digest::digest(file=file.path(destination,'r1','products_base.parquet')))
unlink(tmp,recursive=TRUE)
cat('Legal interval splitting, daily/point parity and atomic normalized preparation passed\n')

partial <- bind_rows(x,x[1,] %>% mutate(country='5700'))
stopifnot(inherits(try(validate_snapshot_intervals(partial,min(x$valid_from),max(x$valid_until)),silent=TRUE),'try-error'))
partial <- x;partial$valid_until<-NA
stopifnot(inherits(try(validate_snapshot_intervals(partial,min(x$valid_from),max(x$valid_until)),silent=TRUE),'try-error'))
cat('Partial product-country grids and partially missing intervals fail closed\n')

# Exercise the orchestration without rebuilding a real revision. This checks
# that the core calculator is actually called again at an intra-revision event,
# and that both wide and normalized outputs retain those separate states.
local({
  env <- new.env(parent=environment(calculate_revision_legal_states))
  runner <- calculate_revision_legal_states;environment(runner)<-env
  env$extract_ieepa_fentanyl_rates <- function(...) tibble()
  env$load_ieepa_country_amendments <- function() list(change=list(effective_from='2025-11-14T00:01:00-05:00'))
  env$load_stacking_rules <- function() list()
  env$extract_ieepa_rates <- function(...) tibble()
  env$extract_section232_rates <- function(...) list()
  calls <- character()
  env$calculate_rates_for_revision <- function(products,ch99,ieepa,usmca,countries,revision,day,...,
      normalized_output_dir,normalized_valid_until) {
    calls <<- c(calls,as.character(day))
    data <- x[x$valid_from==day,]
    dir.create(file.path(normalized_output_dir,revision),recursive=TRUE)
    for(file in c('products_base','authority_country_rates','authority_product_applicability','authority_exemptions'))
      arrow::write_parquet(data,file.path(normalized_output_dir,revision,paste0(file,'.parquet')))
    data
  }
  out<-tempfile();dir.create(out)
  result<-runner(NULL,NULL,NULL,NULL,'5800','r1',rd,NULL,
    list(SERIES_HORIZON_END=as.Date('2025-12-31')),normalized_root=out,emit_normalized=TRUE)
  stopifnot(identical(calls,c('2025-11-13','2025-11-14')),nrow(result)==2,
    identical(result$rate_ieepa_recip,c(.15,.1)),
    nrow(arrow::read_parquet(file.path(out,'r1','products_base.parquet')))==2)
  unlink(out,recursive=TRUE)
})
cat('Shared builder recalculates each legal state and assembles normalized intervals\n')

suppressPackageStartupMessages({library(tidyverse);library(here)})
source('src/helpers.R')
source('src/07_emit_normalized.R')
root<-tempfile();dir.create(root)
readr::write_csv(tibble(hts10='1111111101'),file.path(root,'exact.csv'))
products<-c('1111111101','1111111102','2222222201')
cfg<-list(products_file='exact.csv',prefixes='1111')
x<-match_s232_heading_products(products,cfg,root)
stopifnot(identical(x$products,'1111111101'),x$matches$scope_grain=='exact_hts10',nchar(x$source_sha256)==64)
stopifnot(!length(match_s232_heading_products(products[-1],cfg,root)$products))
cfg$products_file<-'absent.csv'
stopifnot(inherits(try(match_s232_heading_products(products,cfg,root),silent=TRUE),'try-error'))
readr::write_csv(tibble(hts10=''),file.path(root,'empty.csv'))
stopifnot(inherits(try(match_s232_heading_products(products,list(products_file='empty.csv'),root),silent=TRUE),'try-error'))
# Candidate persistence retains both competing programs even if aggregate
# modeling subsequently strips one from its selected product set.
candidates<-list(auto_parts=list(scope_matches=x$matches,scope_source=x$source_path,scope_sha256=x$source_sha256),
                 semiconductors=list(scope_matches=x$matches,scope_source=x$source_path,scope_sha256=x$source_sha256))
y<-emit_authority_product_candidates(candidates,'test',root)
z<-arrow::read_parquet(file.path(root,'test','authority_product_candidates.parquet'))
stopifnot(nrow(z)==2,setequal(z$program,names(candidates)),all(z$status=='candidate_requires_legal_predicates'))
# All current configured scope sources must validate without widening.
pp<-load_policy_params()
for(cfg in pp$section_232_headings) match_s232_heading_products('1111111101',cfg)
unlink(root,recursive=TRUE)
cat('Section 232 exact scopes, missing-source and candidate-persistence safeguards passed\n')


# Conditional automobile scope may not escape through the legacy statutory
# total. A model's zero/positive rate is not a product-use determination.
r <- zero_fill_authority_rates(tibble(hts10=c('1111111101','1111111102','2222222201'),country='5700',
  base_rate=0,statutory_base_rate=0,metal_share=1,rate_232=c(.25,0,.1),total_rate=c(.25,0,.1),
  statutory_rate_232=c(.25,0,.1)))
for (column in setdiff(unname(STATUTORY_RATE_COL_MAP),'statutory_rate_232')) r[[column]] <- 0
before <- r
r <- mark_s232_auto_parts_scope(r,products[1:2],pp$section_232_headings$auto_parts)
stopifnot(all(is.na(r$statutory_rate_232[1:2])),r$statutory_rate_232[3]==.1,
  identical(before$rate_232,r$rate_232),identical(before$total_rate,r$total_rate),
  all(r$shipment_232_scope_status[1:2]=='needs_inputs'))
r <- suppressWarnings(compute_statutory_totals(r))
stopifnot(all(is.na(r$statutory_total_rate[1:2])),r$statutory_total_rate[3]==.1)
stopifnot(inherits(try(mark_s232_auto_parts_scope(before,products,list()),silent=TRUE),'try-error'))
cat('Conditional automobile-parts columns cannot produce a complete statutory total\n')

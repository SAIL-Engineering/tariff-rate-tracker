suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/04_parse_products.R');source('src/05_parse_policy_params.R');source('src/ieepa_reciprocal_revision.R')
rev<-'2025_rev_8'
products<-parse_products(paste0('data/hts_archives/hts_',rev,'.json'))
started<-proc.time()[['elapsed']]
fragment<-compile_reciprocal_initial_fragment(load_reciprocal_scope(rev),products$hts10)
scoped<-unique(unlist(lapply(fragment$rules,function(r)r$scope$hts_exact)))
stopifnot(setequal(scoped,products$hts10),length(fragment$coverage)==0L)
jsonlite::write_json(list(kind='source-only complete product inventory compilation, not a rates build',revision=rev,
  products=nrow(products),rules=length(fragment$rules),coverage_count=length(fragment$coverage),
  elapsed_seconds=proc.time()[['elapsed']]-started,compiler_sha256=fragment$compiler_sha256),
  '/tmp/reciprocal-full-products.json',auto_unbox=TRUE,pretty=TRUE)
cat(nrow(products),'exact products compiled;',length(fragment$rules),'rules; no rates built\n')

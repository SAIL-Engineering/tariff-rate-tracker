suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/section232_autos.R')
source('src/shipment_build.R')
requested <- read.csv('tests/fixtures/shipment/diagnostic-cohort.csv',colClasses='character')$hts10
countries <- c('2010','1220','5700','4120','4280','5880','5800','5830')
report <- list()
for(revision in c('2025_rev_11','2026_rev_19')) {
  base <- load_shipment_base_source(revision)
  products <- intersect(requested,vapply(base$products,`[[`,character(1),'hts10'))
  fragment <- compile_s232_autos_fragment(revision,products,countries)
  stopifnot(length(fragment$rules)>0L,length(fragment$sources)>0L,
    all(vapply(fragment$source_artifacts,function(s)
      identical(digest::digest(file=s$path,algo='sha256'),s$sha256),logical(1))))
  report[[revision]] <- list(products=length(products),rules=length(fragment$rules),
    source_artifacts=length(fragment$source_artifacts),coverage_complete=FALSE)
}
jsonlite::write_json(list(qualification='source_compilation_only',revision_build_executed=FALSE,
  revisions=report),'/tmp/diagnostic-source-compiler-preflight.json',auto_unbox=TRUE,pretty=TRUE)
cat('Both diagnostic automobile source compilers and artifact hashes passed; no revision or rates build executed\n')

suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/ieepa_reciprocal_revision.R')
revisions<-strsplit(trimws(readLines('docs/audits/2026-10-23-motherduck/rebuild-revisions.txt')),',',fixed=TRUE)[[1]]
stopifnot(length(revisions)==55L)
rows<-list()
for(rev in revisions) {
  x<-load_reciprocal_scope(rev)
  fragment<-compile_reciprocal_initial_fragment(x,'0106199120')
  stopifnot(length(fragment$coverage)==0L)
  for(rule in fragment$rules) {
    stopifnot(rule$scope$from>=fragment$legal_horizon$from_,rule$scope$until<=fragment$legal_horizon$until)
  }
  rows[[length(rows)+1L]]<-list(revision=rev,rule_count=length(fragment$rules),
    supported_from=fragment$supported_from,supported_until=fragment$supported_until,
    legal_horizon=fragment$legal_horizon,compiler_sha256=fragment$compiler_sha256,
    compiler_dependencies=fragment$compiler_dependencies,
    sources=lapply(fragment$sources,function(s)s[c('id','sha256')]),
    coverage_count=length(fragment$coverage))
  cat(rev,length(fragment$rules),'rules; no coverage attestation\n')
}
jsonlite::write_json(list(kind='source-only exact-product compiler sweep, not a rates rebuild',
  products=list('0106199120'),results=rows),'/tmp/reciprocal-source-sweep.json',auto_unbox=TRUE,pretty=TRUE)

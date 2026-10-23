# Source-only audit. Does not build rate partitions or write MotherDuck.
args <- commandArgs(trailingOnly=TRUE)
if(length(args)!=1||file.exists(args[1])) stop('Usage: NEW_OUTPUT_DIRECTORY')
suppressPackageStartupMessages({library(tidyverse);library(here)})
source('src/helpers.R');source('src/05_parse_policy_params.R')
lookup <- build_country_lookup('resources/census_codes.csv')
countries <- read_csv('resources/census_codes.csv',col_types=cols(.default=col_character()))$Code
revisions <- strsplit(readLines('docs/audits/2026-10-23-motherduck/rebuild-revisions.txt'),',',fixed=TRUE)[[1]]
rd <- load_revision_dates()
report <- list(audit='ordinary IEEPA country selection; not complete product/claim coverage',
  extractor_sha256=digest::digest(file='src/05_parse_policy_params.R',algo='sha256'),
  selector_sha256=digest::digest(file='src/ieepa_actions.R',algo='sha256'),
  amendment_parser_sha256=digest::digest(file='src/ieepa_amendments.py',algo='sha256'),revisions=list())
dir.create(args[1],recursive=TRUE)
for(rev in revisions) {
 day <- rd$effective_date[match(rev,rd$revision)]
 hts <- paste0('data/hts_archives/hts_',rev,'.json')
 x <- extract_ieepa_rates(jsonlite::fromJSON(hts,simplifyVector=FALSE),lookup,day)
 excluded <- c('1220','2010',load_non_ntr_countries(rev,day))
 ci <- select_ieepa_country_actions(x,countries,excluded)
 active <- if(has_ieepa_collection_ended(day)) NULL else ci
 decisions <- ieepa_action_decisions(x,active,rev)
 report$revisions[[rev]] <- list(entry_day=as.character(day),collection_ended=has_ieepa_collection_ended(day),
   hts_sha256=digest::digest(file=hts,algo='sha256'),ordinary_actions=active,
   retired_headings=sort(unique(x$ch99_code[x$terminated])),
   amendment_sources=attr(x,'amendment_sources'))
 con <- gzfile(file.path(args[1],paste0(rev,'.json.gz')),'wt')
 writeLines(jsonlite::toJSON(decisions,auto_unbox=TRUE,pretty=TRUE,null='null',na='null',digits=NA),con);close(con)
}
jsonlite::write_json(report,file.path(args[1],'report.json'),auto_unbox=TRUE,pretty=TRUE,null='null',na='null',digits=NA)
cat('Audited',length(revisions),'revision sources without rebuilding rates\n')

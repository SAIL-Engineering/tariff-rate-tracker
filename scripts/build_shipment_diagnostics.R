# WJR-run diagnostic builds only. No combine, publication, API activation or
# MotherDuck connection. Use a new directory outside the canonical data outputs.
suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/logging.R');source('src/03_parse_chapter99.R');source('src/04_parse_products.R')
source('src/05_parse_policy_params.R');source('src/06_calculate_rates.R');source('src/legal_intervals.R')
source('src/shipment_build.R')
args <- commandArgs(TRUE)
if(any(!grepl('^--(revisions|output|countries)=.+$|^--(cohort|plan)$',args)))stop('Unknown or empty diagnostic option')
if(anyDuplicated(sub('=.*$','',args)))stop('Duplicate diagnostic option')
option <- function(key,default=NULL) {
 matches <- args[startsWith(args,paste0('--',key,'='))]
 if(length(matches)>1L)stop('Duplicate --',key)
 if(!length(matches))return(default)
 substring(matches,nchar(key)+4L)
}
revisions <- strsplit(option('revisions',''),',',fixed=TRUE)[[1]]
calendar <- load_revision_dates(use_policy_dates=TRUE)
if(!length(revisions)||any(!revisions %in% calendar$revision)||any(!grepl('^202[56]_',revisions)))stop('Select identified 2025/2026 revisions with --revisions=')
output <- option('output');if(is.null(output)||file.exists(output))stop('Provide a new --output= directory')
# Require an existing parent, so canonicalization also resolves symlinks/.. .
output <- file.path(normalizePath(dirname(output),mustWork=TRUE),basename(output))
for(blocked in here::here(c('data','frontend','output/normalized')))if(output==blocked||startsWith(output,paste0(blocked,'/')))stop('Diagnostic output must be outside canonical data/publication roots')
cohort <- '--cohort' %in% args
requested <- if(cohort)as.character(read.csv('tests/fixtures/shipment/diagnostic-cohort.csv',colClasses='character')$hts10) else NULL
countries <- if(is.null(option('countries')))as.character(read.csv('resources/census_codes.csv',colClasses='character')$Code) else strsplit(option('countries'),',',fixed=TRUE)[[1]]
roster <- as.character(read.csv('resources/census_codes.csv',colClasses='character')$Code)
if(any(!countries %in% roster)||anyDuplicated(countries))stop('Unknown or duplicate Census origin')
revisions <- calendar$revision[calendar$revision %in% revisions]
if('--plan' %in% args) {
 print(calendar %>% filter(revision %in% revisions) %>% select(revision,effective_date))
 cat('Output: ',output,'\nOrigins: ',length(countries),'\nProduct scope: ',if(cohort)'explicit diagnostic cohort' else 'complete native inventory','\n',sep='')
 quit(status=0)
}
dir.create(output)
ctx <- load_shipment_build_context();initial_version <- ctx$dataset_version
save_ledger <- duty_ledger_save;duty_ledger_save <- function(...)save_ledger(dir=file.path(output,'provenance'),...)
Sys.setenv(SAIL_EMIT_NORMALIZED='1',SAIL_REQUIRE_NORMALIZED='1')
pp <- load_policy_params()
# The diagnostic audit ends at the declared legal collection cutoff. This is
# a build horizon, never an amendment/effectiveness inference.
pp$SERIES_HORIZON_END <- as.Date(substr(SHIPMENT_BUILD_SPEC$audit_until,1,10))-1L
lookup <- build_country_lookup('resources/census_codes.csv');report <- list()
for(revision in revisions) {
 path <- file.path('data/hts_archives',paste0('hts_',revision,'.json'))
 products <- parse_products(path)
 absent <- if(cohort)setdiff(requested,products$hts10) else character()
 if(cohort)products <- products %>% filter(hts10 %in% requested)
 if(!nrow(products))stop('No cohort products valid in ',revision)
 hts <- jsonlite::fromJSON(path,simplifyVector=FALSE);ch99 <- parse_chapter99(path,revision_id=revision)
 other <- parse_chapter99_other(hts_raw=hts,revision_id=revision)
 rates <- calculate_revision_legal_states(products,ch99,hts,extract_usmca_eligibility(hts),countries,
  revision,calendar,lookup,pp,ch99_other=other,normalized_root=file.path(output,'normalized'),emit_normalized=TRUE)
 if(!identical(load_shipment_build_context()$dataset_version,initial_version))stop('Source inputs changed during diagnostic build; do not qualify this partial output')
 folder <- file.path(output,'rates',paste0('revision=',revision));dir.create(folder,recursive=TRUE)
 arrow::write_parquet(rates %>% select(-revision),file.path(folder,'data.parquet'),compression='zstd')
 report[[revision]] <- list(revision=revision,products=n_distinct(rates$hts10),countries=n_distinct(rates$country),rows=nrow(rates),
  missing_requested_products=as.list(absent),rates_partitioning='hive_revision')
 jsonlite::write_json(list(mode='diagnostic',dataset_version=initial_version,revisions=report,
  publication_qualified=FALSE,legal_coverage_complete=FALSE),file.path(output,'diagnostic-build.json'),auto_unbox=TRUE,pretty=TRUE,null='null',digits=17)
}
cat('Diagnostic artifacts ready at ',output,'; production and active releases were not changed.\n',sep='')

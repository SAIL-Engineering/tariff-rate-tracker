# Read-only source/extraction census. This is not a timeseries/rates rebuild,
# legal coverage certification, release preparation or database migration.
suppressPackageStartupMessages(library(here))
source('src/helpers.R');source('src/shipment_build.R')
args <- commandArgs(trailingOnly=TRUE)
target <- sub('^--output=','',args[grepl('^--output=',args)])
if(length(target)!=1L)stop('Usage: Rscript scripts/preflight_shipment_sources.R --output=/path/report.json')
calendar <- read.csv('config/revision_dates.csv',colClasses='character')
revisions <- calendar$revision[grepl('^202[56]_',calendar$revision)]
reports <- lapply(revisions,function(revision) {
  message('Checking primary shipment sources: ',revision)
  tryCatch({
    x <- load_shipment_base_source(revision)
    rows <- x$products
    expressions <- lapply(c('general','column2'),function(field) {
      raw <- sort(unique(vapply(rows,function(p)p[[field]]$expression %||% '<missing>',character(1))))
      unresolved <- Filter(function(s)!identical(parse_shipment_duty_expression(s)$status,'parsed'),as.list(raw))
      list(column=field,unique_expressions=length(raw),unresolved_complete_expressions=unresolved)
    })
    list(revision=revision,status='source_extraction_verified',product_count=length(rows),
      hts_sha256=x$source$sha256,gn3_sha256=x$gn3$source$sha256,column2_country_names=x$gn3$country_names,
      missing_general=sum(vapply(rows,function(p)is.null(p$general$expression),logical(1))),
      missing_column2=sum(vapply(rows,function(p)is.null(p$column2$expression),logical(1))),
      expressions=expressions)
  },error=function(e)list(revision=revision,status='unresolved_source',error=conditionMessage(e)))
})
report <- list(contract_version='sail.shipment-source-preflight/v1',qualification='source_extraction_only',
  legal_coverage_verified=FALSE,production_release_prepared=FALSE,revision_count=length(revisions),revisions=reports)
dir.create(dirname(target),recursive=TRUE,showWarnings=FALSE)
jsonlite::write_json(report,target,auto_unbox=TRUE,pretty=TRUE,null='null',digits=NA)
bad <- Filter(function(x)x$status!='source_extraction_verified'||x$missing_general>0L||x$missing_column2>0L,reports)
cat(length(reports),'primary revision/GN3 inventories checked;',length(bad),'missing or unresolved primary inventories\n')
if(length(bad))quit(status=1)

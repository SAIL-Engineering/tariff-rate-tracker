# Read-only CLI. Supply identified local artifacts, never a database credential.
suppressPackageStartupMessages(library(dplyr))
source('src/helpers.R');source('scripts/lib/shipment_partition_validation.R')
args <- commandArgs(TRUE)
value <- function(key) {
  a <- args[startsWith(args,paste0('--',key,'='))]
  if(length(a)!=1L)stop('Provide exactly one --',key,'= value')
  substring(a,nchar(key)+4L)
}
request <- jsonlite::fromJSON(value('request'),simplifyVector=FALSE)
result <- validate_shipment_partition(request$normalized_dir,unlist(request$rates),
  if(is.null(request$memberships))NULL else unlist(request$memberships),
  if(is.null(request$classes))NULL else unlist(request$classes),isTRUE(request$require_full_source_inventory),request$rates_partition_revision)
jsonlite::write_json(result,value('output'),auto_unbox=TRUE,pretty=TRUE,null='null',digits=17)

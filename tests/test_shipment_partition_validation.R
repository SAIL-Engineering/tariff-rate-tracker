suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/shipment_build.R')
source('scripts/lib/shipment_partition_validation.R')
export <- Sys.getenv('SHIPMENT_PARTITION_FIXTURE_DIR','')
root <- if(nzchar(export))export else tempfile('shipment-partition-verification-');dir.create(root)
fixture <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
fixture$revision <- 'synthetic_partition';fixture$dataset_version <- paste0('shipment-',strrep('a',64))
fixture$evidence_snapshot_id <- strrep('0',64);fixture$products <- as.list(c('1234567890','1234567891'))
fixture$countries <- as.list(c('2010','5700'));fixture$coverage_requirements <- as.list(SHIPMENT_BUILD_AUTHORITIES)
fixture$claim_definitions <- list();fixture$rules <- fixture$rules[1]
fixture$rules[[1]]$scope <- NULL;fixture$rules[[1]]$formula <- list(op='multiply',args=list(list(fact='customs_value'),list(value=.05)))
fixture$coverage <- list(list(authority=fixture$rules[[1]]$authority,status='verified',determination='rules',rule_ids=list(fixture$rules[[1]]$id),source_ids=fixture$rules[[1]]$source_ids))
for(a in setdiff(SHIPMENT_BUILD_AUTHORITIES,fixture$rules[[1]]$authority))fixture$coverage[[length(fixture$coverage)+1L]] <- list(authority=a,status='unresolved_source',rule_ids=list(),source_ids=list(),question='Synthetic inventory deliberately incomplete')
entries <- list()
for(i in 1:2) {
 b <- fixture;b$valid_from <- c('2026-01-01T05:00:00Z','2026-01-01T12:00:00Z')[i]
 b$valid_until <- c('2026-01-01T12:00:00Z','2026-01-02T05:00:00Z')[i]
 b$bundle_id <- .shipment_source_signature(b);name <- paste0('shipment_bundle_',b$bundle_id,'.json')
 jsonlite::write_json(b,file.path(root,name),auto_unbox=TRUE,null='null',digits=17)
 entries[[i]] <- list(bundle_id=b$bundle_id,path=name,sha256=digest::digest(file=file.path(root,name),algo='sha256'),valid_from=b$valid_from,valid_until=b$valid_until)
}
index <- list(contract_version='sail.shipment-bundle-index/v1',revision=fixture$revision,dataset_version=fixture$dataset_version,
 evidence_snapshot_id=fixture$evidence_snapshot_id,valid_from=entries[[1]]$valid_from,valid_until=entries[[2]]$valid_until,bundles=entries)
jsonlite::write_json(index,file.path(root,'shipment_rules.json'),auto_unbox=TRUE,null='null',digits=17)
rates <- tidyr::expand_grid(hts10=unlist(fixture$products),country=unlist(fixture$countries))
rates$rate_301 <- 0;rates$rate_s301_maritime <- 0
for(k in shipment_wide_fields())rates[[k]] <- NA_real_
projected <- project_shipment_state(rates,index,root)
projected$rates$revision <- fixture$revision;projected$rates$valid_from <- as.Date('2026-01-01');projected$rates$valid_until <- as.Date('2026-01-01')
original <- list(rates=projected$rates,shipment_decision_classes=projected$classes,shipment_decision_membership=projected$memberships)
write <- function(x=original)for(k in names(x))arrow::write_parquet(x[[k]],file.path(root,paste0(k,'.parquet')))
write()
check <- function()validate_shipment_partition(root,file.path(root,'rates.parquet'))
r <- check();stopifnot(r$grid_cells==4L,r$membership_rows==8L,r$bundles==2L,!r$legal_coverage_complete)
bad <- function(table,edit,pattern) {
 x <- original;x[[table]] <- edit(x[[table]]);write(x)
 e <- tryCatch({check();NULL},error=function(e)e)
 if(!inherits(e,'error')||!grepl(pattern,conditionMessage(e),fixed=TRUE))stop('Missing expected validation failure: ',pattern)
 write()
}
bad('rates',function(x)x[-1,],'Incomplete product-country grid')
bad('rates',function(x){x$statutory_total_rate[1] <- 0;x},'Wide shipment projection mismatch')
bad('rates',function(x){x$shipment_dataset_version[1] <- 'stale';x},'Wide shipment projection mismatch')
bad('shipment_decision_membership',function(x)x[-1,],'Decision membership mismatch')
bad('shipment_decision_membership',function(x){x$class_id[1] <- strrep('f',64);x},'Decision membership mismatch')
bad('shipment_decision_classes',function(x){x$known_subtotal[1] <- 999;x},'Decision class mismatch')
bad('shipment_decision_classes',function(x){x$profile_json[1] <- '{}';x},'Decision class mismatch')
bad('shipment_decision_classes',function(x)dplyr::bind_rows(x,x[1,]),'Duplicate decision class')
if(!nzchar(export))unlink(root,recursive=TRUE)
cat('9 complete-grid, class, profile, version and nullable-rate verification checks passed\n')

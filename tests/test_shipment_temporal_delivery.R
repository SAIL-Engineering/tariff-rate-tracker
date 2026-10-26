suppressPackageStartupMessages({library(here);library(arrow)})
source('src/helpers.R');source('src/shipment_build.R');source('src/legal_intervals.R')
# Synthetic mechanics only: two daily source states, immutable exact-time
# bundles, no legal coverage certification and no full revision calculation.
tmp <- tempfile();dir.create(tmp);roots <- file.path(tmp,c('first','second'))
destination <- file.path(tmp,'merged');dir.create(destination)
segments <- data.frame(valid_from=as.Date(c('2025-11-13','2025-11-14')),
  valid_until=as.Date(c('2025-11-13','2025-11-14')))
case <- jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]
paths <- character();precise <- 1.2345678901234567
for(i in seq_along(roots)) {
  dir <- file.path(roots[i],'synthetic');dir.create(dir,recursive=TRUE)
  b <- case$bundle;b$revision <- 'synthetic';b$products <- list(case$hts10);b$countries <- list(case$country)
  b$rules <- b$rules[1];b$rules[[1]]$formula <- list(value=precise)
  b$rules[[1]]$when <- b$rules[[1]]$suppressed_when <- NULL
  b$coverage_requirements <- as.list(SHIPMENT_BUILD_AUTHORITIES);b$coverage <- list()
  b$valid_from <- .shipment_day_start(segments$valid_from[i])
  b$valid_until <- .shipment_day_start(segments$valid_until[i]+1)
  b$bundle_id <- .shipment_source_signature(b)
  name <- paste0('shipment_bundle_',b$bundle_id,'.json');path <- file.path(dir,name)
  writeLines(.shipment_json(b),path);paths <- c(paths,path)
  index <- b[c('revision','dataset_version','evidence_snapshot_id','valid_from','valid_until')]
  index$contract_version <- 'sail.shipment-bundle-index/v1'
  index$bundles <- list(list(bundle_id=b$bundle_id,path=name,sha256=digest::digest(file=path,algo='sha256'),
    valid_from=b$valid_from,valid_until=b$valid_until))
  writeLines(.shipment_json(index),file.path(dir,'shipment_rules.json'))
  # These are source hashes, not hashes of a JSON semantic equivalence class.
  fragment <- '{ "id": "raw-fragment", "value": 1.2345678901234567 }'
  writeLines(fragment,file.path(dir,'fragment.json'))
  for(name in c('products_base','authority_country_rates','authority_product_applicability','authority_exemptions'))
    arrow::write_parquet(data.frame(revision=character(),valid_from=as.Date(character()),valid_until=as.Date(character())),
      file.path(dir,paste0(name,'.parquet')))
}
merge_normalized_segments(roots,'synthetic',destination,segments)
out <- file.path(destination,'synthetic')
index <- jsonlite::fromJSON(file.path(out,'shipment_rules.json'),simplifyVector=FALSE)
stopifnot(length(index$bundles)==2L)
for(i in seq_along(index$bundles)) {
  entry <- index$bundles[[i]]
  stopifnot(identical(digest::digest(file=file.path(out,entry$path),algo='sha256'),entry$sha256))
  result <- resolve_shipment_duties(out,case$hts10,case$country,entry$valid_from,list())
  stopifnot(result$status=='unresolved_source',identical(result$known_subtotal,precise),
    !any(grepl('hash_mismatch|mixed_shipment|invalid_shipment',result$source_errors)))
}
stopifnot(identical(digest::digest(file=file.path(out,'fragment.json'),algo='sha256'),
  digest::digest(file=file.path(roots[1],'synthetic','fragment.json'),algo='sha256')))
# Failed preparation must leave the previously installed revision byte-identical.
before <- vapply(list.files(out,full.names=TRUE),function(p)digest::digest(file=p,algo='sha256'),character(1))
writeLines('{}',paths[1])
stopifnot(inherits(try(merge_normalized_segments(roots,'synthetic',destination,segments),silent=TRUE),'try-error'))
after <- vapply(list.files(out,full.names=TRUE),function(p)digest::digest(file=p,algo='sha256'),character(1))
stopifnot(identical(before,after))
unlink(tmp,recursive=TRUE)
cat('Temporal normalization preserves bundle/source bytes, exact numeric values and the previous revision on failure\n')

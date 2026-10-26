suppressPackageStartupMessages(library(here))
source('src/helpers.R');source('src/shipment_build.R')
stopifnot(identical(.shipment_json(list(rate=NA_real_)),'{"rate":null}'))
# This file uses synthetic coverage solely to test build mechanics. It does not
# certify any legal inventory or ordinary FTZ assumptions in production.
products <- c('8703230190','2203000030')
origins <- c('2010','2390')
base <- compile_shipment_base_fragment(load_shipment_base_source('2025_rev_8'),products,origins)
context <- list(dataset_version='synthetic-build-test',evidence_snapshot_id='unresolved_trade_intelligence_snapshot',
  evidence_status='unresolved_source',input_manifest=list(fixture='not a production release'))
f <- base;f$id <- 'synthetic-action';f$base_source_map <- NULL;f$coverage <- list()
f$rules <- list(list(id='synthetic_232',action_id='synthetic_232',authority='section_232',kind='duty',
  verification='verified',source_ids=base$rules[[1]]$source_ids,reporting_codes=list('9903.99.99'),
  scope=list(hts_exact=list(products[1]),countries=list('2010'),from='2025-04-09T00:01:00-04:00'),
  formula=list(op='multiply',args=list(list(fact='customs_value'),list(value=.25)))))
f$supported_from <- '2025-04-09T00:00:00-04:00';f$supported_until <- '2025-04-10T00:00:00-04:00'
f$legal_horizon <- list(from_='2025-04-09T00:01:00-04:00',until='2025-04-09T12:00:00-04:00')
dir <- tempfile();dir.create(dir)
assembled <- assemble_shipment_state('2025_rev_8',products,origins,'2025-04-09','2025-04-09',
  list(base,f),context,dir)
stopifnot(assembled$contract_version=='sail.shipment-bundle-index/v1',length(assembled$bundles)==3L,
  all(vapply(assembled$bundles,function(e)file.exists(file.path(dir,e$path)),logical(1))))
at <- c('2025-04-09T00:00:59-04:00','2025-04-09T00:01:00-04:00','2025-04-09T12:00:00-04:00')
rs <- lapply(at,function(t)resolve_shipment_duties(dir,products[1],'2010',t,list(customs_value=100,ieepa_ftz_entry=FALSE)))
stopifnot(rs[[1]]$known_subtotal==2.5,rs[[2]]$known_subtotal==27.5,rs[[3]]$known_subtotal==2.5,
  all(vapply(rs,function(r)is.null(r$complete_total)&&r$status=='unresolved_source',logical(1))),
  any(grepl('coverage_unverified:section_232',rs[[2]]$source_errors)))
# A source horizon is not a legal repeal or a zero-rate determination.
index <- jsonlite::fromJSON(file.path(dir,'shipment_rules.json'),simplifyVector=FALSE)
later <- jsonlite::fromJSON(file.path(dir,index$bundles[[3]]$path),simplifyVector=FALSE)
stopifnot(any(vapply(later$unresolved_questions,function(q)q$fragment_id==f$id&&q$reason=='outside_executable_horizon',logical(1))),
  !any(vapply(later$rules,function(r)r$id=='synthetic_232',logical(1))))
rates <- expand.grid(hts10=products,country=origins,stringsAsFactors=FALSE)
rates$base_rate <- .987;rates$total_rate <- .876;rates$rate_232 <- .123
rates$statutory_base_rate <- .987;rates$statutory_rate_232 <- .123;rates$statutory_total_rate <- .876
p <- project_shipment_state(rates,assembled,dir)
stopifnot(identical(p$rates$base_rate,rates$base_rate),identical(p$rates$total_rate,rates$total_rate),
  identical(p$rates$rate_232,rates$rate_232),all(is.na(p$rates$statutory_total_rate)),
  all(is.na(p$rates$statutory_base_rate)),all(p$rates$shipment_status=='unresolved_source'),
  all(p$rates$shipment_dataset_version==context$dataset_version),nrow(p$memberships)==12L,
  all(p$memberships$class_id %in% p$classes$class_id),
  any(grepl('ieepa_ftz_entry',p$classes$decision_json,fixed=TRUE)))
stopifnot(all(vapply(p$classes$decision_json,function(s)is.list(jsonlite::fromJSON(s,simplifyVector=FALSE)$applied_rules),logical(1))))
changed <- rates;changed$base_rate <- 0;changed$rate_232 <- 1;changed$metal_share <- .001
p2 <- project_shipment_state(changed,assembled,dir)
stopifnot(identical(p$memberships,p2$memberships),identical(p$classes,p2$classes))
# Synthetic reviewed inventory: a whole-value action becomes a numeric rate
# only inside its supported scope/window. The daily row spans a legal change.
verified <- f
verified$coverage <- list(list(authority='section_232',status='verified',determination='rules',
  rule_ids=list('synthetic_232'),source_ids=base$rules[[1]]$source_ids))
verified_dir <- tempfile();dir.create(verified_dir)
vi <- assemble_shipment_state('2025_rev_8',products,origins,'2025-04-09','2025-04-09',list(base,verified),context,verified_dir)
vp <- project_shipment_state(rates,vi,verified_dir)
parameters <- vapply(vp$classes$rate_projection_json,function(s)
  jsonlite::fromJSON(s,simplifyVector=FALSE)$statutory_rate_232 %||% NA_real_,numeric(1))
stopifnot(any(parameters==.25,na.rm=TRUE),all(is.na(vp$rates$statutory_rate_232)),all(is.na(vp$rates$statutory_total_rate)))
unlink(verified_dir,recursive=TRUE)
# A malformed index is unsupported, never an uncaught exception or a zero.
bad <- index;bad$valid_from <- NULL
jsonlite::write_json(bad,file.path(dir,'shipment_rules.json'),auto_unbox=TRUE,null='null')
bad_result <- resolve_shipment_duties(dir,products[1],'2010',at[1],list())
stopifnot(bad_result$status=='unresolved_source',is.null(bad_result$complete_total))
bad <- index;bad$bundles <- list('malformed')
jsonlite::write_json(bad,file.path(dir,'shipment_rules.json'),auto_unbox=TRUE,null='null')
stopifnot(resolve_shipment_duties(dir,products[1],'2010',at[1],list())$status=='unresolved_source')
jsonlite::write_json(index,file.path(dir,'shipment_rules.json'),auto_unbox=TRUE,null='null')
# A tampered local bundle cannot be selected or priced.
writeLines('{}',file.path(dir,index$bundles[[1]]$path))
r <- resolve_shipment_duties(dir,products[1],'2010',at[1],list())
stopifnot('shipment_bundle_hash_mismatch' %in% r$source_errors,is.null(r$complete_total))
stopifnot(inherits(try(project_shipment_state(rates,assembled,dir),silent=TRUE),'try-error'))
unlink(dir,recursive=TRUE)
# Separate daily aggregate states must merge into one exact-time index without
# overwriting another state's bundle or accepting mixed source versions.
dirs <- c(tempfile(),tempfile());lapply(dirs,dir.create)
indexes <- lapply(seq_along(dirs),function(i)assemble_shipment_state('2025_rev_8',products,origins,
  as.Date('2025-04-09')+i-1,as.Date('2025-04-09')+i-1,list(base),context,dirs[i]))
merged <- merge_shipment_bundle_indexes(indexes,dirs)
stopifnot(length(merged$bundles)==2L,merged$valid_until=='2025-04-11T04:00:00Z')
indexes[[2]]$dataset_version <- 'different-source-version'
stopifnot(inherits(try(merge_shipment_bundle_indexes(indexes,dirs),silent=TRUE),'try-error'))
lapply(dirs,unlink,recursive=TRUE)
cat('Normal-build bundle chronology, source horizon, projection, aggregate isolation and tamper checks passed\n')

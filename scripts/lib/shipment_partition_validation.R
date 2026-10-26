# Read-only reconciliation of every emitted shipment cell against its immutable
# executable bundles. This verifies the declared rule contract, not complete law.
source(here::here('src/shipment_build.R'))

shipment_wide_fields <- function() c('statutory_base_rate','statutory_rate_232','statutory_rate_301',
 'statutory_rate_ieepa_recip','statutory_rate_ieepa_fent','statutory_rate_s122',
 'statutory_rate_section_201','statutory_rate_other','statutory_rate_s301fl','statutory_rate_s301br',
 'statutory_rate_s301_maritime','statutory_rate_s338','statutory_total_additional','statutory_total_rate')

.shipment_audit_rows <- function(actual,expected,keys,label) {
  if(!all(names(expected) %in% names(actual)))stop(label,': missing fields')
  key <- function(x)do.call(paste,c(x[keys],sep='|'))
  ak <- key(actual);ek <- key(expected)
  if(anyDuplicated(ak)||length(ak)!=length(ek)||!setequal(ak,ek))stop(label,': identity inventory')
  actual <- actual[match(ek,ak),names(expected),drop=FALSE]
  for(k in names(expected)) {
    a <- actual[[k]];e <- expected[[k]]
    if(endsWith(k,'_json')) {
      same <- vapply(seq_along(e),function(i) {
        if(is.na(a[i])||is.na(e[i]))return(is.na(a[i])&&is.na(e[i]))
        tryCatch(identical(.shipment_canonical(jsonlite::fromJSON(a[i],simplifyVector=FALSE)),
          .shipment_canonical(jsonlite::fromJSON(e[i],simplifyVector=FALSE))),error=function(error)FALSE)
      },logical(1))
      if(!all(same))stop(label,': ',k)
    } else {
      if(is.numeric(a)&&is.numeric(e)){a <- as.numeric(a);e <- as.numeric(e)}
      if(!identical(unname(a),unname(e)))stop(label,': ',k)
    }
  }
  invisible(TRUE)
}

.shipment_audit_graph <- function(b) {
  maps <- .shipment_rule_maps(b)
  if(!is.null(maps$error))stop('Invalid executable bundle: ',maps$error)
  if(!setequal(unlist(b$coverage_requirements),SHIPMENT_BUILD_AUTHORITIES))stop('Incomplete authority requirement inventory')
  ids <- names(maps$rules);sources <- names(maps$sources)
  for(s in b$sources)if(!identical(s$status,'verified')||!grepl('^[a-f0-9]{64}$',s$sha256 %||% '')||
    !nzchar(s$url %||% '')||!nzchar(s$citation %||% ''))stop('Invalid executable source provenance')
  references <- function(x) {
    if(!is.list(x))return(character())
    c(unlist(x[c('rule_applies','rule_amount')],use.names=FALSE),unlist(lapply(x,references),use.names=FALSE))
  }
  for(r in b$rules) {
    if(!identical(r$verification,'verified')||!length(r$source_ids)||!all(unlist(r$source_ids)%in%sources)||
      !nzchar(r$action_id %||% '')||!nzchar(r$authority %||% '')||!all(references(r)%in%ids))stop('Invalid executable rule provenance or dependency')
    for(bound in c(r$scope$from,r$scope$until)) {
      t <- .shipment_time(bound)
      if(t>.shipment_time(b$valid_from)&&t<.shipment_time(b$valid_until))stop('Unpartitioned legal rule boundary')
    }
  }
  for(c in b$coverage) {
    if(!all(unlist(c$rule_ids)%in%ids)||!all(unlist(c$source_ids)%in%sources))stop('Invalid coverage relationship')
    for(bound in c(c$scope$from,c$scope$until)) {
      t <- .shipment_time(bound)
      if(t>.shipment_time(b$valid_from)&&t<.shipment_time(b$valid_until))stop('Unpartitioned coverage boundary')
    }
  }
  for(c in b$claim_definitions)if(!length(c$rule_ids)||!all(unlist(c$rule_ids)%in%ids)||
    !length(c$source_ids)||!all(unlist(c$source_ids)%in%sources))stop('Invalid claim relationship')
  invisible(TRUE)
}

validate_shipment_partition <- function(normalized_dir,rates_paths,membership_paths=NULL,class_paths=NULL,require_full_source_inventory=FALSE,rates_partition_revision=NULL) {
  if(!length(rates_paths)||any(!file.exists(rates_paths)))stop('Missing wide rate artifacts')
  index_path <- file.path(normalized_dir,'shipment_rules.json')
  index <- jsonlite::fromJSON(index_path,simplifyVector=FALSE)
  if(!identical(index$contract_version,'sail.shipment-bundle-index/v1')||!length(index$bundles))stop('Unsupported shipment index')
  cursor <- .shipment_time(index$valid_from);end <- .shipment_time(index$valid_until)
  if(anyNA(c(cursor,end))||cursor>=end)stop('Invalid shipment index interval')
  products <- countries <- NULL
  for(e in index$bundles) {
    if(.shipment_time(e$valid_from)!=cursor||.shipment_time(e$valid_until)<=cursor)stop('Shipment index gap or overlap')
    b <- .shipment_verified_bundle(index,e,normalized_dir);.shipment_audit_graph(b)
    if(is.null(products)){products <- unlist(b$products);countries <- unlist(b$countries)}
    if(anyDuplicated(unlist(b$products))||anyDuplicated(unlist(b$countries))||
      !setequal(products,unlist(b$products))||!setequal(countries,unlist(b$countries)))stop('Mixed bundle product-country inventories')
    cursor <- .shipment_time(e$valid_until)
  }
  if(cursor!=end||anyDuplicated(vapply(index$bundles,`[[`,character(1),'bundle_id')))stop('Invalid shipment index coverage')
  if(require_full_source_inventory) {
    base <- load_shipment_base_source(index$revision)
    full_products <- vapply(c(base$products,base$special_classifications),`[[`,character(1),'hts10')
    full_countries <- as.character(read.csv(here::here('resources/census_codes.csv'),colClasses='character')$Code)
    if(!setequal(products,full_products)||!setequal(countries,full_countries))stop('Production release lacks complete native product/origin inventory')
    for(e in index$bundles) {
      b <- .shipment_verified_bundle(index,e,normalized_dir)
      if(.shipment_time(e$valid_from)<.shipment_time(SHIPMENT_BUILD_SPEC$audit_until)&&
         !base$source$sha256 %in% vapply(b$sources,`[[`,character(1),'sha256'))stop('Production native inventory source pin mismatch')
    }
  }
  membership <- arrow::open_dataset(membership_paths %||% file.path(normalized_dir,'shipment_decision_membership.parquet'))
  classes <- arrow::open_dataset(class_paths %||% file.path(normalized_dir,'shipment_decision_classes.parquet'))
  rates <- arrow::open_dataset(rates_paths)
  if(!is.null(rates_partition_revision)) {
    if(!identical(rates_partition_revision,index$revision)||'revision' %in% names(rates)||
      any(basename(dirname(normalizePath(rates_paths)))!=paste0('revision=',index$revision)))stop('Invalid Hive revision identity')
    rates <- rates %>% dplyr::mutate(revision=!!index$revision)
  }
  class_keys <- classes %>% dplyr::select(bundle_id,class_id) %>% dplyr::collect()
  if(anyDuplicated(class_keys$class_id))stop('Duplicate decision class')
  n_members <- membership %>% dplyr::summarise(n=dplyr::n()) %>% dplyr::collect()
  n_rates <- rates %>% dplyr::summarise(n=dplyr::n()) %>% dplyr::collect()
  states <- rates %>% dplyr::select(revision,valid_from,valid_until) %>% dplyr::distinct() %>% dplyr::collect()
  states <- states[order(states$valid_from),]
  if(any(states$revision!=index$revision)||anyNA(states)||any(states$valid_from>states$valid_until)||
    (nrow(states)>1L&&any(states$valid_from[-1]!=head(states$valid_until,-1)+1)))stop('Invalid daily state inventory')
  grid <- length(products)*length(countries)
  if(as.numeric(n_rates$n)!=grid*nrow(states))stop('Incomplete product-country grid')
  if(as.numeric(n_members$n)!=grid*length(index$bundles))stop('Decision membership mismatch: full grid count')
  if(.shipment_time(.shipment_day_start(min(states$valid_from)))!=.shipment_time(index$valid_from)||
    .shipment_time(.shipment_day_start(max(states$valid_until)+1))!=end)stop('Daily state/index interval mismatch')
  checked_classes <- new.env(hash=TRUE,parent=emptyenv())
  checked_bundles <- new.env(hash=TRUE,parent=emptyenv())
  for(s in seq_len(nrow(states))) {
    from <- states$valid_from[s];until <- states$valid_until[s]
    lo <- .shipment_time(.shipment_day_start(from));hi <- .shipment_time(.shipment_day_start(until+1))
    selected <- Filter(function(e).shipment_time(e$valid_from)>=lo&&.shipment_time(e$valid_until)<=hi,index$bundles)
    if(!length(selected)||.shipment_time(selected[[1]]$valid_from)!=lo||.shipment_time(tail(selected,1)[[1]]$valid_until)!=hi)
      stop('Daily state not tiled by exact-time bundles')
    state_index <- index;state_index$bundles <- selected;state_index$valid_from <- selected[[1]]$valid_from
    state_index$valid_until <- tail(selected,1)[[1]]$valid_until
    for(origin in countries) {
      actual <- rates %>% dplyr::filter(country==!!origin,valid_from==!!from,valid_until==!!until) %>% dplyr::collect()
      if(nrow(actual)!=length(products)||anyDuplicated(actual$hts10)||!setequal(actual$hts10,products))stop('Incomplete product-country grid')
      bare <- data.frame(hts10=as.character(actual$hts10),country=as.character(actual$country))
      for(k in shipment_wide_fields())bare[[k]] <- NA_real_
      recomputed <- project_shipment_state(bare,state_index,normalized_dir)
      fields <- c('hts10','country',shipment_wide_fields(),grep('^shipment_',names(recomputed$rates),value=TRUE))
      .shipment_audit_rows(actual,recomputed$rates[fields],c('hts10','country'),'Wide shipment projection mismatch')
      for(e in selected) {
        bid <- e$bundle_id
        expected_m <- recomputed$memberships[recomputed$memberships$bundle_id==bid,,drop=FALSE]
        actual_m <- membership %>% dplyr::filter(bundle_id==!!bid,country==!!origin) %>% dplyr::collect()
        .shipment_audit_rows(actual_m,expected_m,c('bundle_id','hts10','country'),'Decision membership mismatch')
        expected_c <- recomputed$classes[recomputed$classes$bundle_id==bid,,drop=FALSE]
        fresh <- !vapply(expected_c$class_id,exists,logical(1),envir=checked_classes,inherits=FALSE)
        expected_c <- expected_c[fresh,,drop=FALSE]
        if(!nrow(expected_c))next
        ids <- expected_c$class_id
        actual_c <- classes %>% dplyr::filter(class_id %in% !!ids) %>% dplyr::collect()
        .shipment_audit_rows(actual_c,expected_c,c('bundle_id','class_id'),'Decision class mismatch')
        b <- .shipment_verified_bundle(index,e,normalized_dir)
        for(i in seq_len(nrow(expected_c))) {
          representative <- expected_m[expected_m$class_id==expected_c$class_id[i],,drop=FALSE][1,]
          profile <- jsonlite::fromJSON(expected_c$profile_json[i],simplifyVector=FALSE)
          direct <- evaluate_shipment_bundle(b,representative$hts10,origin,e$valid_from,profile$facts)
          decision <- .shipment_compact_decision(direct)
          if(!identical(.shipment_canonical(decision),.shipment_canonical(jsonlite::fromJSON(expected_c$decision_json[i],simplifyVector=FALSE))))
            stop('Direct/prepared decision mismatch')
          assign(expected_c$class_id[i],TRUE,envir=checked_classes)
        }
        assign(bid,TRUE,envir=checked_bundles)
      }
    }
  }
  if(!setequal(class_keys$class_id,ls(checked_classes,all.names=TRUE)))stop('Unused or missing decision class inventory')
  list(contract_version='sail.shipment-partition-verification/v1',revision=index$revision,
    dataset_version=index$dataset_version,evidence_snapshot_id=index$evidence_snapshot_id,
    grid_cells=as.numeric(n_rates$n),membership_rows=as.numeric(n_members$n),decision_classes=nrow(class_keys),
    bundles=length(index$bundles),daily_states=nrow(states),status='consistent_with_declared_rules',
    legal_coverage_complete=FALSE,production_qualified=FALSE,aggregate_methodology_qualified=FALSE)
}

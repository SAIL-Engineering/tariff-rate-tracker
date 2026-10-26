# An HTS release is a source snapshot, not a promise of constant liability
# until the next release. Daily aggregate intervals split at legal events;
# executable shipment rules retain the exact instants independently.

legal_event_days <- function(value) {
  dates <- character()
  visit <- function(x) {
    if(!is.list(x)) return()
    for(name in names(x)) {
      child <- x[[name]]
      if(name %in% c('valid_from','valid_until','from','from_','until','effective_from','effective_at','effective_date',
                    'policy_effective_date','activation_date','patented_pharma_exempt_date')) {
        if(length(child)==1L && !is.list(child) && !is.na(child)) {
          day <- substr(as.character(child),1,10)
          if(grepl('^[0-9]{4}-[0-9]{2}-[0-9]{2}$',day)) dates <<- c(dates,day)
        }
      } else if(name %in% c('expiry_date','policy_expiry_date')) {
        if(length(child)==1L && !is.list(child) && !is.na(child))
          dates <<- c(dates,as.character(as.Date(child)+1))
      }
      if(is.list(child)) visit(child)
    }
    if(is.null(names(x))) for(child in x) if(is.list(child)) visit(child)
  }
  visit(value)
  sort(unique(as.Date(dates)))
}

revision_legal_segments <- function(revision,revision_dates,policy_params,source_events=list()) {
  ordered <- revision_dates[order(revision_dates$effective_date),]
  i <- match(revision,ordered$revision)
  if(is.na(i)||anyDuplicated(ordered$revision)) stop('Ambiguous revision calendar')
  start <- as.Date(ordered$effective_date[i])
  end <- if(i<nrow(ordered)) as.Date(ordered$effective_date[i+1])-1 else as.Date(policy_params$SERIES_HORIZON_END %||% Sys.Date())
  if(is.na(end)||end<start) stop('Invalid revision horizon')
  events <- legal_event_days(list(policy=policy_params,sources=source_events))
  starts <- sort(unique(c(start,events[events>start & events<=end])))
  data.frame(revision=revision,valid_from=starts,valid_until=c(starts[-1]-1,end))
}

validate_snapshot_intervals <- function(snapshot,start,end) {
  present <- c('valid_from','valid_until') %in% names(snapshot)
  if(any(present) && !all(present)) stop('Partially missing snapshot legal intervals')
  have <- all(present) && !(all(is.na(snapshot$valid_from)) && all(is.na(snapshot$valid_until)))
  if(!have) {
    snapshot$valid_from <- as.Date(start);snapshot$valid_until <- as.Date(end)
  }
  windows <- unique(snapshot[c('valid_from','valid_until')])
  windows <- windows[order(windows$valid_from),]
  if(anyNA(windows)||any(windows$valid_from>windows$valid_until) ||
     windows$valid_from[1]!=as.Date(start)||tail(windows$valid_until,1)!=as.Date(end)||
     (nrow(windows)>1L && any(windows$valid_from[-1]!=head(windows$valid_until,-1)+1)))
    stop('Snapshot legal intervals do not tile the configured revision; rebuild required')
  if(anyDuplicated(snapshot[c('hts10','country','valid_from')])) stop('Duplicate shipment pair in legal interval')
  identities <- paste(snapshot$hts10,snapshot$country,sep='|')
  sets <- split(identities,snapshot$valid_from)
  if(!all(vapply(sets,function(keys) setequal(keys,sets[[1]]),logical(1))))
    stop('Incomplete product-country grid across legal intervals')
  snapshot
}

# Normalize each state independently, then assemble the complete revision.
# Nothing replaces the prior normalized directory until all states validate.
merge_normalized_segments <- function(segment_roots,revision,destination,segments) {
  target <- file.path(destination,revision)
  staging <- tempfile(paste0('.',revision,'-assembled-'),tmpdir=destination)
  dir.create(staging,recursive=TRUE)
  on.exit(unlink(staging,recursive=TRUE),add=TRUE)
  roots <- file.path(segment_roots,revision)
  files <- sort(unique(unlist(lapply(roots,list.files))))
  temporal_tables <- c('products_base.parquet','authority_country_rates.parquet',
    'authority_product_applicability.parquet','authority_exemptions.parquet')
  for(root in roots) if(!all(file.exists(file.path(root,temporal_tables))))
    stop('Missing normalized state partitions; previous revision preserved')
  for(file in files) {
    present <- which(file.exists(file.path(roots,file)))
    if(endsWith(file,'.parquet')) {
      rows <- lapply(present,function(i) {
        x <- as.data.frame(arrow::read_parquet(file.path(roots[i],file)))
        # Evidence windows and claim windows are independent of aggregate
        # state windows. Do not truncate a source's exact legal timestamps.
        if(file %in% temporal_tables) {
          x$valid_from <- rep(segments$valid_from[i],nrow(x))
          x$valid_until <- rep(segments$valid_until[i],nrow(x))
        } else if(file %in% c('ieepa_action_decisions.parquet','section232_scope_decisions.parquet')) {
          x$state_valid_from <- rep(segments$valid_from[i],nrow(x))
          x$state_valid_until <- rep(segments$valid_until[i],nrow(x))
        }
        x
      })
      arrow::write_parquet(unique(dplyr::bind_rows(rows)),file.path(staging,file))
    } else if(endsWith(file,'.json')) {
      values <- lapply(present,function(i) jsonlite::fromJSON(file.path(roots[i],file),simplifyVector=FALSE))
      result <- values[[1]]
      if(file=='shipment_rules.json') {
        source(here::here('src/shipment_build.R'))
        if(length(present)!=length(roots))stop('Missing executable shipment state index; previous revision preserved')
        result <- merge_shipment_bundle_indexes(values,roots[present])
      } else if(file=='ieepa_evidence_sources.json') {
        for(key in c('sources','source_artifacts')) {
          entries <- unlist(lapply(values,`[[`,key),recursive=FALSE)
          names <- vapply(entries,function(e) e$id %||% e$source_id,character(1))
          result[[key]] <- lapply(unique(names),function(id) {
            candidates <- entries[names==id]
            if(!all(vapply(candidates,function(x) identical(x,candidates[[1]]),logical(1))))
              stop('Conflicting evidence across legal intervals: ',id)
            candidates[[1]]
          })
        }
      } else if(!all(vapply(values,function(x) identical(x,result),logical(1))))
        stop('Unresolved rule/source changes across intervals: ',file)
      jsonlite::write_json(result,file.path(staging,file),auto_unbox=TRUE,pretty=TRUE,null='null',digits=NA)
    } else stop('Unrecognized normalized artifact: ',file)
  }
  shared <- sort(unique(unlist(lapply(segment_roots,function(p) list.files(p,pattern='\\.parquet$')))))
  shared_paths <- list()
  for(file in shared) {
    paths <- file.path(segment_roots,file);paths<-paths[file.exists(paths)]
    hashes <- vapply(paths,function(p) digest::digest(file=p,algo='sha256'),character(1))
    if(length(unique(hashes))!=1L) stop('Shared normalized artifact varies between legal states: ',file)
    shared_paths[[file]] <- paths[1]
  }
  backup <- tempfile(paste0('.',revision,'-previous-'),tmpdir=destination)
  dir.create(backup)
  # Stage and preserve shared files before replacing anything. Restore both
  # the revision and shared files if a subsequent local installation fails.
  old_shared <- names(shared_paths)[file.exists(file.path(destination,names(shared_paths)))]
  for(file in old_shared) if(!file.copy(file.path(destination,file),file.path(backup,file)))
    stop('Could not preserve shared normalized artifact')
  had_target <- dir.exists(target); installed <- FALSE; committed <- FALSE; changed_shared <- character()
  on.exit({
    if(!committed) {
      if(installed) unlink(target,recursive=TRUE)
      if(dir.exists(file.path(backup,'revision'))) file.rename(file.path(backup,'revision'),target)
      for(file in changed_shared) {
        if(file %in% old_shared) file.copy(file.path(backup,file),file.path(destination,file),overwrite=TRUE)
        else unlink(file.path(destination,file))
      }
    }
    unlink(backup,recursive=TRUE)
  },add=TRUE)
  if(had_target && !file.rename(target,file.path(backup,'revision'))) stop('Could not preserve previous normalized revision')
  if(!file.rename(staging,target)) stop('Could not install prepared normalized revision')
  installed <- TRUE
  for(file in names(shared_paths)) {
    changed_shared <- c(changed_shared,file)
    if(!file.copy(shared_paths[[file]],file.path(destination,file),overwrite=TRUE)) stop('Could not install shared normalized artifact')
  }
  committed <- TRUE
  invisible(target)
}


# Shared by the full build and normalized re-emission. Individual point
# calculations remain available for fixtures and deliberately date-scoped audits.
calculate_revision_legal_states <- function(products,ch99_data,hts_raw,usmca,countries,
    revision_id,revision_dates,country_lookup,policy_params,stacking_method='mutual_exclusion',ch99_other=NULL,
    normalized_root=here::here('output','normalized'),emit_normalized=NULL) {
  first <- revision_dates$effective_date[match(revision_id,revision_dates$revision)]
  fentanyl <- extract_ieepa_fentanyl_rates(hts_raw,country_lookup,first,revision_id)
  source_events <- list(country_amendments=load_ieepa_country_amendments(),
    emergency=attr(fentanyl,'emergency_source'),stacking=load_stacking_rules())
  if(!is.null(policy_params$SECTION_338)) {
    if(!exists('load_s338_source',mode='function')) source(here::here('src/section338_revision.R'))
    source_events$section338 <- load_s338_source()
  }
  # Section 301 source windows include exclusions, grant/extension chronology,
  # maritime suspension and amendments to historical classification references.
  if(grepl('^202[56]_',revision_id)) {
    if(!exists('load_s301_revision_source',mode='function')) source(here::here('src/section301_revision.R'))
    source_events$section301 <- load_s301_revision_source(revision_id,download=FALSE)
    if(!exists('load_reciprocal_scope',mode='function')) source(here::here('src/ieepa_reciprocal_revision.R'))
    source_events$reciprocal_scope <- load_reciprocal_scope(revision_id)$history
    if(!exists('load_s232_legacy_source',mode='function')) source(here::here('src/section232_legacy.R'))
    source_events$section232_legacy <- load_s232_legacy_source(revision_id)
  }
  segments <- revision_legal_segments(revision_id,revision_dates,policy_params,source_events)
  emit <- emit_normalized %||% !identical(Sys.getenv('SAIL_EMIT_NORMALIZED','1'),'0')
  old_emit <- Sys.getenv('SAIL_EMIT_NORMALIZED',unset=NA_character_)
  on.exit(if(is.na(old_emit)) Sys.unsetenv('SAIL_EMIT_NORMALIZED') else Sys.setenv(SAIL_EMIT_NORMALIZED=old_emit),add=TRUE)
  Sys.setenv(SAIL_EMIT_NORMALIZED=if(emit) '1' else '0')
  stage <- tempfile(paste0('normalized-',revision_id,'-'))
  on.exit(unlink(stage,recursive=TRUE),add=TRUE)
  states <- vector('list',nrow(segments));roots <- character(nrow(segments))
  for(i in seq_len(nrow(segments))) {
    day <- segments$valid_from[i];roots[i] <- file.path(stage,as.character(day))
    states[[i]] <- calculate_rates_for_revision(products,ch99_data,
      extract_ieepa_rates(hts_raw,country_lookup,effective_date=day),usmca,countries,revision_id,day,
      s232_rates=extract_section232_rates(ch99_data,effective_date=day),
      fentanyl_rates=extract_ieepa_fentanyl_rates(hts_raw,country_lookup,effective_date=day,revision_id=revision_id),
      stacking_method=stacking_method,policy_params=policy_params,ch99_other=ch99_other,
      s301_exclusions=build_s301_exclusion_candidates(ch99_data,day),
      normalized_output_dir=roots[i],normalized_valid_until=segments$valid_until[i])
    states[[i]]$valid_from <- day;states[[i]]$valid_until <- segments$valid_until[i]
  }
  rates <- validate_snapshot_intervals(dplyr::bind_rows(states),min(segments$valid_from),max(segments$valid_until))
  if(emit) {
    dir.create(normalized_root,recursive=TRUE,showWarnings=FALSE)
    merge_normalized_segments(roots,revision_id,normalized_root,segments)
  }
  rates
}

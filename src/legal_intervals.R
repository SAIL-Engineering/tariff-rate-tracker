# An HTS release is a source snapshot, not a promise of constant liability
# until the next release. Daily aggregate intervals split at legal events;
# executable shipment rules retain the exact instants independently.

legal_event_days <- function(value) {
  dates <- character()
  visit <- function(x) {
    if(!is.list(x)) return()
    for(name in names(x)) {
      child <- x[[name]]
      # Shared rule-window fields, including nested transit/claim deadlines.
      # Publication/retrieval dates are evidence metadata, not legal events.
      legal_window <- name %in% c('inception','from','from_','until','effective_at','effective_date',
                    'collection_ended_at','policy_effective_date','activation_date','patented_pharma_exempt_date') ||
        grepl('(_from|_until)$',name)
      if(legal_window) {
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

# Use the same original-action extractor as executable compilation. Product
# exemption history alone cannot reveal country continuations, partner claims,
# sector interactions or transit deadlines between HTS source snapshots.
load_reciprocal_legal_events <- function(root=here::here()) {
  path <- tempfile(fileext='.json');on.exit(unlink(path),add=TRUE)
  status <- system2('python3',c(shQuote(file.path(root,'src/ieepa_reciprocal_initial.py')),shQuote(path)))
  if(status!=0L)stop('Reciprocal legal-event extraction failed; cannot tile revision history')
  history <- jsonlite::fromJSON(path,simplifyVector=FALSE)
  if(is.null(history$inception)||is.null(history$collection_ended_at)||!length(history$sources))
    stop('Incomplete reciprocal legal-event inventory')
  if(!all(vapply(history$sources,function(s)file.exists(s$path) &&
      identical(s$sha256,digest::digest(file=s$path,algo='sha256')),logical(1))))
    stop('Reciprocal legal-event source/hash mismatch')
  history
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
  # Check the grid one legal window at a time. The previous form keyed every
  # row at once and then split() copied the result, so a four-state revision
  # paid several times the grid in character vectors on top of the states
  # themselves. Same two predicates: (hts10,country) is unique within a
  # window, and valid_from differs between windows, so a duplicate triple can
  # only ever be a duplicate pair inside one window.
  reference <- NULL
  for(w in seq_len(nrow(windows))) {
    rows <- which(snapshot$valid_from==windows$valid_from[w])
    keys <- paste(snapshot$hts10[rows],snapshot$country[rows],sep='|')
    if(anyDuplicated(keys)) stop('Duplicate shipment pair in legal interval')
    if(is.null(reference)) reference <- keys
    else if(!setequal(keys,reference)) stop('Incomplete product-country grid across legal intervals')
  }
  reference <- NULL
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
      immutable <- TRUE
      if(file=='shipment_rules.json') {
        immutable <- FALSE
        source(here::here('src/shipment_build.R'))
        if(length(present)!=length(roots))stop('Missing executable shipment state index; previous revision preserved')
        result <- merge_shipment_bundle_indexes(values,roots[present])
      } else if(file=='ieepa_evidence_sources.json') {
        immutable <- all(vapply(values,function(x)identical(x,result),logical(1)))
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
      if(immutable) {
        paths <- file.path(roots[present],file)
        hashes <- vapply(paths,function(p)digest::digest(file=p,algo='sha256'),character(1))
        if(length(unique(hashes))!=1L)stop('Conflicting immutable JSON bytes across legal states: ',file)
        # Bundle indexes and source manifests pin actual bytes. Reformatting
        # otherwise equivalent JSON invalidates those pins and can round legal
        # numeric literals. Immutable artifacts cross this stage unchanged.
        if(!file.copy(paths[1],file.path(staging,file)))stop('Could not preserve immutable JSON artifact: ',file)
      } else jsonlite::write_json(result,file.path(staging,file),auto_unbox=TRUE,pretty=TRUE,null='null',digits=17)
    } else stop('Unrecognized normalized artifact: ',file)
  }
  index_path <- file.path(staging,'shipment_rules.json')
  if(file.exists(index_path)) {
    source(here::here('src/shipment_build.R'))
    index <- jsonlite::fromJSON(index_path,simplifyVector=FALSE)
    if(!identical(index$contract_version,'sail.shipment-bundle-index/v1'))stop('Unsupported merged shipment index')
    # Validate the staged files, not just the pre-merge input directories,
    # before replacing an installed revision or any shared normalized tables.
    for(entry in index$bundles).shipment_verified_bundle(index,entry,staging)
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


# Assemble a revision's legal states without ever holding them all at once.
# `bind_rows(states)` allocated the combined frame while every state was still
# resident, so the peak was twice the revision's whole panel: one state is
# 4,901,280 rows x 95 columns = 3.42 GB, and 2026_rev_22's four states reached
# a 51.5 GB peak on a 62 GB machine. Here each state is spilled as it is
# computed and read back once into preallocated columns, so the peak is the
# combined frame plus one state (~17 GB for four) rather than twice the set.
# The result must be identical to what bind_rows produced: this is the duty
# panel, so a coerced type or a reordered row is a changed legal answer.
.legal_state_rss <- function() {
  x <- tryCatch(readLines('/proc/self/status'),error=function(e) character(0))
  v <- function(k) {
    h <- grep(k,x,value=TRUE)
    if(!length(h)) return(NA_real_)
    # Strip every non-digit rather than matching a space before the number.
    # The kernel pads the value into a fixed width, so once RSS passes 8
    # digits (about 9.5 GB) the separator is a bare tab and a pattern
    # expecting ' (\\d+) kB' stops matching -- returning the whole line and
    # an NA. It failed silently at exactly the sizes worth reporting.
    as.numeric(gsub('[^0-9]','',h[1]))/2^20
  }
  c(rss=v('^VmRSS'),peak=v('^VmHWM'))
}

# Compared at spill time AND at read time. bind_rows would coerce a column
# whose type disagrees between two legal states -- a logical that is character
# in one state becomes character for the whole revision -- which on a duty
# panel is a silently changed answer, so this refuses instead. Checking at
# spill time matters for the schedule: a four-state revision takes ~10 min per
# state, so catching it on the state that introduces it costs 20 minutes
# instead of the 46 it takes to compute all four and begin assembling.
check_legal_state_schema <- function(state,template,i) {
  cols <- names(template)
  if(!identical(names(state),cols))
    stop('Legal state ',i,' does not carry the same column set: ',
         paste(c(setdiff(names(state),cols),setdiff(cols,names(state))),collapse=', '),
         call.=FALSE)
  for(col in cols) {
    if(!identical(class(state[[col]]),class(template[[col]])))
      stop('Legal state ',i,' disagrees on the type of ',col,': ',
           paste(class(state[[col]]),collapse='/'),' vs ',
           paste(class(template[[col]]),collapse='/'),call.=FALSE)
    if(is.factor(template[[col]]) && !identical(levels(state[[col]]),levels(template[[col]])))
      stop('Legal state ',i,' disagrees on the levels of ',col,call.=FALSE)
  }
  invisible(TRUE)
}

assemble_legal_states <- function(paths,counts,template) {
  if(length(paths)!=length(counts)) stop('Legal state spill is not accounted for')
  total <- sum(counts);cols <- names(template)
  # Indexing a zero-row column with NA yields a typed, attribute-preserving
  # vector: Date stays Date, a factor keeps its levels, integer stays integer.
  nas <- rep(NA_integer_,total)
  out <- lapply(template,function(x) x[nas])
  nas <- NULL
  at <- 1L
  for(i in seq_along(paths)) {
    state <- readRDS(paths[i])
    check_legal_state_schema(state,template,i)
    if(nrow(state)!=counts[i]) stop('Legal state ',i,' changed length while spilled')
    idx <- seq.int(at,length.out=counts[i])
    for(col in cols) {
      # Drop the list's reference before widening the column, so the
      # subassignment is in place. `out[[col]][idx] <- v` leaves the vector
      # referenced twice and copies the whole column instead.
      v <- out[[col]];out[[col]] <- logical(0)
      v[idx] <- state[[col]]
      out[[col]] <- v;v <- NULL
    }
    at <- at+counts[i]
    state <- NULL;unlink(paths[i]);gc(FALSE)
  }
  if(at-1L!=total) stop('Assembled legal states do not fill the revision')
  attrs <- attributes(template);attrs$row.names <- .set_row_names(total)
  attributes(out) <- attrs
  m <- .legal_state_rss()
  message('  Assembled ',length(paths),' legal states into ',
          format(total,big.mark=','),' rows; RSS ',round(m[['rss']],2),
          ' GB, peak ',round(m[['peak']],2),' GB')
  out
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
    source_events$reciprocal_policy <- load_reciprocal_legal_events()
    if(!exists('load_s301_labor_history',mode='function')) source(here::here('src/section301_labor.R'))
    source_events$forced_labor_policy <- load_s301_labor_history()
    if(!exists('load_s232_legacy_source',mode='function')) source(here::here('src/section232_legacy.R'))
    source_events$section232_legacy <- load_s232_legacy_source(revision_id)
  }
  segments <- revision_legal_segments(revision_id,revision_dates,policy_params,source_events)
  # The §338 action columns this revision must carry in EVERY state -- see the
  # zero-fill in calculate_rates_for_revision() for why a per-state answer is
  # not enough. The action set comes from the original annex: amendments only
  # insert and delete products within an existing program (a new program would
  # leave load_s338_actions()'s heading lookup empty and stop()), so they cannot
  # change it. Requested only when some state really does reach the in-force
  # branch, mirroring both of that branch's conditions so this can never add a
  # column the in-force state will not also have.
  s338_actions <- character(0)
  if(!is.null(policy_params$SECTION_338) && !is.null(source_events$section338) &&
     any(as.Date(segments$valid_from) >= as.Date(policy_params$SECTION_338$effective_date)) &&
     as.character(policy_params$SECTION_338$country %||% '1220') %in% countries)
    s338_actions <- sort(unique(vapply(source_events$section338$actions,`[[`,character(1),'program')))
  emit <- emit_normalized %||% !identical(Sys.getenv('SAIL_EMIT_NORMALIZED','1'),'0')
  old_emit <- Sys.getenv('SAIL_EMIT_NORMALIZED',unset=NA_character_)
  on.exit(if(is.na(old_emit)) Sys.unsetenv('SAIL_EMIT_NORMALIZED') else Sys.setenv(SAIL_EMIT_NORMALIZED=old_emit),add=TRUE)
  Sys.setenv(SAIL_EMIT_NORMALIZED=if(emit) '1' else '0')
  stage <- tempfile(paste0('normalized-',revision_id,'-'))
  on.exit(unlink(stage,recursive=TRUE),add=TRUE)
  n <- nrow(segments)
  roots <- character(n);counts <- integer(n);paths <- rep(NA_character_,n)
  # A single legal state needs no concatenation and no spill; 41 of the 56
  # rebuild revisions have exactly one. Beyond one, no state is kept in memory
  # after it is computed -- see assemble_legal_states for why.
  spill <- file.path(stage,'_states')
  if(n>1L) dir.create(spill,recursive=TRUE,showWarnings=FALSE)
  combined <- NULL;template <- NULL
  for(i in seq_len(n)) {
    day <- segments$valid_from[i];roots[i] <- file.path(stage,as.character(day))
    state <- calculate_rates_for_revision(products,ch99_data,
      extract_ieepa_rates(hts_raw,country_lookup,effective_date=day),usmca,countries,revision_id,day,
      s232_rates=extract_section232_rates(ch99_data,effective_date=day),
      fentanyl_rates=extract_ieepa_fentanyl_rates(hts_raw,country_lookup,effective_date=day,revision_id=revision_id),
      stacking_method=stacking_method,policy_params=policy_params,ch99_other=ch99_other,
      s301_exclusions=build_s301_exclusion_candidates(ch99_data,day),s338_actions=s338_actions,
      normalized_output_dir=roots[i],normalized_valid_until=segments$valid_until[i])
    state$valid_from <- day;state$valid_until <- segments$valid_until[i]
    counts[i] <- nrow(state)
    if(n==1L) {combined <- state;next}
    if(is.null(template)) template <- state[0,,drop=FALSE] else
      check_legal_state_schema(state,template,i)
    paths[i] <- file.path(spill,sprintf('state-%03d.rds',i))
    # Uncompressed: this is scratch read back once, and compressing 3.42 GB
    # costs more wall clock than the write it saves.
    saveRDS(state,paths[i],compress=FALSE)
    state <- NULL;gc(FALSE)
    m <- .legal_state_rss()
    message('  Legal state ',i,' of ',n,' (',format(counts[i],big.mark=','),
            ' rows) spilled to ',round(file.size(paths[i])/2^30,2),' GB on disk; RSS ',
            round(m[['rss']],2),' GB, peak ',round(m[['peak']],2),' GB')
  }
  if(n>1L) combined <- assemble_legal_states(paths,counts,template)
  template <- NULL
  rates <- validate_snapshot_intervals(combined,min(segments$valid_from),max(segments$valid_until))
  combined <- NULL
  if(emit) {
    dir.create(normalized_root,recursive=TRUE,showWarnings=FALSE)
    merge_normalized_segments(roots,revision_id,normalized_root,segments)
  }
  rates
}

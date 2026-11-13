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
# computed (see spill_legal_state) and either read back column by column into
# preallocated columns, or streamed straight into the snapshot file without the
# panel ever being held (write_legal_states_rds, used by the build).
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

# A spilled legal state is a directory holding one file per column plus a
# manifest of its column names and row count. The column is the unit both
# assemblers read back, so the in-memory assembler holds the panel plus one
# column (not plus one whole state), and the streaming writer below never holds
# the panel at all.
#
# Why that matters: the panel grew from 95 to 171-185 columns between
# 2026-11-06 and 2026-11-13 (shipment, aggregate_* and modeled_legacy_*
# columns), so one 4.85M-row state is 6.0 GB in memory. Assembling 2025_rev_4's
# three states took ~10 GB of process + 18 GB of panel + 6 GB for the state
# being read, and was killed by the kernel's global OOM on 2026-11-13 with the
# desktop holding ~30 GB. A four-state revision would have needed ~45 GB.
#
# gzip level 1: the states are mostly repeated JSON text, so the uncompressed
# spill was 8.9 GB per state -- 36 GB of scratch disk for a four-state revision
# on a drive that had 14 GB free -- and level 1 costs seconds per state.
spill_legal_state <- function(state,dir) {
  dir.create(dir,recursive=TRUE,showWarnings=FALSE)
  cols <- names(state)
  for(j in seq_along(cols)) {
    con <- gzfile(file.path(dir,sprintf('col-%04d.rds',j)),'wb',compression=1L)
    tryCatch(saveRDS(state[[j]],con),finally=close(con))
  }
  saveRDS(list(columns=cols,rows=nrow(state)),file.path(dir,'manifest.rds'))
  invisible(dir)
}

.spill_bytes <- function(dir) sum(file.size(list.files(dir,full.names=TRUE)))

# Read-time half of check_legal_state_schema(): the column set from the
# manifest, then each column's type, factor levels and length as it is read.
check_spilled_state <- function(dir,template,i,count) {
  m <- readRDS(file.path(dir,'manifest.rds'));cols <- names(template)
  if(!identical(m$columns,cols))
    stop('Legal state ',i,' does not carry the same column set: ',
         paste(c(setdiff(m$columns,cols),setdiff(cols,m$columns)),collapse=', '),
         call.=FALSE)
  if(!identical(as.integer(m$rows),as.integer(count)))
    stop('Legal state ',i,' changed length while spilled')
  invisible(TRUE)
}

read_spilled_column <- function(dir,j,template,i,count) {
  col <- names(template)[j];t <- template[[col]]
  v <- readRDS(file.path(dir,sprintf('col-%04d.rds',j)))
  if(!identical(class(v),class(t)))
    stop('Legal state ',i,' disagrees on the type of ',col,': ',
         paste(class(v),collapse='/'),' vs ',paste(class(t),collapse='/'),call.=FALSE)
  if(is.factor(t) && !identical(levels(v),levels(t)))
    stop('Legal state ',i,' disagrees on the levels of ',col,call.=FALSE)
  if(length(v)!=count) stop('Legal state ',i,' changed length while spilled')
  v
}

assemble_legal_states <- function(paths,counts,template,columns=names(template)) {
  if(length(paths)!=length(counts)) stop('Legal state spill is not accounted for')
  for(i in seq_along(paths)) check_spilled_state(paths[i],template,i,counts[i])
  total <- sum(counts);starts <- c(0L,cumsum(counts))
  # Indexing a zero-row column with NA yields a typed, attribute-preserving
  # vector: Date stays Date, a factor keeps its levels, integer stays integer.
  nas <- rep(NA_integer_,total)
  out <- vector('list',length(columns))
  for(k in seq_along(columns)) {
    j <- match(columns[k],names(template))
    v <- template[[j]][nas]
    for(i in seq_along(paths)) if(counts[i]>0L)
      v[seq.int(starts[i]+1L,length.out=counts[i])] <- read_spilled_column(paths[i],j,template,i,counts[i])
    out[[k]] <- v;v <- NULL
  }
  nas <- NULL
  attrs <- attributes(template[columns]);attrs$row.names <- .set_row_names(total)
  attributes(out) <- attrs
  m <- .legal_state_rss()
  message('  Assembled ',length(paths),' legal states into ',
          format(total,big.mark=','),' rows x ',length(columns),' columns; RSS ',
          round(m[['rss']],2),' GB, peak ',round(m[['peak']],2),' GB')
  out
}

# ---- Streaming the snapshot RDS without materialising the panel ----
#
# saveRDS() of a data frame writes, after the stream header: the list's flags
# and length, each column as flags | length | elements | attributes, then the
# frame's own attributes (R Internals, "Serialization Formats"). Every piece of
# that can be produced from one column at a time, so the snapshot is written
# column by column, each column state by state. readRDS() of the result is
# identical() to readRDS() of saveRDS() of the assembled frame; the test pins
# that, and byte equality of the uncompressed stream where no symbol repeats.
#
# The pieces are cut from serialize() of small objects, never hand-encoded:
#   * the header from serialize(NULL), which is header | NILVALUE_SXP;
#   * the frame's flags and attributes from a list of k NULLs carrying the
#     frame's attributes (each NULL is the 4-byte NILVALUE_SXP);
#   * each column's flags and attributes from a fresh zero-length vector
#     carrying that column's attributes;
#   * each column's elements from serialize() of a plain slice of it.
# A slice is copied into a freshly allocated vector first. Slicing an ALTREP
# vector (a deferred string from as.character(), say) can return another ALTREP
# that serializes as ALTREP_SXP instead of its elements; the copy cannot, and
# every slice's type code is still checked before its bytes are written.
#
# No piece carries a back-reference: a column's attributes are atomic with
# unique tags, so serialize() writes no REFSXP inside any piece and the pieces
# can be concatenated. Symbols that saveRDS() would write once and then refer
# back to are simply written in full each time, which unserialize() accepts.
.RDS_TYPE_CODE <- c(logical=10L,integer=13L,double=14L,character=16L)
.rds_int <- function(v) writeBin(as.integer(v),raw(),size=4L,endian='big')

.rds_header <- function() {
  h <- serialize(NULL,NULL);n <- length(h)
  if(!identical(h[(n-3L):n],.rds_int(254L))) stop('Unexpected serialization header layout')
  h[seq_len(n-4L)]
}

# Every column a plain logical/integer/double/character vector whose only
# attributes are class/levels/tzone/units with atomic, attribute-free values
# (so Date, POSIXct and factor qualify; a list column or a named vector does
# not). Anything else is assembled in memory and saved with saveRDS() instead.
legal_states_streamable <- function(template) {
  ok_attr <- c('class','levels','tzone','units')
  all(vapply(template,function(x) {
    a <- attributes(x)
    typeof(x) %in% names(.RDS_TYPE_CODE) && all(names(a) %in% ok_attr) &&
      all(vapply(a,function(v) is.atomic(v) && is.null(attributes(v)),logical(1)))
  },logical(1)))
}

write_legal_states_rds <- function(paths,counts,template,file,chunk_rows=131072L) {
  if(length(paths)!=length(counts)) stop('Legal state spill is not accounted for')
  if(!legal_states_streamable(template)) stop('Legal state columns cannot be streamed to RDS')
  for(i in seq_along(paths)) check_spilled_state(paths[i],template,i,counts[i])
  total <- sum(counts);k <- length(template)
  if(total>.Machine$integer.max) stop('Revision exceeds the short-vector row limit')
  hdr <- .rds_header();h <- length(hdr)
  attrs <- attributes(template);attrs$row.names <- .set_row_names(total)
  sk <- vector('list',k);attributes(sk) <- attrs
  sb <- serialize(sk,NULL);sk <- NULL
  if(!identical(sb[seq_len(h)],hdr) || !identical(sb[(h+5L):(h+8L)],.rds_int(k)) ||
     !identical(sb[seq.int(h+9L,length.out=4L*k)],rep(.rds_int(254L),k)))
    stop('Unexpected data frame serialization layout')
  frame_attr <- sb[seq.int(h+9L+4L*k,length(sb))]
  unlink(Sys.glob(paste0(file,'.partial-*')))
  tmp <- paste0(file,'.partial-',Sys.getpid())
  con <- gzfile(tmp,'wb');done <- FALSE
  on.exit({if(!is.null(con)) close(con);if(!done) unlink(tmp)},add=TRUE)
  writeBin(c(hdr,sb[(h+1L):(h+8L)]),con);sb <- NULL
  for(j in seq_len(k)) {
    t <- template[[j]];code <- .rds_int(.RDS_TYPE_CODE[[typeof(t)]])
    z <- vector(typeof(t),0L);attributes(z) <- attributes(t)
    zb <- serialize(z,NULL);z <- NULL
    writeBin(c(zb[(h+1L):(h+4L)],.rds_int(total)),con)
    for(i in seq_along(paths)) {
      if(counts[i]==0L) next
      x <- read_spilled_column(paths[i],j,template,i,counts[i])
      for(a in seq.int(1L,counts[i],by=chunk_rows)) {
        b <- min(a+chunk_rows-1L,counts[i])
        y <- vector(typeof(t),b-a+1L);y[] <- .subset(x,a:b)
        s <- serialize(y,NULL);y <- NULL
        if(!identical(s[seq_len(h)],hdr) || !identical(s[(h+1L):(h+4L)],code) ||
           !identical(s[(h+5L):(h+8L)],.rds_int(b-a+1L)))
          stop('Column ',names(template)[j],' did not serialize as a plain vector')
        writeBin(s[(h+9L):length(s)],con);s <- NULL
      }
      x <- NULL
    }
    if(length(zb)>h+8L) writeBin(zb[(h+9L):length(zb)],con)
    zb <- NULL
  }
  writeBin(frame_attr,con);close(con);con <- NULL
  if(!file.rename(tmp,file)) stop('Could not move the streamed snapshot into place: ',file)
  done <- TRUE
  m <- .legal_state_rss()
  message('  Streamed ',length(paths),' legal states (',format(total,big.mark=','),
          ' rows x ',k,' columns) into ',basename(file),'; RSS ',round(m[['rss']],2),
          ' GB, peak ',round(m[['peak']],2),' GB')
  invisible(file)
}

# Shared by the full build and normalized re-emission. Individual point
# calculations remain available for fixtures and deliberately date-scoped audits.
calculate_revision_legal_states <- function(products,ch99_data,hts_raw,usmca,countries,
    revision_id,revision_dates,country_lookup,policy_params,stacking_method='mutual_exclusion',ch99_other=NULL,
    normalized_root=here::here('output','normalized'),emit_normalized=NULL,snapshot_file=NULL) {
  # snapshot_file: when given and the revision has more than one legal state,
  # the snapshot is streamed to this path from the spilled states and the
  # return value is a NARROW frame (hts10, country, valid_from, valid_until,
  # rate_ieepa_recip) carrying attr 'snapshot_file'. The full panel is never
  # held, so the peak is one state's calculation regardless of how many states
  # the revision has. With one state, the full frame is returned unchanged and
  # writing the snapshot stays with the caller.
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
    paths[i] <- file.path(spill,sprintf('state-%03d',i))
    spill_legal_state(state,paths[i])
    state <- NULL;gc(FALSE)
    m <- .legal_state_rss()
    message('  Legal state ',i,' of ',n,' (',format(counts[i],big.mark=','),
            ' rows) spilled to ',round(.spill_bytes(paths[i])/2^30,2),' GB on disk; RSS ',
            round(m[['rss']],2),' GB, peak ',round(m[['peak']],2),' GB')
  }
  streamed <- n>1L && !is.null(snapshot_file) && legal_states_streamable(template)
  if(n>1L && !is.null(snapshot_file) && !streamed)
    message('  Legal states carry a column that cannot be streamed; assembling in memory')
  if(streamed) {
    # Only the columns the interval check and the build's summary read.
    narrow <- intersect(c('hts10','country','valid_from','valid_until','rate_ieepa_recip'),
                        names(template))
    combined <- assemble_legal_states(paths,counts,template,columns=narrow)
  } else if(n>1L) combined <- assemble_legal_states(paths,counts,template)
  rates <- validate_snapshot_intervals(combined,min(segments$valid_from),max(segments$valid_until))
  combined <- NULL
  if(emit) {
    dir.create(normalized_root,recursive=TRUE,showWarnings=FALSE)
    merge_normalized_segments(roots,revision_id,normalized_root,segments)
  }
  # Last, as the caller's saveRDS was: a revision that fails validation or the
  # normalized merge leaves its previous snapshot in place.
  if(streamed) {
    write_legal_states_rds(paths,counts,template,snapshot_file)
    attr(rates,'snapshot_file') <- snapshot_file
  }
  template <- NULL
  rates
}

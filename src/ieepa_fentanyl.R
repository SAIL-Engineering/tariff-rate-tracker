# Revision-bound emergency evidence. General selection has no max-rate or
# first-row arbitration. Conditional replacements remain separate candidates.
load_ieepa_emergency_source <- function(revision_id,root=here::here()) {
  pdf <- file.path(root,'data/us_notes',paste0('chapter99_',revision_id,'.pdf'))
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision_id,'.json'))
  script <- file.path(root,'src/ieepa_fentanyl_sources.py')
  dependency <- file.path(root,'src/section301_sources.py')
  hash <- function(p) digest::digest(file=p,algo='sha256')
  if(!file.exists(pdf)||!file.exists(hts)) stop('Missing revision-bound IEEPA emergency evidence')
  valid <- function(x) identical(x$contract_version,'sail.ieepa-emergency-extraction/v1') &&
    identical(x$revision,revision_id) && identical(x$extractor_sha256,hash(script)) &&
    identical(x$parser_dependency_sha256,hash(dependency)) &&
    identical(x$sources[[1]]$sha256,hash(pdf)) && identical(x$sources[[2]]$sha256,hash(hts)) &&
    all(vapply(x$additional_sources,function(s) file.exists(s$path)&&identical(s$sha256,hash(s$path)),logical(1)))
  cache <- file.path(root,'data/processed/ieepa_emergency_sources',paste0(revision_id,'.json'))
  x <- if(file.exists(cache)) tryCatch(jsonlite::fromJSON(cache,simplifyVector=FALSE),error=function(e) NULL) else NULL
  if(is.null(x)||!valid(x)) {
    out <- tempfile(fileext='.json');on.exit(unlink(out),add=TRUE)
    status <- system2('python3',c(shQuote(script),'--pdf',shQuote(pdf),'--hts',shQuote(hts),
      '--revision',shQuote(revision_id),'--output',shQuote(out)))
    if(status!=0L) stop('Emergency note extraction failed; refusing inferred-origin/rate fallback')
    x <- jsonlite::fromJSON(out,simplifyVector=FALSE)
    if(!valid(x)) stop('Emergency evidence hash mismatch')
    dir.create(dirname(cache),recursive=TRUE,showWarnings=FALSE)
    if(!file.copy(out,cache,overwrite=TRUE)) stop('Could not retain emergency extraction')
  }
  x
}

emergency_source_rows <- function(x,country_lookup) {
  empty <- tibble::tibble(ch99_code=character(),rate=double(),country_name=character(),
    census_code=character(),entry_type=character(),valid_from=character(),valid_until=character(),
    collection_ended_at=character(),termination_source_ids=character(),
    source_description=character(),duty_expression=character(),source_heading_sha256=character(),
    source_note_sha256=character(),note_locator=character(),amendment_source_id=character(),
    amendment_source_sha256=character(),amendment_effective_from=character())
  rows <- lapply(x$actions,function(a) {
    origins <- match_countries(unlist(a$country_names),country_lookup)
    if(anyNA(origins$census_code)) stop('Unresolved source origin')
    tibble::tibble(ch99_code=a$ch99_code,rate=a$rate,country_name=origins$country_name,
      census_code=origins$census_code,entry_type=a$entry_type,
      valid_from=a$valid_from %||% NA_character_,valid_until=a$valid_until %||% NA_character_,
      collection_ended_at=a$collection_ended_at %||% NA_character_,
      termination_source_ids=paste(unlist(a$termination_source_ids),collapse=';'),
      source_description=a$source_description,duty_expression=a$duty_expression,
      source_heading_sha256=a$source_heading_sha256,source_note_sha256=a$source_note_sha256,
      note_locator=a$note_locator,amendment_source_id=a$amendment_source_id %||% NA_character_,
      amendment_source_sha256=a$amendment_source_sha256 %||% NA_character_,
      amendment_effective_from=a$amendment_effective_from %||% NA_character_)
  })
  dplyr::bind_rows(c(list(empty),rows))
}

select_ieepa_emergency_actions <- function(rows,entry_at,daily=FALSE) {
  if(is.null(entry_at)) stop('Entry time required for emergency action selection')
  if(daily) {
    # Daily aggregates use the legal entry day; exact 00:01 boundaries are
    # preserved separately for the timestamp-based shipment interpreter.
    at <- as.Date(entry_at)
    from <- as.Date(substr(rows$valid_from,1,10));until <- as.Date(substr(rows$valid_until,1,10))
  } else {
    if(!exists('.shipment_time',mode='function')) source(here::here('src/resolve_shipment_duties.R'))
    parse <- function(x) vapply(x,.shipment_time,numeric(1))
    at <- parse(as.character(entry_at));from <- parse(rows$valid_from);until <- parse(rows$valid_until)
    if(length(at)!=1L||is.na(at)) stop('Explicit offset entry timestamp required')
  }
  active <- (is.na(from)|at>=from)&(is.na(until)|at<until)
  if(anyNA(rows$valid_from)||anyNA(rows$valid_until)) stop('Missing emergency source entry window')
  if(any(!is.na(rows$valid_from)&is.na(from))||any(!is.na(rows$valid_until)&is.na(until))) stop('Invalid emergency source window')
  result <- unique(rows[active & rows$entry_type!='exemption',])
  # Retained headings cease at the independently sourced CBP collection
  # boundary. An empty match alone is not evidence of zero duty.
  if(nrow(rows)&&'collection_ended_at'%in%names(rows)&&
     !anyNA(rows$collection_ended_at)&&length(unique(rows$collection_ended_at))==1L&&
     all(nzchar(rows$termination_source_ids))) {
    end<-if(daily) as.Date(substr(rows$collection_ended_at[[1]],1,10)) else parse(rows$collection_ended_at[[1]])
    if(is.na(end)) stop('Invalid emergency collection boundary')
    if(at>=end) {
      if(nrow(result)) stop('Emergency action survives collection termination')
      return(result)
    }
  }
  general <- result[result$entry_type=='general',]
  if(any(duplicated(general$census_code))) stop('Overlapping ordinary emergency actions; source reconciliation required')
  # An expired retained heading cannot silently supply a different origin's
  # missing action; the gap must be reconciled from another source version.
  expected <- unique(rows$census_code[rows$entry_type=='general'])
  if(!all(expected %in% general$census_code)) stop('No active ordinary emergency action for a published origin')
  result
}

ordinary_emergency_parameters <- function(rows) {
  selected <- unique(as.data.frame(rows[rows$entry_type=='general',c('census_code','rate','ch99_code')]))
  if(any(duplicated(selected$census_code))) stop('Ambiguous ordinary emergency parameters')
  names(selected)[names(selected)=='rate'] <- 'fent_rate'
  names(selected)[names(selected)=='ch99_code'] <- 'fent_ch99'
  tibble::as_tibble(selected)
}

emergency_action_decisions <- function(extracted,active,revision,entry_day=NULL) {
  x <- attr(extracted,'emergency_source');rows <- attr(extracted,'emergency_candidates')
  if(is.null(x)||is.null(rows)) return(NULL)
  key <- function(r) paste(r$census_code,r$ch99_code,r$rate,r$valid_from,r$valid_until)
  selected <- if(is.null(active)) character() else key(active)
  ended <- !is.null(entry_day) && has_ieepa_collection_ended(entry_day)
  notes <- setNames(lapply(x$actions,`[[`,'source_note'),vapply(x$actions,`[[`,character(1),'ch99_code'))
  dplyr::transmute(rows,revision=revision,authority='ieepa_fentanyl',country=census_code,
    ch99_code,rate,rate_type=if_else(entry_type=='exemption','passthrough','surcharge'),
    phase=entry_type,terminated=ended,
    decision=if(ended) 'retired_heading' else if_else(key(rows) %in% selected & entry_type=='general',
      'ordinary_action_selected','published_candidate'),
    source_description,duty_expression,source_heading_sha256,hts_sha256=x$sources[[2]]$sha256,
    pdf_sha256=x$sources[[1]]$sha256,
    amendment_source_id,amendment_source_sha256,amendment_effective_from,
    source_note_locator=note_locator,source_note_sha256,
    source_note=vapply(ch99_code,function(code) notes[[code]],character(1)),
    entry_valid_from=valid_from,entry_valid_until=valid_until)
}

attach_emergency_evidence <- function(fragment,extracted) {
  x <- attr(extracted,'emergency_source')
  if(is.null(x)) return(fragment)
  for(i in seq_along(x$sources)) {
    id <- paste0('USITC-',x$revision,'-ieepa-emergency-',if(i==1) 'note2' else 'headings')
    s <- x$sources[[i]]
    fragment$sources[[length(fragment$sources)+1L]] <- list(id=id,status='verified',sha256=s$sha256,
      url=if(i==1) paste0('https://hts.usitc.gov/reststop/file?release=',build_release_name(x$revision),'&filename=Chapter%2099') else
        paste0('https://hts.usitc.gov/reststop/exportList?release=',build_release_name(x$revision),'&exportFormat=JSON'),
      citation=paste0('USITC ',x$revision,' U.S. note 2(a)-(u) and emergency headings; conditional candidates, not full coverage'))
    fragment$source_artifacts[[length(fragment$source_artifacts)+1L]] <- list(source_id=id,path=s$path,sha256=s$sha256)
  }
  for(s in x$additional_sources) {
    fragment$sources[[length(fragment$sources)+1L]] <- list(id=s$id,status='verified',sha256=s$sha256,url=s$url,citation=s$citation)
    fragment$source_artifacts[[length(fragment$source_artifacts)+1L]] <- list(source_id=s$id,path=s$path,sha256=s$sha256)
  }
  fragment
}

# Executable source-derived emergency decisions. This produces a local fragment;
# release preparation still requires all-action coverage and the other programs.
compile_ieepa_emergency_fragment <- function(x,products) {
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(list(x=x,products=as.list(sort(unique(products)))),input,
    auto_unbox=TRUE,null='null',digits=NA)
  status<-system2('python3',c(shQuote(here::here('src/ieepa_emergency_rules.py')),shQuote(input),shQuote(output)))
  if(status!=0L) stop('IEEPA emergency executable-rule compilation failed')
  jsonlite::fromJSON(output,simplifyVector=FALSE)
}

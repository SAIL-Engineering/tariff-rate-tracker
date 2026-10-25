# EO 14257 Annex II is a source-derived product decision, not a model list.
# Original effective instants survive even when an HTS snapshot lags the law.
load_reciprocal_scope <- function(revision_id, root=here::here()) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision_id)) stop('Identified reciprocal source revision required')
  pdf <- file.path(root,'data/us_notes',paste0('chapter99_',revision_id,'.pdf'))
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision_id,'.json'))
  script <- file.path(root,'src/ieepa_reciprocal_sources.py')
  cache <- file.path(root,'data/processed/ieepa_reciprocal_sources',paste0(revision_id,'.json'))
  hash <- function(p) digest::digest(file=p,algo='sha256')
  deps <- c(extractor_sha256='ieepa_reciprocal_sources.py',parser_dependency_sha256='section301_sources.py',
    history_compiler_sha256='ieepa_reciprocal_history.py',emergency_parser_sha256='ieepa_fentanyl_sources.py')
  valid <- function(x) identical(x$contract_version,'sail.ieepa-reciprocal-scope/v1') && identical(x$revision,revision_id) &&
    all(vapply(names(deps),function(k) identical(x[[k]],hash(file.path(root,'src',deps[[k]]))),logical(1))) &&
    identical(x$sources[[1]]$sha256,hash(pdf)) && identical(x$sources[[2]]$sha256,hash(hts)) &&
    length(x$history$sources)>0L && all(vapply(x$history$sources,function(s)
      file.exists(s$path) && identical(s$sha256,hash(s$path)),logical(1)))
  if(!file.exists(pdf)||!file.exists(hts)) stop('Missing reciprocal PDF/HTS source: ',revision_id)
  x <- if(file.exists(cache)) tryCatch(jsonlite::fromJSON(cache,simplifyVector=FALSE),error=function(e) NULL) else NULL
  if(is.null(x)||!valid(x)) {
    out <- tempfile(fileext='.json');on.exit(unlink(out),add=TRUE)
    status <- system2('python3',c(shQuote(script),'--pdf',shQuote(pdf),'--hts',shQuote(hts),
      '--revision',shQuote(revision_id),'--output',shQuote(out)))
    if(status!=0L) stop('Reciprocal scope reconciliation failed; no static exemption-list fallback')
    x <- jsonlite::fromJSON(out,simplifyVector=FALSE)
    if(!valid(x)) stop('Reciprocal scope/source hash mismatch')
    dir.create(dirname(cache),recursive=TRUE,showWarnings=FALSE)
    if(!file.copy(out,cache,overwrite=TRUE)) stop('Could not retain reciprocal scope extraction')
  }
  x
}

reciprocal_scope_decisions <- function(x,products,entry_at=NULL,daily_model=FALSE) {
  if(!exists('.shipment_time',mode='function')) source(here::here('src/resolve_shipment_duties.R'))
  products <- sort(unique(as.character(products)))
  if(any(!grepl('^[0-9]{10}$',products))) stop('Reciprocal scope requires exact HTS10 identifiers')
  # Noon represents the daily model's legal day; never use this adapter for
  # an exact entry. Exact rules retain the initial minute and exclusive end.
  at <- if(is.null(entry_at)) NULL else if(daily_model)
    as.numeric(as.POSIXct(paste(as.Date(entry_at),'12:00:00'),tz='America/New_York')) else .shipment_time(entry_at)
  if(!is.null(at) && is.na(at)) stop('Invalid reciprocal entry instant')
  rows <- lapply(x$history$products,function(r) {
    if(!is.null(at) && (at<.shipment_time(r$valid_from)||at>=.shipment_time(r$valid_until))) return(NULL)
    selected <- products[startsWith(products,r$scope_code)]
    if(!length(selected)) return(NULL)
    data.frame(revision=x$revision,hts10=selected,scope_code=r$scope_code,scope_grain=as.integer(r$scope_grain),
      condition=r$condition,condition_text=r$condition_text,reporting_code=r$reporting_code,
      source_id=r$source_id,source_locator=r$source_locator,source_scope_sha256=r$source_scope_sha256,
      valid_from=r$valid_from,valid_until=r$valid_until,
      termination_source_id=if(is.null(r$termination_source_id)) NA_character_ else r$termination_source_id,
      pdf_sha256=x$sources[[1]]$sha256,hts_sha256=x$sources[[2]]$sha256)
  })
  empty <- data.frame(revision=character(),hts10=character(),scope_code=character(),scope_grain=integer(),
    condition=character(),condition_text=character(),reporting_code=character(),source_id=character(),
    source_locator=character(),source_scope_sha256=character(),valid_from=character(),valid_until=character(),
    termination_source_id=character(),pdf_sha256=character(),hts_sha256=character())
  unique(dplyr::bind_rows(empty,rows))
}

reciprocal_exempt_projection <- function(decisions) {
  # Description-limited provisions require shipment facts; they never turn an
  # entire HTS8 into an unconditional zero. Overlapping legal prefixes are OR.
  unconditional <- decisions[decisions$condition=='none',]
  unconditional <- unconditional[!duplicated(unconditional$hts10),]
  data.frame(hts10=unconditional$hts10,source=ifelse(grepl('electronics',unconditional$source_id),'ita','annex_ii'))
}

reciprocal_scope_fragment <- function(x) {
  all <- c(x$sources,x$history$sources)
  ids <- c(paste0('USITC-',x$revision,c('-reciprocal-notes','-reciprocal-headings')),
    vapply(x$history$sources,`[[`,character(1),'id'))
  sources <- lapply(seq_along(all),function(i) {
    s <- all[[i]]
    list(id=ids[i],status='verified',sha256=s$sha256,
      url=if(is.null(s$url)) paste0('https://hts.usitc.gov/reststop/',
        if(i==1) 'file?release=' else 'exportList?release=',build_release_name(x$revision),
        if(i==1) '&filename=Chapter%2099' else '&exportFormat=JSON') else s$url,
      citation=if(is.null(s$citation)) paste('USITC',x$revision,'reciprocal source reconciliation') else s$citation)
  })
  list(contract_version='sail.shipment-rule-fragment/v1',id=paste0('reciprocal_scope_evidence_',x$revision),
    sources=sources,source_artifacts=lapply(seq_along(all),function(i)
      list(source_id=ids[i],path=all[[i]]$path,sha256=all[[i]]$sha256)),
    reciprocal_scope=list(contract_version=x$history$contract_version,revision=x$revision,
      pdf_sha256=x$sources[[1]]$sha256,hts_sha256=x$sources[[2]]$sha256,products=x$history$products),
    rules=list(),coverage=list(),relations=list(),fact_definitions=list(),
    limitations=list('Product exemption chronology only; does not attest reciprocal country, FTZ, valuation or cross-program completeness.'))
}

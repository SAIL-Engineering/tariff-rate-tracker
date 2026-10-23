# Revision-bound China Section 301 extraction and evaluation. The PDF tables
# supply scope; the same revision's HTS heading supplies the rate expression.
# Never use a global HTS8 list or choose a maximum to resolve legal conflicts.

load_s301_revision_source <- function(revision_id, root = here::here(), download = TRUE) {
  if (!grepl('^202[56]_(basic|rev_[0-9]+)$', revision_id))
    stop('Section 301 source extraction requires an identified 2025/2026 revision')
  pdf <- file.path(root, 'data/us_notes', paste0('chapter99_', revision_id, '.pdf'))
  hts <- file.path(root, 'data/hts_archives', paste0('hts_', revision_id, '.json'))
  if (!file.exists(pdf) && download) {
    dir.create(dirname(pdf), recursive=TRUE, showWarnings=FALSE)
    url <- build_chapter99_url(build_release_name(revision_id))
    temp <- tempfile(fileext='.pdf')
    on.exit(unlink(temp), add=TRUE)
    utils::download.file(url, temp, mode='wb', quiet=TRUE)
    if (!identical(rawToChar(readBin(temp,'raw',4)), '%PDF')) stop('Not a Chapter 99 PDF: ', url)
    if (!file.copy(temp,pdf)) stop('Could not retain Chapter 99 source')
  }
  if (!file.exists(pdf) || !file.exists(hts)) stop('Missing revision-bound Section 301 PDF/HTS source: ', revision_id)
  script <- file.path(root, 'src/section301_sources.py')
  cache <- file.path(root, 'data/processed/s301_sources', paste0(revision_id,'.json'))
  hash <- function(file) digest::digest(file=file,algo='sha256')
  valid <- function(x) identical(x$contract_version,'sail.section301-extraction/v1') &&
    identical(x$revision,revision_id) && identical(x$extractor_sha256,hash(script)) &&
    identical(x$sources[[1]]$sha256,hash(pdf)) && identical(x$sources[[2]]$sha256,hash(hts)) &&
    all(vapply(x$additional_sources,function(s) file.exists(s$path) && identical(s$sha256,hash(s$path)),logical(1)))
  x <- if(file.exists(cache)) tryCatch(jsonlite::fromJSON(cache,simplifyVector=FALSE),error=function(e) NULL) else NULL
  if(is.null(x) || !valid(x)) {
    temp <- tempfile(fileext='.json')
    on.exit(unlink(temp),add=TRUE)
    status <- system2('python3',c(shQuote(script),'--pdf',shQuote(pdf),'--hts',shQuote(hts),
      '--revision',shQuote(revision_id),'--output',shQuote(temp)))
    if(status!=0L) stop('Section 301 source extraction failed; refusing legacy-list fallback')
    x <- jsonlite::fromJSON(temp,simplifyVector=FALSE)
    if(!valid(x)) stop('Section 301 extraction source/hash mismatch')
    dir.create(dirname(cache),recursive=TRUE,showWarnings=FALSE)
    if(!file.copy(temp,cache,overwrite=TRUE)) stop('Could not retain source extraction')
  }
  x
}

s301_revision_matches <- function(extraction, products, entry_at, country='5700') {
  if(!exists('.shipment_time',mode='function')) source(here::here('src/resolve_shipment_duties.R'))
  at <- .shipment_time(entry_at)
  if(is.na(at)) stop('An exact entry timestamp is required')
  rows <- list()
  products <- unique(as.character(products))
  if(any(!grepl('^[0-9]{10}$',products))) stop('Products must be valid HTS10 identifiers')
  by_prefix <- split(products,substr(products,1,8))
  for(action in extraction$actions) {
    if(!is.null(action$country_scope) && action$country_scope!='all' && action$country_scope!=country) next
    if(!is.null(action$valid_from) && at < .shipment_time(action$valid_from)) next
    if(!is.null(action$valid_until) && at >= .shipment_time(action$valid_until)) next
    for(scope in action$scopes) {
      inc <- unlist(scope$includes); exc <- unlist(scope$excludes)
      if(any(!nchar(c(inc,exc)) %in% c(8L,10L))) stop('Invalid Section 301 scope grain')
      included <- unique(c(unlist(by_prefix[inc[nchar(inc)==8]],use.names=FALSE),
        intersect(products,inc[nchar(inc)==10])))
      included <- included[!included %in% exc & !substr(included,1,8) %in% exc]
      if(!length(included)) next
      rows[[length(rows)+1L]] <- data.frame(hts10=included,
        ch99_code=action$reporting_code, rate=action$rate,
        program=action$program,country_scope=action$country_scope,
        condition_text=if(is.null(scope$condition_text)) NA_character_ else scope$condition_text,
        source_locator=scope$locator, source_text_sha256=scope$source_text_sha256,
        pdf_sha256=extraction$sources[[1]]$sha256, hts_sha256=extraction$sources[[2]]$sha256,
        valid_from=if(is.null(action$valid_from)) NA_character_ else action$valid_from,
        valid_until=if(is.null(action$valid_until)) NA_character_ else action$valid_until,
        stringsAsFactors=FALSE)
    }
  }
  empty <- data.frame(hts10=character(),ch99_code=character(),rate=numeric(),program=character(),country_scope=character(),condition_text=character(),
    source_locator=character(),source_text_sha256=character(),pdf_sha256=character(),hts_sha256=character(),
    valid_from=character(),valid_until=character())
  if(!length(rows)) return(empty)
  out <- unique(do.call(rbind,rows))
  # Multiple rows within a single heading are OR alternatives, not cumulative
  # duties. Distinct headings require a legally extracted relationship; rate
  # magnitude is never a tie-breaker.
  by_product <- split(out$ch99_code,paste(out$hts10,out$program))
  bad <- names(Filter(function(x) length(unique(x))>1,by_product))
  if(length(bad)) stop('Unresolved overlapping Section 301 actions: ',paste(head(bad,20),collapse=', '))
  out
}

s301_revision_lookup <- function(matches) {
  if(length(unique(matches$program))>1) stop('Distinct Section 301 investigations require separate projections')
  if(!nrow(matches)) return(data.frame(hts10=character(),blanket_301=numeric(),src_301=character(),
    s301_scope_requires_inputs=logical(),modeled_s301_scope_share=numeric()))
  rows <- lapply(split(matches,matches$hts10),function(x) {
    if(length(unique(x$rate))!=1) stop('Conflicting rates for Section 301 action')
    data.frame(hts10=x$hts10[1],blanket_301=x$rate[1],src_301=x$ch99_code[1],
      s301_scope_requires_inputs=all(!is.na(x$condition_text)),modeled_s301_scope_share=1)
  })
  do.call(rbind,rows)
}

# Executable source fragment for the shared R/TypeScript interpreter. This is
# emitted by the ordinary normalized build, not maintained as copied constants.
# It deliberately does not attest complete Section 301 coverage (other actions
# and exclusion/Chapter-98 claim effects must be composed separately).
compile_s301_revision_fragment <- function(extraction, products) {
  revision <- extraction$revision
  source_ids <- paste0('USITC-',revision,c('-chapter99','-hts'))
  release <- build_release_name(revision)
  sources <- lapply(seq_along(source_ids),function(i) list(id=source_ids[i],status='verified',
    sha256=extraction$sources[[i]]$sha256,
    url=paste0('https://hts.usitc.gov/reststop/',if(i==1) 'file?release=' else 'exportList?release=',
      release,if(i==1) '&filename=Chapter%2099' else '&exportFormat=JSON'),
    citation=paste0('USITC ',revision,': Chapter 99 notes 20/31 and headings 9903.88, 9903.91, 9903.92.10. ',
      'Charge scope only; see the rule source locator and description.')))
  artifacts <- lapply(seq_along(source_ids),function(i)
    list(source_id=source_ids[i],path=extraction$sources[[i]]$path,sha256=extraction$sources[[i]]$sha256))
  for(s in extraction$additional_sources) {
    sources[[length(sources)+1L]] <- list(id=s$id,status='verified',sha256=s$sha256,url=s$url,citation=s$citation)
    artifacts[[length(artifacts)+1L]] <- list(source_id=s$id,path=s$path,sha256=s$sha256)
    source_ids <- c(source_ids,s$id)
  }
  rules <- list(); facts <- list(customs_value=list(type='number',minimum=0,unit='USD',
    label='Customs value (USD)',source_ids=as.list(source_ids)))
  for(action in extraction$actions) {
    one <- extraction; one$actions <- list(action)
    at <- if(is.null(action$valid_from)) '2025-01-01T00:00:00-05:00' else action$valid_from
    matched <- s301_revision_matches(one,products,at)
    if(!nrow(matched)) next
    if(any(duplicated(matched$hts10))) stop('Overlapping alternatives within Section 301 heading')
    groups <- split(matched,ifelse(is.na(matched$condition_text),'unconditional',matched$source_text_sha256))
    for(key in names(groups)) {
      group <- groups[[key]]
      id <- paste0('s301_',gsub('[.]','',action$reporting_code),'_',key)
      scope <- list(hts_exact=as.list(sort(group$hts10)),countries=list('5700'))
      if(action$country_scope=='all') scope$countries <- NULL
      if(!is.null(action$valid_from)) scope$from <- action$valid_from
      if(!is.null(action$valid_until)) scope$until <- action$valid_until
      rule <- list(id=id,action_id=paste0('s301_',gsub('[.]','',action$reporting_code)),
        authority='section_301',kind='duty',verification='verified',scope=scope,
        formula=list(op='multiply',args=list(list(fact='customs_value'),list(value=action$rate))),
        reporting_codes=list(action$reporting_code),source_ids=as.list(source_ids),
        legal_locator=action$locator,source_scope_locators=as.list(unique(group$source_locator)))
      if(key!='unconditional') {
        name <- paste0('matches_',id)
        rule$when <- list(fact=name)
        facts[[name]] <- list(type='boolean',label=paste0('Product meets ',action$reporting_code,' description'),
          description=group$condition_text[1],source_ids=as.list(source_ids))
      }
      rules[[length(rules)+1L]] <- rule
      if(!is.null(action$start_time_conflict)) {
        gap <- rule
        gap$id <- paste0(rule$id,'_unresolved_time_zone')
        gap$verification <- 'unresolved_source'
        gap$scope$from <- action$start_time_conflict$unresolved_from
        gap$scope$until <- action$start_time_conflict$unresolved_until
        gap$source_discrepancy <- action$start_time_conflict
        rules[[length(rules)+1L]] <- gap
      }
    }
  }
  list(contract_version='sail.shipment-rule-fragment/v1',id=paste0('s301_china_',revision),
    supported_from='2025-01-01T00:00:00-05:00',supported_until='2026-10-23T00:00:00-04:00',
    sources=sources,source_artifacts=artifacts,
    rules=rules,fact_definitions=facts,coverage=list(),relations=list(),
    limitations=extraction$limitations)
}

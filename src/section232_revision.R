# Revision-specific note 16 evidence and aggregate adapter. Shipment liability
# still requires the note's material, weight, origin, use and claim predicates.
# This file never turns membership or model shares into statutory eligibility.

load_s232_note16_source <- function(revision_id, root=here::here()) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision_id)) stop('Identified 2025/2026 revision required')
  pdf <- file.path(root,'data/us_notes',paste0('chapter99_',revision_id,'.pdf'))
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision_id,'.json'))
  if(!file.exists(pdf) || !file.exists(hts)) stop('Missing revision-bound note 16 source: ',revision_id)
  script <- file.path(root,'src/section232_sources.py')
  dependency <- file.path(root,'src/section301_sources.py')
  hash <- function(p) digest::digest(file=p,algo='sha256')
  valid <- function(x) identical(x$contract_version,'sail.section232-note16-extraction/v1') &&
    identical(x$revision,revision_id) && identical(x$extractor_sha256,hash(script)) &&
    identical(x$parser_dependency_sha256,hash(dependency)) &&
    identical(x$sources[[1]]$sha256,hash(pdf)) && identical(x$sources[[2]]$sha256,hash(hts)) &&
    all(vapply(x$additional_sources,function(s) file.exists(s$path) && identical(s$sha256,hash(s$path)),logical(1)))
  cache <- file.path(root,'data/processed/s232_note16_sources',paste0(revision_id,'.json'))
  x <- if(file.exists(cache)) tryCatch(jsonlite::fromJSON(cache,simplifyVector=FALSE),error=function(e) NULL) else NULL
  if(is.null(x) || !valid(x)) {
    temp <- tempfile(fileext='.json');on.exit(unlink(temp),add=TRUE)
    status <- system2('python3',c(shQuote(script),'--pdf',shQuote(pdf),'--hts',shQuote(hts),
      '--revision',shQuote(revision_id),'--output',shQuote(temp)))
    if(status!=0L) stop('Note 16 extraction failed; refusing static list/chapter fallback')
    x <- jsonlite::fromJSON(temp,simplifyVector=FALSE)
    if(!valid(x)) stop('Note 16 source/hash mismatch')
    dir.create(dirname(cache),recursive=TRUE,showWarnings=FALSE)
    if(!file.copy(temp,cache,overwrite=TRUE)) stop('Could not retain note 16 extraction')
  }
  x
}

s232_note16_matches <- function(extraction,products) {
  products <- sort(unique(as.character(products)))
  if(any(!grepl('^[0-9]{10}$',products))) stop('Invalid note 16 HTS10')
  index <- lapply(c(4L,6L,8L,10L),function(n) split(products,substr(products,1,n)))
  names(index) <- c('4','6','8','10')
  rows <- list()
  for(s in extraction$lists) for(code in unlist(s$includes)) {
    if(!nchar(code) %in% c(4L,6L,8L,10L)) stop('Invalid note 16 scope grain')
    hit <- index[[as.character(nchar(code))]][[code]]
    if(!length(hit)) next
    rows[[length(rows)+1L]] <- data.frame(hts10=hit,scope_code=code,scope_grain=as.integer(nchar(code)),
      list_id=s$id,metal=s$metal,derivative=s$derivative,source_locator=s$locator,
      source_text_sha256=s$source_text_sha256,pdf_sha256=extraction$sources[[1]]$sha256,
      hts_sha256=extraction$sources[[2]]$sha256,stringsAsFactors=FALSE)
  }
  if(!length(rows)) return(data.frame(hts10=character(),scope_code=character(),scope_grain=integer(),
    list_id=character(),metal=character(),derivative=logical(),source_locator=character(),
    source_text_sha256=character(),pdf_sha256=character(),hts_sha256=character()))
  unique(do.call(rbind,rows))
}

s232_note16_projection <- function(extraction,matches,products) {
  # These labels only adapt to the existing aggregate annex model. Membership
  # is a complete revision snapshot, not a union with an older derivative list.
  labels <- c('9903.82.02'='annex_1a','9903.82.09'='annex_1b','9903.82.10'='annex_3')
  tiers <- list()
  for(t in extraction$ordinary_tiers) for(id in unlist(t$list_ids)) {
    if(!is.null(tiers[[id]])) stop('Ambiguous ordinary note 16 tier')
    tiers[[id]] <- t$reporting_code
  }
  grouped <- split(matches,matches$hts10)
  data <- lapply(sort(unique(products)),function(hts) {
    m <- grouped[[hts]]
    if(is.null(m)) return(data.frame(hts10=hts,s232_annex='annex_2',s232_metal=NA_character_,
      s232_note16_lists_json='[]',s232_note16_metals_json='[]',s232_note16_status='outside_note16_scope'))
    codes <- unique(unlist(tiers[unique(m$list_id)]))
    if(length(codes)!=1) stop('Overlapping ordinary note 16 tiers: ',hts)
    metals <- sort(unique(m$metal))
    data.frame(hts10=hts,s232_annex=unname(labels[codes]),
      s232_metal=if(length(metals)==1) metals else NA_character_,
      s232_note16_lists_json=as.character(jsonlite::toJSON(sort(unique(m$list_id)))),
      s232_note16_metals_json=as.character(jsonlite::toJSON(metals)),
      s232_note16_status='candidate_requires_legal_predicates')
  })
  do.call(rbind,data)
}

mark_s232_note16_scope <- function(rates,projection) {
  at <- match(rates$hts10,projection$hts10)
  candidate <- !is.na(at) & projection$s232_note16_status[at]=='candidate_requires_legal_predicates'
  # Outside this particular list is not an attestation of no Section 232 action.
  # All matched articles need actual metal/claim facts before a shipment total.
  rates$statutory_rate_232[candidate] <- NA_real_
  rates$s232_note16_status <- projection$s232_note16_status[at]
  rates$s232_note16_lists_json <- projection$s232_note16_lists_json[at]
  rates$s232_note16_metals_json <- projection$s232_note16_metals_json[at]
  rates
}

reconcile_s232_note16_model_actions <- function(rates,projection,other_program_products=character()) {
  # Note 16(a): one mutually exclusive metal heading on the whole article.
  # Older content/action columns must not resurrect a retired or lowered rate
  # at the final stacking pass. These are MODEL allocations only; retain every
  # metal/list membership in the independent scope evidence above.
  ix <- match(rates$hts10,projection$hts10)
  controlled <- !is.na(ix) & !rates$hts10 %in% other_program_products
  rates <- zero_fill_authority_rates(rates,S232_ACTION_RATE_COLS)
  for(col in S232_ACTION_RATE_COLS) rates[[col]][controlled] <- 0
  metal <- projection$s232_metal[ix]
  for(m in c('steel','aluminum','copper')) {
    hit <- controlled & !is.na(metal) & metal==m
    rates[[paste0('rate_232_',m)]][hit] <- rates$rate_232[hit]
  }
  mixed <- controlled & is.na(metal) & rates$rate_232>0
  rates$rate_232_other[mixed] <- rates$rate_232[mixed]
  rates$modeled_s232_note16_combined_metals <- mixed
  rates
}

compile_s232_note16_fragment <- function(extraction,products,jurisdictions=NULL) {
  if(!isTRUE(extraction$active_regime)) stop('Note 16 regime is not active in this source')
  if(is.null(jurisdictions)) {
    if(!file.exists(here::here('resources/gn3_column2_countries.csv')))
      stop('Missing GN 3(b) country evidence')
    country <- function(name) {
      name <- sub('^a member nation of the European Union$','European Union',name)
      result <- as.character(resolve_country_name(name))
      if(!length(result) || anyNA(result)) stop('Unresolved note 16 origin: ',name)
      result
    }
    partner <- Filter(function(h) identical(h$code,'9903.82.22'),extraction$headings)
    partner_codes <- character()
    if(length(partner)) {
      if(!exists('extract_countries_from_description',mode='function'))
        source(here::here('src/05_parse_policy_params.R'))
      names <- extract_countries_from_description(partner[[1]]$description)
      if(!length(names)) stop('Missing note 16(xi) partner inventory')
      partner_codes <- unlist(lapply(names,country),use.names=FALSE)
    }
    jurisdictions <- list(all=as.character(read.csv(here::here('resources/census_codes.csv'))$Code),
      uk=country('United Kingdom'),russia=country('Russian Federation'),
      non_ntr=load_non_ntr_countries(extraction$revision,'2026-04-06',strict=TRUE),
      usmca=c(country('Canada'),country('Mexico')),xi_partner=partner_codes)
  }
  input <- tempfile(fileext='.json');output <- tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  source(here::here('src/shipment_build.R'))
  base<-load_shipment_base_source(extraction$revision)
  extraction$column1_amounts<-compile_shipment_column1_references(base,products,strict=FALSE)
  extraction$additional_sources<-c(extraction$additional_sources,list(c(list(id=paste0('USITC-',extraction$revision,'-shipment-gn3')),base$gn3$source)))
  jsonlite::write_json(list(x=extraction,products=as.list(sort(unique(products))),
    jurisdictions=lapply(jurisdictions,as.list)),input,auto_unbox=TRUE,null='null',digits=NA)
  script <- here::here('src/section232_note16_rules.py')
  status <- system2('python3',c(shQuote(script),shQuote(input),shQuote(output)))
  if(status!=0L) stop('Note 16 predicate compilation failed')
  fragment <- jsonlite::fromJSON(output,simplifyVector=FALSE)
  fragment$compiler_sha256 <- digest::digest(file=script,algo='sha256')
  fragment$extraction_sha256 <- extraction$extractor_sha256
  for(p in c('src/section232_revision.R','src/shipment_build.R','src/shipment_duty_expression.R'))
    fragment$compiler_dependencies[[p]]<-digest::digest(file=here::here(p),algo='sha256')
  # The extraction belongs to a specific snapshot. An earlier/later bundle
  # cannot consume it to carry amended lists or thresholds across revisions.
  dates <- read.csv(here::here('config/revision_dates.csv'),stringsAsFactors=FALSE)
  row <- dates[dates$revision==extraction$revision,,drop=FALSE]
  if(nrow(row)!=1L) stop('Missing note 16 revision interval')
  # Calendar dates alone cannot attest a legal sub-day boundary. Start at the
  # later of the known policy date and the new regime's verified 00:01 instant.
  date <- as.character(row$policy_effective_date)
  if(is.na(date) || date=='NA') date <- as.character(row$effective_date)
  later <- as.Date(dates$policy_effective_date)
  later <- later[!is.na(later) & later>as.Date(date)]
  after <- if(length(later)) min(later) else as.Date('2026-10-23')
  eastern <- function(day) {
    time <- as.POSIXct(paste(day,'00:00:00'),tz='America/New_York')
    offset <- format(time,'%z',tz='America/New_York')
    paste0(day,'T00:00:00',substr(offset,1,3),':',substr(offset,4,5))
  }
  fragment$supported_from <- if(date=='2026-04-06') '2026-04-06T00:01:00-04:00' else
    if(date=='2026-06-08') '2026-06-08T00:01:00-04:00' else eastern(date)
  fragment$supported_until <- eastern(min(after,as.Date('2026-10-23')))
  fragment
}

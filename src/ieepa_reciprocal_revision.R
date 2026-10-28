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

# Country text from an original instrument uses the ordinary ingestion resolver.
# Shared by reciprocal extraction and independent Section232 agreements.
resolve_original_action_origins <- function(country_text) {
  names<-extract_countries_from_description(paste('articles the product of',country_text,'as provided for in subdivision (v)'))
  resolved<-lapply(names,resolve_country_name)
  if(any(lengths(resolved)==0L)) stop('Unresolved original action country token: ',paste(names[lengths(resolved)==0L],collapse=', '))
  found<-unlist(resolved)
  if(!length(found)||anyNA(found)) stop('Unresolved original action origin: ',country_text)
  as.list(sort(unique(found)))
}

# Compile original reciprocal country/valuation decisions using the same
# jurisdiction resolver as ingestion. Never read a calculated rate column.
compile_reciprocal_initial_fragment <- function(x,products,root=here::here()) {
  paths<-replicate(3,tempfile(fileext='.json'));on.exit(unlink(paths),add=TRUE)
  status<-system2('python3',c(shQuote(file.path(root,'src/ieepa_reciprocal_initial.py')),shQuote(paths[1])))
  if(status!=0L) stop('Original reciprocal history extraction failed')
  h<-jsonlite::fromJSON(paths[1],simplifyVector=FALSE)
  if(!exists('match_countries',mode='function')) source(file.path(root,'src/05_parse_policy_params.R'))
  lookup<-build_country_lookup(file.path(root,'resources/census_codes.csv'))
  resolve_action<-function(a) {
    resolve_original_action_origins(a$country_text)
  }
  actions<-setNames(lapply(h$actions,resolve_action),vapply(h$actions,`[[`,character(1),'code'))
  august_actions<-setNames(lapply(h$august_country_policy$actions,resolve_action),
    vapply(h$august_country_policy$actions,function(a)paste(unlist(a$reporting_codes),collapse='|'),character(1)))
  later_actions<-setNames(lapply(h$later_policy$country_amendments,resolve_action),
    vapply(h$later_policy$country_amendments,function(a)paste(unlist(a$reporting_codes),collapse='|'),character(1)))
  partner_exemptions<-setNames(lapply(h$later_policy$exemptions,resolve_action),
    vapply(h$later_policy$exemptions,`[[`,character(1),'reporting_code'))
  source(file.path(root,'src/shipment_build.R'))
  frame<-shipment_source_selection_window(x$revision,root)
  amounts<-list()
  if(length(products) && .shipment_time(frame$from)<.shipment_time(h$collection_ended_at) &&
     .shipment_time(frame$until)>.shipment_time(h$august_country_policy$from_)) {
    native<-load_shipment_base_source(x$revision,root)
    native<-setNames(native$products,vapply(native$products,`[[`,character(1),'hts10'))
    amounts<-setNames(lapply(as.character(products),function(p) {
      record<-native[[p]]$general
      if(is.null(record))return(list(raw=NULL,fixed_advalorem=FALSE,
        formula=list(unresolved_source=paste0('reciprocal_column1_general_special_classification:',p)),
        fact_definitions=list(),input_constraints=list()))
      parsed<-parse_shipment_duty_expression(record$expression)
      list(raw=record$expression,source_code=record$source_code,source_row_index=record$source_row_index,
        fixed_advalorem=parsed$status=='parsed' && grepl('^(Free|[0-9]+(\\.[0-9]+)?%)$',parsed$normalized_text,ignore.case=TRUE),
        formula=if(parsed$status=='parsed')parsed$formula else list(unresolved_source=paste('reciprocal_column1_general_expression',p,parsed$reason,sep=':')),
        fact_definitions=parsed$fact_definitions,input_constraints=parsed$input_constraints %||% list())
    }),as.character(products))
  }
  # No carry-forward of an absent country inventory for executable decisions.
  gn_path<-file.path(root,'resources/gn3_column2_countries.csv')
  gn<-read.csv(gn_path,colClasses='character')
  gn<-gn[gn$revision==x$revision,]
  if(!nrow(gn)||any(is.na(gn$source_url)|!nzchar(gn$source_url))) stop('Missing revision-bound GN3 country evidence')
  excluded<-lapply(gn$country_name,resolve_country_name)
  if(any(lengths(excluded)==0L)) stop('Unresolved GN3 country')
  files<-c('resources/gn3_column2_countries.csv','resources/census_codes.csv','resources/country_qualified_names.csv','resources/country_name_aliases.csv','config/policy_params.yaml')
  # Country resolver uses the policy EU membership; preserve both its input
  # and implementation version with the derived jurisdiction inventory.
  files<-c(files,'src/helpers.R','src/05_parse_policy_params.R')
  evidence<-lapply(files,function(p) list(id=paste0('reciprocal-jurisdiction-',gsub('[^a-zA-Z0-9]','-',p)),
    path=normalizePath(file.path(root,p),mustWork=TRUE),sha256=digest::digest(file=file.path(root,p),algo='sha256'),
    url=paste0('https://hts.usitc.gov/reststop/file?release=',build_release_name(x$revision),'&filename=General%20Note%203'),
    citation=paste('Derived jurisdiction mapping; General Note 3 and versioned Census/EU country resolution:',p)))
  jurisdictions<-list(all=as.list(sort(unique(read.csv(file.path(root,'resources/census_codes.csv'),colClasses='character')$Code))),non_ntr=as.list(sort(unique(unlist(excluded)))),
    actions=actions,august_actions=august_actions,later_actions=later_actions,partner_exemptions=partner_exemptions,
    Canada=as.list(resolve_country_name('Canada')),Mexico=as.list(resolve_country_name('Mexico')),
    UnitedKingdom=as.list(resolve_country_name('United Kingdom')),sources=evidence)
  jsonlite::write_json(list(x=x,products=as.list(sort(unique(products))),jurisdictions=jurisdictions,base_amounts=amounts),paths[2],auto_unbox=TRUE,null='null',digits=NA)
  status<-system2('python3',c(shQuote(file.path(root,'src/ieepa_reciprocal_rules.py')),shQuote(paths[2]),shQuote(paths[3])))
  if(status!=0L) stop('Reciprocal executable compilation failed')
  jsonlite::fromJSON(paths[3],simplifyVector=FALSE)
}

# Historical metal notes feed both the model's candidate inventory and the
# independent shipment interpreter. Model shares never enter the latter.
load_s232_legacy_source <- function(revision_id,root=here::here()) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision_id)) stop('Identified revision required')
  pdf<-file.path(root,'data/us_notes',paste0('chapter99_',revision_id,'.pdf'))
  hts<-file.path(root,'data/hts_archives',paste0('hts_',revision_id,'.json'))
  script<-file.path(root,'src/section232_legacy_sources.py')
  dependency<-file.path(root,'src/section301_sources.py')
  hash<-function(p) digest::digest(file=p,algo='sha256')
  if(!all(file.exists(c(pdf,hts)))) stop('Missing revision-specific legacy metal sources')
  valid<-function(x) identical(x$contract_version,'sail.section232-legacy-extraction/v1') &&
    identical(x$revision,revision_id) && identical(x$extractor_sha256,hash(script)) &&
    identical(x$parser_dependency_sha256,hash(dependency)) &&
    identical(x$sources[[1]]$sha256,hash(pdf)) && identical(x$sources[[2]]$sha256,hash(hts)) &&
    (is.null(x$pre_march) || (identical(x$pre_march_dependency_sha256,hash(file.path(root,'src/section232_pre_march.py'))) &&
      all(vapply(x$pre_march$bulletins,function(s) file.exists(s$artifact_path)&&identical(s$sha256,hash(s$artifact_path)),logical(1))))) &&
    all(vapply(x$additional_sources,function(s) file.exists(s$path)&&identical(s$sha256,hash(s$path)),logical(1)))
  cache<-file.path(root,'data/processed/s232_legacy_sources',paste0(revision_id,'.json'))
  x<-if(file.exists(cache)) tryCatch(jsonlite::fromJSON(cache,simplifyVector=FALSE),error=function(e) NULL) else NULL
  if(is.null(x)||!valid(x)) {
    tmp<-tempfile(fileext='.json');on.exit(unlink(tmp),add=TRUE)
    status<-system2('python3',c(shQuote(script),'--pdf',shQuote(pdf),'--hts',shQuote(hts),
      '--revision',shQuote(revision_id),'--output',shQuote(tmp)))
    if(status!=0L) stop('Historical metal extraction failed; no static scope fallback')
    x<-jsonlite::fromJSON(tmp,simplifyVector=FALSE)
    if(!valid(x)) stop('Legacy source/hash mismatch')
    dir.create(dirname(cache),recursive=TRUE,showWarnings=FALSE)
    if(!file.copy(tmp,cache,overwrite=TRUE)) stop('Could not retain legacy metal extraction')
  }
  x
}

s232_legacy_matches <- function(x,products,effective_date=NULL) {
  if(!is.null(effective_date) && !is.null(x$pre_march) && as.Date(effective_date)<as.Date('2025-03-12')) x$lists<-x$pre_march$lists
  products<-sort(unique(as.character(products)))
  if(any(!grepl('^[0-9]{10}$',products))) stop('Invalid HTS10')
  index<-lapply(c(4,6,8,10),function(n) split(products,substr(products,1,n)))
  names(index)<-c('4','6','8','10');rows<-list()
  for(s in x$lists) for(prefix in unlist(s$includes)) {
    hit<-index[[as.character(nchar(prefix))]][[prefix]]
    if(!length(hit)) next
    for(ex in unlist(s$excludes)) hit<-hit[!startsWith(hit,ex)]
    if(!length(hit)) next
    rows[[length(rows)+1L]]<-data.frame(hts10=hit,list_id=s$id,scope_code=prefix,scope_grain=nchar(prefix),
      metal=s$metal,derivative=s$derivative,reporting_code=s$reporting_code,country_group=s$country_group,
      conditional=!is.null(s$condition_text),source_locator=s$locator,source_text_sha256=s$source_text_sha256,
      pdf_sha256=x$sources[[1]]$sha256,hts_sha256=x$sources[[2]]$sha256)
  }
  if(!length(rows)) return(data.frame(hts10=character(),list_id=character(),scope_code=character(),
    scope_grain=integer(),metal=character(),derivative=logical(),reporting_code=character(),country_group=character(),
    conditional=logical(),source_locator=character(),source_text_sha256=character(),pdf_sha256=character(),hts_sha256=character()))
  unique(do.call(rbind,rows))
}

s232_legacy_derivative_projection <- function(matches) {
  rows<-matches[matches$derivative & matches$country_group=='ordinary',]
  unique(data.frame(hts_prefix=rows$hts10,ch99_code=rows$reporting_code,derivative_type=rows$metal))
}

compile_s232_legacy_fragment <- function(x,products) {
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  jurisdictions<-list(all=as.list(as.character(read.csv(here::here('resources/census_codes.csv'))$Code)),
    uk=as.list(as.character(resolve_country_name('United Kingdom'))),
    russia=as.list(as.character(resolve_country_name('Russian Federation'))))
  jsonlite::write_json(list(x=x,products=as.list(sort(unique(products))),jurisdictions=jurisdictions),
    input,auto_unbox=TRUE,null='null',digits=NA)
  script<-here::here('src/section232_legacy_rules.py')
  status<-system2('python3',c(shQuote(script),shQuote(input),shQuote(output)))
  if(status!=0L) stop('Legacy metal predicate compilation failed')
  fragment<-jsonlite::fromJSON(output,simplifyVector=FALSE)
  fragment$compiler_sha256<-digest::digest(file=script,algo='sha256')
  fragment
}

mark_s232_legacy_scope <- function(rates,matches) {
  hit<-rates$hts10 %in% matches$hts10
  # Content, material production, limited descriptions and competing actions
  # cannot be resolved using the model's metal-share/country assumptions.
  rates$statutory_rate_232[hit]<-NA_real_
  rates$s232_legacy_status<-ifelse(hit,'candidate_requires_legal_predicates','outside_legacy_metal_scope')
  rates
}

# Original-annex Section 338 evidence and rule emission. No live database I/O.
load_s338_source <- function() {
  output <- tempfile(fileext='.json');on.exit(unlink(output),add=TRUE)
  status <- system2('python3',c(shQuote(here::here('src/section338_sources.py')),shQuote(output)))
  if(status!=0L) stop('Section 338 original-annex extraction failed')
  jsonlite::fromJSON(output,simplifyVector=FALSE)
}

compile_s338_fragment <- function(revision,products) {
  input<-tempfile(fileext='.json');output<-tempfile(fileext='.json')
  on.exit(unlink(c(input,output)),add=TRUE)
  jsonlite::write_json(list(revision=revision,products=as.list(sort(unique(products)))),input,
    auto_unbox=TRUE,null='null',digits=NA)
  status<-system2('python3',c(shQuote(here::here('src/section338_rules.py')),shQuote(input),shQuote(output)))
  if(status!=0L) stop('Section 338 executable-rule compilation failed')
  jsonlite::fromJSON(output,simplifyVector=FALSE)
}

emit_s338_rules <- function(revision,products,output_dir) {
  dir.create(file.path(output_dir,revision),recursive=TRUE,showWarnings=FALSE)
  jsonlite::write_json(load_s338_source(),file.path(output_dir,revision,'section338_source.json'),
    auto_unbox=TRUE,null='null',digits=NA)
  jsonlite::write_json(compile_s338_fragment(revision,products),
    file.path(output_dir,revision,'section338_rules.json'),auto_unbox=TRUE,null='null',digits=NA)
}

s338_normalized_applicability <- function(revision,effective_date,valid_from,valid_until) {
  x<-load_s338_source()
  # A published percentage is an action parameter, not a priced shipment. Use
  # the existing applicability table without manufacturing a statutory total.
  empty<-tibble::tibble(revision=character(),authority=character(),program=character(),
    hts10=character(),hts_prefix=character(),country_scope=character(),ch99_code=character(),
    statutory_rate=double(),legal_rate_parameter=double(),scope_status=character(),
    rate_kind=character(),scaling_dimension=character(),deriv_type=character(),precedence=integer(),
    usmca_exempt=logical(),requires_section232_inventory=logical(),source_ids_json=character(),
    entry_valid_from=character(),valid_from=as.Date(character()),valid_until=as.Date(character()))
  rows<-lapply(x$actions,function(a) {
    if(as.Date(effective_date)<as.Date(substr(a$from_,1,10))) return(empty)
    codes<-unlist(a$products);source_ids<-c(a$source_id,'FR-2026-17294');entry_from<-a$from_
    dependencies<-a$s232_exempt
    amendments<-Filter(function(m) identical(m$program,a$program)&&
      as.Date(substr(m$effective_at,1,10))<=as.Date(effective_date),x$amendments)
    amendments<-amendments[order(vapply(amendments,`[[`,character(1),'effective_at'))]
    for(m in amendments) {
      if(!all(unlist(m$delete)%in%codes)) stop('Section338 normalized amendment predecessor missing')
      codes<-sort(union(setdiff(codes,unlist(m$delete)),unlist(m$insert)))
      dependencies<-m$s232_exempt;entry_from<-m$effective_at;source_ids<-c(source_ids,m$source_id)
    }
    tibble::tibble(revision=revision,authority='section_338',program=paste0('section338_',a$program),
      hts10=ifelse(nchar(codes)==10,codes,NA_character_),hts_prefix=ifelse(nchar(codes)==8,codes,NA_character_),
      country_scope='1220',ch99_code=a$heading,statutory_rate=NA_real_,legal_rate_parameter=a$rate,
      scope_status='requires_shipment_rules',rate_kind='executable_action',scaling_dimension='none',deriv_type=NA_character_,
      precedence=1L,usmca_exempt=FALSE,requires_section232_inventory=dependencies,
      source_ids_json=as.character(jsonlite::toJSON(as.list(source_ids),auto_unbox=TRUE)),
      entry_valid_from=entry_from,valid_from=as.Date(valid_from),valid_until=as.Date(valid_until))
  })
  dplyr::bind_rows(empty,rows)
}

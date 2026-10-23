# Note 2(aa) scope from the actual source revision. A product-list match does
# not establish a use/claim predicate or a Section 232 interaction.
load_s122_revision_source <- function(revision_id, root=here::here()) {
  pdf <- file.path(root,'data/us_notes',paste0('chapter99_',revision_id,'.pdf'))
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision_id,'.json'))
  script <- file.path(root,'src/section122_sources.py')
  dependency <- file.path(root,'src/section301_sources.py')
  hash <- function(p) digest::digest(file=p,algo='sha256')
  if(!file.exists(pdf)||!file.exists(hts)) stop('Missing revision-bound Section 122 evidence')
  valid <- function(x) identical(x$contract_version,'sail.section122-extraction/v1') &&
    identical(x$revision,revision_id) && identical(x$extractor_sha256,hash(script)) &&
    identical(x$parser_dependency_sha256,hash(dependency)) &&
    identical(x$sources[[1]]$sha256,hash(pdf)) && identical(x$sources[[2]]$sha256,hash(hts))
  cache <- file.path(root,'data/processed/s122_sources',paste0(revision_id,'.json'))
  x <- if(file.exists(cache)) tryCatch(jsonlite::fromJSON(cache,simplifyVector=FALSE),error=function(e) NULL) else NULL
  if(is.null(x)||!valid(x)) {
    out <- tempfile(fileext='.json');on.exit(unlink(out),add=TRUE)
    status <- system2('python3',c(shQuote(script),'--pdf',shQuote(pdf),'--hts',shQuote(hts),
      '--revision',shQuote(revision_id),'--output',shQuote(out)))
    if(status!=0L) stop('Section 122 note extraction failed; refusing static-list fallback')
    x <- jsonlite::fromJSON(out,simplifyVector=FALSE)
    if(!valid(x)) stop('Section 122 evidence hash mismatch')
    dir.create(dirname(cache),recursive=TRUE,showWarnings=FALSE)
    if(!file.copy(out,cache,overwrite=TRUE)) stop('Could not retain Section 122 evidence')
  }
  x
}

s122_exemptions_from_source <- function(x) {
  out <- dplyr::bind_rows(x$products)
  if(!nrow(out)) return(out)
  out$source_url <- paste0('https://hts.usitc.gov/reststop/file?release=',
    build_release_name(x$revision),'&filename=Chapter%2099')
  out$pdf_sha256 <- x$sources[[1]]$sha256
  out$hts_sha256 <- x$sources[[2]]$sha256
  out
}

s122_scope_rows <- function(exemptions) {
  ex <- exemptions
  if(!'scope_code' %in% names(ex) && 'hts8' %in% names(ex)) ex$scope_code <- ex$hts8
  if(!'scope_code' %in% names(ex) || anyNA(ex$scope_code) || anyDuplicated(ex$scope_code) ||
      any(!grepl('^([0-9]{8}|[0-9]{10})$',ex$scope_code)))
    stop('Section 122 exemption source has invalid or ambiguous product precision')
  ex
}

s122_match_exemptions <- function(hts10,exemptions) {
  ex <- s122_scope_rows(exemptions)
  products <- data.frame(hts10=unique(hts10),scope_code=substr(unique(hts10),1,8))
  prefix <- merge(products,ex[nchar(ex$scope_code)==8,],by='scope_code')
  products$scope_code <- products$hts10
  exact <- merge(products,ex[nchar(ex$scope_code)==10,],by='scope_code')
  matches <- dplyr::bind_rows(prefix,exact)
  if(anyDuplicated(matches$hts10)) stop('Overlapping Section 122 conditions need explicit alternatives')
  matches
}

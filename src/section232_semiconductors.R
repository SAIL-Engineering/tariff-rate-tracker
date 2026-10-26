# Note 39's original-annex chronology, independent of modeled sector shares.
# Every historical period is emitted so amendments between HTS releases retain
# their actual entry instant. Authority completeness remains a separate review.
compile_s232_semiconductors_fragment <- function(revision_id,products,root=here::here()) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision_id)) stop('Identified 2025/2026 revision required')
  pdf <- file.path(root,'data/us_notes',paste0('chapter99_',revision_id,'.pdf'))
  hts <- file.path(root,'data/hts_archives',paste0('hts_',revision_id,'.json'))
  if(!file.exists(pdf)||!file.exists(hts)) stop('Missing revision-bound semiconductor source')
  products_file <- tempfile(fileext='.json');output <- tempfile(fileext='.json')
  on.exit(unlink(c(products_file,output)),add=TRUE)
  jsonlite::write_json(as.list(sort(unique(as.character(products)))),products_file,auto_unbox=TRUE)
  status <- system2('python3',c(shQuote(file.path(root,'src/section232_semiconductors.py')),
    '--pdf',shQuote(pdf),'--hts',shQuote(hts),'--revision',shQuote(revision_id),
    '--products',shQuote(products_file),'--output',shQuote(output)))
  if(status!=0L) stop('Semiconductor historical reconciliation failed; refusing static fallback')
  jsonlite::fromJSON(output,simplifyVector=FALSE)
}

suppressPackageStartupMessages(library(tidyverse))
source('src/extract_note_scope.R')
source('src/scrape_us_notes.R')
x <- extract_numbered_product_scope('(1) 1901.10.10\n(2) N95 respirators described in 6307.90.9842 or 6307.90.9844\n(3) Battery for vehicles of 8703.40, described in 8507.60.0010', 'source', 'note 31(b)')
stopifnot(nrow(x)==4, x$hts_prefix[1]=='19011010',
  setequal(x$hts_exact[-1],c('6307909842','6307909844','8507600010')),
  all(is.na(x$hts_prefix[-1])),grepl('vehicles',x$source_text[4]),
  identical(normalize_to_hts8('1901.10.10'),'19011010'),
  '1901.10.10' %in% extract_hts_codes('1901.10.10'))
for(code in c('6307.90.9842','8471.50','8703')) stopifnot(inherits(try(normalize_to_hts8(code),silent=TRUE),'try-error'))
stopifnot(inherits(try(extract_numbered_product_scope('Unbounded 6307.90.9842','s','note'),silent=TRUE),'try-error'))
cat('Exact scope, chapter 19 and lossy-extraction safeguards passed\n')


# A real source enumeration, bounded by note subdivisions, is independent of
# the polluted legacy lookup. Five mask/respirator codes are not all of HTS8.
meta <- jsonlite::fromJSON('resources/legal_evidence/2024-21217/source.json')
file <- 'resources/legal_evidence/2024-21217/notice.txt'
stopifnot(digest::digest(file=file,algo='sha256')==meta$sha256)
text <- paste(readLines(file,warn=FALSE),collapse='\n')
span <- bounded_legal_source_span(text,'(?m)^.*\\(h\\) Heading 9903\\.91\\.07 applies to',
  '(?m)^.*\\(i\\) Heading 9903\\.91\\.08 applies to',meta$source_id,'Annex C paragraph 4, note 31(h)')
scope <- extract_numbered_product_scope(span$source_text,span$source_id,span$locator)
stopifnot(nrow(scope)==5,all(is.na(scope$hts_prefix)),
  setequal(scope$hts_exact,c('6307909842','6307909844','6307909850','6307909870','6307909875')),
  !'6307909891' %in% scope$hts_exact,all(grepl('respirators|Respirators|masks',scope$source_text)))
stopifnot(inherits(try(bounded_legal_source_span(text,'Heading','absent','s','l'),silent=TRUE),'try-error'))
stopifnot(identical(extract_hts_codes('8703.23.01.90 9802.00.80 9903.94.05'),'8703.23.01.90'))
stopifnot(inherits(try(normalize_to_hts8(extract_hts_codes('8703.23.01.90')),silent=TRUE),'try-error'))
cat('Primary note 31(h) exact-scope and bounded-source regression passed\n')

# Narrow extraction primitive for a legally identified numbered enumeration.
# The caller supplies a bounded note subdivision, not everything until the next
# heading mentioned somewhere in the document. Descriptive conditions are kept.
extract_numbered_product_scope <- function(text, source_id, locator) {
  if (!is.character(text) || length(text)!=1 || !nzchar(source_id) || !nzchar(locator))
    stop('A bounded source span and provenance are required')
  starts <- gregexpr('(?m)^\\s*\\([0-9]+\\)\\s*',text,perl=TRUE)[[1]]
  if(starts[1]<0) stop('No numbered product enumeration')
  out <- list()
  for(i in seq_along(starts)) {
    span <- trimws(substr(text,starts[i],if(i<length(starts)) starts[i+1]-1 else nchar(text)))
    number <- as.integer(regmatches(span,regexec('^\\(([0-9]+)\\)',span))[[1]][2])
    # 8/10-digit provisions only; 6-digit references in descriptions are not
    # broadened/padded into subheadings. Keep the original span for legal review.
    codes <- unique(regmatches(span,gregexpr('(?<![0-9.])[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}(?:\\.?[0-9]{2})?(?![0-9.])',span,perl=TRUE))[[1]])
    codes <- codes[!grepl('^(98|99)',codes)]
    if(!length(codes)) stop('Enumeration has no eligible 8/10-digit scope at item ',number)
    for(code in codes) {
      clean<-gsub('\\.','',code)
      out[[length(out)+1L]]<-data.frame(item=number, hts_exact=if(nchar(clean)==10) clean else NA_character_,
        hts_prefix=if(nchar(clean)==8) clean else NA_character_, source_id=source_id,
        source_locator=paste0(locator,' item ',number),source_text=span, stringsAsFactors=FALSE)
    }
  }
  do.call(rbind,out)
}


# Explicit, unique legal boundaries keep an enumeration from swallowing another
# note. Callers retain the source version and choose reviewed locator patterns;
# a heading mention alone is not a list boundary or proof of applicability.
bounded_legal_source_span <- function(text, start_pattern, end_pattern, source_id, locator) {
  if(length(text)!=1L || !is.character(text) || !nzchar(source_id) || !nzchar(locator))
    stop('Source text and provenance required')
  starts <- gregexpr(start_pattern,text,perl=TRUE)[[1]]
  if(starts[1]<0 || length(starts)!=1L) stop('Ambiguous or missing legal start boundary')
  remaining <- substring(text,starts[1])
  ends <- gregexpr(end_pattern,remaining,perl=TRUE)[[1]]
  if(ends[1]<0 || length(ends)!=1L || ends[1]<=1L) stop('Ambiguous or missing legal end boundary')
  span <- substr(remaining,1L,ends[1]-1L)
  list(source_id=source_id,locator=locator,start_offset=as.integer(starts[1]),
    end_offset_exclusive=as.integer(starts[1]+ends[1]-1L),source_text=span)
}

# Source census and links to emitted rules; never prices a shipment or grants
# legal coverage. Full note text is normalized once and joined by note ID/hash.
emit_chapter99_inventory <- function(revision,output_dir,fragment_files=character(),root=here::here()) {
  if(!grepl('^202[56]_(basic|rev_[0-9]+)$',revision)) stop('Identified inventory revision required')
  pdf<-file.path(root,'data/us_notes',paste0('chapter99_',revision,'.pdf'))
  hts<-file.path(root,'data/hts_archives',paste0('hts_',revision,'.json'))
  tmp<-tempfile(fileext='.json');on.exit(unlink(tmp),add=TRUE)
  args<-c(shQuote(file.path(root,'src/chapter99_inventory.py')),'--pdf',shQuote(pdf),'--hts',shQuote(hts),
    '--revision',shQuote(revision),'--output',shQuote(tmp),
    unlist(lapply(fragment_files,function(p)c('--fragment',shQuote(normalizePath(p,mustWork=TRUE))))))
  status<-system2('python3',args)
  if(status!=0L) stop('Chapter 99 inventory reconciliation failed; no missing-provision fallback')
  x<-jsonlite::fromJSON(tmp,simplifyVector=FALSE)
  json<-function(v)as.character(jsonlite::toJSON(v,auto_unbox=TRUE,null='null',digits=NA))
  scalar<-function(v)if(is.null(v)) NA_character_ else as.character(v)
  provisions<-lapply(x$provisions,function(p) {
    row<-data.frame(revision=revision,reporting_code=p$reporting_code,presence=p$presence,
      structural_parent=p$structural_parent,description=p$description,duty_expression=p$duty_expression,
      expression_source_code=scalar(p$expression_source_code),native_record_sha256=scalar(p$native_record_sha256),
      authority=scalar(p$authority),status=p$status,snapshot_status=p$snapshot_status,
      reference_membership_is_discovery_only=TRUE,stringsAsFactors=FALSE)
    for(k in c('native_record','note_evidence','referenced_product_codes','referenced_reporting_codes',
               'legal_intervals','linked_authorities','rule_links','unresolved_aspects','executable_gaps','questions')) row[[paste0(k,'_json')]]<-json(p[[k]])
    row$pdf_sha256<-x$sources[[1]]$sha256;row$hts_sha256<-x$sources[[2]]$sha256
    row$inventory_compiler_sha256<-x$compiler_sha256
    row
  })
  provisions<-do.call(rbind,provisions)
  notes<-data.frame(revision=character(),note_id=character(),subchapter=character(),note_number=character(),
    source_locator=character(),source_text=character(),source_text_sha256=character(),
    referenced_product_codes_json=character(),referenced_reporting_codes_json=character(),stringsAsFactors=FALSE)
  if(length(x$notes)) notes<-do.call(rbind,lapply(x$notes,function(n)data.frame(revision=revision,note_id=n$id,
    subchapter=n$subchapter,note_number=n$number,source_locator=n$locator,source_text=n$text,source_text_sha256=n$sha256,
    referenced_product_codes_json=json(n$referenced_product_codes),referenced_reporting_codes_json=json(n$referenced_reporting_codes),stringsAsFactors=FALSE)))
  dir.create(output_dir,recursive=TRUE,showWarnings=FALSE)
  arrow::write_parquet(provisions,file.path(output_dir,'chapter99_provisions.parquet'))
  arrow::write_parquet(notes,file.path(output_dir,'chapter99_notes.parquet'))
  x$notes<-NULL;x$provisions<-NULL
  jsonlite::write_json(x,file.path(output_dir,'chapter99_inventory_sources.json'),auto_unbox=TRUE,null='null',digits=NA)
  invisible(list(provisions=nrow(provisions),notes=nrow(notes)))
}

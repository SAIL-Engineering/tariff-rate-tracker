suppressPackageStartupMessages(library(tidyverse))
stopifnot(file.exists('src/chapter99_inventory.R'))
source('src/helpers.R');source('src/ieepa_reciprocal_revision.R');source('src/chapter99_inventory.R')
out<-tempfile('inventory-');dir.create(out)
fragment<-compile_reciprocal_initial_fragment(load_reciprocal_scope('2025_rev_8'),c('0106199120','8528520000'))
path<-file.path(out,'reciprocal_rules.json')
jsonlite::write_json(fragment,path,auto_unbox=TRUE,null='null',digits=NA)
emit_chapter99_inventory('2025_rev_8',out,fragment_files=path)
provisions<-arrow::read_parquet(file.path(out,'chapter99_provisions.parquet'))
notes<-arrow::read_parquet(file.path(out,'chapter99_notes.parquet'))
meta<-jsonlite::fromJSON(file.path(out,'chapter99_inventory_sources.json'),simplifyVector=FALSE)
native<-provisions[provisions$presence=='native_heading',]
raw<-jsonlite::fromJSON('data/hts_archives/hts_2025_rev_8.json',simplifyVector=FALSE)
codes<-vapply(Filter(function(r)startsWith(r$htsno %||% '','99'),raw),`[[`,character(1),'htsno')
stopifnot(nrow(native)==3448L,setequal(native$reporting_code,codes),all(c('9903.01.63','9902.01.01','9903.92') %in% provisions$reporting_code),
  all(provisions$revision=='2025_rev_8'),all(provisions$status %in% c('linked_rules_partial','unresolved_source')),
  length(meta$coverage)==0L,nrow(notes)>0L,all(nzchar(notes$source_text)),all(nchar(notes$source_text_sha256)==64L))
china<-provisions[provisions$reporting_code=='9903.01.63',]
links<-jsonlite::fromJSON(china$rule_links_json,simplifyVector=FALSE)
stopifnot(length(links)>0L,any(vapply(links,function(r)'5700' %in% unlist(r$scope$countries),logical(1))),
  all(vapply(links,function(r)r$authority=='ieepa_reciprocal',logical(1))))
expired<-provisions[provisions$reporting_code=='9902.01.01',]
stopifnot(expired$snapshot_status=='source_declares_expired',expired$status=='unresolved_source',expired$legal_intervals_json=='[]')
stopifnot(!any(c('shipment_total','complete_total','statutory_rate') %in% names(provisions)))
unlink(out,recursive=TRUE)
cat('Chapter 99 typed inventory and real-source reciprocal links passed\n')

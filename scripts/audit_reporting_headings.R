# Source-only research inventory; no rate/revision build and no database writes.
# A discovery authority label is not an applicability or absence determination.
args<-commandArgs(trailingOnly=TRUE)
if(length(args)!=1L || file.exists(args[1])) stop('Usage: NEW_OUTPUT_DIRECTORY')
suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/section232_revision.R')
revisions<-strsplit(readLines('docs/audits/2026-10-23-motherduck/rebuild-revisions.txt'),',',fixed=TRUE)[[1]]
dir.create(args[1],recursive=TRUE)
report<-list(audit='Reporting-heading source inventory and note16 conditional compilation; not complete legal coverage',
  cutoff='2026-10-22',script_sha256=digest::digest(file='scripts/audit_reporting_headings.R',algo='sha256'),revisions=list())
write_gzip<-function(value,path) { con<-gzfile(path,'wt');on.exit(close(con));
  writeLines(jsonlite::toJSON(value,auto_unbox=TRUE,null='null',na='null',digits=NA),con) }
for(rev in revisions) {
  path<-paste0('data/hts_archives/hts_',rev,'.json')
  raw<-jsonlite::fromJSON(path,simplifyVector=FALSE)
  x<-load_s232_note16_source(rev)
  products<-sort(unique(vapply(Filter(function(r) grepl('^[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}\\.?[0-9]{2}$',r$htsno %||% '') &&
    substr(r$htsno,1,2)<'98',raw),function(r) gsub('[.]','',r$htsno),character(1))))
  f<-if(isTRUE(x$active_regime)) compile_s232_note16_fragment(x,products) else NULL
  headings<-Filter(function(r) grepl('^990[0-9]\\.[0-9]{2}\\.[0-9]{2}$',r$htsno %||% ''),raw)
  inventory<-lapply(headings,function(r) {
    code<-r$htsno
    matched<-Filter(function(d) code %in% unlist(d$reporting_codes),f$reporting_decisions)
    list(code=code,discovery_authority=classify_authority(code),
      status=if(length(matched)) 'conditional_decision_compiled' else 'outside_note16_compiler_requires_program_review',
      descriptions=r$description,duty_expression=r$general,special_expression=r$special,other_expression=r$other,
      source_row_sha256=digest::digest(jsonlite::toJSON(r,auto_unbox=TRUE,null='null'),algo='sha256',serialize=FALSE),
      compiled_rule_ids=lapply(matched,`[[`,'rule_id'),
      source_discrepancies=unique(unlist(lapply(Filter(function(d)
        d$status=='requires_source_reconciliation',matched),`[[`,'reason'))))
  })
  write_gzip(list(revision=rev,source_sha256=digest::digest(file=path,algo='sha256'),
    source_url=paste0('https://hts.usitc.gov/reststop/exportList?release=',build_release_name(rev),'&exportFormat=JSON'),
    inventory=inventory),file.path(args[1],paste0(rev,'-inventory.json.gz')))
  if(!is.null(f)) write_gzip(f,file.path(args[1],paste0(rev,'-note16.json.gz')))
  report$revisions[[rev]]<-list(published_headings=length(inventory),
    source_sha256=digest::digest(file=path,algo='sha256'),active_note16=isTRUE(x$active_regime),
    note16_rules=length(f$rules),
    matched_products=length(unique(unlist(lapply(f$rules,function(r) r$scope$hts_exact)))),
    origins=length(unique(unlist(lapply(f$rules,function(r) r$scope$countries)))),
    formula_discrepancies=unique(unlist(lapply(Filter(function(d)
      d$status=='requires_source_reconciliation',f$reporting_decisions),`[[`,'reason'))),
    compiler_sha256=f$compiler_sha256,semantic_review_sha256=f$semantic_review_sha256,
    extraction_sha256=x$extractor_sha256)
  cat(rev,':',length(inventory),'source headings;',length(f$rules),'note16 rules\n')
}
jsonlite::write_json(report,file.path(args[1],'report.json'),auto_unbox=TRUE,pretty=TRUE,null='null',digits=NA)

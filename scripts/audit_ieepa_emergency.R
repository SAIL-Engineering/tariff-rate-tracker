# Source-only audit of all configured revisions; no rate/timeseries rebuild.
# Optional read-only MotherDuck export is reconciled to the ordinary branch,
# not certified as a shipment total or a calculation of financial exposure.
args<-commandArgs(trailingOnly=TRUE)
if(length(args)<1L||length(args)>2L||file.exists(args[1])) stop('Usage: NEW_OUTPUT_DIR [READ_ONLY_MOTHERDUCK.json]')
suppressPackageStartupMessages({library(tidyverse);library(here)})
source('src/helpers.R');source('src/05_parse_policy_params.R');source('src/legal_intervals.R')
source('src/section301_revision.R')
lookup<-build_country_lookup('resources/census_codes.csv');rd<-load_revision_dates();pp<-load_policy_params()
revs<-strsplit(readLines('docs/audits/2026-10-23-motherduck/rebuild-revisions.txt'),',',fixed=TRUE)[[1]]
dir.create(args[1],recursive=TRUE)
report<-list(audit='Revision-bound emergency actions and legal-event calendar; not full shipment coverage',
  revisions=list(),extractor_sha256=digest::digest(file='src/ieepa_fentanyl_sources.py',algo='sha256'),
  selector_sha256=digest::digest(file='src/ieepa_fentanyl.R',algo='sha256'),
  calendar_sha256=digest::digest(file='src/legal_intervals.R',algo='sha256'))
selected<-list()
for(rev in revs) {
  day<-rd$effective_date[match(rev,rd$revision)]
  x<-load_ieepa_emergency_source(rev);rows<-emergency_source_rows(x,lookup)
  active<-select_ieepa_emergency_actions(rows,day,daily=TRUE)
  events<-list(country=load_ieepa_country_amendments(),emergency=x,stacking=load_stacking_rules(),
    section301=load_s301_revision_source(rev,download=FALSE),
    section338=jsonlite::fromJSON(pp$SECTION_338$amendments_file,simplifyVector=FALSE))
  segments<-revision_legal_segments(rev,rd,pp,events)
  segments<-segments[segments$valid_from<=as.Date('2026-10-22'),]
  segments$valid_until<-pmin(segments$valid_until,as.Date('2026-10-22'))
  report$revisions[[rev]]<-list(entry_day=as.character(day),collection_ended=has_ieepa_collection_ended(day),
    ordinary_parameters=ordinary_emergency_parameters(active),legal_intervals=segments,
    sources=x$sources,additional_sources=x$additional_sources,action_count=length(x$actions))
  selected[[rev]]<-active
  con<-gzfile(file.path(args[1],paste0(rev,'.json.gz')),'wt')
  writeLines(jsonlite::toJSON(x,auto_unbox=TRUE,pretty=TRUE,null='null',na='null',digits=NA),con);close(con)
  cat(rev,':',nrow(active),'active parameter candidates;',nrow(segments),'daily legal states\n')
}
if(length(args)==2L) {
  live<-jsonlite::fromJSON(args[2],simplifyVector=FALSE)
  if(!identical(live$access_mode,'READ_ONLY')) stop('Not a read-only audit export')
  findings<-list()
  for(row in live$results$emergency) {
    if(is.null(row$statutory_rate_ieepa_fent)||row$statutory_rate_ieepa_fent==0) next
    candidate<-selected[[row$revision]]
    if(is.null(candidate)) stop('Live revision outside source inventory')
    country<-candidate[candidate$census_code==row$country,]
    general<-ordinary_emergency_parameters(country)
    kind<-NULL
    if(has_ieepa_collection_ended(row$valid_from)) kind<-'positive_rate_after_collection_end'
    else if(!row$statutory_rate_ieepa_fent %in% country$rate[country$entry_type %in% c('general','carveout')])
      kind<-if(row$statutory_rate_ieepa_fent %in% country$rate[country$entry_type=='conditional_replacement'])
        'conditional_replacement_as_ordinary_parameter' else 'ordinary_rate_chronology_mismatch'
    if(!is.null(kind)) findings[[length(findings)+1L]]<-c(list(finding=kind,expected_ordinary=general),row)
    ordinary_rate<-nrow(general)==1L && row$statutory_rate_ieepa_fent==general$fent_rate
    if(ordinary_rate && !identical(row$ch99_code_ieepa_fent,general$fent_ch99))
      findings[[length(findings)+1L]]<-c(list(finding='ordinary_reporting_heading_mismatch',expected_ordinary=general),row)
  }
  report$motherduck<-list(snapshot_sha256=digest::digest(file=args[2],algo='sha256'),
    database=live$database,started_at=live$started_at,finished_at=live$finished_at,findings=findings)
}
jsonlite::write_json(report,file.path(args[1],'report.json'),auto_unbox=TRUE,pretty=TRUE,null='null',na='null',digits=NA)
cat('PASS:',length(revs),'revision sources. No timeseries or database writes.\n')

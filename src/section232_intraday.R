# A legal amendment instant is distinct from a daily source-selection date.
# Replay a prior source only for the explicitly reviewed intervening window,
# and only where the native classification hierarchy has stayed identical.
# This does not extrapolate a rate, borrow today's scope, or attest other sectors.
compile_s232_intraday_fragment <- function(revision,products,root=here::here()) {
 source(file.path(root,'src/shipment_build.R'))
 manifest_path<-file.path(root,'resources/legal_evidence/section232/intraday-transitions.json')
 manifest<-jsonlite::fromJSON(manifest_path,simplifyVector=FALSE)
 if(!identical(manifest$contract_version,'sail.section232-intraday-transitions/v1'))stop('Unknown intraday legal review')
 selection<-shipment_source_selection_window(revision,root)
 transitions<-Filter(function(t)substr(t$effective_from,1,10)==substr(selection$from,1,10)&&
  .shipment_time(t$effective_from)>.shipment_time(selection$from),manifest$transitions)
 if(!length(transitions))return(NULL)
 if(length(transitions)!=1L)stop('Ambiguous intraday amendment clock')
 event<-transitions[[1]];start<-selection$from;until<-event$effective_from
 s<-event$source;path<-file.path(root,s$path)
 if(!file.exists(path)||!identical(digest::digest(file=path,algo='sha256'),s$sha256))stop('Changed intraday primary source')
 text<-if(grepl('\\.pdf$',path))paste(system2('pdftotext',c('-layout',shQuote(path),'-'),stdout=TRUE),collapse=' ') else paste(readLines(path,warn=FALSE),collapse=' ')
 text<-gsub('\\s+',' ',text,perl=TRUE)
 if(!all(vapply(s$required_text,function(q)grepl(q,text,fixed=TRUE),logical(1))))stop('Unreconciled amendment clock')
 # Use the preceding build source, then independently check the latest
 # published metal snapshot. A retroactive unrelated policy date can reorder
 # releases; it must not quietly choose different historical metal semantics.
 calendar<-read.csv(file.path(root,'config/revision_dates.csv'),colClasses='character')
 earlier<-calendar[calendar$effective_date<substr(until,1,10),,drop=FALSE]
 if(!nrow(earlier))stop('Missing archived predecessor')
 published_previous<-earlier$revision[which.max(as.Date(earlier$effective_date))]
 build_calendar<-load_revision_dates(file.path(root,'config/revision_dates.csv'),use_policy_dates=TRUE)
 build_earlier<-build_calendar[build_calendar$effective_date<as.Date(substr(until,1,10)),,drop=FALSE]
 previous<-build_earlier$revision[which.max(build_earlier$effective_date)]
 old<-load_shipment_base_source(previous,root);now<-load_shipment_base_source(revision,root)
 bycode<-function(x)setNames(x$products,vapply(x$products,`[[`,character(1),'hts10'))
 old_products<-bycode(old);new_products<-bycode(now)
 stable<-vapply(sort(unique(products)),function(p) {
  a<-old_products[[p]];b<-new_products[[p]]
  !is.null(a)&&!is.null(b)&&identical(a$native_code,b$native_code)&&
   identical(a$classification_path,b$classification_path)
 },logical(1))
 unchanged<-names(stable)[stable];changed<-names(stable)[!stable]
 if(event$prior_compiler=='legacy_metals') {
  source(file.path(root,'src/section232_legacy.R'))
  extraction<-load_s232_legacy_source(previous,root)
  latest<-load_s232_legacy_source(published_previous,root)
  keys<-c('regime','lists','clauses','headings')
  fragment<-compile_s232_legacy_fragment(extraction,unchanged)
 } else if(event$prior_compiler=='note16_metals') {
  source(file.path(root,'src/section232_revision.R'))
  extraction<-load_s232_note16_source(previous,root)
  latest<-load_s232_note16_source(published_previous,root)
  keys<-c('lists','clauses','headings','external_headings','parameters')
  fragment<-compile_s232_note16_fragment(extraction,unchanged)
 } else stop('Unknown predecessor compiler')
 if(!all(vapply(keys,function(k)identical(extraction[[k]],latest[[k]]),logical(1))))
  stop('Build predecessor disagrees with the latest published metal treatment')
 cutoff<-fragment$supported_until
 if(.shipment_time(cutoff)!=.shipment_time(start))stop('Predecessor source does not meet the reviewed amendment window')
 if(any(vapply(fragment$rules,function(r)!is.null(r$scope$from)&&.shipment_time(r$scope$from)>=.shipment_time(cutoff),logical(1))))
  stop('Predecessor includes future rules; reconcile their activation before replay')
 # Calendar clipping is lifted only at this exact, verified cutover. An earlier
 # independently ending action is never extended to fill a gap.
 kept<-Filter(function(r)is.null(r$scope$until)||.shipment_time(r$scope$until)>=.shipment_time(cutoff),fragment$rules)
 removed<-setdiff(vapply(fragment$rules,`[[`,character(1),'id'),vapply(kept,`[[`,character(1),'id'))
 if(length(removed))stop('Predecessor has separately ending rules; reconcile their relationships before replay')
 prefix<-paste0('intraday_',previous,'_')
 mapping<-setNames(paste0(prefix,vapply(kept,`[[`,character(1),'id')),vapply(kept,`[[`,character(1),'id'))
 remap<-function(x) {
  if(is.character(x))return(vapply(x,function(y)if(y%in%names(mapping))mapping[[y]] else y,character(1),USE.NAMES=FALSE))
  if(is.list(x))lapply(x,remap) else x
 }
 fragment<-remap(fragment);fragment$id<-paste0('s232_intraday_',revision)
 for(i in seq_along(fragment$rules)) {
  fragment$rules[[i]]$scope$from<-start;fragment$rules[[i]]$scope$until<-until
 }
 source_id<-s$id
 fragment$sources<-c(fragment$sources,list(c(s[c('id','sha256','url','citation')],list(status='verified'))))
 fragment$source_artifacts<-c(fragment$source_artifacts,list(list(source_id=source_id,path=normalizePath(path),sha256=s$sha256)))
 # The classification comparison and independent publication check are part of
 # this decision's evidence, even where their rates are not selected for replay.
 additional<-c(list(now$source),if(published_previous!=previous)latest$sources else list())
 decision_sources<-source_id
 for(j in seq_along(additional)) {
  evidence<-additional[[j]];sid<-paste0(fragment$id,'_source_check_',j)
  evidence_path<-normalizePath(evidence$path)
  release<-sub('_rev_','HTSRev',published_previous)
  fallback_url<-if(grepl('\\.json$',evidence_path))paste0('https://hts.usitc.gov/reststop/exportList?release=',release,'&exportFormat=JSON') else
   paste0('https://hts.usitc.gov/reststop/file?release=',release,'&filename=Chapter%2099')
  fragment$sources[[length(fragment$sources)+1L]]<-list(id=sid,status='verified',sha256=evidence$sha256,
   url=evidence$url %||% fallback_url,
   citation='Native classification identity and independent preceding-publication metal-semantics comparison; not a rate override.')
  fragment$source_artifacts[[length(fragment$source_artifacts)+1L]]<-list(source_id=sid,path=evidence_path,sha256=evidence$sha256)
  decision_sources<-c(decision_sources,sid)
 }
 for(i in seq_along(fragment$rules))fragment$rules[[i]]$source_ids<-as.list(sort(unique(c(unlist(fragment$rules[[i]]$source_ids),decision_sources))))
 if(length(changed))fragment$rules[[length(fragment$rules)+1L]]<-list(id=paste0(fragment$id,'_classification_question'),
  action_id='s232_intraday_classification',authority='section_232',kind='duty',verification='verified',
  scope=list(hts_exact=as.list(changed),from=start,until=until),formula=list(unresolved_source='intraday_predecessor_classification_changed'),
  reporting_codes=list(),source_ids=as.list(decision_sources))
 # Historical scope/rate replay cannot establish privileged admission treatment.
 fragment$fact_definitions$ieepa_ftz_entry<-list(type='boolean',label='Entry from a foreign trade zone',source_ids=list(source_id))
 fragment$entry_context<-list(mode='ordinary_only',fact='ieepa_ftz_entry',source_ids=list(source_id),
  unresolved_source='intraday_metal_ftz_admission_history_requires_separate_rule')
 fragment$supported_from<-start;fragment$supported_until<-until
 fragment$temporal_replay<-list(previous_revision=previous,latest_published_revision=published_previous,effective_from=until,source_ids=list(source_id),
  identical_classification_products=as.list(unchanged),unresolved_classification_products=as.list(changed),
  qualification='Predecessor steel/aluminum or note16 decisions only; no all-sector or PF-history coverage attested.')
 fragment$compiler_dependencies$intraday<-digest::digest(file=file.path(root,'src/section232_intraday.R'),algo='sha256')
 fragment$compiler_dependencies$intraday_review<-digest::digest(file=manifest_path,algo='sha256')
 fragment$compiler_dependencies$source_calendar<-digest::digest(file=file.path(root,'config/revision_dates.csv'),algo='sha256')
 fragment$compiler_dependencies$classification_extractor<-digest::digest(file=file.path(root,'src/shipment_base_sources.py'),algo='sha256')
 fragment
}

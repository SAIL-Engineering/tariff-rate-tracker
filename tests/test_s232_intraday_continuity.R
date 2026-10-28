suppressPackageStartupMessages(library(tidyverse))
source('src/helpers.R');source('src/compile_shipment_rules.R')
source('src/section232_revision.R');source('src/section232_intraday.R')
products<-c('7318158085','8403100000')
bundles<-list();cases<-list()
for(revision in c('2026_rev_5','2026_rev_10')) {
 current<-compile_s232_note16_fragment(load_s232_note16_source(revision),products)
 prior<-compile_s232_intraday_fragment(revision,products)
 stopifnot(!is.null(prior),length(prior$rules)>0,prior$supported_until==current$supported_from)
 template<-jsonlite::fromJSON('tests/fixtures/shipment/conformance.json',simplifyVector=FALSE)[[1]]$bundle
 template$revision<-revision;template$dataset_version<-'source-intraday-continuity-not-release'
 template$products<-as.list(products);template$countries<-list('5700')
 template$rules<-template$coverage<-template$claim_definitions<-template$sources<-list()
 template$fact_definitions<-list();template$coverage_requirements<-list('section_232','base')
 # Fragment horizons deliberately differ. The normal assembler selects each
 # half-open interval; neither compiler is extended across the actual amendment.
 for(pair in list(list(id=paste0(revision,'_before'),fragment=prior),list(id=paste0(revision,'_after'),fragment=current))) {
  b<-template;b$valid_from<-pair$fragment$supported_from;b$valid_until<-pair$fragment$supported_until
  bundles[[pair$id]]<-compose_shipment_rules(b,list(pair$fragment))
 }
 # Exercise the same temporal assembly used by the normal Parquet emitter.
 # This is a two-product rule-only point check, not a revision/rates rebuild.
 base_fragment<-compile_shipment_base_fragment(load_shipment_base_source(revision),products,'5700')
 temp<-tempfile();dir.create(temp)
 index<-assemble_shipment_state(revision,products,'5700',as.Date(substr(prior$supported_from,1,10)),
  as.Date(substr(prior$supported_from,1,10)),list(base_fragment,current,prior),
  list(dataset_version='intraday-normal-assembly-test',evidence_snapshot_id='primary-source-test',input_manifest=list()),temp)
 stopifnot(length(index$bundles)==2L,.shipment_time(index$bundles[[1]]$valid_until)==.shipment_time(prior$supported_until),
  .shipment_time(index$bundles[[2]]$valid_from)==.shipment_time(current$supported_from))
 first<-jsonlite::fromJSON(file.path(temp,index$bundles[[1]]$path),simplifyVector=FALSE)
 stopifnot(any(startsWith(vapply(first$rules,`[[`,character(1),'id'),'intraday_')))
 unlink(temp,recursive=TRUE)
}
facts<-list(customs_value=100,ieepa_ftz_entry=FALSE,steel_weight_fraction=1,us_steel_origin_fraction=.9,
 contains_steel=TRUE,steel_content_value=20,steel_processed_from_us_metal=FALSE,
 s232_auto_parts_use=FALSE,privileged_ftz_before_20250312=FALSE,privileged_ftz_before_20250604=FALSE)
add<-function(name,revision,side,at,amount,code,f=facts) {
 key<-paste0(revision,'_',side);r<-evaluate_shipment_bundle(bundles[[key]],products[1],'5700',at,f)
 applied<-Filter(function(c)c$status=='applied',r$components)
 if(r$known_subtotal!=amount||length(r$missing_inputs))print(list(name=name,result=r[c('known_subtotal','missing_inputs','source_errors')]))
 stopifnot(r$known_subtotal==amount,code%in%unlist(lapply(applied,`[[`,'reporting_codes')),
  !length(r$missing_inputs),is.null(r$complete_total))
 cases[[length(cases)+1L]]<<-list(name=name,bundle=key,hts10=products[1],country='5700',entry_at=at,facts=f,expected=shipment_result_for_json(r))
}
add('April predecessor content valuation','2026_rev_5','before','2026-04-06T00:00:59-04:00',10,'9903.81.90')
add('April whole article at exact amendment','2026_rev_5','after','2026-04-06T00:01:00-04:00',50,'9903.82.02')
add('June predecessor domestic threshold','2026_rev_10','before','2026-06-08T00:00:59-04:00',50,'9903.82.02')
add('June amended domestic threshold','2026_rev_10','after','2026-06-08T00:01:00-04:00',10,'9903.82.06')
# A fragment replay is not a PF admission/history implementation.
q<-facts;q$ieepa_ftz_entry<-TRUE
for(key in c('2026_rev_5_before','2026_rev_10_before')) {
 b<-bundles[[key]];r<-evaluate_shipment_bundle(b,products[1],'5700',b$valid_from,q)
 stopifnot(!any(vapply(r$components,function(c)c$status=='applied',logical(1))),is.null(r$complete_total))
 cases[[length(cases)+1L]]<-list(name=paste(key,'requires FTZ history'),bundle=key,hts10=products[1],country='5700',entry_at=b$valid_from,facts=q,expected=shipment_result_for_json(r))
}
stopifnot(is.null(compile_s232_intraday_fragment('2026_rev_19',products)))
if('--emit'%in%commandArgs(trailingOnly=TRUE)) {
 out<-gzfile('tests/fixtures/shipment/metal-intraday.json.gz','wb')
 writeBin(charToRaw(jsonlite::toJSON(list(bundles=bundles,cases=cases),auto_unbox=TRUE,null='null',digits=NA)),out);close(out)
}
cat(length(cases),'source-bound intraday metal R/TypeScript cases passed\n')
